{
  PasClaw.Providers.Intf - the ILLMProvider interface every provider implements.
  Mirrors the LLMProvider interface in pkg/providers/types.go.
}
unit PasClaw.Providers.Intf;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types;

type
  TStreamCallback = procedure(const Chunk: TStreamChunk) of object;

  ILLMProvider = interface
    ['{6F1E1A1B-7B0E-4B53-B6E3-71D9F1F1A001}']
    function Chat(const Messages: array of TMessage;
                  const Tools:    array of TToolDefinition;
                  const Model:    string;
                  const Options:  TChatOptions): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
    function ChatStream(const Messages: array of TMessage;
                        const Tools:    array of TToolDefinition;
                        const Model:    string;
                        const Options:  TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
  end;

  { Named alias for `array of ILLMProvider`. Used by TToolLoopConfig.
    Fallbacks and PasClaw.Providers.Factory.ResolveFallbacks. Declared
    here (not in Factory) so PasClaw.Tools.ToolLoop can reference the
    named type without picking up the whole factory dependency, which
    matters under dcc64 -- Delphi 12 enforces strict named-type matching
    on dynamic-array assignments, so an inline `array of ILLMProvider`
    on TToolLoopConfig.Fallbacks would reject the named-type return of
    ResolveFallbacks with E2010. }
  TLLMProviderArray = array of ILLMProvider;

implementation

end.
