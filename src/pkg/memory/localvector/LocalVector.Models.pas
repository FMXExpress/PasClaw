{
  Vendored from FMXExpress/localvector (MIT licensed; LICENSE preserved
  alongside this file). Upstream commit: 0f00eece553da47e83169ddc8d72965c0dc40bcc.
  https://github.com/FMXExpress/localvector

  Modifications kept to a minimum — PasClaw uses these units verbatim
  as the in-tree implementation of the hybrid FTS5+vector memory backend
  (PasClaw.Memory.Vector). Diff against upstream for change tracking.
}

unit LocalVector.Models;

{ Registry of the built-in embedding models. Each entry knows where to fetch the
  ONNX model + vocab, how to pool the token embeddings, and whether the model
  takes token_type_ids. Adding a new BERT/WordPiece model is just another row. }

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils;
{$ELSE}
  System.SysUtils;
{$ENDIF}

type
  TPooling = (poMean, poCLS, poLast);

  TModelSpec = record
    Key: string;               // canonical selector, e.g. 'minilm'
    DisplayName: string;       // human label
    SubDir: string;            // models/<SubDir>/
    BaseURL: string;           // Hugging Face resolve base, trailing '/'
    ModelRelURL: string;       // remote model path, e.g. 'model.onnx' or 'onnx/model.onnx'
    VocabRelURL: string;       // remote vocab path, e.g. 'vocab.txt'
    Pooling: TPooling;
    NeedsTokenTypeIds: Boolean;
    DoLowerCase: Boolean;
    Dim: Integer;
    SizeDesc: string;
  end;

{ Resolves a selector (including a few aliases) to a model spec. }
function FindModelSpec(const AKey: string; out ASpec: TModelSpec): Boolean;

{ Comma-separated list of the canonical keys, for help text/errors. }
function ModelKeys: string;

function ParsePooling(const AStr: string; out APooling: TPooling): Boolean;
function PoolingName(APooling: TPooling): string;

const
  DEFAULT_MODEL = 'minilm';

implementation

function MakeSpec(const AKey, ADisplay, ASubDir, ABaseURL, AModelRel, AVocabRel: string;
  APooling: TPooling; ANeedsTT, ALower: Boolean; ADim: Integer; const ASize: string): TModelSpec;
begin
  Result.Key := AKey;
  Result.DisplayName := ADisplay;
  Result.SubDir := ASubDir;
  Result.BaseURL := ABaseURL;
  Result.ModelRelURL := AModelRel;
  Result.VocabRelURL := AVocabRel;
  Result.Pooling := APooling;
  Result.NeedsTokenTypeIds := ANeedsTT;
  Result.DoLowerCase := ALower;
  Result.Dim := ADim;
  Result.SizeDesc := ASize;
end;

function FindModelSpec(const AKey: string; out ASpec: TModelSpec): Boolean;
var
  K: string;
begin
  Result := True;
  K := LowerCase(Trim(AKey));

  if (K = 'minilm') or (K = 'all-minilm') or (K = 'all-minilm-l6-v2') then
    ASpec := MakeSpec('minilm', 'all-MiniLM-L6-v2', 'all-MiniLM-L6-v2',
      'https://huggingface.co/onnx-models/all-MiniLM-L6-v2-onnx/resolve/main/',
      'model.onnx', 'vocab.txt', poMean, True, True, 384, '~90 MB')
  else if (K = 'bge') or (K = 'bge-small') or (K = 'bge-small-en') or (K = 'bge-small-en-v1.5') then
    ASpec := MakeSpec('bge', 'bge-small-en-v1.5', 'bge-small-en-v1.5',
      'https://huggingface.co/Xenova/bge-small-en-v1.5/resolve/main/',
      'onnx/model.onnx', 'vocab.txt', poCLS, True, True, 384, '~133 MB')
  else if (K = 'mxbai') or (K = 'mxbai-large') or (K = 'mxbai-embed-large') or (K = 'mixedbread') then
    // Quantized (int8) export. Same BERT/WordPiece + CLS pooling as bge, 1024-d.
    ASpec := MakeSpec('mxbai', 'mxbai-embed-large-v1 (int8)', 'mxbai-embed-large-v1',
      'https://huggingface.co/mixedbread-ai/mxbai-embed-large-v1/resolve/main/',
      'onnx/model_quantized.onnx', 'vocab.txt', poCLS, True, True, 1024, '~337 MB')
  else
    Result := False;
end;

function ModelKeys: string;
begin
  Result := 'minilm, bge, mxbai';
end;

function ParsePooling(const AStr: string; out APooling: TPooling): Boolean;
var
  S: string;
begin
  Result := True;
  S := LowerCase(Trim(AStr));
  if S = 'mean' then APooling := poMean
  else if (S = 'cls') or (S = 'first') then APooling := poCLS
  else if S = 'last' then APooling := poLast
  else Result := False;
end;

function PoolingName(APooling: TPooling): string;
begin
  case APooling of
    poMean: Result := 'mean';
    poCLS:  Result := 'cls';
    poLast: Result := 'last';
  else
    Result := '?';
  end;
end;

end.
