(*
  PasClaw.MCP.Headers - the request headers 2026-07-28 Streamable HTTP
  mirrors out of the JSON-RPC body, so load balancers and gateways can
  route on them without parsing JSON:

    Mcp-Method        every request: the JSON-RPC method
    Mcp-Name          tools/call, prompts/get: params.name;
                      resources/read: params.uri;
                      tasks/get|update|cancel: params.taskId
    Mcp-Param-<Name>  tools/call: each argument whose inputSchema property
                      carries "x-mcp-header": "<Name>"

  A value that is not plain visible ASCII (or that has leading/trailing
  blanks, or already looks like the sentinel) travels as
  =?base64?<base64 of the UTF-8 bytes>?=.

  Pure string functions, so the rules are pinned by a unit test rather than
  only by a server that happens to use them.
*)
unit PasClaw.MCP.Headers;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes;

type
  TMCPHeader = record
    Name, Value: string;
  end;
  TMCPHeaderArray = array of TMCPHeader;

  TMCPParamHeader = record
    Header: string;            { the x-mcp-header value: sent as Mcp-Param-<Header> }
    Path:   TArray<string>;    { chain of `properties` keys from the schema root }
  end;
  TMCPParamHeaderArray = array of TMCPParamHeader;

{ The x-mcp-header annotations of a tool's inputSchema. False (with Err)
  when one breaks the rules -- empty, not an HTTP token, a duplicate, on a
  non-primitive or `number` property, or not reachable from the root
  through `properties` alone. Such a tool must be left out of the tool list. }
function ExtractParamHeaders(const SchemaJSON: string;
                             out Specs: TMCPParamHeaderArray;
                             out Err: string): Boolean;

{ The Mcp-Param-* headers for one call's arguments; an argument that is
  absent or null gets no header. }
function ParamHeadersFor(const Specs: TMCPParamHeaderArray;
                         const ArgsJSON: string): TMCPHeaderArray;

{ The source of Mcp-Name for Method, read out of the request params ('' =
  the method has no Mcp-Name). }
function McpNameFor(const Method, ParamsJSON: string): string;

{ Encode a value for an Mcp-Name / Mcp-Param-* header. }
function EncodeMcpHeaderValue(const S: string): string;

implementation

uses
  PasClaw.JSON,
  PasClaw.Crypto.HMAC;   { BytesToBase64 }

const
  Sentinel = '=?base64?';
  SentinelEnd = '?=';

function IsTokenChar(C: Char): Boolean;
begin
  { RFC 9110 tchar }
  Result := CharInSet(C, ['!', '#', '$', '%', '&', '''', '*', '+', '-', '.',
                          '^', '_', '`', '|', '~', '0'..'9', 'A'..'Z', 'a'..'z']);
end;

function IsToken(const S: string): Boolean;
var
  i: Integer;
begin
  Result := S <> '';
  for i := 1 to Length(S) do
    if not IsTokenChar(S[i]) then Exit(False);
end;

function EncodeMcpHeaderValue(const S: string): string;
var
  i: Integer;
  Plain: Boolean;
begin
  Plain := True;
  for i := 1 to Length(S) do
    if not ((Ord(S[i]) >= $20) and (Ord(S[i]) <= $7E)) and (S[i] <> #9) then
    begin
      Plain := False;
      Break;
    end;
  if Plain and (S <> '') and ((S[1] = ' ') or (S[1] = #9) or
     (S[Length(S)] = ' ') or (S[Length(S)] = #9)) then
    Plain := False;
  { A plain value that already reads as the sentinel is encoded too, or the
    server would decode it. }
  if Plain and (Copy(S, 1, Length(Sentinel)) = Sentinel) and
     (Copy(S, Length(S) - 1, 2) = SentinelEnd) and (Length(S) >= Length(Sentinel) + 2) then
    Plain := False;
  if Plain then
    Result := S
  else
    Result := Sentinel + BytesToBase64(TEncoding.UTF8.GetBytes(S)) + SentinelEnd;
end;

function McpNameFor(const Method, ParamsJSON: string): string;
var
  P: TJsonObject;
begin
  Result := '';
  P := JsonTryParse(ParamsJSON);
  if P = nil then Exit;
  try
    if (Method = 'tools/call') or (Method = 'prompts/get') then
      Result := P.GetStr('name', '')
    else if Method = 'resources/read' then
      Result := P.GetStr('uri', '')
    else if (Method = 'tasks/get') or (Method = 'tasks/update') or
            (Method = 'tasks/cancel') then
      Result := P.GetStr('taskId', '');
  finally
    P.Free;
  end;
end;

type
  TWalker = class
    Specs: TMCPParamHeaderArray;
    Err: string;
    procedure Walk(Obj: TJsonObject; const Path: TArray<string>; Reachable: Boolean);
    procedure WalkArray(Arr: TJsonArray; const Path: TArray<string>);
    procedure Annotation(Prop: TJsonObject; const Path: TArray<string>; Reachable: Boolean);
  end;

function AppendPath(const Path: TArray<string>; const Key: string): TArray<string>;
var
  i: Integer;
begin
  SetLength(Result, Length(Path) + 1);
  for i := 0 to High(Path) do Result[i] := Path[i];
  Result[High(Result)] := Key;
end;

procedure TWalker.Annotation(Prop: TJsonObject; const Path: TArray<string>;
                             Reachable: Boolean);
var
  H, Kind: string;
  i, N: Integer;
begin
  if Err <> '' then Exit;
  H := Prop.GetStr('x-mcp-header', #0);
  if H = #0 then
  begin
    Err := 'x-mcp-header must be a string';
    Exit;
  end;
  if not Reachable then
  begin
    Err := 'x-mcp-header "' + H + '" is not reachable through properties alone';
    Exit;
  end;
  if not IsToken(H) then
  begin
    Err := 'x-mcp-header "' + H + '" is not an HTTP header token';
    Exit;
  end;
  Kind := Prop.GetStr('type', '');
  if (Kind <> 'string') and (Kind <> 'integer') and (Kind <> 'boolean') then
  begin
    Err := 'x-mcp-header "' + H + '" is on a property of type "' + Kind +
           '" (only string, integer and boolean are allowed)';
    Exit;
  end;
  for i := 0 to High(Specs) do
    if SameText(Specs[i].Header, H) then
    begin
      Err := 'x-mcp-header "' + H + '" is used twice';
      Exit;
    end;
  N := Length(Specs);
  SetLength(Specs, N + 1);
  Specs[N].Header := H;
  Specs[N].Path := Path;
end;

procedure TWalker.WalkArray(Arr: TJsonArray; const Path: TArray<string>);
var
  i: Integer;
  O: TJsonObject;
  A: TJsonArray;
begin
  for i := 0 to Arr.Count - 1 do
  begin
    if Err <> '' then Exit;
    O := Arr.ItemObject(i);
    if O <> nil then
    try
      Walk(O, Path, False);
    finally
      O.Free;
    end
    else
    begin
      A := Arr.ItemArray(i);
      if A <> nil then
      try
        WalkArray(A, Path);
      finally
        A.Free;
      end;
    end;
  end;
end;

procedure TWalker.Walk(Obj: TJsonObject; const Path: TArray<string>; Reachable: Boolean);
var
  Keys, PropKeys: TStringList;
  i, j: Integer;
  Child, Prop: TJsonObject;
  Arr: TJsonArray;
begin
  Keys := Obj.Keys;
  try
    for i := 0 to Keys.Count - 1 do
    begin
      if Err <> '' then Exit;
      Child := Obj.ChildObject(Keys[i]);
      if Child <> nil then
      try
        if Keys[i] = 'properties' then
        begin
          { Each member is a property schema: the one place an annotation
            is allowed, and only while every step so far was `properties`. }
          PropKeys := Child.Keys;
          try
            for j := 0 to PropKeys.Count - 1 do
            begin
              Prop := Child.ChildObject(PropKeys[j]);
              if Prop = nil then Continue;
              try
                if Prop.Has('x-mcp-header') then
                  Annotation(Prop, AppendPath(Path, PropKeys[j]), Reachable);
                if Err <> '' then Exit;
                Walk(Prop, AppendPath(Path, PropKeys[j]), Reachable);
              finally
                Prop.Free;
              end;
            end;
          finally
            PropKeys.Free;
          end;
        end
        else
        begin
          { items, additionalProperties, not, if/then/else, $defs, ...:
            an annotation below any of these is not statically reachable. }
          if Child.Has('x-mcp-header') then Annotation(Child, Path, False);
          Walk(Child, Path, False);
        end;
      finally
        Child.Free;
      end
      else
      begin
        Arr := Obj.ChildArray(Keys[i]);
        if Arr <> nil then
        try
          WalkArray(Arr, Path);
        finally
          Arr.Free;
        end;
      end;
    end;
  finally
    Keys.Free;
  end;
end;

function ExtractParamHeaders(const SchemaJSON: string;
                             out Specs: TMCPParamHeaderArray;
                             out Err: string): Boolean;
var
  Root: TJsonObject;
  W: TWalker;
  Empty: TArray<string>;
begin
  SetLength(Specs, 0);
  Err := '';
  Result := True;
  { Cheap exit for the common case: no annotation anywhere. }
  if Pos('x-mcp-header', SchemaJSON) = 0 then Exit;
  Root := JsonTryParse(SchemaJSON);
  if Root = nil then Exit;
  W := TWalker.Create;
  try
    SetLength(Empty, 0);
    W.Walk(Root, Empty, True);
    Err := W.Err;
    if Err = '' then Specs := W.Specs;
    Result := Err = '';
  finally
    W.Free;
    Root.Free;
  end;
end;

function ParamHeadersFor(const Specs: TMCPParamHeaderArray;
                         const ArgsJSON: string): TMCPHeaderArray;
var
  Args, Cur, Next: TJsonObject;
  i, j, N: Integer;
  Raw, Value: string;
begin
  SetLength(Result, 0);
  if Length(Specs) = 0 then Exit;
  Args := JsonTryParse(ArgsJSON);
  if Args = nil then Exit;
  try
    for i := 0 to High(Specs) do
    begin
      if Length(Specs[i].Path) = 0 then Continue;
      Cur := Args;
      Next := nil;
      try
        for j := 0 to High(Specs[i].Path) - 1 do
        begin
          Next := Cur.ChildObject(Specs[i].Path[j]);
          if Cur <> Args then Cur.Free;
          Cur := Next;
          if Cur = nil then Break;
        end;
        if Cur = nil then Continue;
        Raw := Cur.GetRaw(Specs[i].Path[High(Specs[i].Path)], 'null');
        if (Raw = 'null') or (Raw = '') then Continue;
        if Raw[1] = '"' then
          Value := Cur.GetStr(Specs[i].Path[High(Specs[i].Path)], '')
        else
          Value := Raw;       { integer or true/false, already in wire form }
        N := Length(Result);
        SetLength(Result, N + 1);
        Result[N].Name := 'Mcp-Param-' + Specs[i].Header;
        Result[N].Value := EncodeMcpHeaderValue(Value);
      finally
        if (Cur <> nil) and (Cur <> Args) then Cur.Free;
      end;
    end;
  finally
    Args.Free;
  end;
end;

end.
