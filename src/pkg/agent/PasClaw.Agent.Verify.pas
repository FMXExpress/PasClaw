(*
  PasClaw.Agent.Verify -- held-out scenarios, run by PasClaw, not the agent.

  An agent that writes both the code and the test that judges it can
  turn a green result into a claim about its own tests. A scenario is a
  check the agent never sees: an executable in a directory outside the
  workspace, run by the tool loop with the workspace as its cwd after the
  model says it is done. Exit 0 is satisfied. Anything else is fed back
  to the model as one more user turn ("[verification] 1 of 2 scenarios
  failed ...") and the loop runs again, for a bounded number of rounds.
  The loop's result records how it went, so a caller can tell "done" from
  "done and verified" -- and "done, but the scenarios still fail".

  Scenario files: *.sh (sh), *.py (python3), anything else run directly.
  Hidden files and README* are skipped; order is by name, so 01-, 02-
  prefixes order them. Each runs through the active shell backend with
  the shell timeout, like shell_exec.

  Measured on bench/ragbench (VERIFY.md): a first draft whose own test
  passed but whose chunking was wrong went out as "done" every time
  without this; with it, the scenario caught it and the second round
  fixed it.
*)
unit PasClaw.Agent.Verify;

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
  PasClaw.Utils;   { TStringArray -- one spelling for both compilers }

type
  TScenarioResult = record
    Name:     string;
    Path:     string;
    Passed:   Boolean;
    ExitCode: Integer;
    Output:   string;   { stdout+stderr, capped }
  end;
  TScenarioResults = array of TScenarioResult;

const
  DefaultVerifyMaxRounds = 2;
  { Per-scenario output kept for the feedback turn. }
  ScenarioOutputCap = 2000;

{ Scenario files in Dir, sorted by name; '' array when the directory is
  missing or empty. Pure except for the directory read. }
function ListScenarios(const Dir: string): TStringArray;

{ The command that runs one scenario file, by extension. Pure. }
function ScenarioCommand(const Path: string): string;

{ Run every scenario with WorkDir as cwd. True when all passed -- and
  False when there was nothing to run: a scenario set that is missing,
  empty or all skipped is a configuration mistake, not a pass (see
  FormatNoScenariosSummary). Each runs under the shell timeout; one that
  hangs is killed and fails with exit 124. }
function RunScenarios(const Dir, WorkDir: string; out Results: TScenarioResults): Boolean;

{ The summary when Dir held no scenario to run. Pure. }
function FormatNoScenariosSummary(const Dir: string): string;

{ What a caller that only returns the answer text must append to it when
  verification ran and failed: the summary and "NOT verified". '' when it
  passed or never ran. Pure. }
function FormatVerificationNotice(Verified: Boolean; Rounds: Integer;
                                  const Summary: string): string;

{ The user turn the model gets after a failing round. Pure. }
function FormatVerificationFeedback(const Results: TScenarioResults;
                                    Round, MaxRounds: Integer): string;

{ One line for logs, the CLI and the gateway: "verification: 2/3 scenarios
  passed (round 2 of 2)". Pure. }
function FormatVerificationSummary(const Results: TScenarioResults;
                                   Round, MaxRounds: Integer): string;

function CountPassed(const Results: TScenarioResults): Integer;

implementation

uses
  PasClaw.Logger,
  PasClaw.Promptware,      { scenario output is untrusted text }
  PasClaw.Shell.Backend;

function IfThenStr(Cond: Boolean; const A, B: string): string;
begin
  if Cond then Result := A else Result := B;
end;

function ListScenarios(const Dir: string): TStringArray;
var
  Sr: TSearchRec;
  L: TStringList;
  i: Integer;
  N: string;
begin
  SetLength(Result, 0);
  if (Trim(Dir) = '') or (not DirectoryExists(Dir)) then Exit;
  L := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile and not faDirectory, Sr) = 0 then
    try
      repeat
        N := Sr.Name;
        if (N = '') or (N[1] = '.') then Continue;
        if (Sr.Attr and faDirectory) <> 0 then Continue;
        if Copy(LowerCase(N), 1, 6) = 'readme' then Continue;
        L.Add(N);
      until FindNext(Sr) <> 0;
    finally
      FindClose(Sr);
    end;
    L.Sort;
    SetLength(Result, L.Count);
    for i := 0 to L.Count - 1 do
      Result[i] := IncludeTrailingPathDelimiter(Dir) + L[i];
  finally
    L.Free;
  end;
end;

function Q(const S: string): string;
begin
  {$IFDEF MSWINDOWS}
  Result := '"' + S + '"';
  {$ELSE}
  Result := '''' + StringReplace(S, '''', '''\''''', [rfReplaceAll]) + '''';
  {$ENDIF}
end;

function ScenarioCommand(const Path: string): string;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(Path));
  if Ext = '.sh' then Result := 'sh ' + Q(Path)
  else if Ext = '.py' then Result := 'python3 ' + Q(Path)
  else if (Ext = '.ps1') then Result := 'powershell -File ' + Q(Path)
  else Result := Q(Path);
end;

function RunScenarios(const Dir, WorkDir: string; out Results: TScenarioResults): Boolean;
var
  Files: TStringArray;
  i: Integer;
  Out_: string;
begin
  Files := ListScenarios(Dir);
  SetLength(Results, Length(Files));
  (* Nothing to run is a failure, not a pass. A misspelled, missing or
     empty verification.scenarios -- or one holding only README and
     hidden files -- used to come back True, so the loop reported
     Verified, /v1/chat said ok, and the CLI printed a green "0/0
     scenarios passed": the exact false success this feature exists to
     prevent, produced by a typo. (Codex P1 on #618.) There is nothing for
     the model to fix, so the loop does not feed this back; it returns the
     answer with verification failed and FormatNoScenariosSummary says
     why. *)
  Result := Length(Files) > 0;
  if not Result then
    LogWarn('verify: no scenarios to run in "%s" -- check verification.scenarios', [Dir]);
  for i := 0 to High(Files) do
  begin
    Results[i].Name := ExtractFileName(Files[i]);
    Results[i].Path := Files[i];
    Out_ := '';
    (* Bounded: RunOneShotViaBackend applies the tool shell timeout
       (shell_timeout_sec, 600 s by default) when no tighter one is set,
       and on expiry kills the scenario's whole process tree and returns
       exit 124 with a "timed out" note -- a failed result like any other.
       A scenario that deadlocks or waits on input cannot hang the turn.
       (Codex P2 on #618; the bound landed on main with #608.) *)
    try
      Results[i].ExitCode := RunOneShotViaBackend(GetCurrentSessionId,
                               ScenarioCommand(Files[i]), WorkDir, Out_);
    except
      on E: Exception do
      begin
        Results[i].ExitCode := -1;
        Out_ := 'scenario could not run: ' + E.Message;
      end;
    end;
    if Length(Out_) > ScenarioOutputCap then
      Out_ := '...' + Copy(Out_, Length(Out_) - ScenarioOutputCap + 1, ScenarioOutputCap);
    Results[i].Output := Trim(Out_);
    Results[i].Passed := Results[i].ExitCode = 0;
    if not Results[i].Passed then Result := False;
    LogInfo('verify: scenario %s %s (exit=%d)',
            [Results[i].Name, IfThenStr(Results[i].Passed, 'passed', 'FAILED'), Results[i].ExitCode]);
  end;
end;

function CountPassed(const Results: TScenarioResults): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(Results) do
    if Results[i].Passed then Inc(Result);
end;

function FormatNoScenariosSummary(const Dir: string): string;
begin
  Result := 'verification FAILED: no scenarios to run in ' + Dir +
            ' -- check verification.scenarios (missing, empty, misspelled, ' +
            'or nothing but README and hidden files)';
end;

function FormatVerificationNotice(Verified: Boolean; Rounds: Integer;
                                  const Summary: string): string;
begin
  if Verified or (Rounds <= 0) then Exit('');
  Result := '[' + Summary + ' -- this answer is NOT verified: the ' +
            'operator''s held-out checks did not pass]';
end;

function FormatVerificationSummary(const Results: TScenarioResults;
                                   Round, MaxRounds: Integer): string;
begin
  Result := Format('verification: %d/%d scenarios passed (round %d of %d)',
                   [CountPassed(Results), Length(Results), Round, MaxRounds]);
end;

function FormatVerificationFeedback(const Results: TScenarioResults;
                                    Round, MaxRounds: Integer): string;
var
  i, Failed: Integer;
  Sb: TStringBuilder;
begin
  Failed := Length(Results) - CountPassed(Results);
  Sb := TStringBuilder.Create;
  try
    Sb.Append(Format('[verification] %d of %d held-out scenario(s) FAILED after your last ' +
                     'answer (round %d of %d). These checks were written by the operator, ' +
                     'not by you, and ran against the workspace as it is now. Fix the ' +
                     'cause, not the check; the scenarios will be re-run automatically ' +
                     'after your next answer, so you do not need to re-run your own tests ' +
                     'for them.', [Failed, Length(Results), Round, MaxRounds]));
    Sb.Append(sLineBreak);
    for i := 0 to High(Results) do
    begin
      Sb.Append(sLineBreak);
      if Results[i].Passed then
        Sb.Append('- ' + Results[i].Name + ': passed')
      else
      begin
        Sb.Append(Format('- %s: FAILED (exit %d)', [Results[i].Name, Results[i].ExitCode]));
        (* The output is the check's, not the operator's: a failing
           assertion echoes workspace files, fixtures and command output,
           all of which the checkout controls. This turn is a USER message,
           so it gets what every tool result gets before the model sees it
           -- the promptware scan, which banners injection text as data --
           and a label saying whose words these are. (Codex P2 on #618.) *)
        if Results[i].Output <> '' then
          Sb.Append(sLineBreak + '  output (the check''s, quoted as data):' + sLineBreak + '  ' +
                    StringReplace(MaybeFlagPromptware(Results[i].Output,
                                    'output of held-out scenario ' + Results[i].Name),
                                  sLineBreak, sLineBreak + '  ', [rfReplaceAll]));
      end;
    end;
    Result := Sb.ToString;
  finally
    Sb.Free;
  end;
end;

end.
