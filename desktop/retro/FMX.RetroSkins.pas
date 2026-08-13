{ FMX.RetroSkins -- runtime recoloring for the retro styles.

  A "skin" in the classic-stylesheets sense is just a set of role colors:
  Hotdog Stand is Windows 3.1 with a yellow desktop and a red window, not a
  different widget design. Baking one .style file per skin would be exact but
  costs ~290 KB each, and there are 200-odd of them.

  So the colors are patched in at load time instead. generate_retro_styles.py
  emits a .rolemap next to every .style listing the byte offset of each color
  literal and which palette role produced it, which makes applying a skin a
  matter of overwriting six hex characters per offset:

      TRetroSkins.Apply('Retro\Win31.style',
                        'Retro\Skins\Win31\hotdog-stand.skin');

  Only the RGB half of each literal is rewritten, so alpha survives -- the
  half-transparent selection washes and fade overlays keep their opacity.

  No FMX style internals are touched: the patched text goes through the same
  TStyleManager.SetStyleFromFile the unskinned styles use. }

unit FMX.RetroSkins;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  ERetroSkin = class(Exception);

  /// <summary>A set of palette role colors, read from a .skin file.</summary>
  TRetroSkin = class
  private
    FName: string;
    FFamily: string;
    FFileName: string;
    FColors: TDictionary<string, Cardinal>;
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    /// <summary>Display name, e.g. 'Hotdog Stand'.</summary>
    property Name: string read FName;
    /// <summary>Style family this skin recolors, e.g. 'win9x'.</summary>
    property Family: string read FFamily;
    property FileName: string read FFileName;
    /// <summary>Role name -> $RRGGBB.</summary>
    property Colors: TDictionary<string, Cardinal> read FColors;
  end;

  /// <summary>Byte offsets of the color literals a .style file's palette
  /// roles produced, read from the generated .rolemap sidecar.</summary>
  TRetroRoleMap = class
  private
    FStyleName: string;
    FFamily: string;
    FSize: Integer;
    FRoles: TDictionary<string, TArray<Integer>>;
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    property StyleName: string read FStyleName;
    /// <summary>Style family, which is what skins are keyed by.</summary>
    property Family: string read FFamily;
    /// <summary>Size the .style file must have for the offsets to be valid.
    /// </summary>
    property Size: Integer read FSize;
    property Roles: TDictionary<string, TArray<Integer>> read FRoles;
  end;

  TRetroSkins = class
  public
    /// <summary>The style's family, from its .rolemap. Empty if unknown.
    /// </summary>
    class function FamilyOf(const AStyleFile: string): string;
    /// <summary>The .skin files that apply to a .style file, from
    /// Skins\&lt;family&gt;\ beside it -- so every Windows 9x style offers
    /// the same skins. Empty when the family has none.</summary>
    class function SkinsFor(const AStyleFile: string): TArray<string>;
    /// <summary>Display name of a .skin file without reading all of it.
    /// </summary>
    class function SkinName(const ASkinFile: string): string;
    /// <summary>The style file's bytes with the skin's colors patched in.
    /// </summary>
    class function Build(const AStyleFile, ASkinFile: string): TBytes;
    /// <summary>Build and write to ADest; returns ADest.</summary>
    class function BuildToFile(const AStyleFile, ASkinFile,
      ADest: string): string;
    /// <summary>Apply a skinned style globally. An empty ASkinFile loads the
    /// style unchanged.</summary>
    class procedure Apply(const AStyleFile, ASkinFile: string);
  end;

implementation

uses
  System.IOUtils, FMX.Styles;

const
  LiteralLength = 9;      { xAARRGGBB }
  RGBOffset = 3;          { skip 'x' and the alpha byte }
  RGBLength = 6;

{ helpers }

function SplitSetting(const ALine: string; out AKey, AValue: string): Boolean;
var
  P: Integer;
begin
  P := Pos('=', ALine);
  Result := P > 1;
  if Result then
  begin
    AKey := Trim(Copy(ALine, 1, P - 1));
    AValue := Trim(Copy(ALine, P + 1, MaxInt));
  end;
end;

function IsComment(const ALine: string): Boolean;
begin
  Result := (ALine = '') or (ALine[Low(string)] = ';') or
    (ALine[Low(string)] = '[');
end;

{ TRetroSkin }

constructor TRetroSkin.Create(const AFileName: string);
var
  Lines: TStringList;
  Line, Key, Value: string;
begin
  inherited Create;
  if AFileName = '' then
    raise ERetroSkin.Create('no skin file given');
  if not System.IOUtils.TFile.Exists(AFileName) then
    raise ERetroSkin.CreateFmt('skin file not found: %s', [AFileName]);
  FFileName := AFileName;
  FColors := TDictionary<string, Cardinal>.Create;
  FName := System.IOUtils.TPath.GetFileNameWithoutExtension(AFileName);
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(AFileName);
    for Line in Lines do
    begin
      if IsComment(Trim(Line)) or not SplitSetting(Trim(Line), Key, Value) then
        Continue;
      if SameText(Key, 'name') then
        FName := Value
      else if SameText(Key, 'family') then
        FFamily := Value
      else
        FColors.AddOrSetValue(LowerCase(Key), StrToUInt('$' + Value));
    end;
  finally
    Lines.Free;
  end;
end;

destructor TRetroSkin.Destroy;
begin
  FColors.Free;
  inherited;
end;

{ TRetroRoleMap }

constructor TRetroRoleMap.Create(const AFileName: string);
var
  Lines: TStringList;
  Parts: TArray<string>;
  Offsets: TArray<Integer>;
  Line, Key, Value: string;
  I: Integer;
begin
  inherited Create;
  if not System.IOUtils.TFile.Exists(AFileName) then
    raise ERetroSkin.CreateFmt('role map not found: %s', [AFileName]);
  FRoles := TDictionary<string, TArray<Integer>>.Create;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(AFileName);
    for Line in Lines do
    begin
      if IsComment(Trim(Line)) or not SplitSetting(Trim(Line), Key, Value) then
        Continue;
      if SameText(Key, 'style') then
        FStyleName := Value
      else if SameText(Key, 'family') then
        FFamily := Value
      else if SameText(Key, 'bytes') then
        FSize := StrToInt(Value)
      else
      begin
        Parts := Value.Split([',']);
        SetLength(Offsets, Length(Parts));
        for I := 0 to High(Parts) do
          Offsets[I] := StrToInt(Parts[I]);
        FRoles.AddOrSetValue(LowerCase(Key), Offsets);
      end;
    end;
  finally
    Lines.Free;
  end;
end;

destructor TRetroRoleMap.Destroy;
begin
  FRoles.Free;
  inherited;
end;

{ TRetroSkins }

class function TRetroSkins.FamilyOf(const AStyleFile: string): string;
var
  MapFile, Line, Key, Value: string;
  Lines: TStringList;
begin
  { The family lives in the .rolemap, so a full parse is avoidable: the
    header is the first handful of lines. }
  Result := '';
  if AStyleFile = '' then
    Exit;
  MapFile := ChangeFileExt(AStyleFile, '.rolemap');
  if not System.IOUtils.TFile.Exists(MapFile) then
    Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(MapFile);
    for Line in Lines do
    begin
      if Trim(Line) = '[roles]' then
        Break;
      if SplitSetting(Trim(Line), Key, Value) and SameText(Key, 'family') then
        Exit(Value);
    end;
  finally
    Lines.Free;
  end;
end;

class function TRetroSkins.SkinsFor(const AStyleFile: string): TArray<string>;
var
  Dir, Family: string;
begin
  { Callers ask before a style has been chosen -- an empty or unknown path
    means "no skins", not an error, so nothing here may touch the RTL path
    routines with an empty string. }
  Result := nil;
  if AStyleFile = '' then
    Exit;      { checked on its own: TPath.GetDirectoryName('') raises, and
                 a short-circuit here would depend on $BOOLEVAL }
  if not System.IOUtils.TFile.Exists(AStyleFile) then
    Exit;
  Family := FamilyOf(AStyleFile);
  if Family = '' then
    Exit;
  Dir := System.IOUtils.TPath.GetDirectoryName(AStyleFile);
  if Dir = '' then
    Exit;
  Dir := IncludeTrailingPathDelimiter(Dir) + 'Skins' + PathDelim + Family;
  if System.IOUtils.TDirectory.Exists(Dir) then
    Result := System.IOUtils.TDirectory.GetFiles(Dir, '*.skin');
end;

class function TRetroSkins.SkinName(const ASkinFile: string): string;
var
  Skin: TRetroSkin;
begin
  Result := '';
  if ASkinFile = '' then
    Exit;
  if not System.IOUtils.TFile.Exists(ASkinFile) then
    Exit;
  Skin := TRetroSkin.Create(ASkinFile);
  try
    Result := Skin.Name;
  finally
    Skin.Free;
  end;
end;

class function TRetroSkins.Build(const AStyleFile, ASkinFile: string): TBytes;
var
  Skin: TRetroSkin;
  Map: TRetroRoleMap;
  MapFile, Hex: string;
  Pair: TPair<string, Cardinal>;
  Offsets: TArray<Integer>;
  Offset, I: Integer;
begin
  Result := nil;
  if AStyleFile = '' then
    raise ERetroSkin.Create('no style file given');
  Result := System.IOUtils.TFile.ReadAllBytes(AStyleFile);
  if ASkinFile = '' then
    Exit;
  MapFile := ChangeFileExt(AStyleFile, '.rolemap');
  if not System.IOUtils.TFile.Exists(MapFile) then
    raise ERetroSkin.CreateFmt('no role map beside %s -- regenerate the ' +
      'styles with tools/generate_retro_styles.py', [AStyleFile]);
  Skin := nil;
  Map := nil;
  try
    Skin := TRetroSkin.Create(ASkinFile);
    Map := TRetroRoleMap.Create(MapFile);
    if Map.Size <> Length(Result) then
      raise ERetroSkin.CreateFmt('%s is %d bytes but its role map describes ' +
        '%d -- the two are out of sync',
        [AStyleFile, Length(Result), Map.Size]);
    if (Skin.Family <> '') and (Map.Family <> '') and
       not SameText(Skin.Family, Map.Family) then
      raise ERetroSkin.CreateFmt('skin %s is for the %s family, not %s',
        [Skin.Name, Skin.Family, Map.Family]);
    for Pair in Skin.Colors do
    begin
      if not Map.Roles.TryGetValue(Pair.Key, Offsets) then
        Continue;   { role the style never paints with -- nothing to do }
      Hex := IntToHex(Integer(Pair.Value and $FFFFFF), RGBLength);
      for Offset in Offsets do
      begin
        if (Offset < 0) or (Offset + LiteralLength > Length(Result)) or
           (Result[Offset] <> Byte(Ord('x'))) then
          raise ERetroSkin.CreateFmt('role map offset %d does not point at ' +
            'a color literal in %s', [Offset, AStyleFile]);
        for I := 0 to RGBLength - 1 do
          Result[Offset + RGBOffset + I] := Byte(Ord(Hex[Low(string) + I]));
      end;
    end;
  finally
    Map.Free;
    Skin.Free;
  end;
end;

class function TRetroSkins.BuildToFile(const AStyleFile, ASkinFile,
  ADest: string): string;
begin
  System.IOUtils.TFile.WriteAllBytes(ADest, Build(AStyleFile, ASkinFile));
  Result := ADest;
end;

class procedure TRetroSkins.Apply(const AStyleFile, ASkinFile: string);
var
  Temp: string;
begin
  if AStyleFile = '' then
    Exit;                     { nothing chosen yet }
  if ASkinFile = '' then
  begin
    TStyleManager.SetStyleFromFile(AStyleFile);
    Exit;
  end;
  { FMX loads styles from a file, so the patched bytes go back to disk in the
    temp directory rather than being streamed in. One file per style/skin
    pair, overwritten on each switch. The skin's full file name goes into the
    temp name -- dots and all, flattened -- because skins like '3.1.skin' and
    '3.skin' would otherwise share it. }
  Temp := System.IOUtils.TPath.Combine(System.IOUtils.TPath.GetTempPath,
    Format('retroskin_%s_%s.style',
      [System.IOUtils.TPath.GetFileNameWithoutExtension(AStyleFile),
       StringReplace(System.IOUtils.TPath.GetFileName(ASkinFile), '.', '_',
         [rfReplaceAll])]));
  TStyleManager.SetStyleFromFile(BuildToFile(AStyleFile, ASkinFile, Temp));
end;

end.
