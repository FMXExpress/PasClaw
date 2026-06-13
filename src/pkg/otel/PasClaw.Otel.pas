(*
  PasClaw.Otel - OpenTelemetry traces (OTLP/HTTP+JSON) for the agent loop
  and gateway HTTP server. Off by default; enable via the
  diagnostics.otel block in config.json, or the standard
  OTEL_EXPORTER_OTLP_ENDPOINT / OTEL_EXPORTER_OTLP_HEADERS env vars
  (env vars win when both are set).

  Span shape mirrors openclaw v2026.2+ so dashboards and exporters
  built for the openclaw ecosystem (Langfuse, Tempo, Jaeger,
  Honeycomb, Datadog) groks our spans without remapping:

    HTTP <method> <route>     (gateway server span, parent of agent.turn
                               when triggered via /v1/chat)
      └── openclaw.agent.turn (one tool-loop iteration)
          ├── chat {model}    (provider request -- gen_ai.* attrs)
          └── execute_tool {name}
              (one per tool dispatch)

  Attribute names follow OpenTelemetry GenAI semantic conventions
  (gen_ai.request.model, gen_ai.usage.input_tokens / output_tokens,
  gen_ai.provider.name, gen_ai.operation.name) plus W3C Trace Context
  for cross-service propagation (traceparent header in/out).

  Transport: OTLP/HTTP with application/json body. We don't ship
  protobuf encoding in this first cut -- the OTLP spec mandates
  both JSON and protobuf on the http path and every collector groks
  both, so JSON is the realistic Pascal choice.

  Threading: the agent loop is single-threaded; the gateway runs
  one OnCommandGet per Indy worker thread. The "current span" is a
  threadvar so per-request gateway traces don't bleed into each
  other. The export buffer is module-level guarded by a critical
  section.
*)
unit PasClaw.Otel;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

interface

uses
  SysUtils, Classes, SyncObjs, DateUtils,
  PasClaw.Config;

type
  TOtelSpanKind = (oskInternal, oskServer, oskClient);
  TOtelStatusCode = (oscUnset, oscOk, oscError);

  TOtelAttrKind = (oakStr, oakInt, oakBool);
  TOtelAttr = record
    Key:    string;
    Kind:   TOtelAttrKind;
    SValue: string;
    IValue: Int64;
    BValue: Boolean;
  end;

  TOtelSpan = class
  public
    TraceId:      string;   { 32 lowercase hex chars (16 bytes) }
    SpanId:       string;   { 16 lowercase hex chars (8 bytes) }
    ParentSpanId: string;   { 16 hex; '' for root spans }
    Name:         string;
    Kind:         TOtelSpanKind;
    StartNanos:   Int64;
    EndNanos:     Int64;
    Attrs:        array of TOtelAttr;
    StatusCode:   TOtelStatusCode;
    StatusMsg:    string;
    PrevCurrent:  TOtelSpan;   { restored on Finish }
    Finished:     Boolean;
  end;

{ Lifecycle. Init is safe to call multiple times -- last config wins.
  Shutdown flushes any buffered spans synchronously; safe at process
  exit. }
procedure InitOtelFromConfig(const Cfg: TConfig);
procedure ShutdownOtel;

{ StartSpan returns nil when OTel is disabled OR when the trace was
  not sampled. All other helpers (SetAttr*, SetStatus, Finish) tolerate
  nil and become no-ops, so call sites stay clean:

    Span := StartSpan('chat ' + Model, oskClient, '');
    try
      ...
    finally
      Finish(Span);
    end;

  ParentTraceparent is the W3C Trace Context header value when this
  span starts as a child of a remote trace (gateway request inbound).
  Empty string means "use the threadvar current span as parent if
  any, else start a new trace". }
function StartSpan(const Name: string;
                   Kind: TOtelSpanKind;
                   const ParentTraceparent: string = ''): TOtelSpan;

procedure SetAttrStr(Span: TOtelSpan; const Key, Value: string);
procedure SetAttrInt(Span: TOtelSpan; const Key: string; Value: Int64);
procedure SetAttrBool(Span: TOtelSpan; const Key: string; Value: Boolean);

procedure SetStatus(Span: TOtelSpan;
                    Code: TOtelStatusCode;
                    const Msg: string = '');

procedure FinishSpan(Span: TOtelSpan);

{ Returns the W3C traceparent string for the current span, or '' when
  OTel is disabled / no current span. Hand this to outbound HTTP
  clients (provider requests, MCP calls) to propagate the trace. }
function CurrentTraceparent: string;

{ True when OTel emits traces (config enabled + endpoint set). Call
  sites can branch around expensive attribute-building when off. }
function OtelEnabled: Boolean;

{ Test seam: swap the export transport for a callback. The test
  passes a closure that captures the POST body so we can assert on
  it without spinning up real HTTP. Pass nil to restore the default
  OTLP/HTTP transport. Not part of the public contract; here so
  src/tests/otel_tests.pas can pin behaviour without a TCP listener. }
type
  TOtelExportFunc = procedure(const Endpoint, JSONBody: string;
                              const Headers: array of string);

procedure SetExportTransport(F: TOtelExportFunc);

implementation

uses
  PasClaw.Logger,
  PasClaw.Crypto.Random,
  PasClaw.Providers.HTTP;

var
  GEnabled:      Boolean = False;
  GEndpoint:     string  = '';   { e.g. http://localhost:4318/v1/traces }
  GServiceName:  string  = 'pasclaw';
  GHeaders:      THeaderPairs;
  GSampleRate:   Double  = 1.0;
  GLock:         TCriticalSection = nil;
  GBuffer:       TList = nil;   { TList of TOtelSpan; flushed when root finishes }
  GFlushThreshold: Integer = 64;  { hard cap so an unbounded trace doesn't grow forever }
  GExportFunc:   TOtelExportFunc = nil;

threadvar
  GCurrent: TOtelSpan;

{ ---------- ID / hex helpers ---------- }

function BytesToHexLower(const B: TBytes): string;
const
  Hex: array[0..15] of Char = '0123456789abcdef';
var
  i: Integer;
begin
  SetLength(Result, Length(B) * 2);
  for i := 0 to High(B) do
  begin
    Result[i * 2 + 1] := Hex[(B[i] shr 4) and $0F];
    Result[i * 2 + 2] := Hex[ B[i]        and $0F];
  end;
end;

function NewTraceId: string;
begin
  Result := BytesToHexLower(GetRandomBytes(16));
end;

function NewSpanId: string;
begin
  Result := BytesToHexLower(GetRandomBytes(8));
end;

{ ---------- Time ---------- }

function UnixNanosNow: Int64;
var
  T: TDateTime;
  Sec: Int64;
  MSec: Word;
begin
  T := Now;
  Sec := DateTimeToUnix(T, True);
  MSec := MilliSecondOf(T);
  Result := Sec * Int64(1000000000) + Int64(MSec) * Int64(1000000);
end;

(* ---------- W3C traceparent ----------
  Format: 00-<32 hex trace id>-<16 hex span id>-<2 hex flags>
  Flags: 01 = sampled. We always emit 01 (we sampled or we wouldn't
  be propagating). Inbound: tolerate any version-00 traceparent;
  on parse failure, start a new trace silently (do not throw). *)

procedure ParseTraceparent(const H: string;
                           out TraceId, SpanId: string;
                           out OK: Boolean);
var
  Parts: TStringList;
begin
  TraceId := '';
  SpanId  := '';
  OK := False;
  if H = '' then Exit;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := '-';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := H;
    if Parts.Count < 4 then Exit;
    if Length(Parts[1]) <> 32 then Exit;
    if Length(Parts[2]) <> 16 then Exit;
    { Don't validate hex character-by-character; the worst that
      happens is the collector rejects this span and we move on. }
    TraceId := LowerCase(Parts[1]);
    SpanId  := LowerCase(Parts[2]);
    OK := True;
  finally
    Parts.Free;
  end;
end;

function FormatTraceparent(const TraceId, SpanId: string): string;
begin
  Result := '00-' + TraceId + '-' + SpanId + '-01';
end;

{ ---------- JSON escape ----------
  Cheap escaper for the attribute payload. We control the keys (all
  ASCII), but values come from user-ish strings (tool names, model
  ids, error messages) so escape what JSON requires. }

function JsonEscape(const S: string): string;
var
  i: Integer;
  c: Char;
  Sb: TStringBuilder;
begin
  Sb := TStringBuilder.Create;
  try
    for i := 1 to Length(S) do
    begin
      c := S[i];
      case c of
        '"':  Sb.Append('\"');
        '\':  Sb.Append('\\');
        #8:   Sb.Append('\b');
        #9:   Sb.Append('\t');
        #10:  Sb.Append('\n');
        #12:  Sb.Append('\f');
        #13:  Sb.Append('\r');
      else
        if Ord(c) < $20 then
          Sb.Append('\u00' + IntToHex(Ord(c), 2))
        else
          Sb.Append(c);
      end;
    end;
    Result := Sb.ToString;
  finally
    Sb.Free;
  end;
end;

{ ---------- Span helpers ---------- }

procedure ResetSpanState(Span: TOtelSpan);
begin
  if Span <> nil then
  begin
    SetLength(Span.Attrs, 0);
    Span.Finished := False;
  end;
end;

function KindToOTLP(K: TOtelSpanKind): Integer;
begin
  { OTLP span kind enum:
      0 SPAN_KIND_UNSPECIFIED
      1 SPAN_KIND_INTERNAL
      2 SPAN_KIND_SERVER
      3 SPAN_KIND_CLIENT
      (we don't emit PRODUCER / CONSUMER) }
  case K of
    oskServer: Result := 2;
    oskClient: Result := 3;
  else
    Result := 1;
  end;
end;

function StatusToOTLP(S: TOtelStatusCode): Integer;
begin
  case S of
    oscOk:    Result := 1;
    oscError: Result := 2;
  else
    Result := 0;
  end;
end;

(* ---------- OTLP/HTTP+JSON encoding ----------
  Body shape (per OTLP spec, ExportTraceServiceRequest):
    resourceSpans[].resource.attributes  <- service.name, telemetry.sdk.name
    resourceSpans[].scopeSpans[].scope   <- {name: "pasclaw"}
    resourceSpans[].scopeSpans[].spans[] <- one entry per finished span

  Per-span keys: traceId, spanId, parentSpanId (omitted on root),
  name, kind (1=internal/2=server/3=client),
  startTimeUnixNano + endTimeUnixNano (string-encoded Int64 per
  OTLP convention -- JSON only safely represents 53-bit ints),
  attributes[] (each {key,value:{stringValue|intValue|boolValue}}),
  status{code:0|1|2, optional message}. *)

procedure AppendAttr(Sb: TStringBuilder; const A: TOtelAttr; First: Boolean);
begin
  if not First then Sb.Append(',');
  Sb.Append('{"key":"').Append(JsonEscape(A.Key)).Append('","value":{');
  case A.Kind of
    oakStr:
      Sb.Append('"stringValue":"').Append(JsonEscape(A.SValue)).Append('"');
    oakInt:
      Sb.Append('"intValue":"').Append(IntToStr(A.IValue)).Append('"');
    oakBool:
      if A.BValue then
        Sb.Append('"boolValue":true')
      else
        Sb.Append('"boolValue":false');
  end;
  Sb.Append('}}');
end;

function EncodeSpan(Span: TOtelSpan): string;
var
  Sb: TStringBuilder;
  k: Integer;
begin
  Sb := TStringBuilder.Create;
  try
    Sb.Append('{"traceId":"').Append(Span.TraceId).Append('",');
    Sb.Append('"spanId":"').Append(Span.SpanId).Append('",');
    if Span.ParentSpanId <> '' then
      Sb.Append('"parentSpanId":"').Append(Span.ParentSpanId).Append('",');
    Sb.Append('"name":"').Append(JsonEscape(Span.Name)).Append('",');
    Sb.Append('"kind":').Append(IntToStr(KindToOTLP(Span.Kind))).Append(',');
    Sb.Append('"startTimeUnixNano":"').Append(IntToStr(Span.StartNanos)).Append('",');
    Sb.Append('"endTimeUnixNano":"').Append(IntToStr(Span.EndNanos)).Append('",');
    Sb.Append('"attributes":[');
    for k := 0 to High(Span.Attrs) do
      AppendAttr(Sb, Span.Attrs[k], k = 0);
    Sb.Append('],');
    Sb.Append('"status":{"code":').Append(IntToStr(StatusToOTLP(Span.StatusCode)));
    if Span.StatusMsg <> '' then
      Sb.Append(',"message":"').Append(JsonEscape(Span.StatusMsg)).Append('"');
    Sb.Append('}}');
    Result := Sb.ToString;
  finally
    Sb.Free;
  end;
end;

function EncodeBuffer(const Spans: array of TOtelSpan): string;
var
  Sb: TStringBuilder;
  i: Integer;
begin
  Sb := TStringBuilder.Create;
  try
    Sb.Append('{"resourceSpans":[{"resource":{"attributes":[');
    Sb.Append('{"key":"service.name","value":{"stringValue":"')
      .Append(JsonEscape(GServiceName)).Append('"}},');
    Sb.Append('{"key":"telemetry.sdk.name","value":{"stringValue":"pasclaw-otel"}},');
    Sb.Append('{"key":"telemetry.sdk.language","value":{"stringValue":"pascal"}}');
    Sb.Append(']},"scopeSpans":[{"scope":{"name":"pasclaw"},"spans":[');
    for i := 0 to High(Spans) do
    begin
      if i > 0 then Sb.Append(',');
      Sb.Append(EncodeSpan(Spans[i]));
    end;
    Sb.Append(']}]}]}');
    Result := Sb.ToString;
  finally
    Sb.Free;
  end;
end;

{ ---------- Default OTLP/HTTP exporter ----------
  Single synchronous POST. Failures are logged at warn -- we never
  want OTel export to crash the agent or block a tool result on a
  flaky collector. PostJSON already has a hard timeout. }

procedure DefaultExport(const Endpoint, JSONBody: string;
                        const ExtraHeadersIgnored: array of string);
var
  AllHeaders: THeaderPairs;
  i, BaseLen: Integer;
  Resp: THTTPResult;
begin
  BaseLen := Length(GHeaders);
  SetLength(AllHeaders, BaseLen + 1);
  for i := 0 to BaseLen - 1 do AllHeaders[i] := GHeaders[i];
  AllHeaders[BaseLen].Name  := 'Content-Type';
  AllHeaders[BaseLen].Value := 'application/json';
  try
    Resp := PostJSON(Endpoint, JSONBody, AllHeaders, 10);
    if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
      LogWarn('otel: export %s -> %d: %s',
              [Endpoint, Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
  except
    on E: Exception do
      LogWarn('otel: export %s raised %s: %s',
              [Endpoint, E.ClassName, E.Message]);
  end;
end;

procedure FlushBufferLocked;
var
  Spans: array of TOtelSpan;
  i: Integer;
  Body: string;
begin
  if (GBuffer = nil) or (GBuffer.Count = 0) then Exit;
  SetLength(Spans, GBuffer.Count);
  for i := 0 to GBuffer.Count - 1 do
    Spans[i] := TOtelSpan(GBuffer[i]);
  Body := EncodeBuffer(Spans);
  if Assigned(GExportFunc) then
    GExportFunc(GEndpoint, Body, [])
  else
    DefaultExport(GEndpoint, Body, []);
  for i := 0 to High(Spans) do
    Spans[i].Free;
  GBuffer.Clear;
end;

{ ---------- Public API ---------- }

function OtelEnabled: Boolean;
begin
  Result := GEnabled and (GEndpoint <> '');
end;

procedure SetExportTransport(F: TOtelExportFunc);
begin
  GExportFunc := F;
end;

function EnsureTracesPath(const Ep: string): string;
{ Standard collectors expose POST /v1/traces. If the configured
  endpoint is just a host:port (the openclaw convention), append
  the path; if it already ends in /v1/traces, leave it alone. }
begin
  if Ep = '' then Exit('');
  if (Length(Ep) >= 10) and (Copy(Ep, Length(Ep) - 9, 10) = '/v1/traces') then
    Exit(Ep);
  Result := Ep;
  while (Result <> '') and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
  Result := Result + '/v1/traces';
end;

procedure ParseHeaderEnv(const S: string; var H: THeaderPairs);
{ OTEL_EXPORTER_OTLP_HEADERS = "k1=v1,k2=v2" (W3C Baggage style).
  Commas and equals inside values aren't escaped per the OTel spec
  -- the common case is API tokens which are URL-safe. We split on
  the first comma / equals; anything weirder needs config.json. }
var
  Parts, KV: TStringList;
  i: Integer;
begin
  SetLength(H, 0);
  if S = '' then Exit;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ',';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := S;
    SetLength(H, Parts.Count);
    KV := TStringList.Create;
    try
      KV.Delimiter := '=';
      KV.StrictDelimiter := True;
      for i := 0 to Parts.Count - 1 do
      begin
        KV.DelimitedText := Parts[i];
        if KV.Count >= 2 then
        begin
          H[i].Name  := Trim(KV[0]);
          H[i].Value := Trim(KV[1]);
        end;
      end;
    finally
      KV.Free;
    end;
  finally
    Parts.Free;
  end;
end;

procedure InitOtelFromConfig(const Cfg: TConfig);
var
  EnvEp, EnvHdr: string;
  i: Integer;
begin
  if GLock = nil then GLock := TCriticalSection.Create;
  if GBuffer = nil then GBuffer := TList.Create;

  GEnabled     := Cfg.Diagnostics.Otel.Enabled;
  GEndpoint    := Cfg.Diagnostics.Otel.Endpoint;
  GServiceName := Cfg.Diagnostics.Otel.ServiceName;
  GSampleRate  := Cfg.Diagnostics.Otel.SampleRate;

  SetLength(GHeaders, Length(Cfg.Diagnostics.Otel.Headers));
  for i := 0 to High(Cfg.Diagnostics.Otel.Headers) do
  begin
    GHeaders[i].Name  := Cfg.Diagnostics.Otel.Headers[i].Name;
    GHeaders[i].Value := Cfg.Diagnostics.Otel.Headers[i].Value;
  end;

  { Env vars override config -- standard OTel SDK contract. The
    presence of OTEL_EXPORTER_OTLP_ENDPOINT also flips enabled=on
    even when config.json has it off, matching what openclaw does. }
  EnvEp := GetEnvironmentVariable('OTEL_EXPORTER_OTLP_ENDPOINT');
  if EnvEp <> '' then
  begin
    GEndpoint := EnvEp;
    GEnabled  := True;
  end;
  EnvHdr := GetEnvironmentVariable('OTEL_EXPORTER_OTLP_HEADERS');
  if EnvHdr <> '' then ParseHeaderEnv(EnvHdr, GHeaders);

  if GEndpoint <> '' then
    GEndpoint := EnsureTracesPath(GEndpoint);

  if GServiceName = '' then GServiceName := 'pasclaw';

  if GEnabled and (GEndpoint <> '') then
    LogInfo('otel: traces enabled, endpoint=%s service=%s sampleRate=%.2f',
            [GEndpoint, GServiceName, GSampleRate])
  else
    LogDebug('otel: disabled (set diagnostics.otel.enabled=true or OTEL_EXPORTER_OTLP_ENDPOINT)');
end;

procedure ShutdownOtel;
begin
  if GLock = nil then Exit;
  GLock.Enter;
  try
    FlushBufferLocked;
  finally
    GLock.Leave;
  end;
end;

function Sampled: Boolean;
begin
  if GSampleRate >= 1.0 then Exit(True);
  if GSampleRate <= 0.0 then Exit(False);
  { Trivial Bernoulli. Random() returns [0,1). }
  Result := Random < GSampleRate;
end;

function StartSpan(const Name: string;
                   Kind: TOtelSpanKind;
                   const ParentTraceparent: string): TOtelSpan;
var
  PTrace, PSpan: string;
  POK: Boolean;
begin
  Result := nil;
  if not OtelEnabled then Exit;

  { Sampling decision: only roll for ROOT spans (no current and no
    parent traceparent). Child spans inherit the trace's decision
    by simple virtue of having a parent already. }
  if (GCurrent = nil) and (ParentTraceparent = '') then
    if not Sampled then Exit;

  Result := TOtelSpan.Create;
  Result.Name := Name;
  Result.Kind := Kind;
  Result.StartNanos := UnixNanosNow;
  Result.EndNanos := 0;
  Result.StatusCode := oscUnset;
  Result.SpanId := NewSpanId;

  if GCurrent <> nil then
  begin
    Result.TraceId := GCurrent.TraceId;
    Result.ParentSpanId := GCurrent.SpanId;
  end
  else if ParentTraceparent <> '' then
  begin
    ParseTraceparent(ParentTraceparent, PTrace, PSpan, POK);
    if POK then
    begin
      Result.TraceId := PTrace;
      Result.ParentSpanId := PSpan;
    end
    else
      Result.TraceId := NewTraceId;
  end
  else
    Result.TraceId := NewTraceId;

  Result.PrevCurrent := GCurrent;
  GCurrent := Result;
end;

procedure SetAttrStr(Span: TOtelSpan; const Key, Value: string);
var
  n: Integer;
begin
  if Span = nil then Exit;
  n := Length(Span.Attrs);
  SetLength(Span.Attrs, n + 1);
  Span.Attrs[n].Key    := Key;
  Span.Attrs[n].Kind   := oakStr;
  Span.Attrs[n].SValue := Value;
end;

procedure SetAttrInt(Span: TOtelSpan; const Key: string; Value: Int64);
var
  n: Integer;
begin
  if Span = nil then Exit;
  n := Length(Span.Attrs);
  SetLength(Span.Attrs, n + 1);
  Span.Attrs[n].Key    := Key;
  Span.Attrs[n].Kind   := oakInt;
  Span.Attrs[n].IValue := Value;
end;

procedure SetAttrBool(Span: TOtelSpan; const Key: string; Value: Boolean);
var
  n: Integer;
begin
  if Span = nil then Exit;
  n := Length(Span.Attrs);
  SetLength(Span.Attrs, n + 1);
  Span.Attrs[n].Key    := Key;
  Span.Attrs[n].Kind   := oakBool;
  Span.Attrs[n].BValue := Value;
end;

procedure SetStatus(Span: TOtelSpan;
                    Code: TOtelStatusCode;
                    const Msg: string);
begin
  if Span = nil then Exit;
  Span.StatusCode := Code;
  if Msg <> '' then Span.StatusMsg := Msg;
end;

procedure FinishSpan(Span: TOtelSpan);
var
  ShouldFlush: Boolean;
begin
  if Span = nil then Exit;
  if Span.Finished then Exit;
  Span.Finished := True;
  Span.EndNanos := UnixNanosNow;

  { Restore the threadvar to whatever was current before this span
    started. Out-of-order Finish (children that outlive their parent)
    is a caller bug; we tolerate it by just restoring our recorded
    PrevCurrent regardless of whether GCurrent matches us right now. }
  if GCurrent = Span then
    GCurrent := Span.PrevCurrent;

  GLock.Enter;
  try
    GBuffer.Add(Span);
    { Flush when the trace root finishes (typical case) OR when the
      buffer grows past the cap (defensive against pathologically
      deep traces). PrevCurrent = nil means "this span has no parent
      span in our process" -- exactly the trace boundary. }
    ShouldFlush := (Span.PrevCurrent = nil) or (GBuffer.Count >= GFlushThreshold);
    if ShouldFlush then
      FlushBufferLocked;
  finally
    GLock.Leave;
  end;
end;

function CurrentTraceparent: string;
begin
  if (GCurrent = nil) or not OtelEnabled then Exit('');
  Result := FormatTraceparent(GCurrent.TraceId, GCurrent.SpanId);
end;

initialization
  Randomize;

finalization
  try ShutdownOtel except end;
  if GBuffer <> nil then FreeAndNil(GBuffer);
  if GLock <> nil then FreeAndNil(GLock);

end.
