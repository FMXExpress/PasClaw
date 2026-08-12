(*
  PasClaw.Suite.Mail - filling the Mail app's inbox from IMAP.

  The Mail suite app is an ordinary html app over the per-app state store: a
  list of {subject, from, tag, read}. Until now the only way anything got in
  there was typing it. This is the bridge that fills it from the real inbox.

  Why this is NOT the Email channel. PasClaw.Channels.Email already polls
  IMAP, but it does something different and far more consequential: it routes
  each unseen message THROUGH THE AGENT LOOP and sends an SMTP reply. That is
  a bot answering your mail. This bridge only reads headers and files them --
  no agent, no reply, nothing sent. They share the same credentials and can
  run side by side, because this one deliberately uses RetrievePeek and never
  touches the \Seen flag: filing a message into a list is not reading it, and
  it must not make the message look answered to anything else.

  Triage. Each filed item gets a category the app shows and the user can
  cycle. The rules here are deliberately DUMB -- a keyword pass over the
  subject, no model call -- because this runs on a timer and a per-message
  model call would be a real cost for a guess the user can fix with one
  click. The agent can re-tag them properly when asked; this is the fast path
  that makes the inbox useful the moment it appears.

  Credentials come from the same environment the Email channel uses:

    PASCLAW_EMAIL_IMAP_HOST / _PORT / _USER / _PASS
*)
unit PasClaw.Suite.Mail;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

const
  { The suite project this fills. Fixed on purpose: the bridge exists to
    serve that app, and a caller naming an arbitrary project would be a way
    to write attacker-chosen JSON into any app's store. }
  MailProject = 'mail';

{ True when the IMAP environment is configured. The app shows a different
  message when it isn't, rather than an empty list that looks broken. }
function MailConfigured: Boolean;

{ Fetch recent inbox headers and merge them into the Mail app's state.
  Returns how many NEW items were filed (0 is a normal, healthy answer).
  Never marks anything read on the server. }
function SyncMail(out Filed: Integer; out Err: string): Boolean;

{ The category a subject line suggests: FYI | Request | Decision | Deadline |
  Risk. Exposed for tests -- the rules are the interesting part. }
function TriageSubject(const Subject: string): string;

{ Merge already-fetched headers into the Mail app's state, newest first,
  skipping anything the UID ledger has seen. This is the half of SyncMail with
  no network in it -- and the half where the idempotence lives -- so it is
  exposed for tests, which have no IMAP server to talk to. }
function MergeMail(const UIDs, Subjects, Froms: array of string;
  out Filed: Integer; out Err: string): Boolean;

implementation

uses
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Apps,
  PasClaw.Projects.Store,
  IdIMAP4, IdMessage, IdSSLOpenSSL, IdExplicitTLSClientServerBase;

const
  { Newest N. Small on purpose: see the RetrievePeek note below -- each one
    is a full message fetch, and an inbox of 20k is not a UI anyway. }
  MaxFetch    = 25;
  IOTimeoutMS = 30000;
  StateKey    = 'items';
  SeenKey     = 'seen_uids';

function MailConfigured: Boolean;
begin
  Result := (Trim(GetEnvironmentVariable('PASCLAW_EMAIL_IMAP_HOST')) <> '') and
            (Trim(GetEnvironmentVariable('PASCLAW_EMAIL_IMAP_USER')) <> '');
end;

{ --------------------------------------------------------------- triage -- }

function HasWord(const Hay, Needle: string): Boolean;
begin
  Result := Pos(Needle, LowerCase(Hay)) > 0;
end;

function TriageSubject(const Subject: string): string;
begin
  { Order matters: a subject can hit several rules, and the most consequential
    reading should win. "URGENT: invoice overdue" is a Risk, not a Deadline. }
  if HasWord(Subject, 'urgent') or HasWord(Subject, 'failed') or
     HasWord(Subject, 'outage') or HasWord(Subject, 'overdue') or
     HasWord(Subject, 'security') or HasWord(Subject, 'breach') then
    Exit('Risk');
  if HasWord(Subject, 'due') or HasWord(Subject, 'deadline') or
     HasWord(Subject, 'expires') or HasWord(Subject, 'reminder') or
     HasWord(Subject, 'renewal') then
    Exit('Deadline');
  if HasWord(Subject, 'approve') or HasWord(Subject, 'decision') or
     HasWord(Subject, 'sign off') or HasWord(Subject, 'sign-off') or
     HasWord(Subject, 'confirm') then
    Exit('Decision');
  if HasWord(Subject, 'can you') or HasWord(Subject, 'please') or
     HasWord(Subject, 'request') or HasWord(Subject, 'could you') or
     HasWord(Subject, '?') then
    Exit('Request');
  Result := 'FYI';
end;

{ ----------------------------------------------------------------- sync -- }

type
  TMailItem = record
    UID:     string;
    Subject: string;
    From_:   string;
  end;
  TMailItems = array of TMailItem;

{ Read the inbox's newest headers. Peek only -- see the unit comment. }
function FetchHeaders(out Items: TMailItems; out Err: string): Boolean;
var
  IMAP: TIdIMAP4;
  SSL: TIdSSLIOHandlerSocketOpenSSL;
  Msg: TIdMessage;
  Total, First, I, N: Integer;
begin
  SetLength(Items, 0);
  Err := '';
  Result := False;
  if not MailConfigured then
  begin
    Err := 'IMAP is not configured (set PASCLAW_EMAIL_IMAP_HOST / _USER / _PASS)';
    Exit;
  end;

  IMAP := TIdIMAP4.Create(nil);
  SSL  := TIdSSLIOHandlerSocketOpenSSL.Create(nil);
  try
    SSL.SSLOptions.Method := sslvTLSv1_2;
    SSL.SSLOptions.SSLVersions := [sslvTLSv1_2];
    IMAP.IOHandler := SSL;
    IMAP.UseTLS := utUseImplicitTLS;
    IMAP.Host := GetEnvironmentVariable('PASCLAW_EMAIL_IMAP_HOST');
    IMAP.Port := StrToIntDef(GetEnvironmentVariable('PASCLAW_EMAIL_IMAP_PORT'), 993);
    IMAP.Username := GetEnvironmentVariable('PASCLAW_EMAIL_IMAP_USER');
    IMAP.Password := GetEnvironmentVariable('PASCLAW_EMAIL_IMAP_PASS');
    IMAP.ConnectTimeout := IOTimeoutMS;
    IMAP.ReadTimeout    := IOTimeoutMS;

    try
      IMAP.Connect;
      try
        IMAP.Login;
        IMAP.SelectMailBox('INBOX');
        Total := IMAP.MailBox.TotalMsgs;
        if Total <= 0 then Exit(True);
        First := Total - MaxFetch + 1;
        if First < 1 then First := 1;

        N := 0;
        SetLength(Items, Total - First + 1);
        for I := Total downto First do
        begin
          Msg := TIdMessage.Create(nil);
          try
            (* RetrievePeek (BODY.PEEK[]) rather than RetrieveHeader.

               Indy's RetrieveHeader issues RFC822.HEADER, and RFC 3501 says
               that MARKS THE MESSAGE \Seen. Listing your inbox must not mark
               it read -- that is a bug a user would rightly be angry about,
               and it would also drain the Email channel's unseen set out from
               under it. BODY.PEEK[] is the only fetch that promises not to.

               The cost is real: peek pulls the whole message, so we take a
               small window (MaxFetch) rather than the mailbox. Correctness
               over bytes -- a list view is worth a few hundred KB, and
               silently marking mail read is not worth anything. *)
            if not IMAP.RetrievePeek(I, Msg) then Continue;
            Items[N].UID     := Msg.MsgId;
            if Items[N].UID = '' then
              Items[N].UID := IntToStr(I) + '|' + Msg.Subject;
            Items[N].Subject := Msg.Subject;
            Items[N].From_   := Msg.From.Address;
            Inc(N);
          finally
            Msg.Free;
          end;
        end;
        SetLength(Items, N);
        Result := True;
      finally
        try IMAP.Disconnect; except end;
      end;
    except
      on E: Exception do
      begin
        Err := 'IMAP: ' + E.Message;
        Exit;
      end;
    end;
  finally
    SSL.Free;
    IMAP.Free;
  end;
end;

function MergeMail(const UIDs, Subjects, Froms: array of string;
  out Filed: Integer; out Err: string): Boolean;
var
  Seen, Existing: string;
  SeenList: TStringList;
  Arr, NewArr: TJsonArray;
  Obj: TJsonObject;
  I: Integer;
  Ignored: string;
begin
  Filed := 0;
  Err := '';
  Result := False;

  if not ProjectExists(MailProject) then
  begin
    Err := 'the Mail app is not installed (run: pasclaw project seed)';
    Exit;
  end;

  { The UID ledger is what makes this idempotent: a message already filed
    stays filed once, even after the user deletes it from the list. Deleting
    an item is a decision, and a re-sync must not undo it. }
  SeenList := TStringList.Create;
  try
    if StateGet(MailProject, SeenKey, Seen) then
      SeenList.Text := Seen;
    SeenList.Sorted := True;
    SeenList.Duplicates := dupIgnore;

    { Merge in front of what is already there, newest first. }
    NewArr := TJsonArray.Create;
    try
      for I := 0 to High(UIDs) do
      begin
        if SeenList.IndexOf(UIDs[I]) >= 0 then Continue;
        SeenList.Add(UIDs[I]);
        Obj := TJsonObject.Create;
        Obj.PutStr ('subject', Subjects[I]);
        Obj.PutStr ('from',    Froms[I]);
        Obj.PutStr ('tag',     TriageSubject(Subjects[I]));
        Obj.PutBool('read',    False);
        NewArr.AddObject(Obj);
        Inc(Filed);
      end;

      if StateGet(MailProject, StateKey, Existing) and (Trim(Existing) <> '') then
      begin
        Arr := nil;
        try
          Arr := TJsonArray.Parse(Existing);
        except
          Arr := nil;
        end;
        if Arr <> nil then
          try
            for I := 0 to Arr.Count - 1 do
            begin
              Obj := Arr.ItemObject(I);
              if Obj <> nil then NewArr.AddRaw(Obj.ToJSON);
            end;
          finally
            Arr.Free;
          end;
      end;

      if Filed > 0 then
      begin
        if not StateSet(MailProject, StateKey, NewArr.ToJSON, Err) then Exit;
        if not StateSet(MailProject, SeenKey, SeenList.Text, Ignored) then
          { A lost ledger only means duplicates next time, not data loss --
            not worth failing the sync over. }
          LogWarn('mail: could not persist the seen-uid ledger');
        LogInfo('mail: filed %d new message(s)', [Filed]);
      end;
      Result := True;
    finally
      NewArr.Free;
    end;
  finally
    SeenList.Free;
  end;
end;

function SyncMail(out Filed: Integer; out Err: string): Boolean;
var
  Items: TMailItems;
  UIDs, Subjects, Froms: array of string;
  I: Integer;
begin
  Filed := 0;
  Result := False;
  if not ProjectExists(MailProject) then
  begin
    Err := 'the Mail app is not installed (run: pasclaw project seed)';
    Exit;
  end;
  if not FetchHeaders(Items, Err) then Exit;

  SetLength(UIDs, Length(Items));
  SetLength(Subjects, Length(Items));
  SetLength(Froms, Length(Items));
  for I := 0 to High(Items) do
  begin
    UIDs[I]     := Items[I].UID;
    Subjects[I] := Items[I].Subject;
    Froms[I]    := Items[I].From_;
  end;
  Result := MergeMail(UIDs, Subjects, Froms, Filed, Err);
end;

end.
