(*
  fphttpclient for the FreePascalOS build of PasClaw.

  FPC's fphttpclient (fcl-web) sits on ssockets and the BSD socket unit,
  neither of which exists for FreePascalOS. The units that download
  model files with it (LocalVector.Downloader, .OrtProvision,
  .VecProvision, PasClaw.Memory.OrtPosix) use a small part of it:
  Create, AllowRedirect, AddHeader and Get into a stream or a file. This
  unit gives them that part over PasClaw.HTTP.FreePascalOS (libhttp), so
  they build unchanged. Only `make fpos` puts src/fpos on the unit path.

  PasClaw's own code, MIT like the rest of it.
*)
unit fphttpclient;

{$MODE OBJFPC}
{$H+}

interface

uses
  SysUtils, Classes;

type
  EHTTPClient = class(Exception)
  private
    FStatusCode: Integer;
  public
    property StatusCode: Integer read FStatusCode write FStatusCode;
  end;

  TFPHTTPClient = class(TComponent)
  private
    FAllowRedirect: Boolean;
    FNames, FValues: array of string;
    FResponseStatusCode: Integer;
    FIOTimeout: Integer;
  public
    constructor Create(AOwner: TComponent); override;
    procedure AddHeader(const AHeader, AValue: string);
    { GET URL into Stream; a status other than 2xx raises EHTTPClient,
      and so does a 2xx whose body did not arrive whole (cut off, timed
      out, or the stream would not take it): Stream then holds part of
      it. }
    procedure Get(const AURL: string; Stream: TStream); overload;
    procedure Get(const AURL: string; const LocalFileName: string); overload;
    function Get(const AURL: string): RawByteString; overload;
    property AllowRedirect: Boolean read FAllowRedirect write FAllowRedirect;
    property ResponseStatusCode: Integer read FResponseStatusCode;
    { Milliseconds; 0: libhttp's default. }
    property IOTimeout: Integer read FIOTimeout write FIOTimeout;
  end;

implementation

uses
  PasClaw.HTTP.FreePascalOS;

type
  { Refuses every redirect when AllowRedirect is off. }
  TRedirectRefuser = class
    procedure Refuse(var DestURL: string; var Allow: Boolean; var Reason: string);
  end;

procedure TRedirectRefuser.Refuse(var DestURL: string; var Allow: Boolean; var Reason: string);
begin
  Allow := False;
  Reason := 'redirect to ' + DestURL + ' not allowed';
end;

constructor TFPHTTPClient.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
end;

procedure TFPHTTPClient.AddHeader(const AHeader, AValue: string);
var
  N: Integer;
begin
  N := Length(FNames);
  SetLength(FNames, N + 1);
  SetLength(FValues, N + 1);
  FNames[N] := AHeader;
  FValues[N] := AValue;
end;

procedure TFPHTTPClient.Get(const AURL: string; Stream: TStream);
var
  X: TFposHttpExchange;
  Refuser: TRedirectRefuser;
  i: Integer;
  E: EHTTPClient;
begin
  X := FposNewExchange('GET', AURL, (FIOTimeout + 999) div 1000);
  for i := 0 to High(FNames) do
    if SameText(FNames[i], 'User-Agent') then
      X.UserAgent := FValues[i]
    else
      FposAddHeader(X, FNames[i], FValues[i]);
  Refuser := nil;
  if not FAllowRedirect then
  begin
    Refuser := TRedirectRefuser.Create;
    X.OnRedirect := @Refuser.Refuse;
  end;
  try
    FposHttpExecute(X, Stream);
  finally
    Refuser.Free;
  end;
  FResponseStatusCode := X.StatusCode;
  { FposHttpExecute keeps a 2xx status when the body fails after the
    headers, and says so in ErrorMsg. }
  if (X.StatusCode < 200) or (X.StatusCode >= 300) or (X.ErrorMsg <> '') then
  begin
    if X.StatusCode = 0 then
      E := EHTTPClient.Create(X.ErrorMsg)
    else if (X.StatusCode >= 200) and (X.StatusCode < 300) then
      E := EHTTPClient.CreateFmt('Status %d, but the body did not arrive whole: %s',
                                 [X.StatusCode, X.ErrorMsg])
    else
      E := EHTTPClient.CreateFmt('Unexpected response status code: %d', [X.StatusCode]);
    E.StatusCode := X.StatusCode;
    raise E;
  end;
end;

procedure TFPHTTPClient.Get(const AURL: string; const LocalFileName: string);
var
  F: TFileStream;
begin
  F := TFileStream.Create(LocalFileName, fmCreate);
  try
    Get(AURL, F);
  finally
    F.Free;
  end;
end;

function TFPHTTPClient.Get(const AURL: string): RawByteString;
var
  M: TMemoryStream;
begin
  Result := '';
  M := TMemoryStream.Create;
  try
    Get(AURL, M);
    SetString(Result, PAnsiChar(M.Memory), M.Size);
  finally
    M.Free;
  end;
end;

end.
