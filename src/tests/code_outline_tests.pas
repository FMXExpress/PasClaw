(*
  code_outline_tests -- PasClaw.Tools.Outline: the scanners, and the tool's
  three modes (symbol, file, directory) through the registry.

  Each fixture carries the traps a line scanner falls into: a declaration
  keyword inside a comment or a string, a routine's own local types and
  variables, a long constant's continuation lines, a function inside a
  function, an `if (` inside a class body.
*)
program code_outline_tests;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.Config,          { TSandboxPolicy }
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.Sandbox,
  PasClaw.Tools.FS,
  PasClaw.Tools.Outline;

var
  Failures: Integer = 0;

procedure Fail(const Msg: string);
begin
  Inc(Failures);
  WriteLn('FAIL: ', Msg);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if Cond then WriteLn('  ok: ', Msg) else Fail(Msg);
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) > 0 then WriteLn('  ok: ', Msg)
  else Fail(Msg + ' -- "' + Needle + '" not in: ' + Copy(Haystack, 1, 400));
end;

procedure AssertMissing(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) = 0 then WriteLn('  ok: ', Msg)
  else Fail(Msg + ' -- "' + Needle + '" found in: ' + Copy(Haystack, 1, 400));
end;

{ name@line kind/depth/section, one per entry, for whole-shape asserts. }
function Shape(const E: TOutlineEntryArray): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(E) do
    Result := Result + Format('%s@%d %s/%d/%s'#10,
      [E[I].Name, E[I].Line, E[I].Kind, E[I].Depth, E[I].Section]);
end;

function Lines(const A: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(A) do Result := Result + A[I] + #10;
end;

const
  PascalUnit: array[0..53] of string = (
    '(*',
    '  Fixture.Unit - what this unit is for, in one paragraph',
    '  that runs onto a second line.',
    '',
    '  A second paragraph that is not the summary.',
    '*)',
    'unit Fixture.Unit;',
    '{$MODE DELPHI}',
    'interface',
    'type',
    '  TShape = (shCircle, shSquare);',
    '  TFoo = class(TObject)',
    '  private',
    '    FCount: Integer;',
    '  public',
    '    constructor Create;',
    '    procedure Bar(const X: string);',
    '    class function Make: TFoo;',
    '    property Count: Integer read FCount;',
    '  end;',
    '  EFixture = class(Exception);',
    '  TPoint2 = record',
    '    X, Y: Integer;',
    '  end;',
    'const',
    '  Limit = 16000; Brace = ''{'';',
    '  Greeting =',
    '    ''procedure NotADecl;'' +',
    '    ''more text'';',
    'var',
    '  GCount: Integer = 0;',
    'function Helper(N: Integer): Integer;',
    '{ procedure InAComment; }',
    'implementation',
    'constructor TFoo.Create;',
    'begin',
    'end;',
    'procedure TFoo.Bar(const X: string);',
    'type',
    '  TLocal = record A: Integer; end;',
    'var',
    '  Tmp: string;',
    '  procedure Nested;',
    '  begin',
    '  end;',
    'begin',
    '  Tmp := ''function Fake: Integer;'';',
    'end;',
    'function Helper(N: Integer): Integer;',
    'begin',
    '  Result := N;',
    'end;',
    'initialization',
    'end.');

procedure TestPascal;
var
  E: TOutlineEntryArray;
  S, Summary: string;
begin
  WriteLn('-- pascal');
  E := OutlineSource(Lines(PascalUnit), 'pascal', Summary);
  S := Shape(E);
  AssertTrue(Summary = 'Fixture.Unit - what this unit is for, in one paragraph that runs onto a second line.',
             'the summary is the leading comment''s first paragraph: ' + Summary);
  AssertContains(S, 'TShape@11 enum/0/interface', 'an enum type');
  AssertContains(S, 'TFoo@12 class/0/interface', 'a class');
  AssertContains(S, 'TFoo.Create@16 method/1/interface', 'its constructor, as a member');
  AssertContains(S, 'TFoo.Bar@17 method/1/interface', 'its method');
  AssertContains(S, 'TFoo.Make@18 method/1/interface', 'a class function');
  AssertMissing(S, 'TFoo.Count', 'a property is not a declaration of its own');
  AssertMissing(S, 'FCount', 'nor a field');
  AssertContains(S, 'EFixture@21 class/0/interface', 'a one-line class');
  AssertContains(S, 'TPoint2@22 record/0/interface', 'and the record after it (the one-liner opened no body)');
  AssertMissing(S, 'TPoint2.X', 'record fields are left out');
  AssertContains(S, 'Limit@26 const/0/interface', 'a constant');
  AssertContains(S, 'Greeting@27 const/0/interface', 'a long constant');
  AssertMissing(S, 'NotADecl', 'its continuation lines are not declarations -- nor a keyword inside a string');
  AssertContains(S, 'GCount@31 var/0/interface', 'a unit variable');
  AssertContains(S, 'Helper@32 function/0/interface', 'an interface function');
  AssertMissing(S, 'InAComment', 'a declaration in a comment is not one');
  AssertContains(S, 'TFoo.Create@35 method/0/implementation', 'a constructor body');
  AssertContains(S, 'TFoo.Bar@38 method/0/implementation', 'a method body');
  AssertMissing(S, 'TLocal', 'a routine''s local type is the routine''s');
  AssertMissing(S, 'Tmp@', 'and so is its local variable');
  AssertMissing(S, 'Nested', 'a nested routine is left out');
  AssertMissing(S, 'Fake', 'a keyword in a string literal is not a declaration');
  AssertContains(S, 'Helper@49 function/0/implementation', 'the body after a method''s local sections');
  { A brace inside a string opened no comment: everything after line 26
    above would have been swallowed. }
  AssertContains(S, 'GCount@31', 'a brace in a string literal is not a comment');

  { Only a const block's first indentation declares: a record constant's
    second line looks like a declaration and is not one. }
  E := OutlineSource(Lines(['unit U;', 'interface', 'const', '  A = 1;',
    '  Origin: TPoint2 = (X: 0;', '    Y: 0);', '  B = 2;', 'implementation', 'end.']),
    'pascal', Summary);
  S := Shape(E);
  AssertContains(S, 'Origin@5 const/0/', 'a typed constant');
  AssertMissing(S, 'Y@', 'its continuation is not a constant');
  AssertContains(S, 'B@7 const/0/', 'and the block goes on after it');

  { Comments that span lines: their inner lines start like declarations. }
  E := OutlineSource(Lines(['unit U;', 'interface', '{ Notes:', 'procedure InABraceBlock;',
    '}', '(* and', 'function InAParenBlock: Integer;', '*)', '// procedure InALineComment;',
    'procedure Real; { function Trailing; }', 'implementation', 'end.']), 'pascal', Summary);
  S := Shape(E);
  AssertMissing(S, 'InABraceBlock', 'a brace comment''s lines are not code');
  AssertMissing(S, 'InAParenBlock', 'nor a paren-star comment''s');
  AssertMissing(S, 'InALineComment', 'nor a // comment');
  AssertMissing(S, 'Trailing', 'nor a trailing one');
  AssertContains(S, 'Real@10 procedure/0/interface', 'the code beside them is');
end;

procedure TestPython;
const
  Src: array[0..18] of string = (
    '#!/usr/bin/env python3',
    '"""Fixture module: what it does.',
    '',
    'def not_a_function(): this is a docstring line',
    '"""',
    'import os',
    '',
    '@decorator',
    'class Store(Base):',
    '    def get(self, key):',
    '        def helper():',
    '            pass',
    '        return 1',
    '',
    '    async def put(self, key, value):',
    '        pass',
    '',
    'async def main():',
    '    pass');
var
  E: TOutlineEntryArray;
  S, Summary: string;
begin
  WriteLn('-- python');
  E := OutlineSource(Lines(Src), 'python', Summary);
  S := Shape(E);
  AssertTrue(Summary = 'Fixture module: what it does.', 'the docstring is the summary: ' + Summary);
  AssertMissing(S, 'not_a_function', 'a def inside the docstring is text');
  AssertContains(S, 'Store@9 class/0/', 'a class');
  AssertContains(S, 'Store.get@10 method/1/', 'its method');
  AssertMissing(S, 'helper', 'a function inside a function is left out');
  AssertContains(S, 'Store.put@15 method/1/', 'an async method');
  AssertContains(S, 'main@18 def/0/', 'a top-level async def');
end;

procedure TestJS;
const
  Src: array[0..21] of string = (
    '/** Fixture script: the desktop''s helpers. */',
    'import x from "y";',
    '// function inALineComment() {}',
    '/* function inABlock() {',
    '   } */',
    'export function render(node) {',
    '  const local = () => 1;',
    '  function inner() {}',
    '}',
    'export default async function boot() {}',
    'const el = (tag, cls) => document.createElement(tag);',
    'const CONFIG = { a: 1 };',
    'class Panel extends Base {',
    '  constructor(opts) {',
    '    if (opts) {',
    '    }',
    '  }',
    '  async open(id) {',
    '  }',
    '}',
    'export interface Props { a: string }',
    'type Id = string;');
var
  E: TOutlineEntryArray;
  S, Summary: string;
begin
  WriteLn('-- js / ts');
  E := OutlineSource(Lines(Src), 'js', Summary);
  S := Shape(E);
  AssertTrue(Summary = 'Fixture script: the desktop''s helpers.', 'a /** */ header is the summary: ' + Summary);
  AssertMissing(S, 'inALineComment', 'a // comment is not code');
  AssertMissing(S, 'inABlock', 'nor a /* */ block');
  AssertContains(S, 'render@6 function/0/', 'an exported function');
  AssertMissing(S, 'local@', 'an arrow const inside a function is left out');
  AssertContains(S, 'inner@8 function/0/', 'a nested function declaration is kept (desktop.html is all of these)');
  AssertContains(S, 'boot@10 function/0/', 'export default async function');
  AssertContains(S, 'el@11 function/0/', 'a top-level arrow function');
  AssertMissing(S, 'CONFIG', 'a top-level object is not a function');
  AssertContains(S, 'Panel@13 class/0/', 'a class');
  AssertContains(S, 'Panel.constructor@14 method/1/', 'its constructor');
  AssertMissing(S, 'Panel.if', 'an if ( inside a method is not a method');
  AssertContains(S, 'Panel.open@18 method/1/', 'an async method');
  AssertContains(S, 'Props@21 interface/0/', 'a TS interface');
  AssertContains(S, 'Id@22 type/0/', 'a TS type');
end;

procedure TestOthers;
var
  E: TOutlineEntryArray;
  S, Summary: string;
begin
  WriteLn('-- go, rust, ruby, php');
  E := OutlineSource(Lines(['// Package store keeps things.', 'package store',
    'type Store struct {', '}', 'func New() *Store {', '}',
    'func (s *Store) Get(k string) string {', '}']), 'go', Summary);
  S := Shape(E);
  AssertTrue(Summary = 'Package store keeps things.', 'go summary');
  AssertContains(S, 'Store@3 type/0/', 'go type');
  AssertContains(S, 'New@5 func/0/', 'go func');
  AssertContains(S, 'Store.Get@7 method/0/', 'go method, by its receiver');

  E := OutlineSource(Lines(['pub struct Store {', '}', 'impl Store {',
    '    pub fn get(&self) -> u8 {', '    }', '}', 'pub(crate) async fn run() {', '}']),
    'rust', Summary);
  S := Shape(E);
  AssertContains(S, 'Store@1 struct/0/', 'rust struct');
  AssertContains(S, 'Store.get@4 method/1/', 'rust method inside impl');
  AssertContains(S, 'run@7 fn/0/', 'rust fn with visibility and async stripped');

  E := OutlineSource(Lines(['module Shop', 'class Cart', '  def total', '  end',
    '  def self.empty', '  end', 'end']), 'ruby', Summary);
  S := Shape(E);
  AssertContains(S, 'Cart@2 class/0/', 'ruby class');
  AssertContains(S, 'Cart.total@3 method/1/', 'ruby method');
  AssertContains(S, 'Cart.empty@5 method/1/', 'ruby class method');

  E := OutlineSource(Lines(['<?php', 'class Cart {', '    public static function total() {',
    '    }', '}', 'function helper() {}']), 'php', Summary);
  S := Shape(E);
  AssertContains(S, 'Cart.total@3 method/1/', 'php method');
  AssertContains(S, 'helper@6 function/0/', 'php function');

  WriteLn('-- strings that hold comment openers (Codex on #626)');
  E := OutlineSource(Lines(['const pattern = "/*";', 'function real() {}',
    'class Linked extends base(''http://x'') {', '  open() {', '  }', '}',
    'const t = `a template', 'function inATemplate() {', '`;',
    'function afterTemplate() {}']), 'js', Summary);
  S := Shape(E);
  AssertContains(S, 'real@2 function', 'a "/*" in a JS string opens no comment');
  AssertContains(S, 'Linked.open@4 method/1/',
                 'a // in a string does not cut the line (the class''s { is after it)');
  AssertMissing(S, 'inATemplate', 'a template literal''s lines are text');
  AssertContains(S, 'afterTemplate@10 function', 'and code resumes after it');

  E := OutlineSource(Lines(['package p', 'var r, q = ''`'', ''"''', 'func A() {}', 'var raw = `/*',
    'func InRaw() {}', '`', 'func B() {}']), 'go', Summary);
  S := Shape(E);
  AssertContains(S, 'A@3 func', 'a Go rune holding a quote or a backtick opens no string');
  AssertMissing(S, 'InRaw', 'a raw string''s lines are text');
  AssertContains(S, 'B@7 func', 'and code resumes after it');

  E := OutlineSource(Lines(['impl<''a> Store {', '    fn get(&self) -> &str { "/*" }',
    '}', 'const Q: char = ''"'';', 'fn after() {}']), 'rust', Summary);
  S := Shape(E);
  AssertContains(S, 'Store.get@2 method/1/', 'a Rust lifetime opens nothing: the impl''s { is still seen');
  AssertContains(S, 'after@5 fn', 'a string''s "/*" opens no comment, nor a char literal''s quote a string');

  E := OutlineSource(Lines(['<?php', '$p = ''/*'';', 'function real() {}']), 'php', Summary);
  S := Shape(E);
  AssertContains(S, 'real@3 function', 'a PHP string''s "/*" opens no comment');

  AssertTrue((OutlineLanguage('a.PAS') = 'pascal') and (OutlineLanguage('desktop.html') = 'js') and
             (OutlineLanguage('x.tsx') = 'js') and (OutlineLanguage('Makefile') = ''),
             'languages come from the file name');
end;

procedure TestTool;
var
  Dir, Out_, Err, Big: string;
  R: TToolRegistry;
  T: TTool;
  Pol: TSandboxPolicy;
  I: Integer;
begin
  WriteLn('-- the tool');
  Dir := JoinPath(GetTempDir, 'pc-outline-tests');
  ForceDirectories(JoinPath(Dir, 'src/sub'));
  ForceDirectories(JoinPath(Dir, 'node_modules/dep'));
  WriteFileText(JoinPath(Dir, 'src/Fixture.Unit.pas'), Lines(PascalUnit));
  WriteFileText(JoinPath(Dir, 'src/caller.py'),
    '"""Calls Helper a lot."""'#10'def run():'#10'    Helper(1); Helper(2)'#10);
  WriteFileText(JoinPath(Dir, 'src/sub/tool.js'), 'function Helper() {}'#10);
  WriteFileText(JoinPath(Dir, 'node_modules/dep/index.js'), 'function Helper() {}'#10);
  WriteFileText(JoinPath(Dir, 'src/README.md'), '# not source'#10);
  Pol := Default(TSandboxPolicy);
  ConfigureSandbox(Pol, Dir);
  R := TToolRegistry.Create;
  try
    RegisterFSTools(R);
    AssertTrue(R.Find('code_outline', T) and (T.Category = tcReadOnly) and T.IsCore,
               'code_outline registers beside grep_files, read-only');

    { symbol= }
    Out_ := R.RunTool('code_outline', '{"symbol":"Helper"}', Err);
    AssertContains(Out_, 'src/Fixture.Unit.pas:32  function Helper(N: Integer): Integer;  [interface]',
                   'the declaration, with its line and section');
    AssertContains(Out_, 'src/Fixture.Unit.pas:49  Helper  (body)', 'the body by its line, not its signature again');
    AssertContains(Out_, 'src/sub/tool.js:1', 'a declaration in another language');
    AssertMissing(Out_, 'caller.py', 'uses are not declarations');
    AssertMissing(Out_, 'node_modules', 'dependency directories are skipped, as grep_files skips them');
    Out_ := R.RunTool('code_outline', '{"symbol":"bar","path":"src"}', Err);
    AssertContains(Out_, 'TFoo.Bar', 'a method by its own name, any case');
    AssertContains(Out_, 'src/Fixture.Unit.pas:38  TFoo.Bar  (body)', 'and its body after its declaration');
    Out_ := R.RunTool('code_outline', '{"symbol":"TFoo.Make"}', Err);
    AssertContains(Out_, ':18  class function Make: TFoo;', 'Owner.Name finds a member');
    Out_ := R.RunTool('code_outline', '{"symbol":"Nowhere"}', Err);
    AssertContains(Out_, 'no declaration of "Nowhere"', 'nothing found says so');
    AssertContains(Out_, 'grep_files finds every use', 'and where to look next');

    { path=FILE }
    Out_ := R.RunTool('code_outline', '{"path":"src/Fixture.Unit.pas"}', Err);
    AssertContains(Out_, 'src/Fixture.Unit.pas -- 54 lines', 'a file: its size');
    AssertContains(Out_, 'Fixture.Unit - what this unit is for', 'its purpose');
    AssertContains(Out_, 'interface:', 'its sections');
    AssertContains(Out_, '    12  TFoo = class(TObject)', 'declarations with line numbers');
    AssertContains(Out_, '    17    procedure Bar(const X: string);', 'members indented under their type');
    AssertContains(Out_, '    49  Helper  (body)', 'an implementation body named, not repeated');
    Out_ := R.RunTool('code_outline', '{"path":"src/README.md"}', Err);
    AssertContains(Out_, 'use read_file', 'a file it cannot read says what to use');

    { path=DIR }
    Out_ := R.RunTool('code_outline', '{"path":"src"}', Err);
    AssertContains(Out_, 'src/Fixture.Unit.pas (54 lines) -- Fixture.Unit - what this unit is for',
                   'a directory: each file with its purpose');
    AssertContains(Out_, '    TShape, TFoo, EFixture, TPoint2, Limit, Greeting, GCount, Helper'#10,
                   'and the names a Pascal unit offers -- its interface, nothing more');
    AssertContains(Out_, 'src/caller.py (3 lines) -- Calls Helper a lot.', 'any language');
    AssertContains(Out_, 'src/sub/  1 source files', 'subdirectories one line each');
    AssertContains(Out_, 'other files: README.md', 'and what it does not read, by name');
    Out_ := R.RunTool('code_outline', '{}', Err);
    AssertContains(Out_, 'src/  ', 'no path is the working directory');
    AssertMissing(Out_, 'node_modules', 'without its dependency folders');

    { Budget: a file too big to outline in one go is cut, and says where to go on. }
    Big := '';
    for I := 1 to 900 do Big := Big + Format('def function_number_%d(argument_one, argument_two, argument_three):'#10'    pass'#10, [I]);
    WriteFileText(JoinPath(Dir, 'src/big.py'), Big);
    Out_ := R.RunTool('code_outline', '{"path":"src/big.py"}', Err);
    AssertTrue(Length(Out_) < OutlineBudget + 400, 'a big file''s outline stays within the budget');
    AssertContains(Out_, 'more declarations -- read_file from line', 'and the cut says where to read on');

    { A root of nothing but directories is held to the budget too (Codex
      on #626: 3,000 of them were 425 KB). }
    for I := 1 to 700 do
      ForceDirectories(JoinPath(Dir, Format('many/subdirectory_with_a_long_name_%d', [I])));
    Out_ := R.RunTool('code_outline', '{"path":"many"}', Err);
    AssertTrue(Length(Out_) < OutlineBudget + 400,
               'a directory of directories stays within the budget: ' + IntToStr(Length(Out_)));
    AssertContains(Out_, 'more subdirectories not shown', 'and says how many it left out');

    { The sandbox. }
    R.RunTool('code_outline', '{"path":"no/such/dir"}', Err);
    AssertContains(Err, 'no such path', 'a missing path is an error');
    Pol.RestrictToWorkspace := True;
    ConfigureSandbox(Pol, Dir);
    R.RunTool('code_outline', '{"path":"/etc"}', Err);
    AssertTrue(Err <> '', 'outside a restricted workspace is refused: ' + Err);
    Pol.RestrictToWorkspace := False;
    ConfigureSandbox(Pol, Dir);

    { grep_files points a failed definition hunt at code_outline. }
    Out_ := R.RunTool('grep_files', '{"path":"src","pattern":"function TFoo.Make"}', Err);
    AssertContains(Out_, 'code_outline symbol="TFoo.Make"', 'a definition-shaped grep that finds nothing names the call that would');
    Out_ := R.RunTool('grep_files', '{"path":"src","pattern":"nothing at all here"}', Err);
    AssertMissing(Out_, 'code_outline', 'an ordinary miss does not');
  finally
    R.Free;
  end;
end;

begin
  TestPascal;
  TestPython;
  TestJS;
  TestOthers;
  TestTool;
  if Failures = 0 then
    WriteLn('code_outline_tests: OK')
  else
  begin
    WriteLn('code_outline_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
