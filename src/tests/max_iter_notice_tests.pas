program max_iter_notice_tests;
(*
  Covers FormatMaxIterNotice -- the operator-facing "stopped at the
  tool-iteration limit" message surfaced by the gateway, CLI and TUI when
  RunToolLoop runs out of iterations mid-task.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Tools.ToolLoop;

procedure Fail_(const Msg: string);
begin WriteLn('FAIL: ' + Msg); Halt(1); end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

function Has(const Hay, Needle: string): Boolean;
begin Result := Pos(Needle, Hay) > 0; end;

var
  Loop: TToolLoopResult;
  S: string;
begin
  { Clean stop (did not hit the cap) -> empty notice, so callers can append
    it unconditionally. }
  Loop := Default(TToolLoopResult);
  Loop.HitMaxIterations := False;
  AssertTrue(FormatMaxIterNotice(Loop, 25, '--max-iter', True) = '',
    'no notice on a clean stop');

  { Hit the cap mid-task with two distinct pending tools. }
  Loop := Default(TToolLoopResult);
  Loop.HitMaxIterations := True;
  Loop.Iterations := 25;
  SetLength(Loop.PendingToolNames, 2);
  Loop.PendingToolNames[0] := 'fs_write';
  Loop.PendingToolNames[1] := 'shell_exec';

  { Resumable caller -> "reply continue". }
  S := FormatMaxIterNotice(Loop, 25, '`--max-iter` on `pasclaw serve`', True);
  AssertTrue(S <> '', 'notice emitted when the cap was hit');
  AssertTrue(Has(S, '25'), 'notice states the iteration count');
  AssertTrue(Has(S, 'unfinished'), 'notice says the task is probably unfinished');
  AssertTrue(Has(S, 'fs_write') and Has(S, 'shell_exec'),
    'notice lists what it was mid-doing');
  AssertTrue(Has(S, 'continue'), 'resumable notice tells the user to reply continue');
  AssertTrue(Has(S, '--max-iter'), 'notice includes the how-to-raise hint');

  { Empty how-to-raise hint -> the "or raise the limit" clause is omitted. }
  S := FormatMaxIterNotice(Loop, 25, '', True);
  AssertTrue(Has(S, 'continue'), 'continue hint still present without raise clause');
  AssertTrue(not Has(S, 'raise the limit'),
    'raise-the-limit clause omitted when hint is empty');

  { Stateless caller -> NO false "continue" promise; tells the user to
    raise the cap and re-run instead (the P2 review fix). }
  S := FormatMaxIterNotice(Loop, 25, '--max-iterations N', False);
  AssertTrue(Has(S, 'does not carry over'),
    'stateless notice says the turn does not carry over');
  AssertTrue(Has(S, 're-run'), 'stateless notice tells the user to re-run');
  AssertTrue(not Has(S, 'reply "continue"') and not Has(S, 'resume from here'),
    'stateless notice does NOT promise a continue that would start fresh');
  AssertTrue(Has(S, '--max-iterations N'), 'stateless notice keeps the how-to-raise hint');

  WriteLn('  ok: format max-iter notice (clean / fields / resumable vs stateless)');
  WriteLn('PASS');
end.
