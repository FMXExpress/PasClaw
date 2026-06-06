{
  Vendored from FMXExpress/localvector (MIT licensed; LICENSE preserved
  alongside this file). Upstream commit: 0f00eece553da47e83169ddc8d72965c0dc40bcc.
  https://github.com/FMXExpress/localvector

  Modifications kept to a minimum — PasClaw uses these units verbatim
  as the in-tree implementation of the hybrid FTS5+vector memory backend
  (PasClaw.Memory.Vector). Diff against upstream for change tracking.
}

unit LocalVector.Embedder;

{ Runs a sentence-transformer style ONNX model and turns the token-level output
  into a single normalized sentence embedding.

  Inputs fed to the model (all int64, shape [1, seq_len]):
    input_ids, attention_mask, and (optionally) token_type_ids
  Output read back:
    last_hidden_state [1, seq_len, hidden]  -> pooled over tokens via
    mean / CLS (token 0) / last-token pooling.
  (If a model instead emits an already-pooled [1, hidden] vector, that is used
  directly.) The pooled vector is L2-normalized by default. }

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, Math,
{$ELSE}
  System.SysUtils, System.Math,
{$ENDIF}
  onnxruntime_pas_api, onnxruntime,
  LocalVector.Runtime, LocalVector.Models;

type
  EEmbedderError = class(Exception);

  TEmbedder = class
  private
    FSession: TORTSession;
    FModelPath: string;
    FLoaded: Boolean;
  public
    constructor Create(const AModelPath: string);
    destructor Destroy; override;
    procedure Load(AVerbose: Boolean = False);
    { Runs the model and pools the token embeddings into one vector.
      APooling selects mean / CLS / last-token pooling; ANeedsTokenTypeIds
      controls whether a token_type_ids input is fed (BERT-style models need it,
      some models do not). }
    function Embed(const ATokenIds: TArray<Int64>; APooling: TPooling;
      ANeedsTokenTypeIds: Boolean; ANormalize: Boolean = True;
      AVerbose: Boolean = False): TArray<Single>;
    property ModelPath: string read FModelPath;
  end;

implementation

constructor TEmbedder.Create(const AModelPath: string);
begin
  inherited Create;
  FModelPath := AModelPath;
  FLoaded := False;
end;

destructor TEmbedder.Destroy;
begin
  // TORTSession is a managed record; it releases itself.
  inherited;
end;

procedure TEmbedder.Load(AVerbose: Boolean);
var
  Info: TOrtRuntimeInfo;
  DllStr, VerStr: string;
begin
  if FLoaded then
    Exit;
  if not FileExists(FModelPath) then
    raise EEmbedderError.CreateFmt('Model file not found: %s', [FModelPath]);

  if AVerbose then
  begin
    WriteLn(ErrOutput, '[localvector] loading model: ', FModelPath);
    PrintOrtRuntimeInfo;
  end;

  // ONNX Runtime 1.22+ no longer auto-selects the CPU execution provider; a
  // session created with no EP fails ("No execution providers were provided or
  // selected"). Make sure the default session options object exists (under FPC
  // the wrapper's managed initializer may leave it nil) and register the CPU EP
  // explicitly. This is harmless on older runtimes that added CPU implicitly.
  if not Assigned(DefaultSessionOptions.p_) then
    ThrowOnError(GetApi().CreateSessionOptions(PPOrtSessionOptions(@DefaultSessionOptions.p_)));
  ThrowOnError(OrtSessionOptionsAppendExecutionProvider_CPU(DefaultSessionOptions.p_, 1));

  try
    FSession := TORTSession.Create(FModelPath);
  except
    on E: Exception do
    begin
      // The classic "old runtime, new model" failure. Make it actionable by
      // naming the onnxruntime.dll that was actually loaded.
      if Pos('IR version', E.Message) > 0 then
      begin
        Info := GetOrtRuntimeInfo;
        if Info.DllPath <> '' then DllStr := Info.DllPath else DllStr := '(unknown path)';
        if Info.Version <> '' then VerStr := Info.Version else VerStr := '(unknown)';
        raise EEmbedderError.Create(
          E.Message + sLineBreak +
          'The loaded ONNX Runtime is too old for this model.' + sLineBreak +
          '  loaded onnxruntime: ' + DllStr + '  version ' + VerStr + sLineBreak +
          '  This model needs IR version 10 (ONNX Runtime >= ~1.17).' + sLineBreak +
          '  Fix: put a current onnxruntime.dll next to the .exe (the build output' + sLineBreak +
          '  folder), then re-run with --diag to confirm the version that loads.');
      end;
      raise EEmbedderError.Create(E.Message);
    end;
  end;

  if AVerbose then
    WriteLn(ErrOutput, '[localvector] model inputs=', FSession.GetInputCount,
                       ' outputs=', FSession.GetOutputCount);
  FLoaded := True;
end;

function TEmbedder.Embed(const ATokenIds: TArray<Int64>; APooling: TPooling;
  ANeedsTokenTypeIds: Boolean; ANormalize: Boolean; AVerbose: Boolean): TArray<Single>;
var
  N, I, T, Dim, SeqLen: Integer;
  PrePooled: Boolean;
  InputIds, AttnMask, TypeIds: TORTTensor<Int64>;
  OutVal: TORTValue;
  OutTensor: TORTTensor<Single>;
  Inputs, Outputs: TORTNameValueList;
  RealShape: TArray<Int64>;
  Acc, Norm: Double;
begin
  if not FLoaded then
    Load(AVerbose);

  N := Length(ATokenIds);
  if N = 0 then
    raise EEmbedderError.Create('No tokens to embed.');

  // TORTTensor.ToValue reverses the declared shape, so declare [seq_len, 1] to
  // hand ONNX a real input tensor of shape [1, seq_len]. The flat data layout
  // is identical either way.
  InputIds := TORTTensor<Int64>.Create([N, 1]);
  AttnMask := TORTTensor<Int64>.Create([N, 1]);
  for I := 0 to N - 1 do
  begin
    InputIds.Index1[I] := ATokenIds[I];
    AttnMask.Index1[I] := 1;
  end;

  Inputs.Add('input_ids',      InputIds.ToValue);
  Inputs.Add('attention_mask', AttnMask.ToValue);
  if ANeedsTokenTypeIds then
  begin
    TypeIds := TORTTensor<Int64>.Create([N, 1]);
    for I := 0 to N - 1 do
      TypeIds.Index1[I] := 0;
    Inputs.Add('token_type_ids', TypeIds.ToValue);
  end;

  if AVerbose then
    WriteLn(ErrOutput, '[localvector] running inference (seq_len=', N,
                       ', pooling=', PoolingName(APooling), ') ...');

  Outputs := FSession.Run(Inputs);
  if Outputs.Count = 0 then
    raise EEmbedderError.Create('Model returned no outputs.');

  OutVal := Outputs.Values[0];

  // Read the *true* ONNX shape (GetShape is not reversed, unlike TORTTensor.Shape).
  RealShape := OutVal.GetTensorTypeAndShapeInfo.GetShape;
  OutTensor := TORTTensor<Single>.FromValue(OutVal);

  // Resolve sequence length / hidden size from the output rank:
  //   [1, hidden]            -> already pooled
  //   [1, seq_len, hidden]   -> token embeddings
  //   [seq_len, hidden]      -> token embeddings (no batch dim)
  PrePooled := False;
  SeqLen := 0;
  case Length(RealShape) of
    2:
      if RealShape[0] = 1 then
      begin
        PrePooled := True;
        Dim := RealShape[1];
      end
      else
      begin
        SeqLen := RealShape[0];
        Dim := RealShape[1];
      end;
    3:
      begin
        SeqLen := RealShape[1];
        Dim := RealShape[2];
      end;
  else
    raise EEmbedderError.CreateFmt('Unexpected output rank: %d', [Length(RealShape)]);
  end;

  SetLength(Result, Dim);

  // OutTensor.Index1 walks the raw, row-major ONNX buffer; token t / dim d lives
  // at Index1[t*Dim + d] (batch 0).
  if PrePooled then
  begin
    for I := 0 to Dim - 1 do
      Result[I] := OutTensor.Index1[I];
  end
  else
    case APooling of
      poMean:
        begin
          for I := 0 to Dim - 1 do Result[I] := 0;
          for T := 0 to SeqLen - 1 do
            for I := 0 to Dim - 1 do
              Result[I] := Result[I] + OutTensor.Index1[T * Dim + I];
          for I := 0 to Dim - 1 do Result[I] := Result[I] / SeqLen;
        end;
      poCLS:
        for I := 0 to Dim - 1 do
          Result[I] := OutTensor.Index1[I];                 // token 0 ([CLS])
      poLast:
        for I := 0 to Dim - 1 do
          Result[I] := OutTensor.Index1[(SeqLen - 1) * Dim + I];
    end;

  if ANormalize then
  begin
    Acc := 0;
    for I := 0 to High(Result) do
      Acc := Acc + Result[I] * Result[I];
    Norm := Sqrt(Acc);
    if Norm > 1e-12 then
      for I := 0 to High(Result) do
        Result[I] := Result[I] / Norm;
  end;

  if AVerbose then
    WriteLn(ErrOutput, '[localvector] embedding dim = ', Length(Result));
end;

end.
