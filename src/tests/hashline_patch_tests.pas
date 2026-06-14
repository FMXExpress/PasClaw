program hashline_patch_tests;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Hashline;

procedure Fail(const Msg: string);
begin
  Writeln('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail(Msg);
end;

procedure TestValidInsertion;
var
  P, Err: string;
  Sections: THLSectionArray;
begin
  P := '¶a.txt#abcd' + #10 + '2:' + #10 + '↑inserted above';
  AssertTrue(ValidateHashlinePatchGrammar(P, Err), 'valid insertion rejected: ' + Err);
  AssertTrue(ParseHashlinePatch(P, Sections, Err), 'valid insertion parse failed: ' + Err);
  AssertTrue(Length(Sections) = 1, 'expected one section for insertion');
end;

procedure TestValidMultilineReplacement;
var
  P, Err: string;
  Sections: THLSectionArray;
begin
  P := '¶b.txt#beef' + #10 + '4-5:' + #10 + '|new line one' + #10 + '|new line two';
  AssertTrue(ValidateHashlinePatchGrammar(P, Err), 'valid replacement rejected: ' + Err);
  AssertTrue(ParseHashlinePatch(P, Sections, Err), 'valid replacement parse failed: ' + Err);
  AssertTrue(Length(Sections) = 1, 'expected one section for replacement');
end;

procedure TestInvalidInlinePayload;
var
  P, Err: string;
begin
  P := '¶c.txt#cafe' + #10 + '60:↓bad inline payload';
  AssertTrue(not ValidateHashlinePatchGrammar(P, Err), 'invalid inline payload accepted');
  AssertTrue(Pos(':↓', Err) > 0, 'expected actionable token in validator error');
end;

procedure TestBareContinuationLineRejected;
{ The exact shape that tripped a real session: a multi-line replacement
  where only the first payload line carries the | marker and the rest are
  bare. Must be rejected (not silently dropped), and the error must point
  at the missing per-line prefix so the model can self-correct. }
var
  P, Err: string;
  Sections: THLSectionArray;
begin
  P := '¶d.txt#dead' + #10 + '40-41:' + #10 +
       '|procedure Foo;' + #10 + 'begin';   { 'begin' has no | prefix }
  AssertTrue(not ParseHashlinePatch(P, Sections, Err),
             'bare continuation line must be rejected, not dropped');
  AssertTrue(Pos('begin', Err) > 0, 'error names the offending line: ' + Err);
  AssertTrue(Pos('per-line', Err) > 0,
             'error explains the per-line prefix requirement: ' + Err);
end;

begin
  TestValidInsertion;
  TestValidMultilineReplacement;
  TestInvalidInlinePayload;
  TestBareContinuationLineRejected;
  Writeln('PASS');
end.
