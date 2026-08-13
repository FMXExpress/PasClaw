program mail_tests;
(*
  Pins the IMAP -> Mail-app bridge, minus the network.

  Two things in PasClaw.Suite.Mail are worth pinning and neither of them
  needs an IMAP server:

    1. Triage. A keyword pass over the subject line, where the ORDER of the
       rules is the whole design -- a subject that hits several rules must
       get the most consequential reading, not the first one.

    2. The merge. Sync runs on a button and on a timer, so it will see the
       same message many times. Filing it once, and keeping it filed once
       after the user deletes it, is the property that makes the inbox
       usable instead of a growing pile of duplicates.

  MergeMail exists as a separate entry point precisely so this file can
  reach it: the fetch half is Indy and a socket, the merge half is the part
  with the rules in it.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils, StrUtils,
  PasClaw.Utils,
  PasClaw.Projects.Store,
  PasClaw.Apps,
  PasClaw.Suite,
  PasClaw.Suite.Mail;

var
  Failures: Integer = 0;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Inc(Failures);
end;

procedure ExpectStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' -- got "' + Got + '", want "' + Want + '"');
end;

procedure ExpectInt(Got, Want: Integer; const Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' -- got ' + IntToStr(Got) + ', want ' + IntToStr(Want));
end;

procedure ExpectTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure ExpectContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) = 0 then
    Fail_(Msg + ' -- "' + Needle + '" not in: ' + Copy(Haystack, 1, 400));
end;

procedure ExpectMissing(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) > 0 then
    Fail_(Msg + ' -- "' + Needle + '" unexpectedly present');
end;

{ The store pretty-prints, so a needle like '"tag":"Risk"' never matches the
  file as written. Drop the whitespace and assert against the shape. }
function Squeeze(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if not (S[I] in [' ', #9, #10, #13]) then
      Result := Result + S[I];
end;

{ How many items the stored list holds -- one "subject" key per item. }
function CountItems(const Json: string): Integer;
var
  P, At: Integer;
begin
  Result := 0;
  At := 1;
  repeat
    P := PosEx('"subject"', Json, At);
    if P = 0 then Break;
    Inc(Result);
    At := P + 9;
  until False;
end;

procedure Triage(const Subject, Want: string);
begin
  ExpectStr(TriageSubject(Subject), Want, 'triage: ' + Subject);
end;

var
  Err, Items: string;
  Filed, N: Integer;
begin
  { ---------------------------------------------------------- triage -- }
  Triage('Weekly newsletter', 'FYI');
  Triage('Q3 numbers attached', 'FYI');

  Triage('Can you send me the deck', 'Request');
  Triage('Where did we land?', 'Request');
  Triage('Please review when you get a chance', 'Request');

  Triage('Approve the vendor contract', 'Decision');
  Triage('Need your sign-off on the budget', 'Decision');

  Triage('Invoice due Friday', 'Deadline');
  Triage('Your domain renewal', 'Deadline');
  Triage('Reminder: standup moved', 'Deadline');

  Triage('URGENT: production outage', 'Risk');
  Triage('Security alert on your account', 'Risk');

  { Precedence is the point. Each of these matches two rules; the more
    consequential reading has to win, or the important mail sorts under
    the polite mail. }
  Triage('URGENT: invoice overdue', 'Risk');
  ExpectStr(TriageSubject('URGENT: invoice overdue'),
            TriageSubject('outage'), 'risk outranks deadline');
  Triage('Please approve this before it expires', 'Deadline');
  Triage('Can you approve the contract?', 'Decision');

  { --------------------------------------------------------- install -- }
  N := SeedSuite(Err);
  ExpectTrue(N > 0, 'suite seeds');
  ExpectTrue(ProjectExists('mail'), 'the Mail app is a project like any other');

  { ------------------------------------------------------- first sync -- }
  ExpectTrue(MergeMail(['uid-1', 'uid-2'],
                       ['URGENT: disk full on prod', 'Lunch?'],
                       ['ops@example.com', 'sam@example.com'],
                       ['Prod is out of disk.', 'Thursday?'],
                       Filed, Err), 'first merge succeeds: ' + Err);
  ExpectInt(Filed, 2, 'both messages filed');

  ExpectTrue(StateGet('mail', 'items', Items), 'the app has an inbox now');
  ExpectContains(Items, 'disk full on prod', 'subject stored');
  ExpectContains(Items, 'ops@example.com', 'sender stored');
  ExpectContains(Squeeze(Items), '"tag":"Risk"', 'triaged on the way in');
  ExpectContains(Squeeze(Items), '"read":false', 'filing is not reading');
  { The excerpt is what "draft a reply" has to work from -- without it the
    model would be drafting from a subject line. }
  ExpectContains(Items, 'Prod is out of disk.', 'a body excerpt is kept');

  { Excerpts are optional: a caller that has none must still be able to
    file. The bridge always has them, but the merge is the tested seam and
    it should not require what it does not need. }

  { ---------------------------------------------------- re-sync is a nop -- }
  { The same fetch window comes back every poll. Seeing it again must file
    nothing -- this is the difference between an inbox and a duplicate mill. }
  ExpectTrue(MergeMail(['uid-1', 'uid-2'],
                       ['URGENT: disk full on prod', 'Lunch?'],
                       ['ops@example.com', 'sam@example.com'],
                       [],
                       Filed, Err), 're-merge succeeds');
  ExpectInt(Filed, 0, 'nothing filed twice');

  StateGet('mail', 'items', Items);
  ExpectInt(CountItems(Items), 2, 'still exactly two items');

  { -------------------------------------------------------- new arrival -- }
  { Newest first: the caller hands them newest-first and the merge puts the
    batch in front of what was already there. }
  ExpectTrue(MergeMail(['uid-3', 'uid-1'],
                       ['Contract needs your sign-off', 'URGENT: disk full on prod'],
                       ['legal@example.com', 'ops@example.com'],
                       [],
                       Filed, Err), 'third merge succeeds');
  ExpectInt(Filed, 1, 'only the genuinely new one is filed');
  StateGet('mail', 'items', Items);
  ExpectInt(CountItems(Items), 3, 'three items now');
  ExpectTrue(Pos('sign-off', Items) < Pos('disk full', Items),
             'the new message lands in front of the old ones');
  ExpectContains(Squeeze(Items), '"tag":"Decision"', 'and is triaged');
  ExpectContains(Items, 'Lunch?', 'the older items survive the merge');

  { ------------------------------------------------------ deletion sticks -- }
  { Deleting a message is a decision the user made. A sync that re-files it
    would quietly overrule them, which is worse than missing mail. }
  ExpectTrue(StateSet('mail', 'items', '[]', Err), 'user empties the list');
  ExpectTrue(MergeMail(['uid-1', 'uid-2', 'uid-3'],
                       ['URGENT: disk full on prod', 'Lunch?', 'Contract needs your sign-off'],
                       ['ops@example.com', 'sam@example.com', 'legal@example.com'],
                       [],
                       Filed, Err), 'merge after deletion succeeds');
  ExpectInt(Filed, 0, 'deleted messages are not resurrected');
  StateGet('mail', 'items', Items);
  ExpectMissing(Items, 'disk full', 'the list stays as the user left it');

  { --------------------------------------------------------- guardrails -- }
  { Configuration is a state, not an error: the app says so instead of
    showing an empty list that looks broken. }
  ExpectTrue(not MailConfigured, 'no IMAP env in the test environment');

  if Failures = 0 then
    WriteLn('mail_tests: OK')
  else
  begin
    WriteLn('mail_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
