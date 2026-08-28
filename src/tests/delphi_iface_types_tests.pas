program delphi_iface_types_tests;
(*
  Guards the one build break CI cannot see: a unit interface that names
  a type FPC's RTL happens to export and Delphi's does not.

  TStringArray is the whole family so far. FPC's SysUtils declares it,
  so a unit can use it in its interface, never say where it came from,
  and compile perfectly here forever -- while dcc64, whose RTL has no
  such type, answers E2003 Undeclared identifier and F2063 on every
  unit downstream. That is exactly how it shipped: PasClaw.Agents grew
  a `TStringArray` out-parameter, the whole FPC suite stayed green, and
  the FireMonkey build stopped compiling.

  Nothing in `make test` runs dcc64 -- it is Windows-and-RAD-Studio
  only -- so no amount of building here would have caught it. A static
  read of the source would have, which is what this is.

  The rule: if a unit's INTERFACE names one of these types, its
  interface uses clause must name a unit that gives Delphi the type.
  Two do:

    PasClaw.Utils           declares the canonical one (aliasing the
                            RTL type on FPC so there is only ever one
                            type identity)
    PasClaw.Tools.Registry  re-exports it under {$IFNDEF FPC} for the
                            units already built on the registry

  Implementation sections are NOT checked. They are compiled as part of
  the same unit and a missing type there fails the same way, but the
  implementation uses clause is where most units already pull Utils in,
  and interfaces are where the leak actually happened -- a signature is
  visible to every consumer, which is what turns one bad line into
  F2063 across the tree.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils, Classes;

const
  { Types FPC's RTL exports and Delphi's does not. One entry today;
    the check is the shape, not the list. }
  GUARDED: array[0..0] of string = ('TStringArray');

  { Units whose interface hands Delphi a definition of them. }
  PROVIDERS: array[0..1] of string =
    ('PasClaw.Utils', 'PasClaw.Tools.Registry');

var
  Failures: Integer = 0;
  Scanned:  Integer = 0;

procedure Fail(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Inc(Failures);
end;

(* Blank out all three Pascal comment forms -- parenthesis-star, brace,
   and line -- so a type merely MENTIONED in prose does not read as a
   declaration. Written with the star form and no literal brace pair,
   because a brace comment containing one closes itself early; that is
   the same FPC trap this file is about to go looking for elsewhere.

   Replaced with spaces rather than deleted, so nothing on either side
   is accidentally joined into a new identifier.

   COMPILER DIRECTIVES ARE KEPT. A directive is spelled like a brace
   comment but is not one, and blanking it was a hole in this check:
   a uses clause reading

     SysUtils, [IFDEF FPC] PasClaw.Utils [ENDIF]

   (with real directive braces) would come through as a plain
   "PasClaw.Utils" and be accepted, while dcc64 never imports the unit
   and still fails with E2003 -- precisely the failure this file
   exists to catch. DelphiActive below reads what is kept here. *)
function StripComments(const S: string): string;
var
  i, N: Integer;
  IsDirective: Boolean;
begin
  Result := S;
  N := Length(Result);
  i := 1;
  while i <= N do
  begin
    if (i < N) and (Result[i] = '(') and (Result[i + 1] = '*') then
    begin
      { (*$...*) is a directive too, and equally must survive. }
      IsDirective := (i + 2 <= N) and (Result[i + 2] = '$');
      if IsDirective then
      begin
        while (i <= N) and not ((i < N) and (Result[i] = '*') and (Result[i + 1] = ')')) do
          Inc(i);
        Inc(i, 2);
      end
      else
      begin
        while (i <= N) and not ((i < N) and (Result[i] = '*') and (Result[i + 1] = ')')) do
        begin
          Result[i] := ' '; Inc(i);
        end;
        if i <= N then begin Result[i] := ' '; Inc(i); end;
        if i <= N then begin Result[i] := ' '; Inc(i); end;
      end;
    end
    else if Result[i] = '{' then
    begin
      IsDirective := (i < N) and (Result[i + 1] = '$');
      if IsDirective then
      begin
        while (i <= N) and (Result[i] <> '}') do Inc(i);
        Inc(i);
      end
      else
      begin
        while (i <= N) and (Result[i] <> '}') do
        begin
          Result[i] := ' '; Inc(i);
        end;
        if i <= N then begin Result[i] := ' '; Inc(i); end;
      end;
    end
    else if (i < N) and (Result[i] = '/') and (Result[i + 1] = '/') then
    begin
      while (i <= N) and not (Result[i] in [#10, #13]) do
      begin
        Result[i] := ' '; Inc(i);
      end;
    end
    else
      Inc(i);
  end;
end;

(* Blank the regions dcc64 would NOT compile, leaving the source as
   Delphi sees it.

   Only the FPC symbol is evaluated, because it is the only one whose
   value we know for certain from here: dcc64 never defines it. An
   {$IFDEF FPC} region is dead to Delphi and is blanked; {$IFNDEF FPC}
   is live and is kept -- which is what lets PasClaw.Tools.Registry's
   own {$IFNDEF FPC} alias of TStringArray still count as a
   declaration.

   Every OTHER conditional (MSWINDOWS, DEBUG, whatever) is left with
   BOTH branches intact. That is deliberate and it is the safe
   direction: keeping a branch Delphi might skip can only ever produce
   a false ALARM, which is loud, visible and one edit to fix. Dropping
   a branch Delphi does compile would produce a false pass, which is
   the bug this whole file is here to prevent. *)
function DelphiActive(const S: string): string;
type
  TRegion = record
    Live:     Boolean;   { does dcc64 compile this region? }
    Decided:  Boolean;   { did we actually evaluate it, or keep both? }
  end;
var
  i, N, DirStart, Depth: Integer;
  Dir: string;
  Stack: array[0..63] of TRegion;
  Live: Boolean;

  function AllLive: Boolean;
  var
    k: Integer;
  begin
    Result := True;
    for k := 0 to Depth - 1 do
      if Stack[k].Decided and not Stack[k].Live then Exit(False);
  end;

begin
  Result := S;
  N := Length(Result);
  Depth := 0;
  i := 1;
  while i <= N do
  begin
    if (Result[i] = '{') and (i < N) and (Result[i + 1] = '$') then
    begin
      DirStart := i;
      while (i <= N) and (Result[i] <> '}') do Inc(i);
      Dir := UpperCase(Copy(Result, DirStart, i - DirStart + 1));

      if (Pos('{$IFDEF', Dir) = 1) or (Pos('{$IFNDEF', Dir) = 1) then
      begin
        if Depth <= High(Stack) then
        begin
          { FPC is the one symbol we can decide. Anything else keeps
            both branches -- Decided stays False. }
          Stack[Depth].Decided := Pos('FPC', Dir) > 0;
          Stack[Depth].Live    := Pos('{$IFNDEF', Dir) = 1;
          Inc(Depth);
        end;
      end
      else if (Pos('{$IF ', Dir) = 1) or (Pos('{$IFOPT', Dir) = 1) then
      begin
        if Depth <= High(Stack) then
        begin
          Stack[Depth].Decided := False;
          Inc(Depth);
        end;
      end
      else if Pos('{$ELSE', Dir) = 1 then
      begin
        if Depth > 0 then Stack[Depth - 1].Live := not Stack[Depth - 1].Live;
      end
      else if Pos('{$ENDIF', Dir) = 1 then
      begin
        if Depth > 0 then Dec(Depth);
      end;

      Inc(i);
      Continue;
    end;

    Live := AllLive;
    if not Live then Result[i] := ' ';
    Inc(i);
  end;
end;

function ReadAll(const Path: string): string;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.LoadFromFile(Path);
    Result := L.Text;
  finally
    L.Free;
  end;
end;

function LowerPos(const Needle, Hay: string; From: Integer): Integer;
begin
  Result := Pos(LowerCase(Needle), LowerCase(Copy(Hay, From, MaxInt)));
  if Result > 0 then Result := Result + From - 1;
end;

(* The interface section: from the `interface` keyword to
   `implementation`, or to the end for an interface-only unit. Matched
   at the start of a line so the WORD "interface" inside a signature or
   a string cannot open a section. *)
function InterfaceSection(const Src: string; out Sec: string): Boolean;
var
  i, j: Integer;
begin
  Sec := '';
  Result := False;
  i := LowerPos(#10'interface', Src, 1);
  if i = 0 then Exit;
  j := LowerPos(#10'implementation', Src, i);
  if j = 0 then j := Length(Src);
  Sec := Copy(Src, i, j - i);
  Result := True;
end;

{ The interface's own uses clause: the first `uses ... ;` in it. }
function InterfaceUses(const Sec: string): string;
var
  i, j: Integer;
begin
  Result := '';
  i := LowerPos('uses', Sec, 1);
  if i = 0 then Exit;
  j := Pos(';', Copy(Sec, i, MaxInt));
  if j = 0 then Exit;
  Result := Copy(Sec, i, j);
end;

{ A unit that declares the type itself is answering the question its
  own way, and is fine. }
function DeclaresItself(const Sec, Ty: string): Boolean;
var
  i: Integer;
  Rest: string;
begin
  Result := False;
  i := LowerPos(Ty, Sec, 1);
  while i > 0 do
  begin
    Rest := TrimLeft(Copy(Sec, i + Length(Ty), 4));
    if (Rest <> '') and (Rest[1] = '=') then Exit(True);
    i := LowerPos(Ty, Sec, i + Length(Ty));
  end;
end;

(* The analysis, as a question rather than a verdict: returns True when
   the unit is fine, and when it is not, says which type is unbacked.
   Split out from the reporting so the fixtures below can ask it
   directly -- a check nobody has watched fail is a check nobody knows
   works. *)
function UnitIsClean(const Path: string; out Offender: string): Boolean;
var
  Src, Sec, Uses_, Base: string;
  t, p: Integer;
  Provided: Boolean;
begin
  Offender := '';
  Result := True;
  Src := StripComments(ReadAll(Path));
  if not InterfaceSection(Src, Sec) then Exit;
  Inc(Scanned);
  Base := ExtractFileName(Path);
  if Base = 'PasClaw.Utils.pas' then Exit;   { the definition itself }

  { Everything below asks a question about DELPHI, so it has to look at
    the source Delphi actually compiles. A type used only inside an
    FPC-only conditional is not Delphi's problem, and a provider
    imported only inside one does not help Delphi at all. }
  Sec := DelphiActive(Sec);
  Uses_ := InterfaceUses(Sec);
  for t := 0 to High(GUARDED) do
  begin
    if LowerPos(GUARDED[t], Sec, 1) = 0 then Continue;
    if DeclaresItself(Sec, GUARDED[t]) then Continue;
    Provided := False;
    for p := 0 to High(PROVIDERS) do
      if Pos(LowerCase(PROVIDERS[p]), LowerCase(Uses_)) > 0 then
      begin
        Provided := True;
        Break;
      end;
    if not Provided then
    begin
      Offender := GUARDED[t];
      Exit(False);
    end;
  end;
end;

procedure CheckUnit(const Path: string);
var
  Offender: string;
begin
  if UnitIsClean(Path, Offender) then Exit;
  Fail(ExtractFileName(Path) + ' names ' + Offender + ' in its INTERFACE ' +
       'where Delphi can see it, but nothing in the interface uses ' +
       'clause gives Delphi that type -- not PasClaw.Utils, not ' +
       'PasClaw.Tools.Registry, and not a declaration of its own. This ' +
       'compiles under FPC (whose SysUtils exports the type) and fails ' +
       'under dcc64 with E2003, taking every downstream unit with it ' +
       '(F2063)');
end;

procedure Walk(const Dir: string);
var
  Rec: TSearchRec;
  Full: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, Rec) <> 0 then
    Exit;
  try
    repeat
      if (Rec.Name = '.') or (Rec.Name = '..') then Continue;
      Full := IncludeTrailingPathDelimiter(Dir) + Rec.Name;
      if (Rec.Attr and faDirectory) <> 0 then
      begin
        { Vendored trees are somebody else's problem and play by their
          own rules. Fixtures are deliberately broken and are checked
          separately, by SelfTest. }
        if (Rec.Name <> 'vendor') and (Rec.Name <> 'fixtures') then Walk(Full);
      end
      else if LowerCase(ExtractFileExt(Rec.Name)) = '.pas' then
        CheckUnit(Full);
    until FindNext(Rec) <> 0;
  finally
    FindClose(Rec);
  end;
end;

(* Point the check at units whose answer is known.

   A scanner that has only ever returned "all clear" is indistinguishable
   from one that returns "all clear" unconditionally, and the conditional
   handling above is fiddly enough to deserve proof. The bad/ fixtures
   are the two shapes Codex found on #592 -- a provider imported only
   where FPC compiles, once through {$IFDEF FPC} and once through the
   {$ELSE} of an {$IFNDEF FPC} -- and the good/ ones are the near
   misses that must NOT be reported, including a unit that imports the
   provider only for Delphi and one that uses the type only for FPC. *)
procedure SelfTest;
const
  FIX = 'src/tests/fixtures/delphi_iface/';
var
  Off_: string;

  procedure MustFlag(const F: string);
  begin
    if UnitIsClean(FIX + 'bad/' + F, Off_) then
      Fail('self-test: ' + F + ' should have been reported and was not -- ' +
           'the check cannot see a provider that only exists for FPC');
  end;

  procedure MustPass(const F: string);
  begin
    if not UnitIsClean(FIX + 'good/' + F, Off_) then
      Fail('self-test: ' + F + ' is correct and was reported anyway -- ' +
           'a check that cries wolf gets switched off');
  end;

begin
  if not DirectoryExists(FIX) then
  begin
    Fail('self-test fixtures missing at ' + FIX);
    Exit;
  end;
  MustFlag('FpcOnlyImport.pas');
  MustFlag('ElseBranch.pas');
  MustPass('PlainImport.pas');
  MustPass('DelphiBranchImport.pas');
  MustPass('OwnAlias.pas');
  MustPass('FpcOnlyUse.pas');
end;

var
  Root: string;
begin
  Root := 'src';
  if ParamCount > 0 then Root := ParamStr(1);
  if not DirectoryExists(Root) then
  begin
    WriteLn('FAIL: no source tree at "' + Root + '" -- run from the repo root');
    Halt(1);
  end;

  if Root = 'src' then SelfTest;
  Scanned := 0;   { the fixtures are not part of the tree's count }
  Walk(Root);

  { A pass over nothing is not a pass. Only asserted for the real tree:
    the argument form exists so the check can be pointed at a small
    fixture directory, which is how the check itself gets tested. }
  if (Root = 'src') and (Scanned < 100) then
    Fail(Format('only %d unit(s) scanned -- the walk found almost nothing, ' +
                'so a pass here would mean nothing', [Scanned]));

  if Failures = 0 then
  begin
    WriteLn(Format('  ok: %d unit interface(s) scanned; every one that names ' +
                   'an FPC-only RTL type says where it comes from', [Scanned]));
    WriteLn('PASS: delphi_iface_types_tests');
  end
  else
  begin
    WriteLn(Format('%d problem(s) across %d unit(s)', [Failures, Scanned]));
    Halt(1);
  end;
end.
