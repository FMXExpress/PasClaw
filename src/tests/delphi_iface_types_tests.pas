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
   is accidentally joined into a new identifier. *)
function StripComments(const S: string): string;
var
  i, N: Integer;
begin
  Result := S;
  N := Length(Result);
  i := 1;
  while i <= N do
  begin
    if (i < N) and (Result[i] = '(') and (Result[i + 1] = '*') then
    begin
      while (i <= N) and not ((i < N) and (Result[i] = '*') and (Result[i + 1] = ')')) do
      begin
        Result[i] := ' '; Inc(i);
      end;
      if i <= N then begin Result[i] := ' '; Inc(i); end;
      if i <= N then begin Result[i] := ' '; Inc(i); end;
    end
    else if Result[i] = '{' then
    begin
      while (i <= N) and (Result[i] <> '}') do
      begin
        Result[i] := ' '; Inc(i);
      end;
      if i <= N then begin Result[i] := ' '; Inc(i); end;
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

procedure CheckUnit(const Path: string);
var
  Src, Sec, Uses_, Base: string;
  t, p: Integer;
  Provided: Boolean;
begin
  Src := StripComments(ReadAll(Path));
  if not InterfaceSection(Src, Sec) then Exit;
  Inc(Scanned);
  Base := ExtractFileName(Path);
  if Base = 'PasClaw.Utils.pas' then Exit;   { the definition itself }

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
      Fail(Base + ' names ' + GUARDED[t] + ' in its INTERFACE but its ' +
           'interface uses clause names neither PasClaw.Utils nor ' +
           'PasClaw.Tools.Registry -- this compiles under FPC (whose ' +
           'SysUtils exports the type) and fails under dcc64 with ' +
           'E2003, taking every downstream unit with it (F2063)');
  end;
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
          own rules. }
        if (Rec.Name <> 'vendor') then Walk(Full);
      end
      else if LowerCase(ExtractFileExt(Rec.Name)) = '.pas' then
        CheckUnit(Full);
    until FindNext(Rec) <> 0;
  finally
    FindClose(Rec);
  end;
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

  Walk(Root);

  if Scanned < 100 then
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
