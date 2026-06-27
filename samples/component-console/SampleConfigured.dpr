(*
  SampleConfigured — make every onboarding choice in code, no config.json.

  SampleSimple shows the one-liner SetProvider path; SampleConsole inherits
  ~/.pasclaw/config.json (i.e. "run `pasclaw onboard` first"). This sample
  shows the third mode: boot a fully self-configured agent purely in code,
  the way you'd embed PasClaw inside another app and drive it via the API.

  The key is two things on the component:

    1. LoadConfigFromDisk := False  -> start from clean TConfig defaults,
       ignoring ~/.pasclaw/config.json (no disk dependency).
    2. Config : TConfig             -> the live config, never nil after
       Create; set ANY field here BEFORE the first Chat/Run to make the same
       choices `pasclaw onboard` makes interactively.

  Onboarding choice  ->  code:
    provider + key + model   SetProvider('anthropic', key, model)
    cheap fallback           add a Providers[] entry + name it in Fallbacks
    distilled memory         Config.MemoryDistillEnabled := True
    web fetch                Config.WebFetchEnabled      := True
    task-aware orient        Config.OrientTaskAware      := True
    tool-output cap          Config.ToolOutputCap        := 8192
    sandbox workspace        Config.Sandbox.Workspace    := '...'
    custom tools             RegisterTool(...)

  Build (FPC):
    cd samples/component-console
    make configured

  Runtime:
    export ANTHROPIC_API_KEY=sk-ant-...
    # optional cheap fallback:
    export GROQ_API_KEY=gsk-...
    ./build/SampleConfigured
*)
program SampleConfigured;

{$APPTYPE CONSOLE}
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Agent,
  PasClaw.Tools;

var
  Agent: TPasClawAgent;
  C: TConfig;
  ApiKey, GroqKey: string;
  n: Integer;
begin
  ApiKey := GetEnvironmentVariable('ANTHROPIC_API_KEY');
  if ApiKey = '' then
  begin
    WriteLn('ANTHROPIC_API_KEY not set — export it and re-run.');
    Halt(2);
  end;
  GroqKey := GetEnvironmentVariable('GROQ_API_KEY');   { optional fallback }

  Agent := TPasClawAgent.Create('claude-opus-4-7');
  try
    { 1. Don't read ~/.pasclaw/config.json -- start from clean defaults so
         every choice below is explicit and the app carries no disk state. }
    Agent.LoadConfigFromDisk := False;

    { 2. Primary provider (catalog fills in base + default model). }
    Agent.SetProvider('anthropic', ApiKey);

    { 3. Everything else onboarding would ask, set directly on the live
         Config -- valid because Config is non-nil right after Create and is
         applied at the first Run. }
    C := Agent.Config;
    C.MemoryDistillEnabled := True;   { auto-distil durable facts per turn }
    C.WebFetchEnabled      := True;   { register web_fetch / memory_fetch }
    C.OrientTaskAware      := True;   { task-aware MEMORY slicing + plan preamble }
    C.ToolOutputCap        := 8192;   { truncate huge tool results, keep a handle }
    C.Sandbox.Workspace    := GetCurrentDir;  { where shell/fs tools operate }

    { 4. Optional cheap fallback (retry chain) -- the code form of
         onboarding's "cheap fallback provider" prompt: add a provider entry
         and name it in Fallbacks. }
    if GroqKey <> '' then
    begin
      n := Length(C.Providers);
      SetLength(C.Providers, n + 1);
      C.Providers[n].Name   := 'groq';
      C.Providers[n].Kind   := 'groq';
      C.Providers[n].APIKey := GroqKey;
      C.Providers[n].Model  := 'llama-3.3-70b-versatile';
      SetLength(C.Fallbacks, Length(C.Fallbacks) + 1);
      C.Fallbacks[High(C.Fallbacks)] := 'groq';
      WriteLn('fallback: groq configured');
    end;

    { 5. Custom + built-in tools, registered in code. }
    Agent.RegisterTool(TWebSearchTool.Create);
    Agent.RegisterTool(TFileSystemTool.Create);

    WriteLn('configured in code: provider=', Agent.Config.DefaultProvider,
            ' model=', Agent.Config.DefaultModel,
            ' memory=', C.MemoryDistillEnabled,
            ' webfetch=', C.WebFetchEnabled,
            ' orient=', C.OrientTaskAware);
    WriteLn;

    try
      WriteLn(Agent.Run('In one sentence, what is Free Pascal?'));
    except
      on E: EPasClawRun do
        WriteLn('agent error: ', E.Message);
    end;
  finally
    Agent.Free;
  end;
end.
