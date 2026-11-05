(*
  PasClaw.Tools.Outline - code_outline: a map of the code, made on demand.

  An agent working in a codebase spends calls finding where things are
  before it can read or change them. Measured on a long PasClaw session,
  7% of all tool calls were repo-wide "which file is X in" searches, and
  most were for a DEFINITION -- grep -rn "function X" -- which a literal
  grep answers with every use as well. This answers the questions a
  repository map would, without putting a map in every request:

    symbol=NAME  where NAME is declared or defined under path: functions,
                 procedures, methods, classes, records, types. Not its
                 uses -- grep_files gives those.
    path=FILE    the file's declarations, with line numbers.
    path=DIR     each source file's purpose (the first paragraph of its
                 leading comment) and the names it declares;
                 subdirectories one line each, to drill into.

  Line scanners, not parsers: one per language, a few rules each, and no
  regex engine, so FPC and Delphi behave the same. Pascal is scanned with
  its comments (braces, paren-star blocks, //) and string literals taken
  out first, so a
  "procedure" in a comment is not a declaration; types are read inside
  `type` blocks, class and record members inside their bodies, routine
  bodies at the left margin of the implementation. Python, JS/TS (and
  the scripts in an .html file), Go, Rust, Ruby and PHP get the keywords
  that start a declaration. What a scanner misses, grep still finds.

  Every result is capped (OutlineBudget). A cut says what it left out and
  how to get it: a narrower path, or a file instead of a directory.
*)
unit PasClaw.Tools.Outline;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

interface

uses
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry;

const
  { Characters in one result. A file's outline that runs past this is a
    file too big to take in at once anyway; the cut names what to ask
    for instead. }
  OutlineBudget = 16000;
  { Declarations listed by symbol=. A name declared more often than this
    is a common word, and the path should be narrower. }
  OutlineMaxHits = 60;

type
  TOutlineEntry = record
    Line:    Integer;   { 1-based }
    Depth:   Integer;   { 0 = top level; 1+ = a member of a type above it }
    Kind:    string;    { function, procedure, method, class, record, type, ... }
    Name:    string;    { as declared; a method body is Owner.Name }
    Text:    string;    { the declaration's first line, trimmed and capped }
    Section: string;    { Pascal: 'interface' or 'implementation'; else '' }
  end;
  TOutlineEntryArray = array of TOutlineEntry;

{ The language a file is outlined as, from its name; '' = not one we read. }
function OutlineLanguage(const FileName: string): string;

(* The declarations in Body. Summary is the first paragraph of the file's
   leading comment (or Python docstring), one line, capped -- what the
   file is for, in its author's words. *)
function OutlineSource(const Body, Lang: string;
                       out Summary: string): TOutlineEntryArray;

function Tool_CodeOutline(const ArgsJSON: string; out ErrMsg: string): string;

procedure RegisterOutlineTool(R: TToolRegistry);

implementation

uses
  SysUtils, Classes,
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Tools.Sandbox,
  PasClaw.Tools.FS;   { IsBlockedGrepDir, LooksBinary: grep_files' rules }

function ParseStringArg(const ArgsJSON, Field: string; out V: string): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  V := '';
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      V := Obj.GetStr(Field, '');
      Result := V <> '';
    finally
      Obj.Free;
    end;
  except
    Result := False;
  end;
end;

const
  TextCap    = 140;   { one declaration line }
  SummaryCap = 160;   { one file's purpose }

{ ------------------------------------------------------------ helpers -- }

function Indent(const S: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to Length(S) do
    if S[I] = ' ' then Inc(Result)
    else if S[I] = #9 then Inc(Result, 2)
    else Break;
end;

function Cap(const S: string; N: Integer): string;
begin
  Result := Trim(S);
  if Length(Result) > N then Result := Copy(Result, 1, N - 3) + '...';
end;

function StartsWord(const S, W: string): Boolean;
{ S begins with the word W: W followed by the end, a space or a non-
  identifier character. S is already lower case. }
var
  C: Char;
begin
  Result := False;
  if Copy(S, 1, Length(W)) <> W then Exit;
  if Length(S) = Length(W) then Exit(True);
  C := S[Length(W) + 1];
  Result := not (C in ['a'..'z', 'A'..'Z', '0'..'9', '_']);
end;

function IsIdentChar(C: Char): Boolean;
begin
  Result := C in ['a'..'z', 'A'..'Z', '0'..'9', '_'];
end;

{ The identifier (dots allowed: Owner.Method) at the start of S, after
  skipping spaces; stops at the first character that cannot be in one. }
function LeadingName(const S: string; AllowDots: Boolean = True): string;
var
  I, J: Integer;
begin
  I := 1;
  while (I <= Length(S)) and (S[I] = ' ') do Inc(I);
  J := I;
  while (J <= Length(S)) and (IsIdentChar(S[J]) or
        (AllowDots and (S[J] = '.')) or (S[J] = '$')) do Inc(J);
  Result := Copy(S, I, J - I);
end;

{ After the leading word W (and spaces), the rest of S. }
function AfterWord(const S, W: string): string;
begin
  Result := TrimLeft(Copy(S, Length(W) + 1, MaxInt));
end;

procedure Add(var A: TOutlineEntryArray; var N: Integer; Line, Depth: Integer;
  const Kind, Name, Text, Section: string);
begin
  if Name = '' then Exit;
  if N >= Length(A) then SetLength(A, N * 2 + 16);
  A[N].Line := Line;
  A[N].Depth := Depth;
  A[N].Kind := Kind;
  A[N].Name := Name;
  A[N].Text := Cap(Text, TextCap);
  A[N].Section := Section;
  Inc(N);
end;

function SplitLines(const Body: string): TStringList;
begin
  Result := TStringList.Create;
  Result.Text := StringReplace(Body, #13#10, #10, [rfReplaceAll]);
end;

function StripBOM(const S: string): string;
begin
  Result := S;
  { FPC reads UTF-8 as bytes; Delphi decodes it, and the BOM is one char. }
  {$IFDEF FPC}
  if Copy(Result, 1, 3) = #$EF#$BB#$BF then Delete(Result, 1, 3);
  {$ELSE}
  if (Result <> '') and (Result[1] = #$FEFF) then Delete(Result, 1, 1);
  {$ENDIF}
end;

{ ------------------------------------------------------------ summary -- }

(* The first paragraph of the leading comment: what the file is for.
   Skips blank lines, a shebang, "<?php" and Pascal compiler directives
   (brace-dollar lines); reads //, #, brace and paren-star blocks, C
   block comments and Python docstrings. *)
function LeadingSummary(const L: TStringList; const Lang: string): string;
var
  I: Integer;
  S, T, Close_, Acc: string;
  InBlock: Boolean;

  function Clean(const X: string): string;
  var
    Y: string;
  begin
    Y := Trim(X);
    while (Y <> '') and (Y[1] in ['*', '/', '#', '!']) do Y := TrimLeft(Copy(Y, 2, MaxInt));
    Result := Y;
  end;

  function Done: Boolean;
  begin
    Result := Length(Acc) >= SummaryCap;
  end;

begin
  Result := '';
  Acc := '';
  InBlock := False;
  Close_ := '';
  for I := 0 to L.Count - 1 do
  begin
    if I > 60 then Break;   { a header is at the top or nowhere }
    S := L[I];
    if I = 0 then S := StripBOM(S);
    T := Trim(S);
    if InBlock then
    begin
      if Pos(Close_, T) > 0 then
      begin
        T := Copy(T, 1, Pos(Close_, T) - 1);
        if Clean(T) <> '' then Acc := Acc + ' ' + Clean(T);
        Break;
      end;
      if Clean(T) = '' then
      begin
        if Acc <> '' then Break;   { the paragraph ended }
        Continue;
      end;
      Acc := Acc + ' ' + Clean(T);
      if Done then Break;
      Continue;
    end;
    if T = '' then
    begin
      if Acc <> '' then Break;
      Continue;
    end;
    if (Copy(T, 1, 2) = '#!') or (Copy(T, 1, 5) = '<?php') or
       (Copy(T, 1, 2) = '{$') or (Copy(T, 1, 15) = '<!DOCTYPE html>') then Continue;
    { Line comments, a run of them. }
    if (Copy(T, 1, 2) = '//') or ((Lang = 'python') or (Lang = 'ruby')) and (Copy(T, 1, 1) = '#') then
    begin
      if Clean(T) = '' then
      begin
        if Acc <> '' then Break;
        Continue;
      end;
      Acc := Acc + ' ' + Clean(T);
      if Done then Break;
      Continue;
    end;
    if Acc <> '' then Break;   { code after a line-comment header }
    { Block comments and docstrings. }
    if Copy(T, 1, 2) = '(*' then begin Close_ := '*)'; T := Copy(T, 3, MaxInt); end
    else if Copy(T, 1, 2) = '/*' then begin Close_ := '*/'; T := Copy(T, 3, MaxInt); end
    else if (Copy(T, 1, 1) = '{') and (Lang = 'pascal') then begin Close_ := '}'; T := Copy(T, 2, MaxInt); end
    else if (Lang = 'python') and ((Copy(T, 1, 3) = '"""') or (Copy(T, 1, 3) = '''''''')) then
    begin
      Close_ := Copy(T, 1, 3);
      T := Copy(T, 4, MaxInt);
    end
    else
      Break;   { code: no header comment }
    if Pos(Close_, T) > 0 then
    begin
      Acc := Clean(Copy(T, 1, Pos(Close_, T) - 1));
      Break;
    end;
    InBlock := True;
    if Clean(T) <> '' then Acc := Clean(T);
  end;
  Result := Cap(Acc, SummaryCap);
end;

{ ------------------------------------------------------------- pascal -- }

(* Line with comments removed. InBrace / InParen carry a comment that is
   still open across lines. A string literal is replaced by '' so its
   text -- "procedure", braces -- cannot look like code. *)
function PascalCode(const Line: string; var InBrace, InParen: Boolean): string;
var
  I, N: Integer;
  C: Char;
begin
  Result := '';
  I := 1;
  N := Length(Line);
  while I <= N do
  begin
    if InBrace then
    begin
      while (I <= N) and (Line[I] <> '}') do Inc(I);
      if I <= N then begin InBrace := False; Inc(I); end;
      Continue;
    end;
    if InParen then
    begin
      while (I < N) and not ((Line[I] = '*') and (Line[I + 1] = ')')) do Inc(I);
      if I < N then begin InParen := False; Inc(I, 2); end
      else I := N + 1;
      Continue;
    end;
    C := Line[I];
    if C = '''' then
    begin
      Inc(I);
      while I <= N do
      begin
        if Line[I] = '''' then
        begin
          if (I < N) and (Line[I + 1] = '''') then Inc(I, 2)
          else Break;
        end
        else Inc(I);
      end;
      Inc(I);
      Result := Result + '''''';
      Continue;
    end;
    if C = '{' then begin InBrace := True; Inc(I); Continue; end;
    if (C = '(') and (I < N) and (Line[I + 1] = '*') then
    begin
      InParen := True;
      Inc(I, 2);
      Continue;
    end;
    if (C = '/') and (I < N) and (Line[I + 1] = '/') then Break;
    Result := Result + C;
    Inc(I);
  end;
end;

function PascalRoutineKind(const T: string; out Rest: string): string;
{ T is lower-cased, trimmed code. The routine keyword it starts with
  ('procedure', 'function', ...), '' when it is not a routine header. }
const
  K: array[0..5] of string = ('procedure', 'function', 'constructor',
                              'destructor', 'operator', 'property');
var
  S: string;
  I: Integer;
begin
  Result := '';
  Rest := '';
  S := T;
  if StartsWord(S, 'class') then S := AfterWord(S, 'class');
  if StartsWord(S, 'static') then S := AfterWord(S, 'static');
  for I := 0 to High(K) do
    if StartsWord(S, K[I]) then
    begin
      Result := K[I];
      Rest := AfterWord(S, K[I]);
      Exit;
    end;
end;

function OutlinePascal(L: TStringList): TOutlineEntryArray;
var
  I, N, Ind, TopInd: Integer;
  InBrace, InParen, InType, InRoutine: Boolean;
  Raw, Code, T, Lo, Section, Kind, Rest, Name, Rhs, InDecl: string;
  DeclInd: Integer;
  Owners: array of string;
  OwnerInd: array of Integer;
  Depth: Integer;

  procedure Push(const Owner: string; AtInd: Integer);
  begin
    SetLength(Owners, Length(Owners) + 1);
    SetLength(OwnerInd, Length(OwnerInd) + 1);
    Owners[High(Owners)] := Owner;
    OwnerInd[High(OwnerInd)] := AtInd;
  end;

  function NameFromRest(const R: string; const Orig: string): string;
  { The routine's name in its original case: R is the lowered text after
    the keyword, Orig the trimmed original line. }
  var
    P: Integer;
  begin
    Result := LeadingName(R);
    if Result = '' then Exit;
    P := Pos(Result, LowerCase(Orig));
    if P > 0 then Result := Copy(Orig, P, Length(Result));
  end;

begin
  Result := nil;
  N := 0;
  InBrace := False;
  InParen := False;
  InType := False;
  InRoutine := False;
  InDecl := '';
  DeclInd := -1;
  Section := '';
  SetLength(Owners, 0);
  SetLength(OwnerInd, 0);
  for I := 0 to L.Count - 1 do
  begin
    Raw := L[I];
    if I = 0 then Raw := StripBOM(Raw);
    Code := PascalCode(Raw, InBrace, InParen);
    T := Trim(Code);
    if T = '' then Continue;
    Lo := LowerCase(T);
    Ind := Indent(Code);

    { Inside a class / record / interface body. }
    Depth := Length(Owners);
    if Depth > 0 then
    begin
      if StartsWord(Lo, 'end') and (Ind <= OwnerInd[High(OwnerInd)]) then
      begin
        SetLength(Owners, Depth - 1);
        SetLength(OwnerInd, Depth - 1);
        Continue;
      end;
      Kind := PascalRoutineKind(Lo, Rest);
      if (Kind <> '') and (Kind <> 'property') then
      begin
        Name := NameFromRest(Rest, T);
        Add(Result, N, I + 1, Depth, 'method', Owners[High(Owners)] + '.' + Name,
            T, Section);
        Continue;
      end;
      { A type nested in a class: its own body to track. }
      if (Pos('=', Lo) > 0) then
      begin
        Rhs := Trim(Copy(Lo, Pos('=', Lo) + 1, MaxInt));
        if (StartsWord(Rhs, 'class') or StartsWord(Rhs, 'record') or
            StartsWord(Rhs, 'packed')) and not StartsWord(Rhs, 'class of') and
           (Copy(Rhs, Length(Rhs), 1) <> ';') then
        begin
          Name := LeadingName(T, False);
          Add(Result, N, I + 1, Depth, 'type', Owners[High(Owners)] + '.' + Name, T, Section);
          Push(Owners[High(Owners)] + '.' + Name, Ind);
        end;
      end;
      Continue;
    end;

    { Section keywords. }
    if (Lo = 'interface') or (Lo = 'implementation') then
    begin
      Section := Lo;
      InType := False;
      InDecl := '';
      Continue;
    end;
    if (Lo = 'initialization') or (Lo = 'finalization') or StartsWord(Lo, 'begin') then
    begin
      InType := False;
      InDecl := '';
      if Ind = 0 then InRoutine := InRoutine and not ((Lo = 'initialization') or (Lo = 'finalization'));
      Continue;
    end;
    { A routine body ends at its column-0 "end;". Until then its local
      type / var / const sections -- also at column 0 here -- are the
      routine's, not the unit's. }
    if InRoutine then
    begin
      if (Ind = 0) and StartsWord(Lo, 'end') then InRoutine := False
      else if (Ind > 0) or (PascalRoutineKind(Lo, Rest) = '') then Continue;
    end;
    if StartsWord(Lo, 'type') then
    begin
      InType := True;
      InDecl := '';
      Lo := Trim(AfterWord(Lo, 'type'));   { "type TFoo = ..." on one line }
      T := Trim(AfterWord(T, 'type'));
      if Lo = '' then Continue;
    end;
    { Unit-level constants and variables: what a role prompt, a limit or
      a deny list is. A routine's own are skipped above. }
    if StartsWord(Lo, 'var') or StartsWord(Lo, 'const') or
       StartsWord(Lo, 'resourcestring') or StartsWord(Lo, 'threadvar') then
    begin
      InType := False;
      InDecl := LeadingName(Lo, False);
      if InDecl = 'resourcestring' then InDecl := 'const';
      if InDecl = 'threadvar' then InDecl := 'var';
      DeclInd := -1;
      T := Trim(AfterWord(T, LeadingName(T, False)));
      { "const X = 1;" on the keyword's line: that one, and the block's
        indentation is still the next line's. }
      Name := LeadingName(T, False);
      Rest := TrimLeft(Copy(T, Length(Name) + 1, MaxInt));
      if (Name <> '') and (Rest <> '') and ((Rest[1] = '=') or (Rest[1] = ':')) then
        Add(Result, N, I + 1, 0, InDecl, Name, Cap(T, 90), Section);
      Continue;
    end;
    if StartsWord(Lo, 'uses') or StartsWord(Lo, 'unit') or
       StartsWord(Lo, 'program') or StartsWord(Lo, 'library') then
    begin
      InType := False;
      InDecl := '';
      Continue;
    end;
    if (InDecl <> '') and (PascalRoutineKind(Lo, Rest) = '') then
    begin
      { Only lines at the block's first indentation are declarations; the
        rest continue one (a long string, an array's items). }
      if DeclInd < 0 then DeclInd := Ind;
      Name := LeadingName(T, False);
      Rest := TrimLeft(Copy(T, Length(Name) + 1, MaxInt));
      if (Ind = DeclInd) and (Name <> '') and (Rest <> '') and
         ((Rest[1] = '=') or (Rest[1] = ':') or (Rest[1] = ',')) then
        Add(Result, N, I + 1, 0, InDecl, Name, Cap(T, 90), Section);
      Continue;
    end;

    { Routines at the left margin: the interface's API, the
      implementation's bodies. Nested routines are left out. }
    Kind := PascalRoutineKind(Lo, Rest);
    if (Kind <> '') and (Kind <> 'property') and (Ind = 0) then
    begin
      InType := False;
      InDecl := '';
      { A body follows in the implementation, unless it is declared
        elsewhere: forward, external. }
      InRoutine := (Section = 'implementation') and (Pos('forward;', Lo) = 0) and
                   (Pos('external', Lo) = 0);
      Name := NameFromRest(Rest, T);
      if Pos('.', Name) > 0 then
        Add(Result, N, I + 1, 0, 'method', Name, T, Section)
      else
        Add(Result, N, I + 1, 0, Kind, Name, T, Section);
      Continue;
    end;

    { Types: "TName = class(...)", "= record", "= (a, b)", ... }
    if InType and (Pos('=', Lo) > 1) then
    begin
      Name := LeadingName(T, False);
      if (Name = '') or (Pos('<', T) > 0) and (Pos('<', T) < Pos('=', T)) then
        Name := Trim(Copy(T, 1, Pos('=', T) - 1));   { generics: TList<T> }
      Rhs := Trim(Copy(Lo, Pos('=', Lo) + 1, MaxInt));
      if StartsWord(Rhs, 'packed') then Rhs := AfterWord(Rhs, 'packed');
      if StartsWord(Rhs, 'class of') then Kind := 'type'
      else if StartsWord(Rhs, 'class') then Kind := 'class'
      else if StartsWord(Rhs, 'record') then Kind := 'record'
      else if StartsWord(Rhs, 'interface') or StartsWord(Rhs, 'dispinterface') then Kind := 'interface'
      else if StartsWord(Rhs, 'object') then Kind := 'object'
      else if Copy(Rhs, 1, 1) = '(' then Kind := 'enum'
      else Kind := 'type';
      Add(Result, N, I + 1, 0, Kind, Name, T, Section);
      { A body follows unless the declaration ends on this line:
        "TFoo = class(Exception);", "IFoo = interface;" (forward). }
      if ((Kind = 'class') or (Kind = 'record') or (Kind = 'interface') or
          (Kind = 'object')) and (Copy(Rhs, Length(Rhs), 1) <> ';') then
      begin
        TopInd := Ind;
        Push(Name, TopInd);
      end;
      Continue;
    end;
  end;
  SetLength(Result, N);
end;

{ --------------------------------------------------- the other scanners -- }

(* Python: class and def, by indentation. A def inside a def is left out;
   a def inside a class is a method. Triple-quoted strings are skipped. *)
function OutlinePython(L: TStringList): TOutlineEntryArray;
var
  I, N, Ind, K: Integer;
  Raw, T, Name, Quote: string;
  Classes: array of string;
  ClassInd: array of Integer;
  InStr: Boolean;
  DefInd: Integer;   { indentation of the def we are inside, -1 = none }

  function CountOf(const Sub, S: string): Integer;
  var
    P: Integer;
    R: string;
  begin
    Result := 0;
    R := S;
    P := Pos(Sub, R);
    while P > 0 do
    begin
      Inc(Result);
      R := Copy(R, P + Length(Sub), MaxInt);
      P := Pos(Sub, R);
    end;
  end;

begin
  Result := nil;
  N := 0;
  InStr := False;
  Quote := '';
  DefInd := -1;
  SetLength(Classes, 0);
  SetLength(ClassInd, 0);
  for I := 0 to L.Count - 1 do
  begin
    Raw := L[I];
    T := Trim(Raw);
    if InStr then
    begin
      if Odd(CountOf(Quote, T)) then InStr := False;
      Continue;
    end;
    if (Pos('"""', T) > 0) and Odd(CountOf('"""', T)) then begin InStr := True; Quote := '"""'; end
    else if (Pos('''''''', T) > 0) and Odd(CountOf('''''''', T)) then begin InStr := True; Quote := ''''''''; end;
    if (T = '') or (T[1] = '#') then Continue;
    Ind := Indent(Raw);
    { Leaving a block: pop classes at or below this indentation. }
    K := Length(Classes);
    while (K > 0) and (Ind <= ClassInd[K - 1]) do Dec(K);
    SetLength(Classes, K);
    SetLength(ClassInd, K);
    if (DefInd >= 0) and (Ind <= DefInd) then DefInd := -1;
    if T[1] = '@' then Continue;   { decorators }
    if StartsWord(T, 'class') then
    begin
      if DefInd >= 0 then Continue;
      Name := LeadingName(AfterWord(T, 'class'), False);
      Add(Result, N, I + 1, K, 'class', Name, T, '');
      SetLength(Classes, K + 1);
      SetLength(ClassInd, K + 1);
      Classes[K] := Name;
      ClassInd[K] := Ind;
      Continue;
    end;
    if StartsWord(T, 'def') or StartsWord(T, 'async') and StartsWord(AfterWord(T, 'async'), 'def') then
    begin
      if DefInd >= 0 then Continue;   { a function inside a function }
      if StartsWord(T, 'async') then Name := AfterWord(AfterWord(T, 'async'), 'def')
      else Name := AfterWord(T, 'def');
      Name := LeadingName(Name, False);
      if K > 0 then
        Add(Result, N, I + 1, K, 'method', Classes[K - 1] + '.' + Name, T, '')
      else
        Add(Result, N, I + 1, 0, 'def', Name, T, '');
      DefInd := Ind;
    end;
  end;
  SetLength(Result, N);
end;

{ Remove // comments and /* */ blocks (C-family). InBlock carries an open
  block across lines. Strings are not tracked: a "//" inside one cuts the
  line short, which costs at worst a declaration's tail. }
function CCode(const Line: string; var InBlock: Boolean): string;
var
  I, N: Integer;
begin
  Result := '';
  I := 1;
  N := Length(Line);
  while I <= N do
  begin
    if InBlock then
    begin
      while (I < N) and not ((Line[I] = '*') and (Line[I + 1] = '/')) do Inc(I);
      if I < N then begin InBlock := False; Inc(I, 2); end else I := N + 1;
      Continue;
    end;
    if (Line[I] = '/') and (I < N) and (Line[I + 1] = '*') then
    begin
      InBlock := True;
      Inc(I, 2);
      Continue;
    end;
    if (Line[I] = '/') and (I < N) and (Line[I + 1] = '/') then Break;
    Result := Result + Line[I];
    Inc(I);
  end;
end;

function StripWords(const S: string; const Words: array of string): string;
var
  Again: Boolean;
  I: Integer;
begin
  Result := S;
  repeat
    Again := False;
    for I := 0 to High(Words) do
      if StartsWord(Result, Words[I]) then
      begin
        Result := AfterWord(Result, Words[I]);
        Again := True;
      end;
  until not Again;
end;

(* JavaScript / TypeScript (and the scripts of an .html page): function
   declarations at any depth, classes and their methods, TS interfaces /
   types / enums, and top-level `const x = (...) =>` / `= function`. *)
function OutlineJS(L: TStringList): TOutlineEntryArray;
const
  NotMethods: array[0..9] of string = ('if', 'for', 'while', 'switch', 'catch',
    'return', 'function', 'else', 'do', 'with');
var
  I, N, Ind, ClassInd, J: Integer;
  InBlock, IsKw: Boolean;
  T, S, Name, ClassName, Rest: string;
begin
  Result := nil;
  N := 0;
  InBlock := False;
  ClassName := '';
  ClassInd := -1;
  for I := 0 to L.Count - 1 do
  begin
    S := CCode(L[I], InBlock);
    T := Trim(S);
    if T = '' then Continue;
    Ind := Indent(S);
    if (ClassInd >= 0) and (Ind <= ClassInd) and (T[1] = '}') then
    begin
      ClassInd := -1;
      ClassName := '';
      Continue;
    end;
    T := StripWords(T, ['export', 'default', 'declare', 'abstract']);
    if StartsWord(T, 'async') then Rest := AfterWord(T, 'async') else Rest := T;
    if StartsWord(Rest, 'function') then
    begin
      Rest := AfterWord(Rest, 'function');
      if Copy(Rest, 1, 1) = '*' then Rest := TrimLeft(Copy(Rest, 2, MaxInt));
      Name := LeadingName(Rest, False);
      Add(Result, N, I + 1, 0, 'function', Name, Trim(S), '');
      Continue;
    end;
    if StartsWord(T, 'class') then
    begin
      Name := LeadingName(AfterWord(T, 'class'), False);
      Add(Result, N, I + 1, 0, 'class', Name, Trim(S), '');
      if Pos('{', T) > 0 then
      begin
        ClassName := Name;
        ClassInd := Ind;
      end;
      Continue;
    end;
    if (Ind = 0) and (StartsWord(T, 'interface') or StartsWord(T, 'enum') or
       StartsWord(T, 'type') and (Pos('=', T) > 0)) then
    begin
      Name := LeadingName(AfterWord(T, LeadingName(T, False)), False);
      Add(Result, N, I + 1, 0, LeadingName(T, False), Name, Trim(S), '');
      Continue;
    end;
    if (Ind = 0) and (StartsWord(T, 'const') or StartsWord(T, 'let') or StartsWord(T, 'var')) then
    begin
      Rest := AfterWord(T, LeadingName(T, False));
      Name := LeadingName(Rest, False);
      Rest := Trim(Copy(Rest, Length(Name) + 1, MaxInt));
      if Copy(Rest, 1, 1) = ':' then Rest := Copy(Rest, Pos('=', Rest), MaxInt);   { TS type }
      if Copy(Rest, 1, 1) = '=' then
      begin
        Rest := TrimLeft(Copy(Rest, 2, MaxInt));
        if StartsWord(Rest, 'async') then Rest := AfterWord(Rest, 'async');
        if StartsWord(Rest, 'function') or (Copy(Rest, 1, 1) = '(') and (Pos('=>', Rest) > 0) or
           (Pos('=>', Rest) > 0) and (Pos('=>', Rest) <= Length(LeadingName(Rest, False)) + 3) then
          Add(Result, N, I + 1, 0, 'function', Name, Trim(S), '');
      end;
      Continue;
    end;
    { A method: "name(args) {" one level inside a class body. }
    if (ClassInd >= 0) and (Ind > ClassInd) and (Ind <= ClassInd + 4) then
    begin
      Rest := StripWords(T, ['static', 'async', 'get', 'set', 'public', 'private',
                             'protected', 'readonly', 'override']);
      if Copy(Rest, 1, 1) = '#' then Rest := Copy(Rest, 2, MaxInt);
      Name := LeadingName(Rest, False);
      IsKw := False;
      for J := 0 to High(NotMethods) do
        if Name = NotMethods[J] then IsKw := True;
      if (Name <> '') and not IsKw and
         (Copy(TrimLeft(Copy(Rest, Length(Name) + 1, MaxInt)), 1, 1) = '(') and
         (Pos('{', T) > 0) then
        Add(Result, N, I + 1, 1, 'method', ClassName + '.' + Name, Trim(S), '');
    end;
  end;
  SetLength(Result, N);
end;

(* Go: func (with a receiver, Type.Name), and top-level type declarations. *)
function OutlineGo(L: TStringList): TOutlineEntryArray;
var
  I, N: Integer;
  InBlock: Boolean;
  S, T, Rest, Recv, Name: string;
begin
  Result := nil;
  N := 0;
  InBlock := False;
  for I := 0 to L.Count - 1 do
  begin
    S := CCode(L[I], InBlock);
    T := Trim(S);
    if (T = '') or (Indent(S) > 0) then Continue;
    if StartsWord(T, 'func') then
    begin
      Rest := AfterWord(T, 'func');
      Recv := '';
      if Copy(Rest, 1, 1) = '(' then
      begin
        Recv := Copy(Rest, 2, Pos(')', Rest) - 2);   { "r *Server" }
        Recv := Trim(Copy(Recv, LastDelimiter(' *', Recv) + 1, MaxInt));
        Rest := TrimLeft(Copy(Rest, Pos(')', Rest) + 1, MaxInt));
      end;
      Name := LeadingName(Rest, False);
      if Recv <> '' then
        Add(Result, N, I + 1, 0, 'method', Recv + '.' + Name, T, '')
      else
        Add(Result, N, I + 1, 0, 'func', Name, T, '');
    end
    else if StartsWord(T, 'type') and (Copy(AfterWord(T, 'type'), 1, 1) <> '(') then
      Add(Result, N, I + 1, 0, 'type', LeadingName(AfterWord(T, 'type'), False), T, '');
  end;
  SetLength(Result, N);
end;

(* Rust: fn, struct, enum, trait, mod, impl -- with their visibility and
   qualifiers stripped; an fn inside an impl is a method. *)
function OutlineRust(L: TStringList): TOutlineEntryArray;
const
  Kinds: array[0..5] of string = ('fn', 'struct', 'enum', 'trait', 'mod', 'impl');
var
  I, N, K, Ind, ImplInd: Integer;
  InBlock: Boolean;
  S, T, Name, Impl: string;
begin
  Result := nil;
  N := 0;
  InBlock := False;
  ImplInd := -1;
  Impl := '';
  for I := 0 to L.Count - 1 do
  begin
    S := CCode(L[I], InBlock);
    T := Trim(S);
    if T = '' then Continue;
    Ind := Indent(S);
    if (ImplInd >= 0) and (Ind <= ImplInd) and (T[1] = '}') then
    begin
      ImplInd := -1;
      Impl := '';
      Continue;
    end;
    if Copy(T, 1, 4) = 'pub(' then T := TrimLeft(Copy(T, Pos(')', T) + 1, MaxInt));
    T := StripWords(T, ['pub', 'async', 'unsafe', 'const', 'extern', 'default']);
    if Copy(T, 1, 1) = '"' then T := TrimLeft(Copy(T, Pos('"', Copy(T, 2, MaxInt)) + 2, MaxInt));
    for K := 0 to High(Kinds) do
      if StartsWord(T, Kinds[K]) then
      begin
        Name := AfterWord(T, Kinds[K]);
        if Copy(Name, 1, 1) = '<' then Name := TrimLeft(Copy(Name, Pos('>', Name) + 1, MaxInt));
        if Kinds[K] = 'impl' then
        begin
          Name := Trim(Copy(Name, 1, Pos('{', Name + '{') - 1));
          Add(Result, N, I + 1, 0, 'impl', Name, Trim(S), '');
          if Pos('{', T) > 0 then begin ImplInd := Ind; Impl := Name; end;
        end
        else if (Kinds[K] = 'fn') and (ImplInd >= 0) and (Ind > ImplInd) then
          Add(Result, N, I + 1, 1, 'method', Impl + '.' + LeadingName(Name, False), Trim(S), '')
        else
          Add(Result, N, I + 1, 0, Kinds[K], LeadingName(Name, False), Trim(S), '');
        Break;
      end;
  end;
  SetLength(Result, N);
end;

(* Ruby: module, class, def (a def inside a class is a method). PHP:
   class / interface / trait / function, with modifiers stripped. Both
   are keyword-led, so one scanner with two vocabularies. *)
function OutlineKeywordLang(L: TStringList; IsPHP: Boolean): TOutlineEntryArray;
var
  I, N, Ind, OwnerInd: Integer;
  InBlock: Boolean;
  S, T, Name, Owner, Kind: string;
begin
  Result := nil;
  N := 0;
  InBlock := False;
  Owner := '';
  OwnerInd := -1;
  for I := 0 to L.Count - 1 do
  begin
    if IsPHP then S := CCode(L[I], InBlock) else
    begin
      S := L[I];
      if Pos('#', S) > 0 then S := Copy(S, 1, Pos('#', S) - 1);
    end;
    T := Trim(S);
    if T = '' then Continue;
    Ind := Indent(S);
    if (OwnerInd >= 0) and (Ind <= OwnerInd) and ((T = 'end') or (T[1] = '}')) then
    begin
      Owner := '';
      OwnerInd := -1;
      Continue;
    end;
    if IsPHP then
      T := StripWords(T, ['public', 'private', 'protected', 'static', 'abstract',
                          'final', 'readonly']);
    Kind := LeadingName(T, False);
    if (Kind = 'class') or (Kind = 'module') or (IsPHP and ((Kind = 'interface') or (Kind = 'trait'))) then
    begin
      Name := LeadingName(AfterWord(T, Kind), not IsPHP);
      Add(Result, N, I + 1, 0, Kind, Name, Trim(S), '');
      Owner := Name;
      OwnerInd := Ind;
    end
    else if (not IsPHP and (Kind = 'def')) or (IsPHP and (Kind = 'function')) then
    begin
      Name := LeadingName(AfterWord(T, Kind), not IsPHP);
      if (not IsPHP) and (Copy(Name, 1, 5) = 'self.') then Name := Copy(Name, 6, MaxInt);
      if (Owner <> '') and (Ind > OwnerInd) then
        Add(Result, N, I + 1, 1, 'method', Owner + '.' + Name, Trim(S), '')
      else
        Add(Result, N, I + 1, 0, Kind, Name, Trim(S), '');
    end;
  end;
  SetLength(Result, N);
end;

{ ---------------------------------------------------------- dispatch -- }

function OutlineLanguage(const FileName: string): string;
var
  E: string;
begin
  E := LowerCase(ExtractFileExt(FileName));
  if (E = '.pas') or (E = '.pp') or (E = '.inc') or (E = '.dpr') or
     (E = '.lpr') or (E = '.dpk') then Result := 'pascal'
  else if (E = '.py') or (E = '.pyi') then Result := 'python'
  else if (E = '.js') or (E = '.mjs') or (E = '.cjs') or (E = '.jsx') or
          (E = '.ts') or (E = '.tsx') or (E = '.mts') or (E = '.cts') or
          (E = '.html') or (E = '.htm') then Result := 'js'
  else if E = '.go' then Result := 'go'
  else if E = '.rs' then Result := 'rust'
  else if E = '.rb' then Result := 'ruby'
  else if E = '.php' then Result := 'php'
  else Result := '';
end;

function OutlineSource(const Body, Lang: string;
                       out Summary: string): TOutlineEntryArray;
var
  L: TStringList;
begin
  Result := nil;
  Summary := '';
  L := SplitLines(Body);
  try
    if Lang <> 'js' then Summary := LeadingSummary(L, Lang)
    else if Pos('<html', LowerCase(Copy(Body, 1, 400))) = 0 then
      Summary := LeadingSummary(L, Lang);
    if Lang = 'pascal' then Result := OutlinePascal(L)
    else if Lang = 'python' then Result := OutlinePython(L)
    else if Lang = 'js' then Result := OutlineJS(L)
    else if Lang = 'go' then Result := OutlineGo(L)
    else if Lang = 'rust' then Result := OutlineRust(L)
    else if Lang = 'ruby' then Result := OutlineKeywordLang(L, False)
    else if Lang = 'php' then Result := OutlineKeywordLang(L, True);
  finally
    L.Free;
  end;
end;

{ --------------------------------------------------------- the tool -- }

const
  MaxSourceBytes = 4 * 1024 * 1024;   { a "source file" bigger than this is data }

function ReadSource(const Path: string; out Body: string): Boolean;
var
  SR: TSearchRec;
begin
  Result := False;
  Body := '';
  if FindFirst(Path, faAnyFile, SR) = 0 then
  try
    if SR.Size > MaxSourceBytes then Exit;
  finally
    FindClose(SR);
  end;
  try
    Body := ReadFileText(Path);
  except
    Exit;
  end;
  Result := not LooksBinary(Body);
end;

function LineCount(const Body: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to Length(Body) do
    if Body[I] = #10 then Inc(Result);
  if (Body <> '') and (Body[Length(Body)] <> #10) then Inc(Result);
end;

{ How a path is shown: as the caller wrote the root, then the rest. }
function ShowPath(const Root, Shown, Full: string): string;
var
  Rel: string;
begin
  Rel := Copy(Full, Length(IncludeTrailingPathDelimiter(Root)) + 1, MaxInt);
  if Full = Root then Rel := '';
  Rel := StringReplace(Rel, '\', '/', [rfReplaceAll]);
  if (Shown = '') or (Shown = '.') or (Shown = './') then Result := Rel
  else if Rel = '' then Result := Shown
  else Result := ExcludeTrailingPathDelimiter(Shown) + '/' + Rel;
  if Result = '' then Result := ExtractFileName(Full);
end;

{ Sorted children of Dir: subdirectories and files, minus the skip list. }
procedure ListDir(const Dir: string; Dirs, Files: TStringList);
var
  SR: TSearchRec;
begin
  if FindFirst(JoinPath(Dir, '*'), faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') or (SR.Name = '') or (SR.Name[1] = '.') then
        Continue;
      if (SR.Attr and faDirectory) <> 0 then
      begin
        if not IsBlockedGrepDir(SR.Name) then Dirs.Add(SR.Name);
      end
      else
        Files.Add(SR.Name);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  Dirs.Sort;
  Files.Sort;
end;

{ Source files under Dir, recursively, in order; at most Limit. }
procedure CollectSources(const Dir: string; Out_: TStringList; Limit: Integer);
var
  Dirs, Files: TStringList;
  I: Integer;
begin
  if Out_.Count >= Limit then Exit;
  Dirs := TStringList.Create;
  Files := TStringList.Create;
  try
    ListDir(Dir, Dirs, Files);
    for I := 0 to Files.Count - 1 do
      if (OutlineLanguage(Files[I]) <> '') and (Out_.Count < Limit) then
        Out_.Add(JoinPath(Dir, Files[I]));
    for I := 0 to Dirs.Count - 1 do
      CollectSources(JoinPath(Dir, Dirs[I]), Out_, Limit);
  finally
    Dirs.Free;
    Files.Free;
  end;
end;

function SymbolMatches(const EntryName, Symbol: string): Boolean;
var
  E, S: string;
begin
  E := LowerCase(EntryName);
  S := LowerCase(Symbol);
  Result := (E = S) or
            ((Pos('.', S) = 0) and (Length(E) > Length(S)) and
             (Copy(E, Length(E) - Length(S), MaxInt) = '.' + S));
end;

function OutlineSymbol(const Root, Shown, Symbol: string): string;
var
  Paths, Declared: TStringList;
  Entries: TOutlineEntryArray;
  Body, Summary, Where, Name: string;
  Sb: TStringBuilder;
  I, J, Hits, Scanned: Integer;
begin
  Paths := TStringList.Create;
  Declared := TStringList.Create;
  Sb := TStringBuilder.Create;
  try
    if DirectoryExists(Root) then CollectSources(Root, Paths, 20000)
    else Paths.Add(Root);
    Hits := 0;
    Scanned := 0;
    for I := 0 to Paths.Count - 1 do
    begin
      if not ReadSource(Paths[I], Body) then Continue;
      Inc(Scanned);
      Entries := OutlineSource(Body, OutlineLanguage(Paths[I]), Summary);
      Declared.Clear;
      for J := 0 to High(Entries) do
        if SymbolMatches(Entries[J].Name, Symbol) then
        begin
          Inc(Hits);
          if Hits > OutlineMaxHits then Continue;
          Sb.Append(ShowPath(Root, Shown, Paths[I])).Append(':')
            .Append(IntToStr(Entries[J].Line)).Append('  ');
          { A Pascal body whose declaration was just shown: its line is
            the news, the signature would be the same text again. The
            method's own name stays (TFoo.Bar) -- it says whose it is. }
          Name := Entries[J].Name;
          if (Entries[J].Section = 'implementation') and
             ((Declared.IndexOf(LowerCase(Name)) >= 0) or
              (Pos('.', Name) > 0) and
              (Declared.IndexOf(LowerCase(Copy(Name, LastDelimiter('.', Name) + 1, MaxInt))) >= 0)) then
            Sb.Append(Name).Append('  (body)').Append(#10)
          else
          begin
            Where := '';
            if Entries[J].Section <> '' then Where := '  [' + Entries[J].Section + ']';
            Sb.Append(Entries[J].Text).Append(Where).Append(#10);
          end;
          if Entries[J].Section = 'interface' then
          begin
            Name := LowerCase(Entries[J].Name);
            Declared.Add(Name);
            if Pos('.', Name) > 0 then
              Declared.Add(Copy(Name, LastDelimiter('.', Name) + 1, MaxInt));
          end;
        end;
    end;
    if Hits = 0 then
      Result := Format('(no declaration of "%s" in %d source file(s) under %s -- ' +
                       'it may be declared in a language code_outline does not ' +
                       'read, or only used here; grep_files finds every use)',
                       [Symbol, Scanned, Shown])
    else
    begin
      Result := Sb.ToString;
      if Hits > OutlineMaxHits then
        Result := Result + Format('(+%d more declarations of "%s": narrow the path)'#10,
                                  [Hits - OutlineMaxHits, Symbol]);
    end;
  finally
    Sb.Free;
    Declared.Free;
    Paths.Free;
  end;
end;

function OutlineOneFile(const Path, Shown: string): string;
var
  Body, Summary, Section, Line_: string;
  Entries: TOutlineEntryArray;
  Iface: TStringList;
  Sb: TStringBuilder;
  I, Cut: Integer;
begin
  if OutlineLanguage(Path) = '' then
    Exit(Format('(%s: code_outline reads Pascal, Python, JS/TS, Go, Rust, Ruby ' +
                'and PHP; use read_file for this one)', [Shown]));
  if not ReadSource(Path, Body) then
    Exit(Format('(%s: not a text source file code_outline can read)', [Shown]));
  Entries := OutlineSource(Body, OutlineLanguage(Path), Summary);
  Sb := TStringBuilder.Create;
  Iface := TStringList.Create;
  try
    Iface.Sorted := True;
    Iface.Duplicates := dupIgnore;
    Sb.Append(Shown).Append(' -- ').Append(IntToStr(LineCount(Body)))
      .Append(' lines, ').Append(IntToStr(Length(Entries))).Append(' declarations')
      .Append(#10);
    if Summary <> '' then Sb.Append(Summary).Append(#10);
    Section := '';
    Cut := 0;
    for I := 0 to High(Entries) do
    begin
      if Sb.Length > OutlineBudget then
      begin
        Cut := Length(Entries) - I;
        Break;
      end;
      if Entries[I].Section <> Section then
      begin
        Section := Entries[I].Section;
        Sb.Append(Section).Append(':').Append(#10);
      end;
      if Section = 'interface' then Iface.Add(LowerCase(Entries[I].Name));
      Line_ := Format('%6d  ', [Entries[I].Line]) + StringOfChar(' ', 2 * Entries[I].Depth);
      { A Pascal body whose signature the interface already showed: its
        line is what is new, so the name is enough. }
      if (Section = 'implementation') and (Iface.IndexOf(LowerCase(Entries[I].Name)) >= 0) then
        Sb.Append(Line_).Append(Entries[I].Name).Append('  (body)').Append(#10)
      else
        Sb.Append(Line_).Append(Entries[I].Text).Append(#10);
    end;
    if Cut > 0 then
      Sb.Append(Format('(+%d more declarations -- read_file from line %d)'#10,
                       [Cut, Entries[Length(Entries) - Cut].Line]));
    if Length(Entries) = 0 then
      Sb.Append('(no declarations found)').Append(#10);
    Result := Sb.ToString;
  finally
    Iface.Free;
    Sb.Free;
  end;
end;

{ The names a file offers: a Pascal unit's interface, else its top level. }
function OfferedNames(const Entries: TOutlineEntryArray): string;
const
  MaxNames = 24;
var
  I, Shown_, Total: Integer;
  HasIface: Boolean;
begin
  Result := '';
  HasIface := False;
  for I := 0 to High(Entries) do
    if Entries[I].Section = 'interface' then HasIface := True;
  Shown_ := 0;
  Total := 0;
  for I := 0 to High(Entries) do
  begin
    if Entries[I].Depth > 0 then Continue;
    if HasIface and (Entries[I].Section <> 'interface') then Continue;
    Inc(Total);
    if Shown_ >= MaxNames then Continue;
    if Result <> '' then Result := Result + ', ';
    Result := Result + Entries[I].Name;
    Inc(Shown_);
  end;
  if Total > Shown_ then Result := Result + Format(', ... (+%d)', [Total - Shown_]);
end;

function OutlineDirectory(const Dir, Shown: string): string;
var
  Dirs, Files, Sub, Others: TStringList;
  Entries: TOutlineEntryArray;
  Body, Summary, Names, Prefix: string;
  Sb: TStringBuilder;
  I, Cut: Integer;
begin
  Dirs := TStringList.Create;
  Files := TStringList.Create;
  Sub := TStringList.Create;
  Others := TStringList.Create;
  Sb := TStringBuilder.Create;
  try
    ListDir(Dir, Dirs, Files);
    Prefix := ShowPath(Dir, Shown, Dir);
    if (Prefix <> '') and (Prefix[Length(Prefix)] <> '/') then Prefix := Prefix + '/';
    if (Shown = '') or (Shown = '.') then Prefix := '';
    Cut := 0;
    for I := 0 to Files.Count - 1 do
    begin
      if OutlineLanguage(Files[I]) = '' then
      begin
        Others.Add(Files[I]);
        Continue;
      end;
      if Sb.Length > OutlineBudget then
      begin
        Inc(Cut);
        Continue;
      end;
      if not ReadSource(JoinPath(Dir, Files[I]), Body) then Continue;
      Entries := OutlineSource(Body, OutlineLanguage(Files[I]), Summary);
      Sb.Append(Prefix).Append(Files[I]).Append(' (').Append(IntToStr(LineCount(Body)))
        .Append(' lines)');
      if Summary <> '' then Sb.Append(' -- ').Append(Summary);
      Sb.Append(#10);
      Names := OfferedNames(Entries);
      if Names <> '' then Sb.Append('    ').Append(Names).Append(#10);
    end;
    for I := 0 to Dirs.Count - 1 do
    begin
      Sub.Clear;
      CollectSources(JoinPath(Dir, Dirs[I]), Sub, 1000);
      Sb.Append(Prefix).Append(Dirs[I]).Append('/  ').Append(IntToStr(Sub.Count));
      if Sub.Count = 1000 then Sb.Append('+');
      Sb.Append(' source files').Append(#10);
    end;
    if Dirs.Count > 0 then
      Sb.Append('(outline a directory to see its files)').Append(#10);
    if Cut > 0 then
      Sb.Append(Format('(+%d more source files not shown -- outline one by path)'#10, [Cut]));
    if Others.Count > 0 then
    begin
      Sb.Append('other files: ');
      for I := 0 to Others.Count - 1 do
      begin
        if I = 20 then
        begin
          Sb.Append(Format(', ... (+%d)', [Others.Count - 20]));
          Break;
        end;
        if I > 0 then Sb.Append(', ');
        Sb.Append(Others[I]);
      end;
      Sb.Append(#10);
    end;
    if Sb.Length = 0 then Sb.Append('(empty directory)').Append(#10);
    Result := Sb.ToString;
  finally
    Sb.Free;
    Others.Free;
    Sub.Free;
    Files.Free;
    Dirs.Free;
  end;
end;

function Tool_CodeOutline(const ArgsJSON: string; out ErrMsg: string): string;
var
  Shown, Root, Symbol: string;
begin
  ErrMsg := '';
  Result := '';
  if not ParseStringArg(ArgsJSON, 'path', Shown) then Shown := '';
  Shown := Trim(Shown);
  if Shown = '' then Shown := '.';
  Root := ExcludeTrailingPathDelimiter(ResolveWorkspacePath(Shown));
  if Root = '' then Root := ResolveWorkspacePath(Shown);
  if not CanReadPath(Root, ErrMsg) then Exit;
  if not (DirectoryExists(Root) or FileExists(Root)) then
  begin
    ErrMsg := 'no such path: ' + Shown;
    Exit;
  end;
  if not ParseStringArg(ArgsJSON, 'symbol', Symbol) then Symbol := '';
  Symbol := Trim(Symbol);
  if Symbol <> '' then
    Result := OutlineSymbol(Root, Shown, Symbol)
  else if DirectoryExists(Root) then
    Result := OutlineDirectory(Root, Shown)
  else
    Result := OutlineOneFile(Root, Shown);
  {$IFDEF FPC}
  { TStringBuilder.ToString drops the UTF-8 tag (see Tool_FSGrep). }
  SetCodePage(RawByteString(Result), CP_UTF8, False);
  {$ENDIF}
end;

procedure RegisterOutlineTool(R: TToolRegistry);
var
  T: TTool;
begin
  if R = nil then Exit;
  T := Default(TTool);
  T.Name        := 'code_outline';
  T.Description := 'Map code without reading it. symbol=NAME: where NAME is declared ' +
                   '(not used) under path. path=FILE: its declarations, with line ' +
                   'numbers. path=DIR: each file''s purpose and names. Pascal, Python, ' +
                   'JS/TS, Go, Rust, Ruby, PHP.';
  T.Schema      := '{"type":"object","properties":{' +
                   '"path":{"type":"string","description":"File or directory; default ."},' +
                   '"symbol":{"type":"string","description":"e.g. TaskReviewers, TFoo.Bar"}' +
                   '}}';
  T.Handler     := Tool_CodeOutline;
  T.IsCore      := True;
  T.Category    := tcReadOnly;
  R.Register(T);
end;

end.
