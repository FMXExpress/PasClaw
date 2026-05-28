{
  PasClaw.Providers.OpenAI - OpenAI Chat Completions client and the
  shared implementation for every OpenAI-compatible provider (Groq,
  DeepSeek, Together, OpenRouter, Ollama, vLLM, Mistral, etc.). Catalog
  entries in PasClaw.Providers.Catalog point here with their own base
  URL + auth scheme; this unit doesn't know which provider it's being
  used for beyond the display name it was created with.

  Endpoint: POST <api_base>/v1/chat/completions
  Auth:     Authorization: Bearer <key>  (default; override via TAuthScheme)
}
unit PasClaw.Providers.OpenAI;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Providers.HTTP,
  PasClaw.Providers.Catalog;

type
  TOpenAIProvider = class(TInterfacedObject, ILLMProvider)
  private
    FAPIKey:       string;
    FAPIBase:      string;
    FDefaultModel: string;
    FAuth:         TAuthScheme;
    FDisplayName:  string;   { surface in GetName / log lines }
    function BuildAuthHeaders: TArray<THeaderPair>;
  public
    { Backwards-compatible constructor: assumes Bearer auth and the
      'openai' display name. Existing call sites stay byte-identical. }
    constructor Create(const APIKey, APIBase, DefaultModel: string); overload;
    { Catalog-aware constructor used by the factory. DisplayName surfaces
      in GetName (so 'groq' returns 'groq', not 'openai'); Auth controls
      how the API key is sent (Bearer / none / custom header). }
    constructor Create(const APIKey, APIBase, DefaultModel, DisplayName: string;
                       const Auth: TAuthScheme); overload;
    function Chat(const Messages: array of TMessage;
                  const Tools:    array of TToolDefinition;
                  const Model:    string;
                  const Options:  TChatOptions): TLLMResponse;
    function ChatStream(const Messages: array of TMessage;
                        const Tools:    array of TToolDefinition;
                        const Model:    string;
                        const Options:  TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
  end;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger;

constructor TOpenAIProvider.Create(const APIKey, APIBase, DefaultModel: string);
var
  Bearer: TAuthScheme;
begin
  Bearer.Kind       := asBearer;
  Bearer.HeaderName := '';
  Create(APIKey, APIBase, DefaultModel, 'openai', Bearer);
end;

constructor TOpenAIProvider.Create(const APIKey, APIBase, DefaultModel, DisplayName: string;
                                    const Auth: TAuthScheme);
begin
  inherited Create;
  FAPIKey := APIKey;
  if APIBase <> '' then FAPIBase := APIBase else FAPIBase := 'https://api.openai.com';
  if DefaultModel <> '' then FDefaultModel := DefaultModel else FDefaultModel := 'gpt-4o-mini';
  if DisplayName <> '' then FDisplayName := DisplayName else FDisplayName := 'openai';
  FAuth := Auth;
end;

function TOpenAIProvider.BuildAuthHeaders: TArray<THeaderPair>;
begin
  case FAuth.Kind of
    asNone:
      SetLength(Result, 0);
    asHeader:
      begin
        if (FAuth.HeaderName = '') or (FAPIKey = '') then
        begin
          SetLength(Result, 0);
          Exit;
        end;
        SetLength(Result, 1);
        Result[0] := MakeHeader(FAuth.HeaderName, FAPIKey);
      end;
  else
    { asBearer is the default — and the safety net for any future enum
      value we forget to handle here. Skip emitting the header when the
      key is empty (local providers misconfigured as Bearer still work). }
    if FAPIKey = '' then
      SetLength(Result, 0)
    else
    begin
      SetLength(Result, 1);
      Result[0] := MakeHeader('Authorization', 'Bearer ' + FAPIKey);
    end;
  end;
end;

function TOpenAIProvider.GetDefaultModel: string;     begin Result := FDefaultModel; end;
function TOpenAIProvider.GetName: string;             begin Result := FDisplayName;  end;
function TOpenAIProvider.SupportsThinking: Boolean;   begin Result := False; end;
function TOpenAIProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TOpenAIProvider.SupportsStreaming: Boolean;  begin Result := False; end;

function BuildOAIRequest(const Messages: array of TMessage;
                         const Tools:    array of TToolDefinition;
                         const Model:    string;
                         const Options:  TChatOptions): string;
var
  Root, M, ToolObj, FObj, TCObj, EmptyParams: TJsonObject;
  MsgArr, ToolArr, TCArr: TJsonArray;
  i, j: Integer;
  Sys: string;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr('model', Model);
    if Options.MaxTokens > 0 then Root.PutInt('max_tokens', Options.MaxTokens);
    if Options.Temperature > 0 then Root.PutFloat('temperature', Options.Temperature);

    Sys := Options.SystemPrompt;

    MsgArr := TJsonArray.Create;
    if Sys <> '' then
    begin
      M := TJsonObject.Create;
      M.PutStr('role',    'system');
      M.PutStr('content', Sys);
      MsgArr.AddObject(M);
    end;

    for i := 0 to High(Messages) do
    begin
      if (Messages[i].Role = mrSystem) and (Sys <> '') then
        Continue;  { already added above }

      M := TJsonObject.Create;
      M.PutStr('role', MsgRoleToString(Messages[i].Role));
      M.PutStr('content', Messages[i].Content);

      if Messages[i].Role = mrTool then
        M.PutStr('tool_call_id', Messages[i].ToolCallId);

      if Length(Messages[i].ToolCalls) > 0 then
      begin
        TCArr := TJsonArray.Create;
        for j := 0 to High(Messages[i].ToolCalls) do
        begin
          TCObj := TJsonObject.Create;
          TCObj.PutStr('id',   Messages[i].ToolCalls[j].Id);
          TCObj.PutStr('type', 'function');
          FObj := TJsonObject.Create;
          FObj.PutStr('name',      Messages[i].ToolCalls[j].Func.Name);
          FObj.PutStr('arguments', Messages[i].ToolCalls[j].Func.Arguments);
          TCObj.PutObject('function', FObj);
          TCArr.AddObject(TCObj);
        end;
        M.PutArray('tool_calls', TCArr);
      end;

      MsgArr.AddObject(M);
    end;
    Root.PutArray('messages', MsgArr);

    if Length(Tools) > 0 then
    begin
      ToolArr := TJsonArray.Create;
      for i := 0 to High(Tools) do
      begin
        ToolObj := TJsonObject.Create;
        ToolObj.PutStr('type', 'function');
        FObj := TJsonObject.Create;
        FObj.PutStr('name', Tools[i].Name);
        if Tools[i].Description <> '' then FObj.PutStr('description', Tools[i].Description);
        if Tools[i].Schema <> '' then
          FObj.PutRaw('parameters', Tools[i].Schema)
        else
        begin
          EmptyParams := TJsonObject.Create;
          FObj.PutObject('parameters', EmptyParams);
        end;
        ToolObj.PutObject('function', FObj);
        ToolArr.AddObject(ToolObj);
      end;
      Root.PutArray('tools', ToolArr);

      { tool_choice maps 1:1 to the OpenAI Chat Completions schema:
          "auto" / "none" / "required" — emitted as a string field.
        Empty means "do not emit; provider default applies". The
        function-by-name object form is not yet supported here;
        TChatOptions.ToolChoice is a plain string. }
      if (Options.ToolChoice = 'auto') or (Options.ToolChoice = 'none') or
         (Options.ToolChoice = 'required') then
        Root.PutStr('tool_choice', Options.ToolChoice);
    end;

    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

procedure ParseOAIResponse(const Body: string; var Resp: TLLMResponse);
var
  Obj, Choice, Msg, FObj, TCObj, Usage: TJsonObject;
  Choices, TCArr: TJsonArray;
  i: Integer;
  TC: TToolCall;
begin
  Resp.Content := '';
  SetLength(Resp.ToolCalls, 0);
  if Trim(Body) = '' then Exit;
  Obj := TJsonObject.Parse(Body);
  if Obj = nil then Exit;
  try
    Resp.Model := Obj.GetStr('model', '');
    Choices := Obj.ChildArray('choices');
    if Choices <> nil then
    try
      if Choices.Count > 0 then
      begin
        Choice := Choices.ItemObject(0);
        if Choice <> nil then
        try
          Resp.FinishReason := Choice.GetStr('finish_reason', '');
          Msg := Choice.ChildObject('message');
          if Msg <> nil then
          try
            Resp.Content := Msg.GetStr('content', '');
            TCArr := Msg.ChildArray('tool_calls');
            if TCArr <> nil then
            try
              for i := 0 to TCArr.Count - 1 do
              begin
                TCObj := TCArr.ItemObject(i);
                if TCObj = nil then Continue;
                try
                  TC.Id   := TCObj.GetStr('id', '');
                  TC.Kind := TCObj.GetStr('type', 'function');
                  FObj := TCObj.ChildObject('function');
                  if FObj <> nil then
                  try
                    TC.Func.Name      := FObj.GetStr('name', '');
                    TC.Func.Arguments := FObj.GetStr('arguments', '{}');
                  finally
                    FObj.Free;
                  end;
                  SetLength(Resp.ToolCalls, Length(Resp.ToolCalls) + 1);
                  Resp.ToolCalls[High(Resp.ToolCalls)] := TC;
                finally
                  TCObj.Free;
                end;
              end;
            finally
              TCArr.Free;
            end;
          finally
            Msg.Free;
          end;
        finally
          Choice.Free;
        end;
      end;
    finally
      Choices.Free;
    end;
    Usage := Obj.ChildObject('usage');
    if Usage <> nil then
    try
      Resp.Usage.InputTokens  := Usage.GetInt('prompt_tokens',     0);
      Resp.Usage.OutputTokens := Usage.GetInt('completion_tokens', 0);
    finally
      Usage.Free;
    end;
  finally
    Obj.Free;
  end;
end;

function TOpenAIProvider.Chat(const Messages: array of TMessage;
                              const Tools:    array of TToolDefinition;
                              const Model:    string;
                              const Options:  TChatOptions): TLLMResponse;
var
  Body, URL, UseModel: string;
  Resp: THTTPResult;
  Headers: TArray<THeaderPair>;
begin
  if Model <> '' then UseModel := Model else UseModel := FDefaultModel;
  URL  := FAPIBase + '/v1/chat/completions';
  Body := BuildOAIRequest(Messages, Tools, UseModel, Options);

  Headers := BuildAuthHeaders;

  LogDebug('%s POST %s (model=%s, body=%d bytes)', [FDisplayName, URL, UseModel, Length(Body)]);
  Resp := PostJSON(URL, Body, Headers, 120);

  Result.Content := '';
  SetLength(Result.ToolCalls, 0);
  if (Resp.StatusCode >= 200) and (Resp.StatusCode < 300) then
    ParseOAIResponse(Resp.Body, Result)
  else
  begin
    if Resp.Body <> '' then
      Result.Content := Format('%s error %d: %s', [FDisplayName, Resp.StatusCode, Resp.Body])
    else
      Result.Content := Format('%s error: status=%d msg=%s', [FDisplayName, Resp.StatusCode, Resp.ErrorMsg]);
    Result.FinishReason := 'error';
  end;
end;

function TOpenAIProvider.ChatStream(const Messages: array of TMessage;
                                    const Tools:    array of TToolDefinition;
                                    const Model:    string;
                                    const Options:  TChatOptions;
                                    OnChunk: TStreamCallback): TLLMResponse;
var
  C: TStreamChunk;
begin
  Result := Chat(Messages, Tools, Model, Options);
  if Assigned(OnChunk) then
  begin
    C.Kind := 'text'; C.Text := Result.Content; OnChunk(C);
    C.Kind := 'done'; C.Text := '';             OnChunk(C);
  end;
end;

end.
