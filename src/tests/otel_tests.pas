program otel_tests;
(*
  Pin the OpenTelemetry exporter shape: span hierarchy, attribute
  names, W3C trace context propagation, sampling toggle, env-var
  override. No real OTel collector is spun up -- we install a
  test-only export transport that captures the JSON body so we can
  parse it and assert on the structure. Same JSON the real OTLP
  exporter would POST to /v1/traces.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.JSON,
  PasClaw.Otel;

var
  GCapturedEndpoint: string;
  GCapturedBody: string;
  GCaptureCount: Integer = 0;

procedure CaptureExport(const Endpoint, JSONBody: string;
                        const Headers: array of string);
begin
  GCapturedEndpoint := Endpoint;
  GCapturedBody := JSONBody;
  Inc(GCaptureCount);
end;

procedure ResetCapture;
begin
  GCapturedEndpoint := '';
  GCapturedBody := '';
  GCaptureCount := 0;
end;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertEq(const A, B, Msg: string);
begin
  if A <> B then
    Fail_(Msg + ' (expected "' + B + '" got "' + A + '")');
end;

procedure AssertEqInt(A, B: Integer; const Msg: string);
begin
  if A <> B then
    Fail_(Msg + ' (expected ' + IntToStr(B) + ' got ' + IntToStr(A) + ')');
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) <= 0 then
    Fail_(Msg + ' (needle "' + Needle + '" missing from "' +
          Copy(Haystack, 1, 400) + '")');
end;

procedure AssertNotContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) > 0 then
    Fail_(Msg + ' (unwanted needle "' + Needle + '" present in "' +
          Copy(Haystack, 1, 400) + '")');
end;

function MakeEnabledConfig: TConfig;
begin
  Result := TConfig.Create;
  Result.Diagnostics.Otel.Enabled     := True;
  Result.Diagnostics.Otel.Endpoint    := 'http://127.0.0.1:65535';
  Result.Diagnostics.Otel.ServiceName := 'otel-test';
  Result.Diagnostics.Otel.SampleRate  := 1.0;
end;

procedure TestDisabledByDefault;
{ Out of the box (TConfig.Create defaults) OTel must NOT export
  anything. The whole point of "off by default" is that running
  `pasclaw status` doesn't fire a stray POST to localhost:4318. }
var
  Cfg: TConfig;
  Span: TOtelSpan;
begin
  ResetCapture;
  Cfg := TConfig.Create;
  try
    InitOtelFromConfig(Cfg);
    SetExportTransport(@CaptureExport);
    AssertTrue(not OtelEnabled, 'OtelEnabled is False on default config');
    Span := StartSpan('whatever', oskInternal, '');
    AssertTrue(Span = nil, 'StartSpan returns nil when disabled');
    FinishSpan(Span);  { must tolerate nil }
    AssertTrue(GCaptureCount = 0, 'no exports happened');
  finally
    Cfg.Free;
  end;
end;

procedure TestSingleSpanShape;
{ One root span emits the canonical OTLP/HTTP+JSON envelope:
  resourceSpans -> resource.attributes -> scopeSpans -> spans.
  Resource attrs must include service.name (matches openclaw's
  diagnostics.otel.serviceName setting). }
var
  Cfg: TConfig;
  Span: TOtelSpan;
begin
  ResetCapture;
  Cfg := MakeEnabledConfig;
  try
    InitOtelFromConfig(Cfg);
    SetExportTransport(@CaptureExport);
    Span := StartSpan('test-root', oskInternal, '');
    AssertTrue(Span <> nil, 'span created when enabled');
    SetAttrStr(Span, 'foo', 'bar');
    SetAttrInt(Span, 'count', 42);
    SetAttrBool(Span, 'is_test', True);
    SetStatus(Span, oscOk, '');
    FinishSpan(Span);

    AssertTrue(GCaptureCount = 1, 'exactly one export fired on root finish');
    AssertContains(GCapturedEndpoint, '/v1/traces',
                   'endpoint path includes /v1/traces');
    AssertContains(GCapturedBody, '"resourceSpans"', 'envelope is resourceSpans');
    AssertContains(GCapturedBody, '"service.name"', 'service.name in resource attrs');
    AssertContains(GCapturedBody, '"otel-test"',     'service name value present');
    AssertContains(GCapturedBody, '"telemetry.sdk.name"',
                   'telemetry.sdk.name in resource attrs');
    AssertContains(GCapturedBody, '"scopeSpans"',    'scopeSpans wrapper');
    AssertContains(GCapturedBody, '"name":"test-root"', 'span name preserved');
    AssertContains(GCapturedBody, '"foo"', 'string attr key');
    AssertContains(GCapturedBody, '"bar"', 'string attr value');
    AssertContains(GCapturedBody, '"count"',         'int attr key');
    AssertContains(GCapturedBody, '"intValue":"42"', 'int attr value as OTLP intValue');
    AssertContains(GCapturedBody, '"is_test"',       'bool attr key');
    AssertContains(GCapturedBody, '"boolValue":true','bool attr value');
    AssertContains(GCapturedBody, '"status":{"code":1', 'status OK');
  finally
    Cfg.Free;
  end;
end;

function ExtractSubstring(const Body, StartTag, EndTag: string): string;
var
  i, j: Integer;
begin
  Result := '';
  i := Pos(StartTag, Body);
  if i <= 0 then Exit;
  Inc(i, Length(StartTag));
  j := Pos(EndTag, Copy(Body, i, Length(Body)));
  if j <= 0 then Exit;
  Result := Copy(Body, i, j - 1);
end;

procedure TestParentChildHierarchy;
{ Nested StartSpan / FinishSpan produces parent-child structure: the
  child carries the parent's traceId AND its spanId as parentSpanId.
  This is the openclaw.agent.turn -> chat -> execute_tool shape that
  Langfuse / Tempo dashboards depend on. }
var
  Cfg: TConfig;
  Parent, Child: TOtelSpan;
  ParentTraceId, ParentSpanId: string;
begin
  ResetCapture;
  Cfg := MakeEnabledConfig;
  try
    InitOtelFromConfig(Cfg);
    SetExportTransport(@CaptureExport);

    Parent := StartSpan('parent-span', oskInternal, '');
    AssertTrue(Parent <> nil, 'parent created');
    ParentTraceId := Parent.TraceId;
    ParentSpanId  := Parent.SpanId;
    AssertEqInt(Length(ParentTraceId), 32, 'trace id is 32 hex chars (16 bytes)');
    AssertEqInt(Length(ParentSpanId),  16, 'span id is 16 hex chars (8 bytes)');

    Child := StartSpan('child-span', oskClient, '');
    AssertTrue(Child <> nil, 'child created');
    AssertEq(Child.TraceId, ParentTraceId,
             'child inherits parent traceId (same trace)');
    AssertEq(Child.ParentSpanId, ParentSpanId,
             'child.parentSpanId points at parent.spanId');

    { Child finishes first; no export yet because parent still open. }
    FinishSpan(Child);
    AssertTrue(GCaptureCount = 0, 'no export until root finishes');

    FinishSpan(Parent);
    AssertTrue(GCaptureCount = 1, 'export fires when root finishes');

    { Both spans in the same envelope, parent referenced by child. }
    AssertContains(GCapturedBody, ParentTraceId,
                   'trace id in body');
    AssertContains(GCapturedBody, '"parentSpanId":"' + ParentSpanId + '"',
                   'child.parentSpanId points at parent');
    AssertContains(GCapturedBody, '"name":"parent-span"', 'parent name');
    AssertContains(GCapturedBody, '"name":"child-span"',  'child name');
    AssertContains(GCapturedBody, '"kind":3',
                   'client kind = 3 (OTLP SPAN_KIND_CLIENT)');
  finally
    Cfg.Free;
  end;
end;

procedure TestTraceparentInbound;
{ The gateway path passes an incoming traceparent header to
  StartSpan. The parsed trace id and parent span id must drive the
  new span's TraceId / ParentSpanId so the upstream caller's trace
  stays connected. }
const
  IncomingTP =
    '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01';
  ExpectedTrace = '0af7651916cd43dd8448eb211c80319c';
  ExpectedParent = 'b7ad6b7169203331';
var
  Cfg: TConfig;
  Span: TOtelSpan;
begin
  ResetCapture;
  Cfg := MakeEnabledConfig;
  try
    InitOtelFromConfig(Cfg);
    SetExportTransport(@CaptureExport);
    Span := StartSpan('HTTP POST /v1/chat', oskServer, IncomingTP);
    AssertTrue(Span <> nil, 'span created from inbound traceparent');
    AssertEq(Span.TraceId, ExpectedTrace,
             'trace id from traceparent header');
    AssertEq(Span.ParentSpanId, ExpectedParent,
             'parent span id from traceparent header');
    FinishSpan(Span);
    AssertContains(GCapturedBody, ExpectedTrace,
                   'inbound trace id in exported body');
    AssertContains(GCapturedBody, '"parentSpanId":"' + ExpectedParent + '"',
                   'inbound parent span id in exported body');
  finally
    Cfg.Free;
  end;
end;

procedure TestTraceparentMalformedTolerated;
{ A garbage traceparent header must not break the request: we silently
  start a new trace instead. Real-world gateways see broken
  propagation all the time -- crashing the request handler over a bad
  header would be the wrong tradeoff. }
var
  Cfg: TConfig;
  Span: TOtelSpan;
begin
  ResetCapture;
  Cfg := MakeEnabledConfig;
  try
    InitOtelFromConfig(Cfg);
    SetExportTransport(@CaptureExport);
    Span := StartSpan('HTTP POST /v1/chat', oskServer,
                      'this-is-not-a-traceparent');
    AssertTrue(Span <> nil, 'span still created with bad traceparent');
    AssertTrue(Span.TraceId <> '', 'fresh trace id generated');
    AssertTrue(Span.ParentSpanId = '',
               'no parent set (treated as root)');
    AssertEqInt(Length(Span.TraceId), 32, 'fresh trace id is 32 hex');
    FinishSpan(Span);
  finally
    Cfg.Free;
  end;
end;

procedure TestCurrentTraceparentForOutbound;
(* While a span is current, CurrentTraceparent returns the W3C header
   string an outbound HTTP client should send. Format:
   00-<trace>-<span>-01. Empty when no current span. *)
var
  Cfg: TConfig;
  Span: TOtelSpan;
  TP: string;
begin
  ResetCapture;
  Cfg := MakeEnabledConfig;
  try
    InitOtelFromConfig(Cfg);
    SetExportTransport(@CaptureExport);
    AssertEq(CurrentTraceparent, '',
             'no current span = empty traceparent');
    Span := StartSpan('parent', oskInternal, '');
    TP := CurrentTraceparent;
    AssertTrue(Pos('00-', TP) = 1, 'traceparent starts with version 00-');
    AssertTrue(Pos(Span.TraceId, TP) > 0,
               'traceparent contains current trace id');
    AssertTrue(Pos(Span.SpanId, TP) > 0,
               'traceparent contains current span id');
    AssertTrue(Copy(TP, Length(TP) - 2, 3) = '-01',
               'traceparent ends with -01 (sampled flag)');
    FinishSpan(Span);
    AssertEq(CurrentTraceparent, '',
             'after finish, no current = empty traceparent');
  finally
    Cfg.Free;
  end;
end;

procedure TestEnvVarOverridesEndpoint;
(* OTEL_EXPORTER_OTLP_ENDPOINT env var must override the config
   endpoint AND flip enabled=true on its own (standard OTel SDK
   contract -- ops sets the var, deploy reads it).

   This test runs only when invoked with --env-mode AND
   OTEL_EXPORTER_OTLP_ENDPOINT is set. FPC's RTL
   GetEnvironmentVariable snapshots envp at process start, so a
   mid-process mutation via libc setenv() isn't visible to the
   PasClaw.Otel reader. The Makefile invokes this binary twice:
   first plain (default tests, env var unset), then with
   OTEL_EXPORTER_OTLP_ENDPOINT=http://env-host:4318 and --env-mode
   to exercise the env-var override path under the env we ACTUALLY
   inherited at process start. *)
var
  Cfg: TConfig;
  Span: TOtelSpan;
begin
  ResetCapture;
  Cfg := TConfig.Create;
  try
    { Note: Diagnostics.Otel.Enabled stays default-False here -- so any
      "enabled" we observe MUST have come from the env var. }
    AssertTrue(not Cfg.Diagnostics.Otel.Enabled,
               'config has otel.enabled=false as a control');
    AssertContains(GetEnvironmentVariable('OTEL_EXPORTER_OTLP_ENDPOINT'),
                   'env-host',
                   'precondition: OTEL_EXPORTER_OTLP_ENDPOINT inherited from Makefile');
    InitOtelFromConfig(Cfg);
    SetExportTransport(@CaptureExport);
    AssertTrue(OtelEnabled,
               'env var alone is enough to enable OTel (openclaw parity)');
    Span := StartSpan('env-test', oskInternal, '');
    AssertTrue(Span <> nil, 'env-var-enabled OTel emits spans');
    FinishSpan(Span);
    AssertContains(GCapturedEndpoint, 'env-host',
                   'env var endpoint reached the exporter');
    AssertContains(GCapturedEndpoint, '/v1/traces',
                   '/v1/traces path appended when env URL has no path');
  finally
    Cfg.Free;
  end;
end;

procedure TestConfigRoundTripPreservesOtelBlock;
(* PR #242 P2 regression: TConfig.ToJSON had no diagnostics emission
   block, so any command that called SaveConfig after LoadConfig
   (auth, model, mcp, skill updates) rewrote config.json through
   ToJSON and silently dropped the whole diagnostics tree. The user
   re-ran the agent expecting traces and got nothing. Pin every
   otel field through a ToJSON / FromJSON round-trip so a future
   refactor that touches the emitter can't regress this silently
   again. *)
var
  Src, Dst: TConfig;
  Roundtripped: string;
begin
  Src := TConfig.Create;
  Dst := TConfig.Create;
  try
    { Mutate every field away from defaults so a missing emission
      shows up as a value drop, not a "happens to match default". }
    Src.Diagnostics.Otel.Enabled     := True;
    Src.Diagnostics.Otel.Endpoint    := 'https://collector.example.com:4318';
    Src.Diagnostics.Otel.Protocol    := 'http/json';
    Src.Diagnostics.Otel.ServiceName := 'pasclaw-prod';
    Src.Diagnostics.Otel.SampleRate  := 0.25;
    Src.Diagnostics.Otel.Traces      := True;
    Src.Diagnostics.Otel.Metrics     := True;
    Src.Diagnostics.Otel.Logs        := True;
    SetLength(Src.Diagnostics.Otel.Headers, 2);
    Src.Diagnostics.Otel.Headers[0].Name  := 'Authorization';
    Src.Diagnostics.Otel.Headers[0].Value := 'Bearer test-token';
    Src.Diagnostics.Otel.Headers[1].Name  := 'x-honeycomb-team';
    Src.Diagnostics.Otel.Headers[1].Value := 'hc-key-123';

    Roundtripped := Src.ToJSON;

    { The emission must produce a diagnostics.otel block at all --
      catch the regression directly so a future change that breaks
      emitting any block shows up as an actionable failure, not just
      "all the field assertions trivially pass because default ==
      default". }
    AssertContains(Roundtripped, '"diagnostics"',
                   'ToJSON emits the diagnostics block');
    AssertContains(Roundtripped, '"otel"',
                   'ToJSON emits the diagnostics.otel block');

    Dst.FromJSON(Roundtripped);
    AssertTrue(Dst.Diagnostics.Otel.Enabled,
               'enabled preserved');
    AssertEq(Dst.Diagnostics.Otel.Endpoint,
             'https://collector.example.com:4318',
             'endpoint preserved');
    AssertEq(Dst.Diagnostics.Otel.Protocol,    'http/json',
             'protocol preserved');
    AssertEq(Dst.Diagnostics.Otel.ServiceName, 'pasclaw-prod',
             'serviceName preserved');
    AssertTrue(Abs(Dst.Diagnostics.Otel.SampleRate - 0.25) < 0.0001,
               'sampleRate preserved');
    AssertTrue(Dst.Diagnostics.Otel.Traces,  'traces preserved');
    AssertTrue(Dst.Diagnostics.Otel.Metrics, 'metrics preserved');
    AssertTrue(Dst.Diagnostics.Otel.Logs,    'logs preserved');
    AssertEqInt(Length(Dst.Diagnostics.Otel.Headers), 2,
                'two headers preserved');
    { Header order is not guaranteed across the JSON object dance;
      check each by name. }
    AssertTrue((Dst.Diagnostics.Otel.Headers[0].Name = 'Authorization') or
               (Dst.Diagnostics.Otel.Headers[1].Name = 'Authorization'),
               'Authorization header survived');
    AssertTrue((Dst.Diagnostics.Otel.Headers[0].Name = 'x-honeycomb-team') or
               (Dst.Diagnostics.Otel.Headers[1].Name = 'x-honeycomb-team'),
               'x-honeycomb-team header survived');
  finally
    Src.Free;
    Dst.Free;
  end;
end;

procedure TestSampleRateZeroDropsTrace;
{ sampleRate=0 means "trace nothing". StartSpan must return nil for
  ROOT spans, so the rest of the call graph stays in no-op mode and
  nothing exports. Real high-volume gateways would set this low
  (0.01) to keep collector cost bounded. }
var
  Cfg: TConfig;
  Span: TOtelSpan;
begin
  ResetCapture;
  Cfg := MakeEnabledConfig;
  Cfg.Diagnostics.Otel.SampleRate := 0.0;
  try
    InitOtelFromConfig(Cfg);
    SetExportTransport(@CaptureExport);
    Span := StartSpan('would-be-root', oskInternal, '');
    AssertTrue(Span = nil,
               'sampleRate=0 drops root spans (no allocation)');
    FinishSpan(Span);
    AssertTrue(GCaptureCount = 0, 'no export, no buffer');
  finally
    Cfg.Free;
  end;
end;

procedure TestErrorStatusEncoded;
{ SetStatus(oscError) writes status.code=2 and the optional message
  into the span. Backends use this for "show errors in red" /
  alerting filters. }
var
  Cfg: TConfig;
  Span: TOtelSpan;
begin
  ResetCapture;
  Cfg := MakeEnabledConfig;
  try
    InitOtelFromConfig(Cfg);
    SetExportTransport(@CaptureExport);
    Span := StartSpan('failing', oskClient, '');
    SetStatus(Span, oscError, 'simulated provider 503');
    FinishSpan(Span);
    AssertContains(GCapturedBody, '"status":{"code":2',
                   'error status code = 2');
    AssertContains(GCapturedBody, 'simulated provider 503',
                   'error message preserved');
  finally
    Cfg.Free;
  end;
end;

procedure TestNilTolerance;
{ All helpers must tolerate nil so call sites stay clean -- you can
  write the instrumentation once and let the StartSpan-returns-nil
  path silently no-op the whole block when OTel is off. }
var
  Cfg: TConfig;
begin
  Cfg := TConfig.Create;
  try
    InitOtelFromConfig(Cfg);  { stays disabled }
    SetExportTransport(@CaptureExport);
    SetAttrStr(nil, 'k', 'v');
    SetAttrInt(nil, 'n', 7);
    SetAttrBool(nil, 'b', True);
    SetStatus(nil, oscError, 'wat');
    FinishSpan(nil);
    AssertTrue(True, 'no crash on nil helpers');
  finally
    Cfg.Free;
  end;
end;

procedure TestJsonEscapeOnAttrs;
{ Attribute values that include JSON-control bytes must be escaped
  so the OTLP payload stays valid JSON. Tool names like "fs_grep"
  are fine; agent error messages that include " or backslash are
  the real risk. }
var
  Cfg: TConfig;
  Span: TOtelSpan;
begin
  ResetCapture;
  Cfg := MakeEnabledConfig;
  try
    InitOtelFromConfig(Cfg);
    SetExportTransport(@CaptureExport);
    Span := StartSpan('escape-test', oskInternal, '');
    SetAttrStr(Span, 'error.message',
               'unexpected " character and ' + #10 + 'newline + \backslash');
    SetStatus(Span, oscError, 'bad "quote" and \slash');
    FinishSpan(Span);
    AssertContains(GCapturedBody, '\" character',
                   'embedded quote got escaped');
    AssertContains(GCapturedBody, '\n',
                   'newline got escaped');
    AssertContains(GCapturedBody, '\\backslash',
                   'backslash got escaped (doubled)');
    AssertContains(GCapturedBody, '\"quote\"',
                   'status message quotes escaped');
  finally
    Cfg.Free;
  end;
end;

begin
  if (ParamCount >= 1) and (ParamStr(1) = '--env-mode') then
  begin
    { Second pass: invoked from the Makefile with
      OTEL_EXPORTER_OTLP_ENDPOINT set. Only run the env-var override
      test (the rest already ran in the first pass with a clean env). }
    TestEnvVarOverridesEndpoint;
    WriteLn('  ok: OTEL_EXPORTER_OTLP_ENDPOINT enables OTel and overrides endpoint');
    WriteLn('PASS');
    Exit;
  end;

  TestDisabledByDefault;
  WriteLn('  ok: disabled-by-default emits nothing');
  TestSingleSpanShape;
  WriteLn('  ok: single root span emits canonical OTLP/HTTP+JSON envelope');
  TestParentChildHierarchy;
  WriteLn('  ok: parent/child spans share trace id, child carries parentSpanId');
  TestTraceparentInbound;
  WriteLn('  ok: W3C traceparent header parsed for cross-service propagation');
  TestTraceparentMalformedTolerated;
  WriteLn('  ok: malformed traceparent does not break span creation');
  TestCurrentTraceparentForOutbound;
  WriteLn('  ok: CurrentTraceparent formats W3C header for outbound HTTP');
  TestConfigRoundTripPreservesOtelBlock;
  WriteLn('  ok: TConfig.ToJSON / FromJSON round-trip preserves diagnostics.otel (PR #242 P2)');
  TestSampleRateZeroDropsTrace;
  WriteLn('  ok: sampleRate=0.0 drops root spans (no buffer, no export)');
  TestErrorStatusEncoded;
  WriteLn('  ok: SetStatus(oscError) writes code=2 + message into span');
  TestNilTolerance;
  WriteLn('  ok: all helpers tolerate nil so disabled call sites stay clean');
  TestJsonEscapeOnAttrs;
  WriteLn('  ok: JSON-control bytes in attribute values are escaped');
  WriteLn('PASS');
end.
