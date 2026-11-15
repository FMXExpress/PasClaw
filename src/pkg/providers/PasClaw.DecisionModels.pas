(*
  PasClaw.DecisionModels - typed questions in, calibrated probabilities out.

  A decision model reads some input the way a language model does and
  answers the way a classifier does: no text, just a probability for each
  possible answer to each question. Three question kinds, shared by every
  vendor that serves one:

    noul    yes / no             -> P(yes)
    choice  one option of 2..255 -> a probability per option
    score   an ordered scale     -> a probability per level, and the
                                    probability-weighted level

  Two wire formats are spoken here:

    google     POST <base>/v1beta/decisions   {model, input, questions}
               Gemini Decision 1 (gemini-decision-1), key in x-goog-api-key.
               Verified against the live API.
    systemone  POST <base>/v1/systemone       {model, state, questions}
               TypeSafe's Jev and OpenJev, Bearer token. Built from
               OpenJev's README; exercised against a fake server only.

  Answers are normalised into one record whatever the vendor. Each
  vendor also reports a `confidence`, and they do not mean the same
  thing (Google: the probability the top answer is right; OpenJev: one
  minus the normalised entropy). It is therefore NOT used: `Top` is the
  probability of the most likely answer, computed here from the
  probabilities, so it means the same thing on every backend. Whether a
  given Top is good enough is a question for the benchmark of a given
  decision point, not a constant (see PasClaw.DecisionModels.Gate).
*)
unit PasClaw.DecisionModels;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

type
  TDecisionKind = (dqNoul, dqChoice, dqScore);

  TDecisionOption = record
    Id, Description: string;
  end;

  TDecisionQuestion = record
    Key: string;                       { [A-Za-z0-9_-], up to 64 chars }
    Kind: TDecisionKind;
    Instructions: string;
    TrueDesc, FalseDesc: string;       { noul, optional }
    Options: array of TDecisionOption; { choice }
    Levels: array of string;           { score, lowest first }
  end;
  TDecisionQuestions = array of TDecisionQuestion;

  TDecisionAnswer = record
    Key: string;
    Kind: TDecisionKind;
    { noul: P(yes). choice: the chosen option's probability. score: the
      probability-weighted level, 0 .. Length(Levels)-1. }
    Value: Double;
    { choice: the chosen option's Id. Empty otherwise. }
    Choice: string;
    { noul: [P(no), P(yes)]. choice: one per option, in the question's
      order. score: one per level, lowest first. }
    Probs: array of Double;
    { The probability of the most likely answer. }
    Top: Double;
  end;
  TDecisionAnswers = array of TDecisionAnswer;

  TDecisionBackendKind = (dbGoogle, dbSystemOne);

  TDecisionBackend = record
    Name: string;
    Kind: TDecisionBackendKind;
    APIBase, APIKey, Model: string;
    TimeoutSec: Integer;
  end;

  TDecisionResult = record
    Ok: Boolean;
    Error: string;
    StatusCode: Integer;
    Answers: TDecisionAnswers;   { in the order the questions were asked }
    InputTokens: Int64;
    ElapsedMs: Int64;
  end;

function DecisionBackendKindName(K: TDecisionBackendKind): string;
function TryParseDecisionBackendKind(const S: string; out K: TDecisionBackendKind): Boolean;
function DefaultDecisionAPIBase(K: TDecisionBackendKind): string;
function DefaultDecisionModel(K: TDecisionBackendKind): string;

{ The request URL and body for B. Pure: no network. }
function DecisionURL(const B: TDecisionBackend): string;
function BuildDecisionBody(const B: TDecisionBackend; const Input: string;
  const Qs: array of TDecisionQuestion): string;

{ Parse a 2xx response body into answers, one per question in Qs order.
  False (with Err) when an answer is missing or of the wrong kind. }
function ParseDecisionResponse(const Body: string;
  const Qs: array of TDecisionQuestion; out Answers: TDecisionAnswers;
  out InputTokens: Int64; out Err: string): Boolean;

{ Ask B. Never raises: transport and API errors come back in Error. }
function Decide(const B: TDecisionBackend; const Input: string;
  const Qs: array of TDecisionQuestion): TDecisionResult;

{ Builders for the three kinds. }
function NoulQuestion(const Key, Instructions: string): TDecisionQuestion;
function ChoiceQuestion(const Key, Instructions: string;
  const Ids, Descriptions: array of string): TDecisionQuestion;
function ScoreQuestion(const Key, Instructions: string;
  const Levels: array of string): TDecisionQuestion;

implementation

uses
  {$IFDEF FPC}DateUtils,{$ELSE}System.DateUtils,{$ENDIF}
  PasClaw.JSON,
  PasClaw.Providers.HTTP;

function DecisionBackendKindName(K: TDecisionBackendKind): string;
begin
  case K of
    dbGoogle:    Result := 'google';
    dbSystemOne: Result := 'systemone';
  else
    Result := '?';
  end;
end;

function TryParseDecisionBackendKind(const S: string; out K: TDecisionBackendKind): Boolean;
var
  L: string;
begin
  L := LowerCase(Trim(S));
  Result := True;
  if (L = 'google') or (L = 'gemini') then K := dbGoogle
  else if (L = 'systemone') or (L = 'jev') or (L = 'openjev') then K := dbSystemOne
  else Result := False;
end;

function DefaultDecisionAPIBase(K: TDecisionBackendKind): string;
begin
  case K of
    dbGoogle:    Result := 'https://generativelanguage.googleapis.com';
    dbSystemOne: Result := 'https://api.typesafe.ai';
  else
    Result := '';
  end;
end;

function DefaultDecisionModel(K: TDecisionBackendKind): string;
begin
  case K of
    dbGoogle:    Result := 'gemini-decision-1';
    dbSystemOne: Result := 'jev-latest';
  else
    Result := '';
  end;
end;

function TrimBase(const S: string): string;
begin
  Result := Trim(S);
  while (Result <> '') and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
end;

function DecisionURL(const B: TDecisionBackend): string;
var
  Base: string;
begin
  Base := TrimBase(B.APIBase);
  if Base = '' then Base := DefaultDecisionAPIBase(B.Kind);
  case B.Kind of
    dbGoogle:
      { A Gemini provider's api_base is the host; tolerate one that
        already carries the version path. }
      if (Length(Base) >= 7) and SameText(Copy(Base, Length(Base) - 6, 7), '/v1beta') then
        Result := Base + '/decisions'
      else
        Result := Base + '/v1beta/decisions';
    dbSystemOne:
      if (Length(Base) >= 3) and SameText(Copy(Base, Length(Base) - 2, 3), '/v1') then
        Result := Base + '/systemone'
      else
        Result := Base + '/v1/systemone';
  else
    Result := Base;
  end;
end;

function KindName(K: TDecisionKind): string;
begin
  case K of
    dqNoul:   Result := 'noul';
    dqChoice: Result := 'choice';
  else
    Result := 'score';
  end;
end;

function BuildDecisionBody(const B: TDecisionBackend; const Input: string;
  const Qs: array of TDecisionQuestion): string;
var
  Root, QMap, Q, Crit: TJsonObject;
  Levels: TJsonArray;
  i, j: Integer;
  Model: string;
begin
  Root := TJsonObject.Create;
  try
    Model := Trim(B.Model);
    if Model = '' then Model := DefaultDecisionModel(B.Kind);
    Root.PutStr('model', Model);
    if B.Kind = dbSystemOne then Root.PutStr('state', Input)
    else Root.PutStr('input', Input);
    QMap := TJsonObject.Create;
    for i := 0 to High(Qs) do
    begin
      Q := TJsonObject.Create;
      Q.PutStr('type', KindName(Qs[i].Kind));
      Q.PutStr('instructions', Qs[i].Instructions);
      case Qs[i].Kind of
        dqNoul:
          if (Qs[i].TrueDesc <> '') or (Qs[i].FalseDesc <> '') then
          begin
            Crit := TJsonObject.Create;
            if B.Kind = dbSystemOne then
            begin
              Crit.PutStr('true', Qs[i].TrueDesc);
              Crit.PutStr('false', Qs[i].FalseDesc);
            end
            else
            begin
              Crit.PutStr('true_description', Qs[i].TrueDesc);
              Crit.PutStr('false_description', Qs[i].FalseDesc);
            end;
            Q.PutObject('criteria', Crit);
          end;
        dqChoice:
          begin
            Crit := TJsonObject.Create;
            for j := 0 to High(Qs[i].Options) do
              Crit.PutStr(Qs[i].Options[j].Id, Qs[i].Options[j].Description);
            Q.PutObject('criteria', Crit);
          end;
        dqScore:
          begin
            Levels := TJsonArray.Create;
            for j := 0 to High(Qs[i].Levels) do
              Levels.AddStr(Qs[i].Levels[j]);
            Q.PutArray('criteria', Levels);
          end;
      end;
      QMap.PutObject(Qs[i].Key, Q);
    end;
    Root.PutObject('questions', QMap);
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function ParseDecisionResponse(const Body: string;
  const Qs: array of TDecisionQuestion; out Answers: TDecisionAnswers;
  out InputTokens: Int64; out Err: string): Boolean;
var
  Root, AMap, A, Probs, Usage: TJsonObject;
  i, j, Best: Integer;
  P, Sum, Weighted: Double;
  Typ: string;
begin
  Result := False;
  Answers := nil;
  InputTokens := 0;
  Err := '';
  Root := nil;
  try
    Root := TJsonObject.Parse(Body);
  except
    on E: Exception do
    begin
      Err := 'response is not JSON';
      Exit;
    end;
  end;
  { ChildObject hands back a fresh wrapper that does not own its data:
    each one is freed here, the data stays with Root. }
  AMap := nil;
  A := nil;
  Probs := nil;
  try
    if Root = nil then begin Err := 'response is not a JSON object'; Exit; end;
    Usage := Root.ChildObject('usage');
    if Usage <> nil then
    try
      InputTokens := Usage.GetInt('total_input_tokens', -1);
      if InputTokens < 0 then InputTokens := Usage.GetInt('input_tokens', -1);
      if InputTokens < 0 then InputTokens := Usage.GetInt('prompt_tokens', 0);
    finally
      Usage.Free;
    end;
    AMap := Root.ChildObject('answers');
    if AMap = nil then begin Err := 'response has no answers'; Exit; end;
    SetLength(Answers, Length(Qs));
    for i := 0 to High(Qs) do
    begin
      FreeAndNil(A);
      FreeAndNil(Probs);
      A := AMap.ChildObject(Qs[i].Key);
      if A = nil then
      begin
        Err := 'no answer for question "' + Qs[i].Key + '"';
        Exit;
      end;
      Typ := LowerCase(A.GetStr('type', KindName(Qs[i].Kind)));
      if Typ <> KindName(Qs[i].Kind) then
      begin
        Err := 'answer "' + Qs[i].Key + '" is a ' + Typ + ', asked a ' + KindName(Qs[i].Kind);
        Exit;
      end;
      Answers[i].Key := Qs[i].Key;
      Answers[i].Kind := Qs[i].Kind;
      Answers[i].Choice := '';
      case Qs[i].Kind of
        dqNoul:
          begin
            if not A.Has('noul') then
            begin
              Err := 'answer "' + Qs[i].Key + '" has no noul probability';
              Exit;
            end;
            P := A.GetFloat('noul', 0);
            if P < 0 then P := 0;
            if P > 1 then P := 1;
            Answers[i].Value := P;
            SetLength(Answers[i].Probs, 2);
            Answers[i].Probs[0] := 1 - P;
            Answers[i].Probs[1] := P;
            if P >= 0.5 then Answers[i].Top := P else Answers[i].Top := 1 - P;
          end;
        dqChoice, dqScore:
          begin
            Probs := A.ChildObject('probabilities');
            if Probs = nil then
            begin
              Err := 'answer "' + Qs[i].Key + '" has no probabilities';
              Exit;
            end;
            if Qs[i].Kind = dqChoice then
              SetLength(Answers[i].Probs, Length(Qs[i].Options))
            else
              SetLength(Answers[i].Probs, Length(Qs[i].Levels));
            Sum := 0;
            for j := 0 to High(Answers[i].Probs) do
            begin
              if Qs[i].Kind = dqChoice then
                P := Probs.GetFloat(Qs[i].Options[j].Id, 0)
              else
                P := Probs.GetFloat(IntToStr(j), 0);
              if P < 0 then P := 0;
              Answers[i].Probs[j] := P;
              Sum := Sum + P;
            end;
            if Sum <= 0 then
            begin
              Err := 'answer "' + Qs[i].Key + '" has no probability on any option asked';
              Exit;
            end;
            { Renormalise: a vendor's rounding should not leak into Top. }
            Best := 0;
            Weighted := 0;
            for j := 0 to High(Answers[i].Probs) do
            begin
              Answers[i].Probs[j] := Answers[i].Probs[j] / Sum;
              if Answers[i].Probs[j] > Answers[i].Probs[Best] then Best := j;
              Weighted := Weighted + j * Answers[i].Probs[j];
            end;
            Answers[i].Top := Answers[i].Probs[Best];
            if Qs[i].Kind = dqChoice then
            begin
              Answers[i].Choice := Qs[i].Options[Best].Id;
              Answers[i].Value := Answers[i].Probs[Best];
            end
            else
              Answers[i].Value := Weighted;
          end;
      end;
    end;
    Result := True;
  finally
    Probs.Free;
    A.Free;
    AMap.Free;
    Root.Free;
  end;
end;

function ErrorMessageOf(const Body: string): string;
var
  Root, E: TJsonObject;
begin
  Result := '';
  Root := nil;
  try
    Root := TJsonObject.Parse(Body);
  except
    Root := nil;
  end;
  if Root = nil then
  begin
    Result := Copy(Trim(Body), 1, 300);
    Exit;
  end;
  try
    E := Root.ChildObject('error');
    if E <> nil then
    try
      Result := E.GetStr('message', '');
      if E.GetStr('code', '') <> '' then
        Result := E.GetStr('code', '') + ': ' + Result;
    finally
      E.Free;
    end
    else
      Result := Root.GetStr('error', Root.GetStr('detail', ''));
    if Result = '' then Result := Copy(Trim(Body), 1, 300);
  finally
    Root.Free;
  end;
end;

function Decide(const B: TDecisionBackend; const Input: string;
  const Qs: array of TDecisionQuestion): TDecisionResult;
var
  Headers: array of THeaderPair;
  Resp: THTTPResult;
  T0: TDateTime;
  Timeout: Integer;
  Err: string;
begin
  Result := Default(TDecisionResult);
  if Length(Qs) = 0 then
  begin
    Result.Error := 'no questions';
    Exit;
  end;
  if Trim(B.APIKey) = '' then
  begin
    Result.Error := 'decision backend "' + B.Name + '" has no API key';
    Exit;
  end;
  SetLength(Headers, 1);
  if B.Kind = dbGoogle then
    Headers[0] := MakeHeader('x-goog-api-key', B.APIKey)
  else
    Headers[0] := MakeHeader('Authorization', 'Bearer ' + B.APIKey);
  Timeout := B.TimeoutSec;
  if Timeout <= 0 then Timeout := 60;
  T0 := Now;
  try
    Resp := PostJSON(DecisionURL(B), BuildDecisionBody(B, Input, Qs), Headers, Timeout);
  except
    on E: Exception do
    begin
      Result.ElapsedMs := MilliSecondsBetween(Now, T0);
      Result.Error := 'request failed: ' + E.Message;
      Exit;
    end;
  end;
  Result.ElapsedMs := MilliSecondsBetween(Now, T0);
  Result.StatusCode := Resp.StatusCode;
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    if Resp.StatusCode <= 0 then
      Result.Error := 'request failed: ' + Resp.ErrorMsg
    else
      Result.Error := 'HTTP ' + IntToStr(Resp.StatusCode) + ': ' + ErrorMessageOf(Resp.Body);
    Exit;
  end;
  if not ParseDecisionResponse(Resp.Body, Qs, Result.Answers, Result.InputTokens, Err) then
  begin
    Result.Error := Err;
    Exit;
  end;
  Result.Ok := True;
end;

function NoulQuestion(const Key, Instructions: string): TDecisionQuestion;
begin
  Result := Default(TDecisionQuestion);
  Result.Key := Key;
  Result.Kind := dqNoul;
  Result.Instructions := Instructions;
end;

function ChoiceQuestion(const Key, Instructions: string;
  const Ids, Descriptions: array of string): TDecisionQuestion;
var
  i: Integer;
begin
  Result := Default(TDecisionQuestion);
  Result.Key := Key;
  Result.Kind := dqChoice;
  Result.Instructions := Instructions;
  SetLength(Result.Options, Length(Ids));
  for i := 0 to High(Ids) do
  begin
    Result.Options[i].Id := Ids[i];
    if i <= High(Descriptions) then Result.Options[i].Description := Descriptions[i]
    else Result.Options[i].Description := '';
  end;
end;

function ScoreQuestion(const Key, Instructions: string;
  const Levels: array of string): TDecisionQuestion;
var
  i: Integer;
begin
  Result := Default(TDecisionQuestion);
  Result.Key := Key;
  Result.Kind := dqScore;
  Result.Instructions := Instructions;
  SetLength(Result.Levels, Length(Levels));
  for i := 0 to High(Levels) do Result.Levels[i] := Levels[i];
end;

end.
