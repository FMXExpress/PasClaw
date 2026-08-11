{
  PasClaw.MCP.Compact - re-encode tabular MCP results as a table.

  Why
  ===

  An MCP tool result is flattened to text and put in the conversation, where
  it is re-sent on EVERY subsequent turn. When a server answers with rows --
  an array of objects -- JSON repeats every column name in every row, so a
  40-row/6-column answer spends most of its tokens restating the header forty
  times. Measured on a representative db-style result: 1420 tokens of JSON
  against 742 as a table, a 48% saving that then compounds per turn.

  This is the same observation the TOON format is built on. What it is NOT is
  a general JSON replacement:

    - Tool SCHEMAS are untouched. Providers require JSON Schema in their
      native tools array, and PasClaw already solves the schema-bulk problem
      properly with progressive disclosure (PasClaw.MCP.Disclosure), which
      reaches the same ~96% and leaves the tools callable. A compact schema
      encoding would break tool calling to save nothing.
    - Free text is untouched. There is no syntax to remove, so re-encoding
      prose buys nothing and only risks mangling it.
    - The symbol substitutions TOON uses for null and newline are skipped on
      purpose: they are multi-byte Unicode that frequently tokenise WORSE
      than the ASCII they replace, and they make the result ambiguous to
      read back.

  Safety
  ======

  * Only a genuinely rectangular result is converted: every row an object,
    every row the same keys, every value scalar. One nested object or one
    ragged row and the original is returned untouched -- silently reshaping
    half a result is worse than not compacting it.
  * The conversion must actually be shorter, or the original is kept. A
    two-row table can easily be longer than its JSON.
  * Delimiters inside values are escaped, so a value containing '|' cannot
    invent a column. This is the failure a naive join would ship.
  * Nothing is dropped. A wrapper's SIBLING fields -- next_cursor, total,
    warnings -- are carried through above the table, and a sibling that is
    itself an object or array refuses the whole conversion. An agent reads
    the compacted text, not the preserved JSON, so a silently discarded
    cursor would strand it mid-pagination with no way to notice.
  * Only the TEXT handed to the model is affected. Callers keep the raw
    result JSON, so structured consumers are unaffected.
}
unit PasClaw.MCP.Compact;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

const
  { Below these a table cannot pay for its own header line. }
  COMPACT_MIN_ROWS = 3;
  COMPACT_MIN_COLS = 2;

{ Re-encode Text as a table when it is a rectangular array of objects.

  Returns True and sets Compact when the conversion applied AND came out
  shorter; returns False and leaves Text alone in every other case. }
function CompactifyResultText(const Text: string; out Compact: string): Boolean;

{ Escape one cell so it cannot break the row's column structure. Exposed for
  the tests, which is the only way to pin the escaping contract. }
function EscapeCell(const Value: string): string;

implementation

uses
  Classes, PasClaw.JSON;

{ One cell's value as text, whatever JSON type it is.

  GetStr returns its DEFAULT for anything that is not a JSON string, so
  reading cells with GetStr alone silently emptied every number -- which on a
  db result is most of the data. Probing with two DIFFERENT defaults settles
  the type without sentinels: if both probes agree the value is really there,
  and if they disagree the accessor was just handing back the default. }
function CellText(Row: TJsonObject; const Key: string): string;
var
  S1, S2: string;
  I1, I2: Int64;
  F1, F2: Double;
  B1, B2: Boolean;
  Fmt: TFormatSettings;
begin
  Result := '';
  if (Row = nil) or not Row.Has(Key) then
    Exit;

  S1 := Row.GetStr(Key, #1'a');
  S2 := Row.GetStr(Key, #1'b');
  if S1 = S2 then
    Exit(S1);            { a real string, including the empty one }

  B1 := Row.GetBool(Key, False);
  B2 := Row.GetBool(Key, True);
  if B1 = B2 then
  begin
    if B1 then
      Exit('true')
    else
      Exit('false');
  end;

  I1 := Row.GetInt(Key, Low(Int64));
  I2 := Row.GetInt(Key, High(Int64));
  if I1 = I2 then
    Exit(IntToStr(I1));

  F1 := Row.GetFloat(Key, -1.5e300);
  F2 := Row.GetFloat(Key, 1.5e300);
  if F1 = F2 then
  begin
    { '.' regardless of locale -- a comma here would look like a new column
      in a delimited row read back by a model }
    Fmt := FormatSettings;
    Fmt.DecimalSeparator := '.';
    Exit(FloatToStr(F1, Fmt));
  end;
  { null, or a type no accessor admits to: an empty cell }
end;

{ Escaping for a metadata line, which has no columns to protect. The pipe is
  deliberately NOT escaped here: a cursor is an opaque token the model has to
  hand back verbatim, and a '\|' it copied faithfully would be the wrong
  cursor. Inside a table the delimiter must be escaped or the row loses its
  shape -- that trade-off is forced there and avoidable here. }
function EscapeMeta(const Value: string): string;
var
  i: Integer;
  ch: Char;
begin
  Result := '';
  for i := 1 to Length(Value) do
  begin
    ch := Value[i];
    case ch of
      '\': Result := Result + '\\';
      #10: Result := Result + '\n';
      #13: ;
    else
      Result := Result + ch;
    end;
  end;
end;

function EscapeCell(const Value: string): string;
var
  i: Integer;
  ch: Char;
begin
  Result := '';
  for i := 1 to Length(Value) do
  begin
    ch := Value[i];
    case ch of
      '\': Result := Result + '\\';
      '|': Result := Result + '\|';
      #10: Result := Result + '\n';
      #13: ;                          { CR is dropped, not escaped }
    else
      Result := Result + ch;
    end;
  end;
end;

{ The rows array, whether the payload is a bare array or an object wrapping
  one. Returns nil when there is no single obvious candidate. }
function FindRows(const Text: string; out Owner: TJsonObject;
  out RowsKey: string): TJsonArray;
const
  { the names servers actually use for "the rows" }
  WRAPPERS: array[0..5] of string =
    ('rows', 'items', 'results', 'data', 'records', 'entries');
var
  Trimmed: string;
  i: Integer;
  Arr: TJsonArray;
begin
  Result := nil;
  Owner := nil;
  RowsKey := '';
  Trimmed := Trim(Text);
  if Trimmed = '' then
    Exit;

  if Trimmed[1] = '[' then
  begin
    try
      Result := TJsonArray.Parse(Trimmed);
    except
      Result := nil;
    end;
    Exit;
  end;

  if Trimmed[1] <> '{' then
    Exit;
  try
    Owner := TJsonObject.Parse(Trimmed);
  except
    Owner := nil;
  end;
  if Owner = nil then
    Exit;
  for i := Low(WRAPPERS) to High(WRAPPERS) do
  begin
    Arr := Owner.ChildArray(WRAPPERS[i]);
    if Arr <> nil then
    begin
      Result := Arr;
      RowsKey := WRAPPERS[i];
      Exit;
    end;
  end;
end;

{ True when every row is an object carrying exactly Cols' keys and nothing
  but scalars. Anything else is not a table and must not be reshaped. }
function RowsAreRectangular(Rows: TJsonArray; Cols: TStringList): Boolean;
var
  r, c: Integer;
  Row: TJsonObject;
  RowKeys: TStringList;
begin
  Result := False;
  for r := 0 to Rows.Count - 1 do
  begin
    Row := Rows.ItemObject(r);
    if Row = nil then
      Exit;
    RowKeys := Row.Keys;
    try
      if RowKeys.Count <> Cols.Count then
        Exit;
    finally
      RowKeys.Free;
    end;
    for c := 0 to Cols.Count - 1 do
    begin
      if not Row.Has(Cols[c]) then
        Exit;
      { a container in any cell means this is not a flat table }
      if (Row.ChildObject(Cols[c]) <> nil) or (Row.ChildArray(Cols[c]) <> nil) then
        Exit;
    end;
  end;
  Result := True;
end;

{ Sibling fields of the rows array, as 'key: value' lines.

  Returns False when a sibling is itself an object or array: those cannot be
  rendered faithfully on one line, and a conversion that cannot carry all of
  the result must not happen at all. }
function CollectSiblings(Owner: TJsonObject; const RowsKey: string;
  Lines: TStringList): Boolean;
var
  Keys: TStringList;
  i: Integer;
  Key: string;
begin
  Result := False;
  if Owner = nil then
    Exit(True);
  Keys := Owner.Keys;
  try
    for i := 0 to Keys.Count - 1 do
    begin
      Key := Keys[i];
      if Key = RowsKey then
        Continue;
      if (Owner.ChildObject(Key) <> nil) or (Owner.ChildArray(Key) <> nil) then
        Exit;
      Lines.Add(EscapeMeta(Key) + ': ' + EscapeMeta(CellText(Owner, Key)));
    end;
  finally
    Keys.Free;
  end;
  Result := True;
end;

function CompactifyResultText(const Text: string; out Compact: string): Boolean;
var
  Rows: TJsonArray;
  Owner, Row, First: TJsonObject;
  Cols: TStringList;
  SB: TStringList;
  Line, RowsKey: string;
  r, c: Integer;
begin
  Result := False;
  Compact := '';
  Owner := nil;
  Rows := FindRows(Text, Owner, RowsKey);
  try
    if (Rows = nil) or (Rows.Count < COMPACT_MIN_ROWS) then
      Exit;
    First := Rows.ItemObject(0);
    if First = nil then
      Exit;
    Cols := First.Keys;
    try
      if Cols.Count < COMPACT_MIN_COLS then
        Exit;
      if not RowsAreRectangular(Rows, Cols) then
        Exit;

      SB := TStringList.Create;
      try
        { siblings FIRST, and their presence is what decides whether the
          conversion may happen at all -- a next_cursor dropped here strands
          the agent mid-pagination with nothing on screen to explain it }
        if not CollectSiblings(Owner, RowsKey, SB) then
          Exit;
        { self-describing header: the model is told the shape before the
          data, so it never has to infer that a bare row list is tabular }
        Line := '';
        for c := 0 to Cols.Count - 1 do
        begin
          if c > 0 then
            Line := Line + '|';
          Line := Line + EscapeCell(Cols[c]);
        end;
        SB.Add(Format('table %dx%d: %s', [Rows.Count, Cols.Count, Line]));

        for r := 0 to Rows.Count - 1 do
        begin
          Row := Rows.ItemObject(r);
          Line := '';
          for c := 0 to Cols.Count - 1 do
          begin
            if c > 0 then
              Line := Line + '|';
            Line := Line + EscapeCell(CellText(Row, Cols[c]));
          end;
          SB.Add(Line);
        end;
        Compact := TrimRight(SB.Text);
      finally
        SB.Free;
      end;
    finally
      Cols.Free;
    end;
  finally
    if Owner <> nil then
      Owner.Free
    else if Rows <> nil then
      Rows.Free;
  end;

  { a table that is not shorter is just a different shape, so keep the JSON }
  if Length(Compact) < Length(Text) then
    Result := True
  else
    Compact := '';
end;

end.
