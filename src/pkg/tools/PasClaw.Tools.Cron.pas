(*
  PasClaw.Tools.Cron - the model-callable `cron` tool.

  Lets the model schedule background work the same way picoclaw / nanobot /
  openclaw do, but bounded: a cron entry only runs an EXISTING operator-
  installed skill on a schedule (it cannot author the work, only schedule
  it), and the tool is OFF unless the operator sets cron_tool_enabled=true.

  Mechanism: the tool edits config.json's `crons[]` array directly (raw
  JSON -- NOT LoadConfig/SaveConfig, which would bake any active profile's
  resolved values into the file). The running TCronScheduler watches
  config.json's mtime and reloads within one tick (~30s), so additions go
  live without a restart; in `pasclaw agent` (no scheduler) they apply the
  next time `serve`/`gateway` runs.

  Actions:
    {"action":"list"}
    {"action":"add","spec":"0 9 * * *","skill":"daily-digest","args":"..."}
    {"action":"remove","id":"cron-..."}
*)
unit PasClaw.Tools.Cron;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

interface

uses
  PasClaw.Tools.Registry;

procedure RegisterCronTool(R: TToolRegistry);

{ The tool handler: action=list|add|remove against config.json's crons[].
  Exposed for tests. }
function Tool_Cron(const ArgsJSON: string; out ErrMsg: string): string;

implementation

uses
  SysUtils, DateUtils,
  PasClaw.Tools.Types,   { TTool / TToolCategory / tcMutating }
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Logger,
  PasClaw.Config,
  PasClaw.Cron.Expr,
  PasClaw.Skills.Loader;

type
  TCronRow = record
    Id, Spec, Skill, Args, ChannelKind, ChannelTarget: string;
    Enabled: Boolean;
  end;
  TCronRows = array of TCronRow;

{ Read config.json (raw) into a TJsonObject. Missing file -> empty object so
  a first add can create it. Returns False with Err on a parse failure. }
function LoadConfigRoot(out Root: TJsonObject; out Err: string): Boolean;
var
  Path, Body: string;
begin
  Root := nil; Err := '';
  Path := GetConfigPath;
  if FileExists(Path) then
  begin
    try
      Body := ReadFileText(Path);
    except
      on E: Exception do begin Err := 'read config: ' + E.Message; Exit(False); end;
    end;
    Root := TJsonObject.Parse(Body);
    if Root = nil then begin Err := 'config.json is not valid JSON'; Exit(False); end;
  end
  else
    Root := TJsonObject.Create;
  Result := True;
end;

function ReadCrons(Root: TJsonObject): TCronRows;
var
  Arr: TJsonArray;
  Item: TJsonObject;
  i, N: Integer;
begin
  SetLength(Result, 0);
  Arr := Root.ChildArray('crons');
  if Arr = nil then Exit;
  try
    N := 0;
    SetLength(Result, Arr.Count);
    for i := 0 to Arr.Count - 1 do
    begin
      Item := Arr.ItemObject(i);
      if Item = nil then Continue;
      try
        Result[N].Id            := Item.GetStr ('id',             '');
        Result[N].Spec          := Item.GetStr ('spec',           '');
        Result[N].Skill         := Item.GetStr ('skill',          '');
        Result[N].Args          := Item.GetStr ('args',           '');
        Result[N].Enabled       := Item.GetBool('enabled',        True);
        Result[N].ChannelKind   := Item.GetStr ('channel_kind',   '');
        Result[N].ChannelTarget := Item.GetStr ('channel_target', '');
        Inc(N);
      finally
        Item.Free;
      end;
    end;
    SetLength(Result, N);
  finally
    Arr.Free;
  end;
end;

{ Replace Root's crons[] with Rows and write config.json back. }
procedure WriteCrons(Root: TJsonObject; const Rows: TCronRows);
var
  Arr: TJsonArray;
  Item: TJsonObject;
  i: Integer;
begin
  Arr := TJsonArray.Create;
  for i := 0 to High(Rows) do
  begin
    Item := TJsonObject.Create;
    Item.PutStr ('id',      Rows[i].Id);
    Item.PutStr ('spec',    Rows[i].Spec);
    Item.PutStr ('skill',   Rows[i].Skill);
    Item.PutStr ('args',    Rows[i].Args);
    Item.PutBool('enabled', Rows[i].Enabled);
    if Rows[i].ChannelKind   <> '' then Item.PutStr('channel_kind',   Rows[i].ChannelKind);
    if Rows[i].ChannelTarget <> '' then Item.PutStr('channel_target', Rows[i].ChannelTarget);
    Arr.AddObject(Item);
  end;
  Root.PutArray('crons', Arr);   { overwrites the existing key }
  WriteFileText(GetConfigPath, Root.ToJSON);
end;

function SkillExists(const Name: string): Boolean;
var
  Skills: TSkillSpecArray;
  i: Integer;
begin
  Result := False;
  Skills := LoadSkillManifests(GetHome);
  for i := 0 to High(Skills) do
    if SameText(Skills[i].Name, Name) then Exit(True);
end;

function GenCronId: string;
begin
  Result := 'cron-' + FormatDateTime('yyyymmdd-hhnnss', Now) +
            '-' + IntToHex(Random(1 shl 16), 4);
end;

function FmtRows(const Rows: TCronRows): string;
var
  i: Integer;
begin
  if Length(Rows) = 0 then Exit('(no cron jobs scheduled)');
  Result := IntToStr(Length(Rows)) + ' cron job(s):'#10;
  for i := 0 to High(Rows) do
  begin
    Result := Result + Format('  %s  [%s]  skill=%s  args=%s',
      [Rows[i].Id, Rows[i].Spec, Rows[i].Skill, Rows[i].Args]);
    if not Rows[i].Enabled then Result := Result + ' (disabled)';
    Result := Result + #10;
  end;
end;

function Tool_Cron(const ArgsJSON: string; out ErrMsg: string): string;
var
  Obj, Root: TJsonObject;
  Action, Spec, Skill, SkArgs, Id: string;
  Rows: TCronRows;
  Expr: TCronExpr;
  i, KeptN: Integer;
  Found: Boolean;
  Err: string;
begin
  ErrMsg := ''; Result := '';
  Action := ''; Spec := ''; Skill := ''; SkArgs := ''; Id := '';
  if Trim(ArgsJSON) <> '' then
  begin
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj <> nil then
    try
      Action := LowerCase(Trim(Obj.GetStr('action', '')));
      Spec   := Trim(Obj.GetStr('spec',  ''));
      Skill  := Trim(Obj.GetStr('skill', ''));
      SkArgs := Obj.GetStr('args', '');
      Id     := Trim(Obj.GetStr('id',    ''));
    finally
      Obj.Free;
    end;
  end;
  if Action = '' then begin ErrMsg := 'missing "action" (list | add | remove)'; Exit; end;

  if not LoadConfigRoot(Root, Err) then begin ErrMsg := Err; Exit; end;
  try
    Rows := ReadCrons(Root);

    if Action = 'list' then
      Result := FmtRows(Rows)

    else if Action = 'add' then
    begin
      if (Spec = '') or (Skill = '') then
      begin ErrMsg := 'add requires "spec" (cron expression) and "skill"'; Exit; end;
      if not ParseCronExpr(Spec, Expr) then
      begin ErrMsg := 'invalid cron expression: "' + Spec + '"'; Exit; end;
      if not SkillExists(Skill) then
      begin
        ErrMsg := 'unknown skill "' + Skill + '" -- cron runs existing ' +
                  'installed skills only; install it first';
        Exit;
      end;
      if Id = '' then Id := GenCronId;
      for i := 0 to High(Rows) do
        if SameText(Rows[i].Id, Id) then
        begin ErrMsg := 'a cron with id "' + Id + '" already exists'; Exit; end;
      SetLength(Rows, Length(Rows) + 1);
      Rows[High(Rows)].Id      := Id;
      Rows[High(Rows)].Spec    := Spec;
      Rows[High(Rows)].Skill   := Skill;
      Rows[High(Rows)].Args    := SkArgs;
      Rows[High(Rows)].Enabled := True;
      WriteCrons(Root, Rows);
      LogInfo('cron tool: scheduled %s (skill=%s spec=%s)', [Id, Skill, Spec]);
      Result := Format('Scheduled cron "%s": skill "%s" on "%s". A running ' +
        'serve/gateway picks it up within ~30s; otherwise it activates on the ' +
        'next start.', [Id, Skill, Spec]);
    end

    else if Action = 'remove' then
    begin
      if Id = '' then begin ErrMsg := 'remove requires "id"'; Exit; end;
      Found := False; KeptN := 0;
      for i := 0 to High(Rows) do
        if SameText(Rows[i].Id, Id) then
          Found := True
        else
        begin
          Rows[KeptN] := Rows[i];
          Inc(KeptN);
        end;
      if not Found then begin ErrMsg := 'no cron with id "' + Id + '"'; Exit; end;
      SetLength(Rows, KeptN);
      WriteCrons(Root, Rows);
      LogInfo('cron tool: removed %s', [Id]);
      Result := Format('Removed cron "%s".', [Id]);
    end

    else
      ErrMsg := 'unknown action "' + Action + '" (want list | add | remove)';
  finally
    Root.Free;
  end;
end;

procedure RegisterCronTool(R: TToolRegistry);
var
  T: TTool;
begin
  if R = nil then Exit;
  T.Name        := 'cron';
  T.Description :=
    'Schedule background jobs that run an installed skill on a cron schedule. ' +
    'action="list" shows current jobs; action="add" needs a 5-field cron ' +
    '"spec" and an installed "skill" name (optional "args"); action="remove" ' +
    'needs the job "id". Jobs run existing skills only -- you cannot schedule ' +
    'arbitrary commands. A running server applies changes within ~30s.';
  T.Schema      :=
    '{"type":"object","properties":{' +
    '"action":{"type":"string","enum":["list","add","remove"]},' +
    '"spec":{"type":"string","description":"5-field cron expression, e.g. \"0 9 * * *\" (add)."},' +
    '"skill":{"type":"string","description":"Name of an installed skill to run (add)."},' +
    '"args":{"type":"string","description":"Arguments passed to the skill (optional)."},' +
    '"id":{"type":"string","description":"Job id (required for remove; auto-generated on add)."}' +
    '},"required":["action"]}';
  T.Handler     := Tool_Cron;
  T.IsCore      := False;
  T.Category    := tcMutating;   { edits config.json + schedules execution }
  R.Register(T);
end;

end.
