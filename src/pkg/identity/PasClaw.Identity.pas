(*
  PasClaw.Identity -- canonical sender identity propagated from each
  channel's inbound boundary down through the agent loop, hooks, and
  audit logs. Ports picoclaw's pkg/identity/identity.go pattern: every
  message gets tagged with `<platform>:<id>` (e.g. "slack:U12345",
  "telegram:5551234567", "matrix:@eli:matrix.org"), and channels
  consult an allowlist before invoking the agent.

  Why one record, not 14 channel-specific ones: tools and hooks
  shouldn't have to know which channel a turn came from to gate on
  identity. Canonical "<platform>:<id>" strings sort, log, and match
  uniformly. Display name and room id ride along for richer logging
  but aren't required for the canonical form.

  Allowlist syntax:
    "slack:U12345"        exact match
    "slack:*"             every Slack user
    "*"                   anyone (effectively allow-all)
    "matrix:@eli:*"       wildcard suffix on a single platform
  No regex -- keep this dumb. Allowlist empty means "no gate"; an
  embedder who wants to deny-all configures `["nobody"]` or sets
  IsAllowedSender's result to False manually.
*)
unit PasClaw.Identity;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

type
  TIdentity = record
    Source:   string;   { 'cli' | 'tui' | 'gateway' | 'cron' | 'slack' |
                          'telegram' | 'discord' | 'line' | 'whatsapp' |
                          'matrix' | 'irc' | 'email' | 'webhook' | ''
                          ('' = unknown / not propagated) }
    UserId:   string;   { platform-native id -- Telegram chat id as string,
                          Slack U..., Matrix @eli:server, email From,
                          IRC nick, etc. Empty for sources like 'cron'. }
    UserName: string;   { display name when the inbound payload carries one;
                          empty otherwise. Never used as a key -- log/UI only. }
    RoomId:   string;   { channel / room / group id when applicable --
                          Slack channel, Matrix room, Telegram chat for
                          group messages. Empty for 1:1. }
  end;

{ Build the canonical "<platform>:<id>" string for hashing / logging /
  allowlist matching. Returns '' when either component is empty --
  callers can check for the empty case to handle "no identity known". }
function BuildCanonicalID(const Platform, Id: string): string;

{ Parse a canonical string back into its components. Returns False
  when the string doesn't have a colon (no platform prefix). The
  rightmost colon decides the split so Matrix MXIDs like
  "@eli:matrix.org" survive a platform prefix "matrix:@eli:matrix.org". }
function ParseCanonicalID(const Canon: string; out Platform, Id: string): Boolean;

{ Convenience: canonical id for an in-memory TIdentity. Equivalent to
  BuildCanonicalID(Identity.Source, Identity.UserId). }
function CanonicalOf(const Identity: TIdentity): string;

function MakeIdentity(const Source, UserId: string): TIdentity; overload;
function MakeIdentity(const Source, UserId, UserName, RoomId: string): TIdentity; overload;

(* Allowlist match. Patterns are exact canonical ids or `<platform>:*`
   wildcards; the wildcard form matches every user on that platform.
   The single `*` pattern matches anything (escape hatch for `cron`
   tasks where there is no human sender). Empty allowlist returns
   True -- caller decides whether absence-of-rule means allow or deny
   (channel.IsAllowedSender treats empty as allow, matching picoclaw). *)
function IsAllowedSender(const Identity: TIdentity;
                         const Allowlist: array of string): Boolean;

{ Human-readable one-liner for the per-turn log / /status output.
  Returns 'cli:eli (Eli Snow)' / 'slack:U123' / '(unknown)' etc. }
function FormatIdentity(const Identity: TIdentity): string;

implementation

function BuildCanonicalID(const Platform, Id: string): string;
begin
  if (Platform = '') or (Id = '') then Exit('');
  Result := Platform + ':' + Id;
end;

function ParseCanonicalID(const Canon: string; out Platform, Id: string): Boolean;
var
  Sep: Integer;
begin
  Platform := '';
  Id       := '';
  Sep := Pos(':', Canon);
  if Sep <= 0 then Exit(False);
  Platform := Copy(Canon, 1, Sep - 1);
  Id       := Copy(Canon, Sep + 1, MaxInt);
  Result := (Platform <> '') and (Id <> '');
end;

function CanonicalOf(const Identity: TIdentity): string;
begin
  Result := BuildCanonicalID(Identity.Source, Identity.UserId);
end;

function MakeIdentity(const Source, UserId: string): TIdentity;
begin
  Result.Source   := Source;
  Result.UserId   := UserId;
  Result.UserName := '';
  Result.RoomId   := '';
end;

function MakeIdentity(const Source, UserId, UserName, RoomId: string): TIdentity;
begin
  Result.Source   := Source;
  Result.UserId   := UserId;
  Result.UserName := UserName;
  Result.RoomId   := RoomId;
end;

function MatchPattern(const Canon, Pattern: string): Boolean;
var
  StarPos: Integer;
  Prefix: string;
begin
  if Pattern = '*' then Exit(True);
  if Pattern = Canon then Exit(True);
  StarPos := Pos('*', Pattern);
  if StarPos = 0 then Exit(False);
  { Suffix wildcards only -- the star MUST be the last character of
    the pattern. A malformed entry like "telegram:*admin" would
    otherwise extract prefix "telegram:" and silently broaden to
    every Telegram user. Fail closed: any star not at the end is a
    typo and the pattern matches nothing. Codex P2 on PR #119. }
  if StarPos <> Length(Pattern) then Exit(False);
  Prefix := Copy(Pattern, 1, StarPos - 1);
  Result := (Prefix <> '')
        and (Length(Canon) >= Length(Prefix))
        and (Copy(Canon, 1, Length(Prefix)) = Prefix);
end;

function IsAllowedSender(const Identity: TIdentity;
                         const Allowlist: array of string): Boolean;
var
  Canon: string;
  i: Integer;
begin
  if Length(Allowlist) = 0 then Exit(True);
  Canon := CanonicalOf(Identity);
  if Canon = '' then
  begin
    { No identity known -- only an explicit '*' pattern lets these
      through. Anything more specific implies the operator wants
      to gate by identity, and an unknown sender doesn't meet
      that bar. }
    for i := 0 to High(Allowlist) do
      if Allowlist[i] = '*' then Exit(True);
    Exit(False);
  end;
  for i := 0 to High(Allowlist) do
    if MatchPattern(Canon, Allowlist[i]) then Exit(True);
  Result := False;
end;

function FormatIdentity(const Identity: TIdentity): string;
begin
  if (Identity.Source = '') and (Identity.UserId = '') then Exit('(unknown)');
  Result := CanonicalOf(Identity);
  if Identity.UserName <> '' then
    Result := Result + ' (' + Identity.UserName + ')';
end;

end.
