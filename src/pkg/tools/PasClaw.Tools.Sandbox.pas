(*
  PasClaw.Tools.Sandbox - tool-side enforcement for the workspace
  boundary and shell denylist documented in TSandboxPolicy
  (PasClaw.Config).

  The previous shell tool shipped six substring checks (rm -rf /,
  mkfs, dd if=, fork bomb, shutdown -h) and the FS tools had no path
  check at all -- the unit header in PasClaw.Tools.FS.pas said
  "Paths are not sandboxed by default; the gateway will install a
  workspace-restricted variant in Phase 4" and that variant was
  never written. This unit is that variant.

  Architecture: module-level GPolicy / GWorkspace, set once via
  Configure() from each command's startup. Tool handlers receive
  only an ArgsJSON string -- there is no provider context to plumb a
  policy through, so a module-level singleton is the only option.
  Configure() is idempotent and may be called repeatedly; the most
  recent call wins.

  Three checks exposed:

    CanReadPath  - fs_read, fs_list, fs_grep call this on every
                   path argument before doing I/O.
    CanWritePath - fs_write, fs_edit_hashline (write side), the
                   append helper.
    ShellAllowed - shell_exec calls this on the raw command string.

  Each returns False with a Reason filled in. The handler converts
  Reason into an error string the model sees so it can adjust its
  next turn instead of looping on a silent failure.

  Allowlist style: AllowReadPaths / AllowWritePaths are real PCRE
  regex patterns. PasClaw.Tools.Regex wraps FPC's RegExpr and
  Delphi's System.RegularExpressions behind one call so config.json
  takes the same syntax as picoclaw's tools.allow_read_paths /
  tools.allow_write_paths -- anchors (^ $), character classes,
  alternation, etc. Empty / invalid patterns fall through to the
  workspace boundary instead of crashing the agent.

  Shell denylist style: a list of "forbidden tokens" matched against
  the command's whitespace-split tokens (sudo, rm, cd, del, format,
  ...) plus a list of "forbidden substrings" matched against the
  lowercased command (dd if=, $( , | sh, powershell -e, ...). The
  token list and substring list cover both POSIX shells and cmd /
  PowerShell, so the policy is consistent regardless of where
  shell_exec eventually lands. Coverage is documented inline next
  to each entry; adding a case requires only one array entry.

  Workspace pinning: when RestrictToWorkspace is on, Tool_Shell
  passes CurrentWorkspace into RunOneShot so the child shell starts
  inside the workspace. Combined with the cd / chdir / pushd / popd
  token denylist and the '..' traversal check, this closes the
  relative-path bypass -- a model that says "cat ../secret" hits the
  refusal before the process spawns, and even if a pattern slips
  through the denylist, the shell's cwd is the workspace, not
  whatever directory the user happened to invoke pasclaw from.

  Canonicalization: ExpandFileName resolves '..' and relative
  references against the current working directory. Symlinks
  pointing outside the workspace can still escape on platforms
  where the OS does not normalize them at the syscall layer --
  picoclaw avoids that via Go 1.24's os.OpenRoot, which we do not
  have an equivalent for in FPC/Delphi RTL. The README's Security
  section flags this as a known limitation.
*)
unit PasClaw.Tools.Sandbox;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes,
  PasClaw.Config;

procedure ConfigureSandbox(const Policy: TSandboxPolicy; const Workspace: string);

function CanReadPath (const Path: string; out Reason: string): Boolean;
function CanWritePath(const Path: string; out Reason: string): Boolean;
function ShellAllowed(const Cmd:  string; out Reason: string): Boolean;

{ Like CanReadPath, but the workspace boundary is ALWAYS enforced regardless of
  RestrictToWorkspace / AllowReadOutsideWorkspace. The gateway's HTTP file
  endpoints (/v1/fs, /v1/fs/read, /v1/fs/download, /v1/fs/peek) use this so a
  client that reaches the gateway can never pull a file from outside the
  workspace -- even when the operator left the agent's tool sandbox
  unrestricted (the default). allow_read_paths still applies as an explicit
  operator opt-in. }
function CanReadPathHTTP(const Path: string; out Reason: string): Boolean;

{ The configured workspace directory in canonical form. The shell
  tool reads this to bind RunOneShot's working directory when
  RestrictToWorkspace is on, so a model that managed to slip a
  relative path past ShellAllowed cannot reference files outside
  the workspace by virtue of where the shell starts. Returns '' if
  ConfigureSandbox has not been called yet. }
function CurrentWorkspace: string;

{ Resolve a possibly-relative file path to an absolute one. Absolute paths
  pass through (canonicalised). A RELATIVE path resolves against the
  configured workspace (CurrentWorkspace) rather than the process's current
  directory -- so a model that writes `write_file("index.html")` on a gateway
  / serve run lands the file in the operator's workspace, not wherever the
  service happened to be launched. When no workspace is configured
  CurrentWorkspace already defaults to the launch dir, so CLI-in-a-project
  behaviour (relative = the project dir) is unchanged. Tools call this before
  the CanRead/CanWritePath gate so the sandbox sees the same resolved path. }
function ResolveWorkspacePath(const Path: string): string;

{ True iff Path canonicalises to a child of Workspace. Exposed for
  testing and for the rare caller that wants to know without going
  through the policy layer. }
function PathInsideDirectory(const Path, Directory: string): Boolean;

{ True iff the workspace boundary is currently being enforced.
  Tool_Shell consults this to decide whether to pin cwd. }
function RestrictionActive: Boolean;

{ True iff outbound URL fetches should be SSRF-guarded against
  private / loopback / link-local addresses. web_fetch consults
  this before each request and inside its redirect handler. }
function NetworkBlockingActive: Boolean;

implementation

uses
  PasClaw.Logger,
  PasClaw.Tools.Regex;

var
  GPolicy:    TSandboxPolicy;
  GWorkspace: string;
  { The agent's own home workspace ($PASCLAW_HOME/workspace -- where memory,
    skills, sessions, checkpoints and generated files live). CanReadPathHTTP
    (the operator-facing /v1/fs browse, NOT the model's CanReadPath) allows
    reads here IN ADDITION to GWorkspace, so the web UI's Files tab can show
    the agent workspace even when it sits outside the launch directory (the
    common case: `pasclaw serve` run from anywhere, or a Docker boot). Set in
    ConfigureSandbox. }
  GOperatorBrowseRoot: string;

procedure ConfigureSandbox(const Policy: TSandboxPolicy; const Workspace: string);
begin
  GPolicy := Policy;
  if Trim(Workspace) <> '' then
    GWorkspace := Workspace
  else if Trim(Policy.Workspace) <> '' then
    GWorkspace := Policy.Workspace
  else
    GWorkspace := GetCurrentDir;
  GWorkspace := ExcludeTrailingPathDelimiter(ExpandFileName(GWorkspace));
  { Independent of the sandbox workspace -- always the agent's data home, so
    the operator Files browser can reach it from any launch directory. }
  GOperatorBrowseRoot := ExcludeTrailingPathDelimiter(ExpandFileName(
    IncludeTrailingPathDelimiter(GetHome) + 'workspace'));
  if Policy.RestrictToWorkspace then
    LogDebug('sandbox: restrict_to_workspace=true workspace=%s', [GWorkspace]);
end;

function CurrentWorkspace: string;
begin
  Result := GWorkspace;
end;

function IsAbsolutePath(const P: string): Boolean;
begin
  {$IFDEF MSWINDOWS}
  { Drive-letter (C:\...), or a leading slash / backslash (root or UNC). }
  Result := ((Length(P) >= 2) and (P[2] = ':')) or
            ((Length(P) >= 1) and ((P[1] = '\') or (P[1] = '/')));
  {$ELSE}
  Result := (Length(P) >= 1) and (P[1] = '/');
  {$ENDIF}
end;

function ResolveWorkspacePath(const Path: string): string;
var
  Base: string;
begin
  if Trim(Path) = '' then Exit(Path);
  if IsAbsolutePath(Path) then
    Result := ExpandFileName(Path)
  else
  begin
    Base := GWorkspace;
    if Trim(Base) = '' then Base := GetCurrentDir;
    Result := ExpandFileName(IncludeTrailingPathDelimiter(Base) + Path);
  end;
end;

function RestrictionActive: Boolean;
begin
  Result := GPolicy.RestrictToWorkspace;
end;

function NetworkBlockingActive: Boolean;
begin
  Result := GPolicy.BlockPrivateNetworks;
end;

{ -------- path helpers -------- }

function Canonicalize(const Path: string): string;
begin
  Result := ExpandFileName(Path);
  Result := ExcludeTrailingPathDelimiter(Result);
end;

function PathsEqual(const A, B: string): Boolean; inline;
begin
  { On case-sensitive filesystems (Linux, macOS with HFS+ case-sensitive,
    most BSDs) "/tmp/workspace" and "/tmp/Workspace" are different
    directories -- using SameText here would treat them as one and let
    the model escape the boundary by varying the case of a path that
    happens to also exist with a different casing. On Windows
    filesystems are case-insensitive at the OS level, so SameText is
    the correct comparison. }
  {$IFDEF MSWINDOWS}
  Result := SameText(A, B);
  {$ELSE}
  Result := A = B;
  {$ENDIF}
end;

function PathInsideDirectory(const Path, Directory: string): Boolean;
var
  P, D, DTrim: string;
begin
  Result := False;
  if (Path = '') or (Directory = '') then Exit;
  P := Canonicalize(Path);
  D := IncludeTrailingPathDelimiter(Canonicalize(Directory));
  DTrim := ExcludeTrailingPathDelimiter(D);
  if PathsEqual(P, DTrim) then Exit(True);
  Result := (Length(P) > Length(D)) and PathsEqual(Copy(P, 1, Length(D)), D);
end;

function AnyRegexMatches(const S: string; const Patterns: array of string): Boolean;
{ True iff S matches at least one of the regex patterns. Empty
  pattern list returns False. PasClaw.Tools.Regex wraps FPC's
  RegExpr and Delphi's System.RegularExpressions behind one call,
  so the patterns in config.json are real PCRE expressions:

    allow_read_paths:  ["^/tmp/.*", "^/usr/(include|share)/.*"]

  Compared with the earlier glob matcher (just '*' and '?'), this
  gives users character classes, anchors, alternation, etc. -- the
  set picoclaw's `allow_read_paths` accepts, since picoclaw is also
  PCRE-style. Migration note for any config that used the old
  globs: '/tmp/*' becomes '^/tmp/.*' (anchor the prefix, replace
  '*' with '.*'). README documents the change. }
var
  i: Integer;
begin
  for i := 0 to High(Patterns) do
    if (Patterns[i] <> '') and RegexMatch(Patterns[i], S) then Exit(True);
  Result := False;
end;

{ -------- access checks -------- }

function CanReadPath(const Path: string; out Reason: string): Boolean;
var
  Canon: string;
begin
  Reason := '';
  if not GPolicy.RestrictToWorkspace then Exit(True);
  if GPolicy.AllowReadOutsideWorkspace then Exit(True);
  Canon := Canonicalize(Path);
  if PathInsideDirectory(Canon, GWorkspace) then Exit(True);
  if AnyRegexMatches(Canon, GPolicy.AllowReadPaths) then Exit(True);
  Reason := 'refused: path "' + Canon + '" is outside the workspace ' +
            '"' + GWorkspace + '" and does not match any allow_read_paths ' +
            'pattern (sandbox.restrict_to_workspace=true)';
  Result := False;
end;

function CanReadPathHTTP(const Path: string; out Reason: string): Boolean;
var
  Canon: string;
begin
  Reason := '';
  { Reject pathological input before touching the filesystem: an embedded NUL
    can truncate the path differently at the canonicalisation check vs the OS
    open (a classic poison-NUL bypass), and a megabyte-long path is only ever a
    DoS/oversize probe. A long-but-sane path is still handled normally -- the
    boundary check below is a lexical prefix test, so length alone can't escape
    the workspace. }
  if Pos(#0, Path) > 0 then
  begin
    Reason := 'refused: path contains a NUL byte';
    Exit(False);
  end;
  if Length(Path) > 4096 then
  begin
    Reason := 'refused: path too long';
    Exit(False);
  end;
  Canon := Canonicalize(Path);
  if PathInsideDirectory(Canon, GWorkspace) then Exit(True);
  { Also allow the agent's own home workspace ($PASCLAW_HOME/workspace) so the
    operator Files browser can reach memory / skills / sessions / generated
    files even when the launch directory (GWorkspace) is elsewhere. Operator
    endpoint only -- the model's CanReadPath is unchanged. Secrets live at the
    home ROOT (config.json / .env), outside this subtree, and are additionally
    hidden by IsRestrictedFsPath. }
  if (GOperatorBrowseRoot <> '') and PathInsideDirectory(Canon, GOperatorBrowseRoot) then
    Exit(True);
  if AnyRegexMatches(Canon, GPolicy.AllowReadPaths) then Exit(True);
  Reason := 'refused: path "' + Canon + '" is outside the workspace "' +
            GWorkspace + '" and the agent home workspace "' +
            GOperatorBrowseRoot + '" -- gateway file access is confined to ' +
            'those (independent of sandbox.restrict_to_workspace)';
  Result := False;
end;

function CanWritePath(const Path: string; out Reason: string): Boolean;
var
  Canon: string;
begin
  Reason := '';
  if not GPolicy.RestrictToWorkspace then Exit(True);
  Canon := Canonicalize(Path);
  if PathInsideDirectory(Canon, GWorkspace) then Exit(True);
  if AnyRegexMatches(Canon, GPolicy.AllowWritePaths) then Exit(True);
  Reason := 'refused: path "' + Canon + '" is outside the workspace ' +
            '"' + GWorkspace + '" and does not match any allow_write_paths ' +
            'pattern (sandbox.restrict_to_workspace=true)';
  Result := False;
end;

{ -------- shell denylist -------- }

const
  { Tokens that, when found as a whitespace-separated word in the
    command, abort the call. The denylist tries to be conservative --
    these are commands the model has no business running from a
    chat session even on a developer workstation.

    A few legit-sounding cases (e.g. `chmod +x build.sh`) are caught
    too. That is intentional: the model can write the file and the
    human can chmod it. Override per-config via custom_shell_deny
    if a specific case is needed. }
  (*  Tokens that, when found as a whitespace-separated word, abort the
      call. Mostly POSIX-flavoured but the Windows-specific ones
      (del / erase / rd / rmdir / format / attrib / takeown / icacls /
       cacls / runas / reg) live in the same list because cmd.exe and
      PowerShell both interpret them when shell_exec runs on Windows.
      A few names overlap with legitimate non-shell uses (e.g. "kill"
      can appear inside a file path); the cost is acceptable since the
      tokenizer splits on whitespace + shell metacharacters, so only
      stand-alone tokens trigger the match.

      cd / chdir / pushd / popd are NOT in here -- they live in
      WorkspaceEscapeTokens below, which is checked only when the
      workspace restriction is active. Banning the cd-family
      unconditionally broke legitimate compile-and-build flows
      ("cmd /c cd <proj> && dcc32 …") in unrestricted mode for no
      additional safety -- the workspace boundary is what they were
      ever meant to protect, so they only matter when that boundary
      exists. *)
  ForbiddenTokens: array[0..23] of string = (
    'sudo',
    'su',
    'rm',          { all rm -- too easy to escape -rf detection }
    'chmod',
    'chown',
    'pkill',
    'killall',
    'kill',
    'shutdown',
    'reboot',
    'poweroff',
    'halt',
    'eval',
    'mkfs',
    'diskpart',
    { Windows additions } 'del',
    'erase',
    'rd',
    'rmdir',
    'format',
    'attrib',
    'takeown',
    'icacls',
    'runas'
  );

  (*  Tokens that would let the model escape the workspace cwd pin --
      the workspace restriction binds the shell's cwd to GWorkspace
      and runs the abs-path scanner on the rest of the command;
      letting the model chdir would defeat both. Only enforced when
      sandbox.restrict_to_workspace is True. In unrestricted mode
      the model can change directories freely (regular CLI use, no
      cwd pin to defeat). *)
  WorkspaceEscapeTokens: array[0..3] of string = (
    'cd',
    'chdir',
    'pushd',
    'popd'
  );

  { Substrings that, when present anywhere in the lowercased command,
    abort the call. Covers picoclaw's regex patterns expressed as
    plain literals -- adequate because the patterns themselves are
    just punctuation runs ($(...), `...`, etc.) or fixed token
    sequences (apt install, npm install -g, etc.). }
  ForbiddenSubstrings: array[0..43] of string = (
    'dd if=',
    ':(){:|',         { fork bomb }
    '<<eof',
    '<<-eof',
    '$(',             { command substitution }
    '${',             { parameter expansion with possible injection }
    '`',              { backtick command substitution }
    '| sh',
    '|sh',
    '| bash',
    '|bash',
    '|/bin/sh',
    '|/bin/bash',
    { curl and wget are intentionally NOT denied -- they're the
      conventional way the model fetches arbitrary URLs from the
      shell, and we already provide web_fetch as the tracked-tool
      alternative. Denying them put PasClaw strictly behind picoclaw
      on URL access, and operators can still flip the whole
      denylist off via sandbox.shell_deny_enabled = false. }
    'apt install',
    'apt remove',
    'apt purge',
    'yum install',
    'yum remove',
    'dnf install',
    'dnf remove',
    'npm install -g',
    'pip install --user',
    'docker run',
    'docker exec',
    'git push',
    'git force',
    'format c:',
    { Windows-specific patterns -- picoclaw lists these in its
      windowsDenyPatterns group. They are checked unconditionally
      since shell_exec on Windows pipes through cmd.exe /C, and
      letting them through "because we are on Linux right now"
      breaks portability of the policy across deploys. }
    'del /f',
    'del /q',
    'del /s',
    'rd /s',
    'rmdir /s',
    'format /q',
    'powershell -e ',     { -EncodedCommand (base64 cmd) }
    'powershell -en ',
    'powershell -enc ',
    'powershell -ec ',
    '-encodedcommand',
    'iex (',              { Invoke-Expression }
    'invoke-expression',
    '[convert]::frombase64',
    '[text.encoding]',
    '.getstring([byte[]',
    'set-executionpolicy'
  );

  { Patterns specifically for writes to block devices. These cause
    instant disk wipes if executed. }
  ForbiddenDeviceWrites: array[0..7] of string = (
    '> /dev/sd',
    '> /dev/hd',
    '> /dev/vd',
    '> /dev/xvd',
    '> /dev/nvme',
    '> /dev/mmcblk',
    '> /dev/loop',
    '> /dev/md'
  );

function IsShellBreak(C: Char): Boolean; inline;
begin
  { Whitespace + shell metacharacters that delimit one token from
    the next. Spelled out as an if-chain rather than a set literal
    so Delphi's UnicodeString Char type does not refuse the
    `in [' ', ...]` form. }
  Result := (C = ' ')  or (C = #9)  or (C = ';')  or (C = '|') or
            (C = '&')  or (C = '(') or (C = ')')  or (C = '<') or
            (C = '>')  or (C = #10) or (C = #13);
end;

function IsPathBreak(C: Char): Boolean; inline;
begin
  Result := IsShellBreak(C) or (C = '"') or (C = '''');
end;

function TokenizeCommand(const Cmd: string): TStringList;
{ Splits on whitespace and shell metacharacters. Caller frees. }
var
  i: Integer;
  Cur: string;
begin
  Result := TStringList.Create;
  Cur := '';
  for i := 1 to Length(Cmd) do
  begin
    if IsShellBreak(Cmd[i]) then
    begin
      if Cur <> '' then begin Result.Add(Cur); Cur := ''; end;
    end
    else
      Cur := Cur + Cmd[i];
  end;
  if Cur <> '' then Result.Add(Cur);
end;

function MatchesAnyTokenForbid(const Cmd: string; out Hit: string): Boolean;
var
  Tokens: TStringList;
  i, j: Integer;
  T: string;
begin
  Result := False;
  Hit := '';
  Tokens := TokenizeCommand(Cmd);
  try
    for i := 0 to Tokens.Count - 1 do
    begin
      T := LowerCase(Tokens[i]);
      for j := 0 to High(ForbiddenTokens) do
        if T = ForbiddenTokens[j] then
        begin
          Hit := ForbiddenTokens[j];
          Exit(True);
        end;
    end;
  finally
    Tokens.Free;
  end;
end;

function MatchesAnyWorkspaceEscape(const Cmd: string; out Hit: string): Boolean;
var
  Tokens: TStringList;
  i, j: Integer;
  T: string;
begin
  Result := False;
  Hit := '';
  Tokens := TokenizeCommand(Cmd);
  try
    for i := 0 to Tokens.Count - 1 do
    begin
      T := LowerCase(Tokens[i]);
      for j := 0 to High(WorkspaceEscapeTokens) do
        if T = WorkspaceEscapeTokens[j] then
        begin
          Hit := WorkspaceEscapeTokens[j];
          Exit(True);
        end;
    end;
  finally
    Tokens.Free;
  end;
end;

function MatchesAnySubstring(const Cmd: string; out Hit: string): Boolean;
var
  Lower: string;
  i: Integer;
begin
  Lower := LowerCase(Cmd);
  for i := 0 to High(ForbiddenSubstrings) do
    if Pos(ForbiddenSubstrings[i], Lower) > 0 then
    begin
      Hit := ForbiddenSubstrings[i];
      Exit(True);
    end;
  for i := 0 to High(ForbiddenDeviceWrites) do
    if Pos(ForbiddenDeviceWrites[i], Lower) > 0 then
    begin
      Hit := ForbiddenDeviceWrites[i];
      Exit(True);
    end;
  for i := 0 to High(GPolicy.CustomShellDeny) do
    if (GPolicy.CustomShellDeny[i] <> '') and
       (Pos(LowerCase(GPolicy.CustomShellDeny[i]), Lower) > 0) then
    begin
      Hit := GPolicy.CustomShellDeny[i];
      Exit(True);
    end;
  Result := False;
end;

function HasTraversalToken(const Cmd: string; out OffendingToken: string): Boolean;
{ Catches relative path-traversal references that the absolute-path
  scanner below would miss. When the shell starts in GWorkspace
  (we now pin cwd to it on every Tool_Shell call), a command like
  `cat ../secret` would otherwise read outside the workspace even
  though no '/' token shows up.

  We flag any token containing '..' anywhere. False positives like
  `git log v1.0..v2.0` (a git range) get rejected too -- that is an
  acceptable trade-off; a sandboxed agent should be writing absolute
  paths or relative paths that stay inside the workspace, and the
  rare git-range case can be replaced by something else or run with
  restrict_to_workspace=false on a trusted host. }
var
  Tokens: TStringList;
  i: Integer;
  T: string;
begin
  Result := False;
  OffendingToken := '';
  Tokens := TokenizeCommand(Cmd);
  try
    for i := 0 to Tokens.Count - 1 do
    begin
      T := Tokens[i];
      if Pos('..', T) > 0 then
      begin
        OffendingToken := T;
        Exit(True);
      end;
    end;
  finally
    Tokens.Free;
  end;
end;

function HasOutsideAbsolutePath(const Cmd: string; out OffendingPath: string): Boolean;
var
  i, Start: Integer;
  Token: string;
  IsSafeDev: Boolean;
begin
  Result := False;
  OffendingPath := '';
  i := 1;
  while i <= Length(Cmd) do
  begin
    if Cmd[i] = '/' then
    begin
      Start := i;
      while (i <= Length(Cmd)) and not IsPathBreak(Cmd[i]) do
        Inc(i);
      Token := Copy(Cmd, Start, i - Start);
      { Kernel pseudo-devices are always safe -- picoclaw's safePaths. }
      IsSafeDev := SameText(Token, '/dev/null')    or SameText(Token, '/dev/zero')   or
                   SameText(Token, '/dev/random')  or SameText(Token, '/dev/urandom') or
                   SameText(Token, '/dev/stdin')   or SameText(Token, '/dev/stdout') or
                   SameText(Token, '/dev/stderr');
      if (not IsSafeDev) and (not PathInsideDirectory(Token, GWorkspace)) and
         (not AnyRegexMatches(Token, GPolicy.AllowReadPaths)) and
         (not AnyRegexMatches(Token, GPolicy.AllowWritePaths)) then
      begin
        OffendingPath := Token;
        Exit(True);
      end;
    end
    else
      Inc(i);
  end;
end;

function ShellAllowed(const Cmd: string; out Reason: string): Boolean;
var
  Hit, Path: string;
begin
  Reason := '';
  if Trim(Cmd) = '' then
  begin
    Reason := 'refused: empty command';
    Exit(False);
  end;

  if GPolicy.ShellDenyEnabled then
  begin
    if MatchesAnyTokenForbid(Cmd, Hit) then
    begin
      Reason := 'refused: command contains forbidden token "' + Hit +
                '" (built-in shell denylist; toggle off via sandbox.shell_deny_enabled=false ' +
                'in config.json -- strongly discouraged)';
      Exit(False);
    end;
    if MatchesAnySubstring(Cmd, Hit) then
    begin
      Reason := 'refused: command contains forbidden pattern "' + Hit +
                '" (built-in shell denylist)';
      Exit(False);
    end;
  end;

  if GPolicy.RestrictToWorkspace then
  begin
    { cd / chdir / pushd / popd only matter when restriction is on --
      they'd let the model escape the workspace cwd pin. In
      unrestricted mode the model can chdir freely (regular CLI use,
      no cwd to pin). Gating these here, rather than in the
      always-on ForbiddenTokens above, fixes the "cmd /c cd <proj> &&
      dcc32 …" Delphi/Windows compile flow that worked before
      sandbox landed. }
    if GPolicy.ShellDenyEnabled and MatchesAnyWorkspaceEscape(Cmd, Hit) then
    begin
      Reason := 'refused: command contains workspace-escape token "' + Hit +
                '" (sandbox.restrict_to_workspace=true pins shell cwd to "' +
                GWorkspace + '"; cd would defeat that). Use absolute paths ' +
                'inside the workspace instead.';
      Exit(False);
    end;
    if HasOutsideAbsolutePath(Cmd, Path) then
    begin
      Reason := 'refused: command references absolute path "' + Path +
                '" which is outside the workspace "' + GWorkspace +
                '" and does not match any allow_*_paths pattern ' +
                '(sandbox.restrict_to_workspace=true)';
      Exit(False);
    end;
    if HasTraversalToken(Cmd, Path) then
    begin
      Reason := 'refused: command contains path-traversal token "' + Path +
                '". Tool_Shell pins the working directory to the workspace, ' +
                'so .. would escape it. Rewrite with absolute paths that ' +
                'stay inside "' + GWorkspace + '" or list the target under ' +
                'sandbox.allow_read_paths / allow_write_paths.';
      Exit(False);
    end;
  end;

  Result := True;
end;

initialization
  { Defaults match TConfig.Create -- sandbox is off, denylist is on.
    Real values land via Configure() during command startup. }
  GPolicy.RestrictToWorkspace       := False;
  GPolicy.AllowReadOutsideWorkspace := False;
  GPolicy.ShellDenyEnabled          := True;
  GWorkspace := '';

end.
