(*
  PasClaw.JSON - thin JSON abstraction so the rest of the codebase doesn't
  bind to a specific JSON library.

  Backends:
    {$IFDEF FPC} fpjson + jsonparser
    {$ELSE}      System.JSON (Delphi 10.4+) or JsonDataObjects

  Surface area: opaque object/array handles + a small set of getters / setters
  that cover everything the agent loop, providers, MCP, gateway, and channels
  need. Call-sites use only this unit; nothing else imports fpjson.

  Memory model: TJsonObject / TJsonArray are reference-counted via interfaces
  in spirit, but we use plain classes with explicit Free since FPC interfaces
  + COM-style refcounting can clash with TInterfacedObject usage elsewhere.
  Owners free the root; nested objects are owned by their parents.
*)
unit PasClaw.JSON;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  EPasClawJSON = class(Exception);

  TJsonObject = class;
  TJsonArray  = class;

  (* TJsonObject: build, parse, mutate JSON objects.
     Get* methods return the supplied Default when the key is missing or has
     the wrong type. ChildObject / ChildArray return live references owned by
     this object — do NOT free them yourself. *)
  TJsonObject = class
  private
    FBacking: TObject;   { wraps the backend's object type }
    FOwnsBacking: Boolean;
  public
    constructor Create;
    constructor CreateWrapping(Backing: TObject; OwnsIt: Boolean);
    destructor  Destroy; override;
    class function Parse(const S: string): TJsonObject;
    function Has(const Key: string): Boolean;
    function Keys: TStringList;   { caller frees; one entry per top-level key }
    function GetStr (const Key: string; const Default: string = ''): string;
    function GetInt (const Key: string; Default: Int64 = 0): Int64;
    function GetBool(const Key: string; Default: Boolean = False): Boolean;
    function GetFloat(const Key: string; Default: Double = 0): Double;
    function ChildObject(const Key: string): TJsonObject;   { nil if absent }
    function ChildArray (const Key: string): TJsonArray;    { nil if absent }
    procedure PutStr  (const Key, Value: string);
    procedure PutInt  (const Key: string; Value: Int64);
    procedure PutBool (const Key: string; Value: Boolean);
    procedure PutFloat(const Key: string; Value: Double);
    procedure PutObject(const Key: string; var Obj: TJsonObject);  { takes ownership; sets Obj := nil }
    procedure PutArray (const Key: string; var Arr: TJsonArray);   { takes ownership; sets Arr := nil }
    procedure PutRaw  (const Key, RawJSON: string);
    procedure Remove  (const Key: string);
    function ToJSON: string;
    function Backing: TObject;  { for cross-unit interop when absolutely needed }
  end;

  TJsonArray = class
  private
    FBacking: TObject;
    FOwnsBacking: Boolean;
  public
    constructor Create;
    constructor CreateWrapping(Backing: TObject; OwnsIt: Boolean);
    destructor  Destroy; override;
    class function Parse(const S: string): TJsonArray;
    function Count: Integer;
    function ItemStr   (Index: Integer; const Default: string = ''): string;
    function ItemInt   (Index: Integer; Default: Int64 = 0): Int64;
    function ItemBool  (Index: Integer; Default: Boolean = False): Boolean;
    function ItemObject(Index: Integer): TJsonObject;   { nil if not object }
    function ItemArray (Index: Integer): TJsonArray;    { nil if not array }
    procedure AddStr   (const Value: string);
    procedure AddInt   (Value: Int64);
    procedure AddBool  (Value: Boolean);
    procedure AddObject(var Obj: TJsonObject);
    procedure AddArray (var Arr: TJsonArray);
    procedure AddRaw   (const RawJSON: string);
    function ToJSON: string;
    function Backing: TObject;
  end;

{ Convenience: parse-then-free helpers for one-shot reads. }
function JsonReadStr (const Body, Key: string; const Default: string = ''): string;
function JsonReadInt (const Body, Key: string; Default: Int64 = 0): Int64;
function JsonReadBool(const Body, Key: string; Default: Boolean = False): Boolean;

{ Escape a string for embedding inside a JSON string literal (without quotes). }
function JsonEscape(const S: string): string;

implementation

{$IFDEF FPC}
uses
  fpjson, jsonparser;
{$ELSE}
uses
  System.JSON, System.JSON.Writers, System.JSON.Readers, System.JSON.Types;
{$ENDIF}

function JsonEscape(const S: string): string;
var
  i: Integer;
  C: Char;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    for i := 1 to Length(S) do
    begin
      C := S[i];
      case C of
        '"':  SB.Append('\"');
        '\':  SB.Append('\\');
        #8:   SB.Append('\b');
        #9:   SB.Append('\t');
        #10:  SB.Append('\n');
        #12:  SB.Append('\f');
        #13:  SB.Append('\r');
      else
        if Ord(C) < 32 then
          SB.Append(Format('\u%.4x', [Ord(C)]))
        else
          SB.Append(C);
      end;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{$IFDEF FPC}
(* ----- FPC backend (fpjson) ----- *)

constructor TJsonObject.Create;
begin
  inherited Create;
  FBacking := fpjson.TJSONObject.Create;
  FOwnsBacking := True;
end;

constructor TJsonObject.CreateWrapping(Backing: TObject; OwnsIt: Boolean);
begin
  inherited Create;
  FBacking := Backing;
  FOwnsBacking := OwnsIt;
end;

destructor TJsonObject.Destroy;
begin
  if FOwnsBacking and (FBacking <> nil) then FBacking.Free;
  inherited Destroy;
end;

class function TJsonObject.Parse(const S: string): TJsonObject;
(* Bypass fpjson's GetJSON wrapper and drive TJSONParser directly
   with EMPTY options — specifically, NO `joUTF8` flag. That looks
   counter-intuitive (PasClaw is a UTF-8 codebase end-to-end) but
   it's the only way to keep non-ASCII bytes intact under FPC 3.2.

   What goes wrong with the default GetJSON path: jsonreader.pp
   has the branch

     tkString : if (joUTF8 in Options) and (DefaultSystemCodePage<>CP_UTF8) then
                  StringValue(TJSONStringType(UTF8Decode(CurrentTokenString)))

   On a container with DefaultSystemCodePage=0 the `<>CP_UTF8`
   guard is true, and the UTF8Decode + cast round-trip silently
   re-encodes the parsed token through the system codepage. The
   AnsiString result tag ends up at whatever CP_ACP resolves to,
   and any codepoint that CP can't represent gets clipped to a
   single byte (or replaced with `?` on a strict-ASCII fallback).
   `¶` (UTF-8 `C2 B6`) arrives here as a single `B6`; `é`
   (`C3 A9`) as `A9`. Wire-visible mojibake downstream — the
   exact symptom toolview_tests.TestEditHashlineCall surfaces.

   Without `joUTF8`, the scanner does a plain `Move` of the raw
   bytes into the token string (jsonscanner.pp:405) and skips the
   round-trip. The token AnsiString carries the original UTF-8
   bytes, AsString returns them unchanged, and PasClaw — which
   already treats every string at every boundary as UTF-8 — sees
   the wire bytes it actually parsed. *)
var
  Stream: TStringStream;
  Parser: TJSONParser;
  Data: TJSONData;
begin
  Result := nil;
  if Trim(S) = '' then Exit;
  Stream := TStringStream.Create(S);
  try
    try
      Parser := TJSONParser.Create(Stream, []);
      try
        Data := Parser.Parse;
      finally
        Parser.Free;
      end;
    except
      on E: Exception do raise EPasClawJSON.CreateFmt('JSON parse: %s', [E.Message]);
    end;
  finally
    Stream.Free;
  end;
  if not (Data is fpjson.TJSONObject) then
  begin
    Data.Free;
    Exit;
  end;
  Result := TJsonObject.CreateWrapping(Data, True);
end;

function TJsonObject.Has(const Key: string): Boolean;
begin
  Result := fpjson.TJSONObject(FBacking).IndexOfName(Key) >= 0;
end;

function TJsonObject.Keys: TStringList;
var
  Obj: fpjson.TJSONObject;
  i: Integer;
begin
  Result := TStringList.Create;
  Obj := fpjson.TJSONObject(FBacking);
  for i := 0 to Obj.Count - 1 do
    Result.Add(Obj.Names[i]);
end;

function TJsonObject.GetStr(const Key: string; const Default: string): string;
begin
  Result := fpjson.TJSONObject(FBacking).Get(Key, Default);
end;

function TJsonObject.GetInt(const Key: string; Default: Int64): Int64;
begin
  Result := fpjson.TJSONObject(FBacking).Get(Key, Default);
end;

function TJsonObject.GetBool(const Key: string; Default: Boolean): Boolean;
begin
  Result := fpjson.TJSONObject(FBacking).Get(Key, Default);
end;

function TJsonObject.GetFloat(const Key: string; Default: Double): Double;
begin
  Result := fpjson.TJSONObject(FBacking).Get(Key, Default);
end;

function TJsonObject.ChildObject(const Key: string): TJsonObject;
var
  D: TJSONData;
begin
  Result := nil;
  if not Has(Key) then Exit;
  D := fpjson.TJSONObject(FBacking).Find(Key);
  if D is fpjson.TJSONObject then
    Result := TJsonObject.CreateWrapping(D, False);
end;

function TJsonObject.ChildArray(const Key: string): TJsonArray;
var
  D: TJSONData;
begin
  Result := nil;
  if not Has(Key) then Exit;
  D := fpjson.TJSONObject(FBacking).Find(Key);
  if D is fpjson.TJSONArray then
    Result := TJsonArray.CreateWrapping(D, False);
end;

{ fpjson's Add() appends without checking — repeated writes to the same
  key would emit a duplicate-keyed JSON object that downstream parsers
  treat ambiguously. Strip any existing entry with this key first so
  Put* has clean "last write wins" semantics. }
procedure RemoveKey(Obj: fpjson.TJSONObject; const Key: string);
var
  Idx: Integer;
begin
  if Obj = nil then Exit;
  Idx := Obj.IndexOfName(Key);
  if Idx >= 0 then Obj.Delete(Idx);
end;

procedure TJsonObject.PutStr  (const Key, Value: string);
begin RemoveKey(fpjson.TJSONObject(FBacking), Key); fpjson.TJSONObject(FBacking).Add(Key, Value); end;

procedure TJsonObject.PutInt  (const Key: string; Value: Int64);
begin RemoveKey(fpjson.TJSONObject(FBacking), Key); fpjson.TJSONObject(FBacking).Add(Key, Value); end;

procedure TJsonObject.PutBool (const Key: string; Value: Boolean);
begin RemoveKey(fpjson.TJSONObject(FBacking), Key); fpjson.TJSONObject(FBacking).Add(Key, Value); end;

procedure TJsonObject.PutFloat(const Key: string; Value: Double);
begin RemoveKey(fpjson.TJSONObject(FBacking), Key); fpjson.TJSONObject(FBacking).Add(Key, Value); end;

procedure TJsonObject.PutObject(const Key: string; var Obj: TJsonObject);
var
  Inner: TJSONData;
begin
  if Obj = nil then Exit;
  Inner := TJSONData(Obj.Backing);
  Obj.FOwnsBacking := False;   { parent now owns it }
  Obj.Free;
  Obj := nil;
  RemoveKey(fpjson.TJSONObject(FBacking), Key);
  fpjson.TJSONObject(FBacking).Add(Key, Inner);
end;

procedure TJsonObject.PutArray(const Key: string; var Arr: TJsonArray);
var
  Inner: TJSONData;
begin
  if Arr = nil then Exit;
  Inner := TJSONData(Arr.Backing);
  Arr.FOwnsBacking := False;
  Arr.Free;
  Arr := nil;
  RemoveKey(fpjson.TJSONObject(FBacking), Key);
  fpjson.TJSONObject(FBacking).Add(Key, Inner);
end;

procedure TJsonObject.PutRaw(const Key, RawJSON: string);
var
  Data: TJSONData;
begin
  RemoveKey(fpjson.TJSONObject(FBacking), Key);
  try
    Data := GetJSON(RawJSON);
    fpjson.TJSONObject(FBacking).Add(Key, Data);
  except
    fpjson.TJSONObject(FBacking).Add(Key, fpjson.TJSONObject.Create);
  end;
end;

procedure TJsonObject.Remove(const Key: string);
begin
  RemoveKey(fpjson.TJSONObject(FBacking), Key);
end;

function TJsonObject.ToJSON: string;
begin
  Result := fpjson.TJSONObject(FBacking).AsJSON;
end;

function TJsonObject.Backing: TObject;
begin
  Result := FBacking;
end;

(* TJsonArray *)

constructor TJsonArray.Create;
begin
  inherited Create;
  FBacking := fpjson.TJSONArray.Create;
  FOwnsBacking := True;
end;

constructor TJsonArray.CreateWrapping(Backing: TObject; OwnsIt: Boolean);
begin
  inherited Create;
  FBacking := Backing;
  FOwnsBacking := OwnsIt;
end;

destructor TJsonArray.Destroy;
begin
  if FOwnsBacking and (FBacking <> nil) then FBacking.Free;
  inherited Destroy;
end;

class function TJsonArray.Parse(const S: string): TJsonArray;
{ See TJsonObject.Parse for why we drive TJSONParser directly with
  empty options — the same joUTF8 + DefaultSystemCodePage interaction
  applies to root-level arrays. }
var
  Stream: TStringStream;
  Parser: TJSONParser;
  Data: TJSONData;
begin
  Result := nil;
  if Trim(S) = '' then Exit;
  Stream := TStringStream.Create(S);
  try
    try
      Parser := TJSONParser.Create(Stream, []);
      try
        Data := Parser.Parse;
      finally
        Parser.Free;
      end;
    except
      on E: Exception do raise EPasClawJSON.CreateFmt('JSON parse: %s', [E.Message]);
    end;
  finally
    Stream.Free;
  end;
  if not (Data is fpjson.TJSONArray) then
  begin
    Data.Free;
    Exit;
  end;
  Result := TJsonArray.CreateWrapping(Data, True);
end;

function TJsonArray.Count: Integer;
begin
  Result := fpjson.TJSONArray(FBacking).Count;
end;

function TJsonArray.ItemStr(Index: Integer; const Default: string): string;
var
  Arr: fpjson.TJSONArray;
begin
  Arr := fpjson.TJSONArray(FBacking);
  if (Index < 0) or (Index >= Arr.Count) then Exit(Default);
  try Result := Arr.Strings[Index]; except Result := Default; end;
end;

function TJsonArray.ItemInt(Index: Integer; Default: Int64): Int64;
var
  Arr: fpjson.TJSONArray;
begin
  Arr := fpjson.TJSONArray(FBacking);
  if (Index < 0) or (Index >= Arr.Count) then Exit(Default);
  try Result := Arr.Int64s[Index]; except Result := Default; end;
end;

function TJsonArray.ItemBool(Index: Integer; Default: Boolean): Boolean;
var
  Arr: fpjson.TJSONArray;
begin
  Arr := fpjson.TJSONArray(FBacking);
  if (Index < 0) or (Index >= Arr.Count) then Exit(Default);
  try Result := Arr.Booleans[Index]; except Result := Default; end;
end;

function TJsonArray.ItemObject(Index: Integer): TJsonObject;
var
  Arr: fpjson.TJSONArray;
  D: TJSONData;
begin
  Result := nil;
  Arr := fpjson.TJSONArray(FBacking);
  if (Index < 0) or (Index >= Arr.Count) then Exit;
  D := Arr[Index];
  if D is fpjson.TJSONObject then
    Result := TJsonObject.CreateWrapping(D, False);
end;

function TJsonArray.ItemArray(Index: Integer): TJsonArray;
var
  Arr: fpjson.TJSONArray;
  D: TJSONData;
begin
  Result := nil;
  Arr := fpjson.TJSONArray(FBacking);
  if (Index < 0) or (Index >= Arr.Count) then Exit;
  D := Arr[Index];
  if D is fpjson.TJSONArray then
    Result := TJsonArray.CreateWrapping(D, False);
end;

procedure TJsonArray.AddStr (const Value: string);
begin fpjson.TJSONArray(FBacking).Add(Value); end;

procedure TJsonArray.AddInt (Value: Int64);
begin fpjson.TJSONArray(FBacking).Add(Value); end;

procedure TJsonArray.AddBool(Value: Boolean);
begin fpjson.TJSONArray(FBacking).Add(Value); end;

procedure TJsonArray.AddObject(var Obj: TJsonObject);
var
  Inner: TJSONData;
begin
  if Obj = nil then Exit;
  Inner := TJSONData(Obj.Backing);
  Obj.FOwnsBacking := False;
  Obj.Free;
  Obj := nil;
  fpjson.TJSONArray(FBacking).Add(Inner);
end;

procedure TJsonArray.AddArray(var Arr: TJsonArray);
var
  Inner: TJSONData;
begin
  if Arr = nil then Exit;
  Inner := TJSONData(Arr.Backing);
  Arr.FOwnsBacking := False;
  Arr.Free;
  Arr := nil;
  fpjson.TJSONArray(FBacking).Add(Inner);
end;

procedure TJsonArray.AddRaw(const RawJSON: string);
var
  Data: TJSONData;
begin
  try
    Data := GetJSON(RawJSON);
    fpjson.TJSONArray(FBacking).Add(Data);
  except
    { swallow: bad JSON yields no addition }
  end;
end;

function TJsonArray.ToJSON: string;
begin
  Result := fpjson.TJSONArray(FBacking).AsJSON;
end;

function TJsonArray.Backing: TObject;
begin
  Result := FBacking;
end;

{$ELSE}
(* ----- Delphi backend (System.JSON) -----
   Same semantics as the FPC backend above. Backing types are
   System.JSON.TJSONObject / TJSONArray. Ownership: a parent owns nested
   children added through PutObject/PutArray/AddObject/AddArray; this is
   how System.JSON works natively. ChildObject/ChildArray/ItemObject/
   ItemArray return non-owning wrappers so the caller frees the wrapper
   but not the underlying System.JSON value. *)

constructor TJsonObject.Create;
begin
  inherited Create;
  FBacking := System.JSON.TJSONObject.Create;
  FOwnsBacking := True;
end;

constructor TJsonObject.CreateWrapping(Backing: TObject; OwnsIt: Boolean);
begin
  inherited Create;
  FBacking := Backing;
  FOwnsBacking := OwnsIt;
end;

destructor TJsonObject.Destroy;
begin
  if FOwnsBacking and (FBacking <> nil) then FBacking.Free;
  inherited Destroy;
end;

class function TJsonObject.Parse(const S: string): TJsonObject;
var
  V: System.JSON.TJSONValue;
begin
  Result := nil;
  if Trim(S) = '' then Exit;
  try
    V := System.JSON.TJSONObject.ParseJSONValue(S);
  except
    on E: Exception do raise EPasClawJSON.CreateFmt('JSON parse: %s', [E.Message]);
  end;
  if not (V is System.JSON.TJSONObject) then
  begin
    V.Free;
    Exit;
  end;
  Result := TJsonObject.CreateWrapping(V, True);
end;

function TJsonObject.Has(const Key: string): Boolean;
begin
  Result := System.JSON.TJSONObject(FBacking).GetValue(Key) <> nil;
end;

function TJsonObject.Keys: TStringList;
var
  Obj: System.JSON.TJSONObject;
  i: Integer;
  Pair: System.JSON.TJSONPair;
begin
  Result := TStringList.Create;
  Obj := System.JSON.TJSONObject(FBacking);
  for i := 0 to Obj.Count - 1 do
  begin
    Pair := Obj.Pairs[i];
    if (Pair <> nil) and (Pair.JsonString <> nil) then
      Result.Add(Pair.JsonString.Value);
  end;
end;

function TJsonObject.GetStr(const Key: string; const Default: string): string;
var
  V: System.JSON.TJSONValue;
begin
  V := System.JSON.TJSONObject(FBacking).GetValue(Key);
  if V = nil then Exit(Default);
  try
    Result := V.Value;
  except
    Result := Default;
  end;
end;

function TJsonObject.GetInt(const Key: string; Default: Int64): Int64;
var
  V: System.JSON.TJSONValue;
begin
  V := System.JSON.TJSONObject(FBacking).GetValue(Key);
  if V = nil then Exit(Default);
  if V is System.JSON.TJSONNumber then
    Result := System.JSON.TJSONNumber(V).AsInt64
  else
    Result := Default;
end;

function TJsonObject.GetBool(const Key: string; Default: Boolean): Boolean;
var
  V: System.JSON.TJSONValue;
begin
  V := System.JSON.TJSONObject(FBacking).GetValue(Key);
  if V = nil then Exit(Default);
  if V is System.JSON.TJSONTrue then Exit(True);
  if V is System.JSON.TJSONFalse then Exit(False);
  if V is System.JSON.TJSONBool then Exit(System.JSON.TJSONBool(V).AsBoolean);
  Result := Default;
end;

function TJsonObject.GetFloat(const Key: string; Default: Double): Double;
var
  V: System.JSON.TJSONValue;
begin
  V := System.JSON.TJSONObject(FBacking).GetValue(Key);
  if V = nil then Exit(Default);
  if V is System.JSON.TJSONNumber then
    Result := System.JSON.TJSONNumber(V).AsDouble
  else
    Result := Default;
end;

function TJsonObject.ChildObject(const Key: string): TJsonObject;
var
  V: System.JSON.TJSONValue;
begin
  Result := nil;
  V := System.JSON.TJSONObject(FBacking).GetValue(Key);
  if V is System.JSON.TJSONObject then
    Result := TJsonObject.CreateWrapping(V, False);
end;

function TJsonObject.ChildArray(const Key: string): TJsonArray;
var
  V: System.JSON.TJSONValue;
begin
  Result := nil;
  V := System.JSON.TJSONObject(FBacking).GetValue(Key);
  if V is System.JSON.TJSONArray then
    Result := TJsonArray.CreateWrapping(V, False);
end;

{ AddPair also appends without checking; mirror the FPC dedup so both
  backends emit unique-keyed JSON regardless of how many times callers
  set the same key. }
procedure RemoveKey(Obj: System.JSON.TJSONObject; const Key: string);
var
  Existing: System.JSON.TJSONPair;
begin
  if Obj = nil then Exit;
  Existing := Obj.RemovePair(Key);
  if Existing <> nil then Existing.Free;
end;

procedure TJsonObject.PutStr  (const Key, Value: string);
begin RemoveKey(System.JSON.TJSONObject(FBacking), Key); System.JSON.TJSONObject(FBacking).AddPair(Key, Value); end;

procedure TJsonObject.PutInt  (const Key: string; Value: Int64);
begin RemoveKey(System.JSON.TJSONObject(FBacking), Key); System.JSON.TJSONObject(FBacking).AddPair(Key, System.JSON.TJSONNumber.Create(Value)); end;

procedure TJsonObject.PutBool (const Key: string; Value: Boolean);
begin RemoveKey(System.JSON.TJSONObject(FBacking), Key); System.JSON.TJSONObject(FBacking).AddPair(Key, System.JSON.TJSONBool.Create(Value)); end;

procedure TJsonObject.PutFloat(const Key: string; Value: Double);
begin RemoveKey(System.JSON.TJSONObject(FBacking), Key); System.JSON.TJSONObject(FBacking).AddPair(Key, System.JSON.TJSONNumber.Create(Value)); end;

procedure TJsonObject.PutObject(const Key: string; var Obj: TJsonObject);
var
  Inner: System.JSON.TJSONValue;
begin
  if Obj = nil then Exit;
  Inner := System.JSON.TJSONValue(Obj.Backing);
  Obj.FOwnsBacking := False;
  Obj.Free;
  Obj := nil;
  RemoveKey(System.JSON.TJSONObject(FBacking), Key);
  System.JSON.TJSONObject(FBacking).AddPair(Key, Inner);
end;

procedure TJsonObject.PutArray(const Key: string; var Arr: TJsonArray);
var
  Inner: System.JSON.TJSONValue;
begin
  if Arr = nil then Exit;
  Inner := System.JSON.TJSONValue(Arr.Backing);
  Arr.FOwnsBacking := False;
  Arr.Free;
  Arr := nil;
  RemoveKey(System.JSON.TJSONObject(FBacking), Key);
  System.JSON.TJSONObject(FBacking).AddPair(Key, Inner);
end;

procedure TJsonObject.PutRaw(const Key, RawJSON: string);
var
  V: System.JSON.TJSONValue;
begin
  try
    V := System.JSON.TJSONObject.ParseJSONValue(RawJSON);
    if V = nil then V := System.JSON.TJSONObject.Create;
  except
    V := System.JSON.TJSONObject.Create;
  end;
  RemoveKey(System.JSON.TJSONObject(FBacking), Key);
  System.JSON.TJSONObject(FBacking).AddPair(Key, V);
end;

procedure TJsonObject.Remove(const Key: string);
begin
  RemoveKey(System.JSON.TJSONObject(FBacking), Key);
end;

function TJsonObject.ToJSON: string;
begin
  Result := System.JSON.TJSONObject(FBacking).ToJSON;
end;

function TJsonObject.Backing: TObject;
begin
  Result := FBacking;
end;

(* TJsonArray *)

constructor TJsonArray.Create;
begin
  inherited Create;
  FBacking := System.JSON.TJSONArray.Create;
  FOwnsBacking := True;
end;

constructor TJsonArray.CreateWrapping(Backing: TObject; OwnsIt: Boolean);
begin
  inherited Create;
  FBacking := Backing;
  FOwnsBacking := OwnsIt;
end;

destructor TJsonArray.Destroy;
begin
  if FOwnsBacking and (FBacking <> nil) then FBacking.Free;
  inherited Destroy;
end;

class function TJsonArray.Parse(const S: string): TJsonArray;
var
  V: System.JSON.TJSONValue;
begin
  Result := nil;
  if Trim(S) = '' then Exit;
  try
    V := System.JSON.TJSONObject.ParseJSONValue(S);
  except
    on E: Exception do raise EPasClawJSON.CreateFmt('JSON parse: %s', [E.Message]);
  end;
  if not (V is System.JSON.TJSONArray) then
  begin
    V.Free;
    Exit;
  end;
  Result := TJsonArray.CreateWrapping(V, True);
end;

function TJsonArray.Count: Integer;
begin
  Result := System.JSON.TJSONArray(FBacking).Count;
end;

function TJsonArray.ItemStr(Index: Integer; const Default: string): string;
var
  V: System.JSON.TJSONValue;
begin
  if (Index < 0) or (Index >= Count) then Exit(Default);
  V := System.JSON.TJSONArray(FBacking).Items[Index];
  if V = nil then Exit(Default);
  try Result := V.Value; except Result := Default; end;
end;

function TJsonArray.ItemInt(Index: Integer; Default: Int64): Int64;
var
  V: System.JSON.TJSONValue;
begin
  if (Index < 0) or (Index >= Count) then Exit(Default);
  V := System.JSON.TJSONArray(FBacking).Items[Index];
  if V is System.JSON.TJSONNumber then
    Result := System.JSON.TJSONNumber(V).AsInt64
  else
    Result := Default;
end;

function TJsonArray.ItemBool(Index: Integer; Default: Boolean): Boolean;
var
  V: System.JSON.TJSONValue;
begin
  if (Index < 0) or (Index >= Count) then Exit(Default);
  V := System.JSON.TJSONArray(FBacking).Items[Index];
  if V is System.JSON.TJSONBool then Result := System.JSON.TJSONBool(V).AsBoolean
  else Result := Default;
end;

function TJsonArray.ItemObject(Index: Integer): TJsonObject;
var
  V: System.JSON.TJSONValue;
begin
  Result := nil;
  if (Index < 0) or (Index >= Count) then Exit;
  V := System.JSON.TJSONArray(FBacking).Items[Index];
  if V is System.JSON.TJSONObject then
    Result := TJsonObject.CreateWrapping(V, False);
end;

function TJsonArray.ItemArray(Index: Integer): TJsonArray;
var
  V: System.JSON.TJSONValue;
begin
  Result := nil;
  if (Index < 0) or (Index >= Count) then Exit;
  V := System.JSON.TJSONArray(FBacking).Items[Index];
  if V is System.JSON.TJSONArray then
    Result := TJsonArray.CreateWrapping(V, False);
end;

procedure TJsonArray.AddStr (const Value: string);
begin System.JSON.TJSONArray(FBacking).Add(Value); end;

procedure TJsonArray.AddInt (Value: Int64);
begin System.JSON.TJSONArray(FBacking).Add(Value); end;

procedure TJsonArray.AddBool(Value: Boolean);
begin System.JSON.TJSONArray(FBacking).AddElement(System.JSON.TJSONBool.Create(Value)); end;

procedure TJsonArray.AddObject(var Obj: TJsonObject);
var
  Inner: System.JSON.TJSONValue;
begin
  if Obj = nil then Exit;
  Inner := System.JSON.TJSONValue(Obj.Backing);
  Obj.FOwnsBacking := False;
  Obj.Free;
  Obj := nil;
  System.JSON.TJSONArray(FBacking).AddElement(Inner);
end;

procedure TJsonArray.AddArray(var Arr: TJsonArray);
var
  Inner: System.JSON.TJSONValue;
begin
  if Arr = nil then Exit;
  Inner := System.JSON.TJSONValue(Arr.Backing);
  Arr.FOwnsBacking := False;
  Arr.Free;
  Arr := nil;
  System.JSON.TJSONArray(FBacking).AddElement(Inner);
end;

procedure TJsonArray.AddRaw(const RawJSON: string);
var
  V: System.JSON.TJSONValue;
begin
  try
    V := System.JSON.TJSONObject.ParseJSONValue(RawJSON);
    if V <> nil then System.JSON.TJSONArray(FBacking).AddElement(V);
  except
    { swallow malformed JSON — call site can detect via Count }
  end;
end;

function TJsonArray.ToJSON: string;
begin
  Result := System.JSON.TJSONArray(FBacking).ToJSON;
end;

function TJsonArray.Backing: TObject;
begin
  Result := FBacking;
end;

{$ENDIF}

function JsonReadStr(const Body, Key: string; const Default: string): string;
var
  Obj: TJsonObject;
begin
  Obj := TJsonObject.Parse(Body);
  if Obj = nil then Exit(Default);
  try
    Result := Obj.GetStr(Key, Default);
  finally
    Obj.Free;
  end;
end;

function JsonReadInt(const Body, Key: string; Default: Int64): Int64;
var
  Obj: TJsonObject;
begin
  Obj := TJsonObject.Parse(Body);
  if Obj = nil then Exit(Default);
  try
    Result := Obj.GetInt(Key, Default);
  finally
    Obj.Free;
  end;
end;

function JsonReadBool(const Body, Key: string; Default: Boolean): Boolean;
var
  Obj: TJsonObject;
begin
  Obj := TJsonObject.Parse(Body);
  if Obj = nil then Exit(Default);
  try
    Result := Obj.GetBool(Key, Default);
  finally
    Obj.Free;
  end;
end;

end.
