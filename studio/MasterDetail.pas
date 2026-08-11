unit MasterDetail;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.JSON,
  System.Rtti, System.Net.HttpClient, System.Net.URLClient, System.NetEncoding,
  System.Threading, System.Generics.Collections, System.IniFiles,
  System.IOUtils, System.StrUtils, System.Math, System.DateUtils,
  FMX.Types, FMX.Controls, FMX.Forms,
  FMX.Platform, FMX.Graphics, FMX.Dialogs, FMX.StdCtrls, FMX.Layouts, FMX.ListBox,
  FMX.Memo, FMX.Edit, FMX.TabControl, FMX.Controls.Presentation,
  FMX.ScrollBox, FMX.MultiView, FMX.Objects;

type
  TChatTurn = record
    Role: string;
    Text: string;
    ToolDetails: string;
  end;

  TPasClawSession = record
    Id: string;
    Title: string;
    UpdatedAt: string;
  end;

  TChatAttachment = record
    Name: string;
    Content: string;
  end;

  TStreamChunkProc = reference to procedure(const ChunkText: string;
    var Abort: Boolean);

  TMasterDetailForm = class(TForm)
  private
    FActiveSessionId: string;
    FAttachmentLabel: TLabel;
    FAttachmentStrip: THorzScrollBox;
    FAttachments: TList<TChatAttachment>;
    FAttachButton: TButton;
    FQueuedPrompts: TQueue<string>;
    FBodyLayout: TLayout;
    FContentLayout: TLayout;
    FClearAttachmentsButton: TButton;
    FConfigFile: string;
    FConfigEditorPane: TLayout;
    FConfigList: TListBox;
    FConfigListPane: TLayout;
    FConfigPathEdit: TEdit;
    FConfigValueMemo: TMemo;
    FCronArgsEdit: TEdit;
    FCronChannelKindEdit: TEdit;
    FCronChannelTargetEdit: TEdit;
    FCronDetailMemo: TMemo;
    FCronDetailMetaLabel: TLabel;
    FCronDetailTitleLabel: TLabel;
    FCronEnabledCheck: TCheckBox;
    FCronEditorPane: TLayout;
    FCronIdEdit: TEdit;
    FCronList: TListBox;
    FCronListPane: TLayout;
    FCronSkillEdit: TEdit;
    FCronSplitter: TSplitter;
    FCronSpecEdit: TEdit;
    FCronStatusLabel: TLabel;
    FDeleteSessionButton: TButton;
    FEndpointBodyMemos: TDictionary<string, TMemo>;
    FEndpointEdits: TDictionary<string, TEdit>;
    FEndpointMethodCombos: TDictionary<string, TComboBox>;
    FFileDetailMemo: TMemo;
    FFileHexToolbar: TLayout;
    FFileLeftPane: TLayout;
    FFileList: TListBox;
    FFileHexLabel: TLabel;
    FFileHexOffset: Int64;
    FFileHexPageSize: Int64;
    FFileHexPath: string;
    FFileHexTotal: Int64;
    FFilePathEdit: TEdit;
    FFilePaneSplitter: TSplitter;
    FFilePreviewImage: TImage;
    FFileRootsList: TListBox;
    FFileViewerPane: TLayout;
    FFileViewerStatusLabel: TLabel;
    FConnectionRow: TLayout;
    { the one-pixel rule under the title bar; held so ApplyTheme can repaint
      it, since a raw TRectangle brush is invisible to the restyle walk }
    FHeaderRule: TRectangle;
    FGatewayEdit: TEdit;
    FHeaderRow: TLayout;
    FCheckpointCurrentTurn: Int64;
    FCheckpointDetailMemo: TMemo;
    FCheckpointDetailPane: TLayout;
    FCheckpointList: TListBox;
    FCheckpointListPane: TLayout;
    FCheckpointSplitter: TSplitter;
    FCheckpointStatusLabel: TLabel;
    FChatParamsLayout: TLayout;
    FChatParamsVisible: Boolean;
    FChatStatsLabel: TLabel;
    FChatToolsExpanded: Boolean;
    FIconButtons: Boolean;
    { StyleLookupExists answers per (active book, lookup) and the answer cannot
      change while the app runs, but it IS asked once per chat-turn Copy
      button. Memoise it so a long transcript does not re-scan the style. }
    FStyleLookupCache: TDictionary<string, Boolean>;
    { Raw text of each loaded .style, kept for StyleLookupExists' fallback
      probe -- our own copy, no dependence on TStyleBook exposing its source. }
    FStyleBookTexts: TDictionary<TStyleBook, string>;
    FComposerLayout: TLayout;
    FComposerStatusLabel: TLabel;
    FSandboxLabel: TLabel;
    FChatTurnEdit: TEdit;
    FLoadingSessions: Boolean;
    FRestyling: Boolean;          { re-entrancy guard for RestyleCoreControls }
    { last payload each auto-refresh rendered, so an unchanged tick is a
      no-op instead of a clear-and-rebuild -- see StatsTimerTick }
    FLastRelayPayload: string;
    FLastStatsPayload: string;
    FLastActivatedTab: string;
    FLogsAbort: Boolean;
    FLogsRunning: Boolean;
    FLogsStatusLabel: TLabel;
    FMaxTokensEdit: TEdit;
    FMode: string;
    FModeButton: TButton;
    FModelCombo: TComboBox;
    FNavButtons: TDictionary<string, TButton>;
    FNavCombo: TComboBox;
    FNavHost: TLayout;
    FNavScroll: THorzScrollBox;
    FMcpArgsPanel: TLayout;
    FMcpLeftPane: TLayout;
    FMcpPanel: TLayout;
    FMcpRightPane: TLayout;
    FMcpSplitter: TSplitter;
    FMcpResultPanel: TLayout;
    FMcpSchemaPanel: TLayout;
    FMcpSchemaForm: TVertScrollBox;
    FMcpList: TListBox;
    FMcpResultDetailMemo: TMemo;
    FMcpResultList: TListBox;
    FMcpResultStatusLabel: TLabel;
    FMcpServerArgsEdit: TEdit;
    FMcpServerCmdEdit: TEdit;
    FMcpServerEnabledCheck: TCheckBox;
    FMcpServerEnvMemo: TMemo;
    FMcpServerNameEdit: TEdit;
    FMcpTabs: TTabControl;
    FMcpToolArgsMemo: TMemo;
    FMcpToolCombo: TComboBox;
    FLoadingChatParams: Boolean;
    FParamsResetButton: TButton;
    FParamsSummaryLabel: TLabel;
    FParamsToggleButton: TButton;
    FPresetDeleteButton: TButton;
    FPresetNameEdit: TEdit;
    FNewSessionButton: TButton;
    FPaneMemos: TDictionary<string, TMemo>;
    FPromptMemo: TMemo;
    FPromptPresetCombo: TComboBox;
    FPresetSaveButton: TButton;
    FProviderBaseEdit: TEdit;
    FProviderCatalogJson: string;
    FProviderCombo: TComboBox;
    FProviderFallbackCheck: TCheckBox;
    FProviderKeyEdit: TEdit;
    FProviderModelEdit: TEdit;
    FProviderNotesLabel: TLabel;
    FProviderRouteCheck: TCheckBox;
    FProviderSecondaryBaseEdit: TEdit;
    FProviderSecondaryCombo: TComboBox;
    FProviderSecondaryKeyEdit: TEdit;
    FProviderSecondaryModelEdit: TEdit;
    FQueueLabel: TLabel;
    FRefreshButton: TButton;
    FRelayAutoRefreshCheck: TCheckBox;
    FRelayLeftPane: TLayout;
    FRelayRightPane: TLayout;
    FRelaySnippetsMemo: TMemo;
    FRelaySplitter: TSplitter;
    FRelayStatsList: TListBox;
    FRelayStatusLabel: TLabel;
    FRelayTimer: TTimer;
    FRelayWorkerDetailMemo: TMemo;
    FRelayWorkerDetailMetaLabel: TLabel;
    FRelayWorkerDetailTitleLabel: TLabel;
    FRelayTokenEdit: TEdit;
    FRelayTokenJson: string;
    FRelayShowTokenButton: TButton;
    FRelayUrlEdit: TEdit;
    FRelayWorkerCommandEdit: TEdit;
    FRelayWorkerConnectButton: TButton;
    FRelayWorkerDisconnectButton: TButton;
    FRelayWorkerIdEdit: TEdit;
    FRelayWorkerLogMemo: TMemo;
    FRelayWorkerLogPath: string;
    FRelayWorkerModelEdit: TEdit;
    FRelayWorkerProfileCombo: TComboBox;
    FRelayWorkerProcessHandle: NativeUInt;
    FRelayWorkerProcessId: Cardinal;
    FRelayWorkerProviderEdit: TEdit;
    FRelayWorkerTimer: TTimer;
    FRelayWorkersList: TListBox;
    FSavedModel: string;
    FSending: Boolean;
    FSendButton: TButton;
    FSettingsTabs: TTabControl;
    FSessionCache: TList<TPasClawSession>;
    FSessionList: TListBox;
    FSessionSearch: TEdit;
    FSessionSearchButton: TButton;
    FSessionSearchVisible: Boolean;
    { The gateway identity (URL + token) that last ANSWERED, not a bare
      boolean: a flag survives an edit to either field and would keep
      reporting Connected for credentials that have never responded. }
    FOnlineIdentity: string;
    FSkillCatalogList: TListBox;
    FSkillCatalogPane: TLayout;
    FSkillDetailMemo: TMemo;
    FSkillDetailMetaLabel: TLabel;
    FSkillDetailTitleLabel: TLabel;
    FSkillInstallEdit: TEdit;
    FSkillInstalledPane: TLayout;
    FSkillLeftPane: TLayout;
    FSkillList: TListBox;
    FSkillPendingList: TListBox;
    FSkillPendingPane: TLayout;
    FSkillSearchEdit: TEdit;
    FSkillSplitter: TSplitter;
    FSessionToggleButton: TButton;
    FSessionDrawer: TMultiView;
    FSessionDrawerWidth: Single;
    FSessionSplitter: TSplitter;
    FSidebar: TLayout;
    FSidebarVisible: Boolean;
    FStatusLabel: TLabel;
    FStatsAutoRefreshCheck: TCheckBox;
    FStatsLeftPane: TLayout;
    FStatsModelList: TListBox;
    FStatsProviderList: TListBox;
    FStatsRightPane: TLayout;
    FStatsStatusLabel: TLabel;
    FStatsSummaryList: TListBox;
    FStatsTimer: TTimer;
    FStyleBook: TStyleBook;
    FLightStyleBook: TStyleBook;
    FDarkStyleEnabled: Boolean;
    FSystemMemo: TMemo;
    FTabControl: TTabControl;
    FTitleLabel: TLabel;
    FTemperatureEdit: TEdit;
    FTemperatureLabel: TLabel;
    FTemperatureTrack: TTrackBar;
    FThemeButton: TButton;
    FTokenClearButton: TButton;
    FTokenEdit: TEdit;
    FTokenShowButton: TButton;
    FToolsToggleButton: TButton;
    FTopBar: TLayout;
    FVaultCurrentSlug: string;
    FVaultDetailMemo: TMemo;
    FVaultDetailPane: TLayout;
    FVaultListPane: TLayout;
    FVaultMetaLabel: TLabel;
    FVaultList: TListBox;
    FVaultSearchEdit: TEdit;
    FVaultTitleLabel: TLabel;
    FChatAbort: Boolean;
    FChatCopyButton: TButton;
    FChatFilesList: TListBox;
    FChatFilesPopup: TPopup;
    FChatFlow: TFlowLayout;
    FChatList: TListBox;
    FChatScroll: TVertScrollBox;
    FChatTurnList: TListBox;
    FSlashList: TListBox;
    FSlashPopup: TPopup;
    FTurns: TList<TChatTurn>;
    FMaxTokensLabel: TLabel;
    FMemoryBackendCombo: TComboBox;
    FMemoryBrowseStatusLabel: TLabel;
    FMemoryDownloadEmbedCheck: TCheckBox;
    FMemoryDownloadRerankCheck: TCheckBox;
    FMemoryFactEdit: TEdit;
    FMemoryFactsList: TListBox;
    FMemoryFactsPane: TLayout;
    FMemoryFileDetailMemo: TMemo;
    FMemoryFileList: TListBox;
    FMemoryFilesPane: TLayout;
    FMemoryModelCombo: TComboBox;
    FMemoryNotesStatusLabel: TLabel;
    FMemoryTabs: TTabControl;
    FMemoryFactsStatusLabel: TLabel;
    FMemoryRerankModelEdit: TEdit;
    FMemorySearchEdit: TEdit;
    FMemoryStatusLabel: TLabel;
    FMemoryVectorCheck: TCheckBox;
    FKBResultsList: TListBox;
    FKBResultsPane: TLayout;
    FKBSearchEdit: TEdit;
    FKBSourceList: TListBox;
    FKBSourcesPane: TLayout;
    FKBStatusLabel: TLabel;
    FOnboardingDismissed: Boolean;
    FOnboardingCard: TRectangle;
    FOnboardingOverlay: TLayout;
    FOnboardingStatusLabel: TLabel;
    FOnboardingPrimaryButton: TButton;
    FOnboardingSkipButton: TButton;
    FOnboardingStep: Integer;      { 0 = provider, 1 = memory }
    FUndoButton: TButton;
    FRedoButton: TButton;
    FWorkflowConnectFromId: string;
    FWorkflowConnectPoint: TPointF;
    FWorkflowDescEdit: TEdit;
    FWorkflowEdgeFromEdit: TEdit;
    FWorkflowEdgeToEdit: TEdit;
    FWorkflowEdgesList: TListBox;
    FWorkflowCanvas: TPaintBox;
    FWorkflowDraggingId: string;
    FWorkflowDragOffset: TPointF;
    { The canvas view transform: screen = logical + pan. Zoom is deferred,
      but every consumer already goes through Wf*To* so adding a scale later
      touches TWO functions, not thirty call sites. }
    FWorkflowPan: TPointF;
    FWorkflowPanning: Boolean;
    FWorkflowPanMouse: TPointF;    { mouse position when the pan started }
    FWorkflowPanOrigin: TPointF;   { pan value when the pan started }
    FWorkflowGraphMemo: TMemo;
    FWorkflowEditorPanel: TLayout;
    FWorkflowInspectorModeLabel: TLabel;
    FWorkflowInputsEdit: TEdit;
    FWorkflowLeftPane: TLayout;
    FWorkflowLlmModelEdit: TEdit;
    FWorkflowLlmPromptMemo: TMemo;
    FWorkflowLlmProviderEdit: TEdit;
    FWorkflowLoopMemo: TMemo;
    FWorkflowNameEdit: TEdit;
    FWorkflowNodeArgsMemo: TMemo;
    FWorkflowNodeIdEdit: TEdit;
    FWorkflowNodePositions: TDictionary<string, TPointF>;
    FWorkflowNodesList: TListBox;
    FWorkflowOutputsMemo: TMemo;
    FWorkflowPickerCombo: TComboBox;
    FWorkflowReplicateResultsList: TListBox;
    FWorkflowReplicateSearchEdit: TEdit;
    FWorkflowReplicatePromptEdit: TEdit;
    FWorkflowReplicateVersionEdit: TEdit;
    FWorkflowRightPane: TLayout;
    FWorkflowRunDetailMemo: TMemo;
    FWorkflowRunInputsMemo: TMemo;
    FWorkflowRunResultsList: TListBox;
    FWorkflowRunStatusLabel: TLabel;
    FWorkflowSelectedEdge: string;
    FWorkflowHoverEdge: string;    { edge text under the cursor (idle hover) }
    FWorkflowRunNodeOk: TDictionary<string, Boolean>;
    FWorkflowRunNodePreview: TDictionary<string, string>;
    FWorkflowPalettePanel: TRectangle;
    FWorkflowPaletteEdit: TEdit;
    FWorkflowPaletteList: TListBox;
    FWorkflowPaletteDrop: TPointF;  { logical spot the palette will drop a node }
    FWorkflowSchemaForm: TVertScrollBox;
    FWorkflowToolCombo: TComboBox;
    FWorkflowToolSchemas: TDictionary<string, string>;

    procedure AddAttachment(const Name, Content: string);
    procedure AddHeader(var Headers: TNetHeaders; const Name, Value: string);
    procedure AddNavigationButton(const Caption: string);
    procedure AddTurn(const Role, Text: string);
    procedure ActivateCurrentTab(AForce: Boolean = False);
    function AttachmentSummary: string;
    procedure AttachmentRemoveClick(Sender: TObject);
    procedure AttachFilesClick(Sender: TObject);
    procedure ApplyResponsiveLayout;
    procedure ApplyTheme;
    function AppendTurnArray(const Turns: TArray<TChatTurn>; const Role,
      Text: string): TArray<TChatTurn>;
    function BuildChatPayload(const Turns: TArray<TChatTurn>;
      const SystemPrompt, Model, Mode, Temperature, MaxTokens: string;
      Stream: Boolean): string;
    function BuildEndpointTab(const Key, Caption, Endpoint,
      Description: string): TLayout;
    procedure BuildInterface;
    procedure BuildCheckpointPanel(AParent: TFmxObject);
    procedure BuildChatTab;
    procedure BuildConfigEditorPanel(AParent: TFmxObject);
    procedure BuildCronPanel(AParent: TFmxObject);
    procedure BuildFilesBrowserPanel(AParent: TFmxObject);
    procedure BuildKbPanel(AParent: TFmxObject);
    procedure BuildMemoryBrowserPanel(AParent: TFmxObject);
    procedure BuildMemoryFactsPanel(AParent: TFmxObject);
    procedure BuildMemorySetupPanel(AParent: TFmxObject);
    procedure BuildMcpPanel(AParent: TFmxObject);
    procedure BuildOnboardingOverlay;
    procedure BuildProviderSetupPanel(AParent: TFmxObject);
    procedure BuildRelayPanel(AParent: TFmxObject);
    procedure BuildSkillsPanel(AParent: TFmxObject);
    procedure BuildStatsPanel(AParent: TFmxObject);
    procedure BuildVaultPanel(AParent: TFmxObject);
    procedure BuildWorkflowEditorPanel(AParent: TFmxObject);
    function BuildSessionPayload(const Turns: TArray<TChatTurn>): string;
    procedure ClearAttachmentsClick(Sender: TObject);
    function CleanBaseUrl(const Value: string): string;
    function ComposePrompt(const TypedPrompt: string): string;
    function ComposeUrl(const BaseUrl, Endpoint: string): string;
    function CurrentModel: string;
    function DecodeIniText(const Value: string): string;
    procedure ChatCheckpointClick(Sender: TObject);
    procedure ChatFileActionClick(Sender: TObject);
    procedure ChatFilesClick(Sender: TObject);
    procedure ChatParamsChanged(Sender: TObject);
    procedure ChatToolsToggleClick(Sender: TObject);
    procedure ChatTranscriptChange(Sender: TObject);
    procedure ChatTurnActionClick(Sender: TObject);
    procedure ChatTurnListChange(Sender: TObject);
    procedure CardListItemClick(Sender: TObject);
    function CollectChatFilePaths: TArray<string>;
    procedure CheckpointActionClick(Sender: TObject);
    procedure CheckpointListChange(Sender: TObject);
    procedure CheckpointRefreshClick(Sender: TObject);
    procedure ConfigAddArrayItemClick(Sender: TObject);
    procedure ConfigApplyValueClick(Sender: TObject);
    procedure ConfigDeleteValueClick(Sender: TObject);
    function ConfigFindValue(Root: TJSONValue; const Path: string;
      out Parent: TJSONValue; out Segment: string): TJSONValue;
    procedure ConfigListChange(Sender: TObject);
    procedure ConfigQuickSectionClick(Sender: TObject);
    procedure ConfigRenderEditor;
    procedure ConfigRefreshClick(Sender: TObject);
    procedure CronClearClick(Sender: TObject);
    procedure CronListChange(Sender: TObject);
    procedure CronLoadFromJson(const JsonText: string);
    procedure CronRefreshClick(Sender: TObject);
    procedure CronRemoveClick(Sender: TObject);
    procedure CronSaveClick(Sender: TObject);
    procedure DeletePresetClick(Sender: TObject);
    procedure DeleteSessionClick(Sender: TObject);
    procedure EndpointRunClick(Sender: TObject);
    function EncodeIniText(const Value: string): string;
    procedure EnqueuePrompt;
    function ExtractAssistantDelta(const JsonText: string): string;
    function ExtractAssistantText(const JsonText: string): string;
    function ExtractSessionId(const JsonText: string): string;
    function ExtractSseDeltas(var Buffer: string; const ChunkText: string;
      out Done: Boolean; ToolDetails: TStrings = nil): string;
    procedure FetchEndpoint(const Key, Method, Endpoint, Body: string);
    procedure FileDetailCopyClick(Sender: TObject);
    procedure FilesBrowseClick(Sender: TObject);
    procedure FilesDownloadSelectedClick(Sender: TObject);
    procedure FilesHexFirstClick(Sender: TObject);
    procedure FilesHexLastClick(Sender: TObject);
    procedure FilesHexNextClick(Sender: TObject);
    procedure FilesHexPrevClick(Sender: TObject);
    procedure FilesListChange(Sender: TObject);
    procedure FilesOpenPath(const Path: string);
    procedure FilesPeekPath(const Path: string; Offset: Int64);
    procedure FilesPreviewImagePath(const Path: string);
    procedure FilesReadPath(const Path: string);
    procedure FilesRootClick(Sender: TObject);
    function FormatBytes(Value: Int64): string;
    function FormatConfigText(const JsonText: string): string;
    function FormatFilesReadText(const JsonText: string): string;
    function FormatFilesText(const JsonText: string): string;
    function FormatKbSearchText(const JsonText: string): string;
    function FormatKbSourcesText(const JsonText: string): string;
    function FormatMcpText(const JsonText: string): string;
    function FormatMcpRpcText(const JsonText: string): string;
    function FormatMemoryText(const JsonText: string): string;
    function FormatRelayStatusText(const JsonText: string): string;
    function FormatRelayTokenText(const JsonText: string): string;
    function FormatSkillsText(const JsonText: string): string;
    function FormatCheckpointText(const JsonText: string): string;
    function FormatCronText(const JsonText: string): string;
    function FormatMemoryProvisionText(const JsonText: string): string;
    function FormatModelsText(const JsonText: string): string;
    function FormatProviderText(const JsonText: string): string;
    function FormatStatusText(const JsonText: string): string;
    function FormatStatsText(const JsonText: string): string;
    function FormatWorkflowRunText(const JsonText: string): string;
    function FormatVaultDetailText(const JsonText: string): string;
    function FormatVaultSearchText(const JsonText: string): string;
    procedure FileDownloadClick(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: Char;
      Shift: TShiftState);
    procedure FormResize(Sender: TObject);
    function GatewayBaseUrl: string;
    function HandleSlashCommand(const Typed: string): Boolean;
    function HttpText(const BaseUrl, Token, SessionId, Method, Endpoint,
      Body, ContentType, Accept: string; out StatusCode: Integer): string;
    function HttpTextStreaming(const BaseUrl, Token, SessionId, Method,
      Endpoint, Body, ContentType, Accept: string; const OnChunk: TStreamChunkProc;
      out StatusCode: Integer): string;
    function HttpPostFile(const BaseUrl, Token, SessionId, Endpoint, FilePath,
      ContentType, Accept: string; out StatusCode: Integer): string;
    function IsHttpOk(StatusCode: Integer): Boolean;
    function JsonAsBool(Obj: TJSONObject; const Name: string): Boolean;
    function JsonAsInt64(Obj: TJSONObject; const Name: string): Int64;
    function JsonAsString(Obj: TJSONObject; const Name: string): string;
    procedure CheckFirstBootOnboarding;
    procedure KbUploadClick(Sender: TObject);
    procedure KbResultsChange(Sender: TObject);
    procedure KbResultOpenFileClick(Sender: TObject);
    procedure KbSearchClick(Sender: TObject);
    procedure KbSourcesChange(Sender: TObject);
    procedure KbSourcesLoadClick(Sender: TObject);
    procedure UpdateToolsToggleCaption;
    procedure LoadLocalSettings;
    procedure LoadStyleBooks;
    procedure LoadChatParams(const SessionId: string);
    procedure LoadModels;
    procedure LoadPromptPresets;
    procedure LoadSandboxStatus;
    procedure LoadSession(const SessionId: string);
    procedure LoadSessions;
    procedure LogsClearClick(Sender: TObject);
    procedure LogsClick(Sender: TObject);
    procedure MemorySetupLoadClick(Sender: TObject);
    procedure MemorySetupSaveClick(Sender: TObject);
    procedure MemoryModelChoiceChange(Sender: TObject);
    procedure MemoryFactAddClick(Sender: TObject);
    procedure MemoryFactDeleteClick(Sender: TObject);
    procedure MemoryFactsExportClick(Sender: TObject);
    procedure MemoryFactsLoadClick(Sender: TObject);
    procedure MemoryFileDetailCopyClick(Sender: TObject);
    procedure MemoryFilesLoadClick(Sender: TObject);
    procedure MemoryListChange(Sender: TObject);
    procedure MemorySearchClick(Sender: TObject);
    procedure ModeClick(Sender: TObject);
    procedure ModelComboChange(Sender: TObject);
    procedure McpRefreshClick(Sender: TObject);
    procedure McpSchemaApplyClick(Sender: TObject);
    procedure McpServerClearClick(Sender: TObject);
    procedure McpServerLoadFromJson(const JsonText: string);
    procedure McpResultCopyClick(Sender: TObject);
    procedure McpResultSelect(Sender: TObject);
    procedure McpRenderInvokeResult(const JsonText: string; Status: Integer);
    procedure McpServerRemoveClick(Sender: TObject);
    procedure McpServerSaveClick(Sender: TObject);
    procedure McpToolChange(Sender: TObject);
    procedure McpToolInvokeClick(Sender: TObject);
    procedure McpToolsClick(Sender: TObject);
    procedure NavButtonClick(Sender: TObject);
    procedure NavComboChange(Sender: TObject);
    procedure NewSessionClick(Sender: TObject);
    procedure OnboardingFinishClick(Sender: TObject);
    procedure OnboardingMemoryClick(Sender: TObject);
    procedure OnboardingProviderClick(Sender: TObject);
    procedure OnboardingSkipClick(Sender: TObject);
    procedure RenderOnboardingStep;
    procedure OnboardingShowClick(Sender: TObject);
    procedure ShowOnboarding;
    procedure ParamsToggleClick(Sender: TObject);
    function ParseSessionTurns(const JsonText: string): TArray<TChatTurn>;
    procedure PromptChange(Sender: TObject);
    procedure PromptKeyDown(Sender: TObject; var Key: Word; var KeyChar: Char;
      Shift: TShiftState);
    procedure PromptPresetChange(Sender: TObject);
    procedure ProviderCatalogClick(Sender: TObject);
    procedure ProviderComboChange(Sender: TObject);
    procedure ProviderSaveClick(Sender: TObject);
    procedure ProviderSecondaryComboChange(Sender: TObject);
    procedure QueueAssistantUpdate(const Text: string);
    procedure QueueLogAppend(const Text: string);
    procedure RefreshClick(Sender: TObject);
    procedure RelayRefreshClick(Sender: TObject);
    procedure RelayRenderSnippets(Sender: TObject);
    procedure RelaySnippetCopyClick(Sender: TObject);
    procedure RelayTimerTick(Sender: TObject);
    procedure RelayTokenClick(Sender: TObject);
    procedure RelayTokenToggleClick(Sender: TObject);
    procedure RelayWorkerListChange(Sender: TObject);
    procedure RelayWorkerProfileChange(Sender: TObject);
    procedure RelayWorkerConnectClick(Sender: TObject);
    procedure RelayWorkerDisconnectClick(Sender: TObject);
    function RelayWorkerRunning: Boolean;
    procedure RelayWorkerTimerTick(Sender: TObject);
    procedure RelayWorkerRefreshLog;
    procedure RelayWorkerUpdateControls(const StateText: string = '');
    procedure RenderAttachments;
    procedure RenderChat;
    procedure RenderModeButton;
    procedure RenderParamsButton;
    procedure ApplyHeaderRuleTheme;
    procedure ApplyOnboardingTheme;
    procedure ReapplyChromeTheme(Obj: TFmxObject);
    class procedure SetChromeRoles(Rect: TRectangle;
      FillRole, StrokeRole: Integer); static;
    procedure RenderConnectButton;
    procedure RenderToolsButton;
    procedure UpdateFooterVisibility;
    procedure SetIconButton(Button: TButton; const Lookup, HintText,
      FallbackCaption: string);
    function GatewayIdentity: string;
    procedure GatewaySettingsChange(Sender: TObject);
    procedure RenderSessionSearchBox;
    procedure SessionSearchToggleClick(Sender: TObject);
    procedure SessionSearchKeyDown(Sender: TObject; var Key: Word;
      var KeyChar: Char; Shift: TShiftState);
    procedure RenderQueue;
    procedure UpdateComposerState;
    procedure RenderSessionList;
    procedure ResetParamsClick(Sender: TObject);
    procedure SaveChatParams(const SessionId: string);
    procedure SaveLocalSettings;
    procedure SavePresetClick(Sender: TObject);
    procedure ChatCodeCopyClick(Sender: TObject);
    procedure SendClick(Sender: TObject);
    procedure SteerActiveTurn(const SteerText: string);
    procedure SessionExportClick(Sender: TObject);
    procedure SessionImportClick(Sender: TObject);
    procedure SessionImportDirClick(Sender: TObject);
    procedure SessionListChange(Sender: TObject);
    procedure SessionSearchChange(Sender: TObject);
    procedure SessionSplitterMoved(Sender: TObject);
    procedure BuildSchemaForm(AParent: TFmxObject; const SchemaText,
      ArgsText: string; InsideInput: Boolean = False);
    function CollectSchemaForm(AParent: TFmxObject;
      InsideInput: Boolean = False): TJSONObject;
    procedure SetControlMargins(Control: TControl; Left, Top, Right,
      Bottom: Single);
    procedure SetControlPadding(Control: TControl; Left, Top, Right,
      Bottom: Single);
    function AddCardListItem(AList: TListBox; const TitleText, DetailText,
      TagText: string; AHeight: Single; Accent: Boolean = False): TListBoxItem;
    procedure AddPanelChrome(Control: TControl; Alt: Boolean = False);
    function AddPaneSplitter(AParent: TFmxObject; AAlign: TAlignLayout): TSplitter;
    function AddSectionHeader(AParent: TFmxObject; const Text: string): TLabel;
    procedure AddListEmptyState(List: TListBox; const Msg: string);
    function AddFormRow(AParent: TFmxObject; const LabelText: string;
      Control: TControl; ControlWidth: Single = 0): TLayout;
    function BuildDetailPane(AParent: TFmxObject; out TitleLabel,
      MetaLabel: TLabel): TLayout;
    procedure StyleButton(Button: TButton; Primary: Boolean = False);
    procedure ApplyButtonIcon(Button: TButton);
    procedure ReadIconButtonsPreference;
    procedure ApplyChatMeasure;
    function StyleLookupExists(const LookupName: string): Boolean;
    procedure StyleChromeRect(Rect: TRectangle; FillColor: TAlphaColor;
      StrokeColor: TAlphaColor; Radius: Single; Interactive: Boolean);
    function ThemePaintColor(Color: TAlphaColor): TAlphaColor;
    function ThemePaintStroke(Color: TAlphaColor): TAlphaColor;
    function ActiveTabIs(const Caption: string): Boolean;
    procedure UpdateClearAttachmentsButton;
    function FriendlyAge(const StampText: string): string;
    class function IsIconified(Button: TButton): Boolean; static;
    procedure SetButtonWidth(Button: TButton; W: Single);
    procedure UseStyledLabelColor(LabelControl: TLabel);
    procedure StyleLabel(LabelControl: TLabel; Color: TAlphaColor;
      Size: Single; Bold: Boolean);
    procedure StyleTextControl(Control: TControl; Color: TAlphaColor;
      Size: Single);
    procedure RestyleCoreControls;
    procedure SetStatus(const Value: string);
    function SnapshotTurns: TArray<TChatTurn>;
    function SelectTabByText(const Caption: string): Boolean;
    procedure SelectSlashSuggestion(RunCommand: Boolean);
    procedure SendQueuedPrompt(const Prompt: string);
    procedure SlashCommandItemClick(Sender: TObject);
    procedure SkillsApproveClick(Sender: TObject);
    procedure SkillsInstallClick(Sender: TObject);
    procedure SkillsListChange(Sender: TObject);
    procedure SkillsRefreshClick(Sender: TObject);
    procedure SkillsRejectClick(Sender: TObject);
    procedure SkillsRemoveClick(Sender: TObject);
    procedure SkillsSearchClick(Sender: TObject);
    procedure TabControlChange(Sender: TObject);
    procedure TemperatureTrackChange(Sender: TObject);
    procedure ThemeClick(Sender: TObject);
    procedure TokenClearClick(Sender: TObject);
    procedure TokenToggleClick(Sender: TObject);
    procedure SetSidebarVisible(Value: Boolean; Persist: Boolean);
    procedure ToggleSessionsClick(Sender: TObject);
    procedure SyncTemperatureTrackFromEdit;
    procedure UpdateLastAssistantTurn(const Text: string);
    procedure UpdateLastAssistantToolDetails(const ToolDetails: string);
    procedure UpdateNavButtons;
    procedure UpdateParamsSummary;
    procedure UpdateSandboxLabelFromConfig(const JsonText: string);
    procedure UpdateSlashPalette;
    function UrlEncode(const Value: string): string;
    procedure VaultBuildWithClick(Sender: TObject);
    procedure VaultDetailCopyClick(Sender: TObject);
    procedure VaultListChange(Sender: TObject);
    procedure VaultSearchClick(Sender: TObject);
    procedure WorkflowAddEdgeClick(Sender: TObject);
    function WorkflowAddEdgeByIds(const FromId, ToId: string): Boolean;
    procedure WorkflowAddNodeClick(Sender: TObject);
    procedure WorkflowApplyInspectorClick(Sender: TObject);
    function WorkflowBuildSpec: string;
    procedure WorkflowDeleteClick(Sender: TObject);
    procedure WorkflowDeleteEdgeClick(Sender: TObject);
    procedure WorkflowDeleteNodeClick(Sender: TObject);
    procedure WorkflowEdgeSelect(Sender: TObject);
    procedure WorkflowLoadClick(Sender: TObject);
    procedure WorkflowLoadInspectorFromNode(const Tool, Args: string);
    procedure WorkflowLoadToolsClick(Sender: TObject);
    procedure WorkflowNewClick(Sender: TObject);
    procedure WorkflowNodeSelect(Sender: TObject);
    function WorkflowNodeIndexById(const NodeId: string): Integer;
    function WorkflowNodeIndexAtPoint(X, Y, CanvasWidth: Single;
      RequireInputPort: Boolean = False): Integer;
    procedure WorkflowCanvasMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    procedure WorkflowCanvasMouseMove(Sender: TObject; Shift: TShiftState; X,
      Y: Single);
    procedure WorkflowCanvasMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    procedure WorkflowCanvasPaint(Sender: TObject; Canvas: TCanvas);
    function WorkflowNodeHasEdge(const NodeId: string;
      Incoming: Boolean): Boolean;
    function WfToScreen(const P: TPointF): TPointF;
    function WfToLogical(const P: TPointF): TPointF;
    function WorkflowIORect(const Which: string;
      CanvasWidth, CanvasHeight: Single): TRectF;
    procedure WorkflowFitView;
    procedure WorkflowFitViewClick(Sender: TObject);
    procedure WorkflowDrawWire(Canvas: TCanvas; const A, B: TPointF;
      Opacity: Single);
    function WorkflowWireHit(const A, B: TPointF; X, Y: Single): Boolean;
    function WorkflowEdgeAtPoint(X, Y: Single; CanvasWidth: Single): Integer;
    function WfSnap(const P: TPointF): TPointF;
    procedure WorkflowShowPalette(const CanvasPt: TPointF);
    procedure WorkflowHidePalette;
    procedure WorkflowPaletteRefresh;
    procedure WorkflowPaletteFilterChange(Sender: TObject);
    procedure WorkflowPaletteAdd(const Tool: string);
    procedure WorkflowPaletteEditKeyDown(Sender: TObject; var Key: Word;
      var KeyChar: Char; Shift: TShiftState);
    procedure WorkflowPaletteItemClick(const Sender: TCustomListBox;
      const Item: TListBoxItem);
    procedure WorkflowDuplicateSelectedNode;
    function WorkflowPositionTaken(const P: TPointF): Boolean;
    procedure OpenFilesTabAt(const Path: string);
    function WorkflowCanvasNodeRect(Index: Integer; CanvasWidth: Single): TRectF;
    procedure WorkflowEnsureNodePosition(const NodeId: string; Index: Integer;
      CanvasWidth: Single);
    procedure WorkflowPickerChange(Sender: TObject);
    procedure WorkflowRenderGraph;
    procedure WorkflowRenderRunResult(const JsonText: string; Status: Integer);
    procedure WorkflowRunResultCopyClick(Sender: TObject);
    procedure WorkflowRunResultSelect(Sender: TObject);
    procedure WorkflowProviderModelClick(Sender: TObject);
    procedure WorkflowReplicatePickClick(Sender: TObject);
    procedure WorkflowReplicateSearchClick(Sender: TObject);
    procedure WorkflowRunClick(Sender: TObject);
    procedure WorkflowRunInputsClick(Sender: TObject);
    procedure WorkflowSaveClick(Sender: TObject);
    procedure WorkflowSetSpecFromJson(const JsonText: string);
    procedure WorkflowToolChange(Sender: TObject);
    procedure WorkflowUpdateNodeClick(Sender: TObject);
    procedure StatsRefreshClick(Sender: TObject);
    procedure StatsTimerTick(Sender: TObject);
    procedure WorkspaceExportClick(Sender: TObject);
    procedure WorkspaceImportClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  MasterDetailForm: TMasterDetailForm;

implementation

{$R *.fmx}

const
  DEFAULT_GATEWAY = 'http://127.0.0.1:8080';
  UI_ACCENT = $FF3BA7FF;
  UI_ACCENT_DIM = $FF1D3347;
  UI_BG = $FF111316;
  UI_BORDER = $FF2D333B;
  { A rule BETWEEN things, softer than a border AROUND something. Reusing
    UI_BORDER for separators is what made the header rule read as a hard
    line across the window. }
  UI_SEPARATOR = $FF23282F;
  UI_PANEL = $FF181B20;
  UI_PANEL_ALT = $FF20242B;
  UI_TEXT = $FFE6EAF0;
  UI_MUTED = $FF9AA4B2;
  UI_WARN = $FFE5B454;
  { Bullet glyph per nesting depth, so sub-lists read as sub-lists. }
  BULLET_GLYPHS: array[0..2] of string = (#$2022, #$25E6, #$25AA);
  { Workflow canvas: width of the derived INPUT/OUTPUT boxes and the left
    gutter auto-placed nodes start after, so a node never lands under the
    INPUT box (web UI parity). }
  { Sanity ceiling for a single chat row. Expanded tool sidecars can make a
    legitimate turn thousands of pixels tall; the old 2200 cap truncated the
    ROW while its children kept full height, so the surplus painted over the
    next bubbles. Only pathological content should ever reach this. }
  CHAT_ROW_MAX = 24000;
  { Square-ish footprint for an icon-only button. }
  ICON_BTN_W = 34;
  { the session-row rail: wide enough to read as a bubble at row scale }
  SESSION_GLYPH_W = 15;

  (* ---- METRIC TOKENS -------------------------------------------------
     A census of this file found eight font sizes, eleven values used as a
     "row" height, fourteen padding signatures and two competing gap units
     (6px at 97 sites, 8px at 78). None of that was decided; it accumulated.
     These are the only numbers the UI may use, and helpers below apply them
     so a new call site cannot invent a twelfth row height.
     Plan and census: docs/studio-metrics-plan.md *)

  { Type scale. Four sizes, and nothing sets Font.Size directly. }
  TXT_CAPTION = 10;   { meta lines, column headers, footnotes }
  TXT_BODY    = 11;   { the default for everything }
  TXT_TITLE   = 12;   { section headers and emphasised items }
  TXT_DISPLAY = 18;   { stats numerals only }

  { Spacing, on a 4px grid. The 6-vs-8 split is resolved in favour of 8:
    6 was never a deliberate choice, and one grid beats two. }
  GAP_XS = 4;
  GAP_S  = 8;
  GAP_M  = 12;
  GAP_L  = 16;

  { Vertical rhythm. The only heights a row may take. }
  ROW_BAR  = 36;      { toolbars and action rows }
  ROW_FORM = 32;      { a label + input pair }
  ROW_LIST = 40;      { single-line list item }
  ROW_CARD = 56;      { two-line list card }
  H_INPUT  = 28;      { edit/combo inside a ROW_FORM }
  ROW_TEXT = 22;      { one line of body text: labels, meta, footers }

  { The label column every form shares. Alignment is what makes a form read
    as designed rather than assembled, and it cannot happen while fifty
    edits each pick their own width. }
  FORM_LABEL_W = 110;

  { Button widths. Three, plus caption-measured for anything longer. }
  BTN_W_S = 64;
  BTN_W_M = 88;
  BTN_W_L = 104;

  { Path data for glyphs the code draws itself, generated alongside the
    button styles so a shape cannot differ between the two. }
{$I PasclawGlyphs.inc}
  (* Reading measure for the conversation column. Long lines are hard to
     track back to the next line's start, so chat UIs cap the column and
     centre it, letting extra width become margin instead of longer lines.
     720-820px is the accepted band (~80-100 characters at this size); 800
     sits in the middle of it and is close to A4 at 96dpi (794px). Below the
     cap the column simply fills the width, so narrow windows stay normal. *)
  CHAT_MAX_W = 800;
  { preferred side gutter for the chat column -- keeps text off the window
    frame even in full-width (drawer hidden) mode. Yields to CHAT_MIN_W on
    viewports too narrow for both. }
  CHAT_GUTTER = 24;
  CHAT_MIN_W = 320;
  { Fixed insets the transcript already carries before ApplyChatMeasure adds
    anything: TranscriptBody's side margin and FChatFlow's own padding. The
    composer is a sibling of TranscriptBody with neither, so its padding has
    to make up the difference or the two columns never line up. }
  CHAT_BODY_M = 10;
  CHAT_FLOW_PAD = 8;
  CHAT_TEXT_INSET = CHAT_BODY_M + CHAT_FLOW_PAD;
  { the "narrow window" breakpoint -- named because UpdateClearAttachments
    has to agree with ApplyResponsiveLayout about what narrow means }
  UI_NARROW_W = 560;
  (* StyleLookups that exist ONLY in the bundled Pasclaw style books. Every
     other name ApplyButtonIcon uses comes from Embarcadero's platform table,
     so it resolves against the platform style too; these have no platform
     equivalent and must not be trusted when no book is loaded.
     scripts/gen-studio-icons.py --check verifies this list against the
     generator's own CUSTOM set, so the two cannot drift. *)
  PASCLAW_ONLY_LOOKUPS: array[0..9] of string = (
    'collapsetoolbutton', 'expandtoolbutton', 'exporttoolbutton',
    'importtoolbutton', 'linkedtoolbutton', 'menutoolbutton',
    'moontoolbutton', 'sliderstoolbutton', 'suntoolbutton',
    'unlinkedtoolbutton');
  WF_IO_W = 104;
  WF_GUTTER = 128;
  { reserved position-dictionary ids for the movable INPUT/OUTPUT boxes --
    kept impossible as node ids (nodes are sanitised identifiers) }
  WF_ID_INPUT  = '__input__';
  WF_ID_OUTPUT = '__output__';
  WF_GRID = 24;              { canvas grid pitch; drops snap to it }
  { run-badge fills. Saturated status hues that read on BOTH palettes, so they
    bypass ThemePaintColor deliberately -- mapping them per-theme would mute
    the one signal that must stay loud. }
  WF_BADGE_OK  = $FF43B97F;
  WF_BADGE_ERR = $FFE0565A;
  WIN_CREATE_ALWAYS = 2;
  WIN_CREATE_NO_WINDOW = $08000000;
  WIN_FILE_ATTRIBUTE_NORMAL = $00000080;
  WIN_FILE_SHARE_READ = $00000001;
  WIN_GENERIC_WRITE = $40000000;
  WIN_STARTF_USESHOWWINDOW = $00000001;
  WIN_STARTF_USESTDHANDLES = $00000100;
  WIN_STILL_ACTIVE = 259;
  WIN_SW_HIDE = 0;

var
  (* Visual hierarchy, assigned per theme in ApplyTheme. These cannot be
     const: the ordering INVERTS between dark and light (chat text is the
     brightest thing on a dark ground and the darkest on a light one).

     The intent, in priority order:
       1. assistant chat text  -- the product; the brightest/highest contrast
       2. the user's turn      -- a bubble that reads as dialogue, not a log
       3. the composer         -- where you act next, so visibly live
       4. everything else      -- chrome, deliberately a step down
     Before this, chat body and every chrome label shared UI_TEXT at the same
     weight, so nothing in the palette said "this is content, that is
     furniture" -- which is what made the chat feel flat. *)
  UI_CHAT_TEXT: TAlphaColor    = $FFF4F7FB;   { 1 -- assistant body }
  UI_CHROME_TEXT: TAlphaColor  = $FFB9C2CE;   { 4 -- tabs, headers, faces }
  UI_USER_FILL: TAlphaColor    = $FF1B2430;   { 2 -- user bubble ground }
  UI_USER_BORDER: TAlphaColor  = $FF2F4560;
  UI_COMPOSER_FILL: TAlphaColor   = $FF1A1E24; { 3 -- composer }
  UI_COMPOSER_BORDER: TAlphaColor = $FF3BA7FF;

type
  TWinSecurityAttributes = record
    nLength: Cardinal;
    lpSecurityDescriptor: Pointer;
    bInheritHandle: LongBool;
  end;

  TWinStartupInfo = record
    cb: Cardinal;
    lpReserved: PChar;
    lpDesktop: PChar;
    lpTitle: PChar;
    dwX: Cardinal;
    dwY: Cardinal;
    dwXSize: Cardinal;
    dwYSize: Cardinal;
    dwXCountChars: Cardinal;
    dwYCountChars: Cardinal;
    dwFillAttribute: Cardinal;
    dwFlags: Cardinal;
    wShowWindow: Word;
    cbReserved2: Word;
    lpReserved2: Pointer;
    hStdInput: NativeUInt;
    hStdOutput: NativeUInt;
    hStdError: NativeUInt;
  end;

  TWinProcessInformation = record
    hProcess: NativeUInt;
    hThread: NativeUInt;
    dwProcessId: Cardinal;
    dwThreadId: Cardinal;
  end;

function WinCloseHandle(hObject: NativeUInt): LongBool; stdcall;
  external 'kernel32.dll' name 'CloseHandle';
function WinCreateFile(lpFileName: PChar; dwDesiredAccess, dwShareMode: Cardinal;
  lpSecurityAttributes: Pointer; dwCreationDisposition,
  dwFlagsAndAttributes: Cardinal; hTemplateFile: NativeUInt): NativeUInt; stdcall;
  external 'kernel32.dll' name 'CreateFileW';
function WinCreateProcess(lpApplicationName, lpCommandLine: PChar;
  lpProcessAttributes, lpThreadAttributes: Pointer; bInheritHandles: LongBool;
  dwCreationFlags: Cardinal; lpEnvironment: Pointer; lpCurrentDirectory: PChar;
  var lpStartupInfo: TWinStartupInfo;
  var lpProcessInformation: TWinProcessInformation): LongBool; stdcall;
  external 'kernel32.dll' name 'CreateProcessW';
function WinGetCurrentProcessId: Cardinal; stdcall;
  external 'kernel32.dll' name 'GetCurrentProcessId';
function WinGetExitCodeProcess(hProcess: NativeUInt;
  var lpExitCode: Cardinal): LongBool; stdcall;
  external 'kernel32.dll' name 'GetExitCodeProcess';
function WinGetLastError: Cardinal; stdcall;
  external 'kernel32.dll' name 'GetLastError';
function WinGetTickCount64: UInt64; stdcall;
  external 'kernel32.dll' name 'GetTickCount64';
function WinTerminateProcess(hProcess: NativeUInt; uExitCode: Cardinal): LongBool;
  stdcall; external 'kernel32.dll' name 'TerminateProcess';
function WinWaitForSingleObject(hHandle: NativeUInt;
  dwMilliseconds: Cardinal): Cardinal; stdcall;
  external 'kernel32.dll' name 'WaitForSingleObject';

function NewJsonBool(Value: Boolean): TJSONValue;
begin
  if Value then
    Result := TJSONTrue.Create
  else
    Result := TJSONFalse.Create;
end;

procedure AddJsonBool(Obj: TJSONObject; const Name: string; Value: Boolean);
begin
  Obj.AddPair(Name, NewJsonBool(Value));
end;

function CloneJsonValue(Value: TJSONValue): TJSONValue;
begin
  Result := nil;
  if Value <> nil then
    Result := TJSONObject.ParseJSONValue(Value.ToJSON);
end;

function ComboSelectedText(Combo: TComboBox): string;
begin
  Result := '';
  if (Combo <> nil) and (Combo.ItemIndex >= 0) and
    (Combo.ItemIndex < Combo.Items.Count) then
    Result := Combo.Items[Combo.ItemIndex];
end;

function IsPreviewImagePath(const Path: string): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(Path));
  Result := (Ext = '.png') or (Ext = '.jpg') or (Ext = '.jpeg') or
    (Ext = '.bmp') or (Ext = '.gif');
end;

function LooksBinaryText(const Text: string): Boolean;
var
  CtrlCount: Integer;
  I: Integer;
  N: Integer;
  Value: Integer;
begin
  if Pos(#0, Text) > 0 then
    Exit(True);
  N := Min(Length(Text), 4096);
  CtrlCount := 0;
  for I := 1 to N do
  begin
    Value := Ord(Text[I]);
    if (Value < 9) or ((Value > 13) and (Value < 32)) then
      Inc(CtrlCount);
  end;
  Result := (N > 0) and (CtrlCount / N > 0.15);
end;

function SchemaFormHasFields(AParent: TFmxObject): Boolean;
var
  Child: TFmxObject;
  I: Integer;
begin
  Result := False;
  if AParent = nil then
    Exit;
  for I := 0 to AParent.ChildrenCount - 1 do
  begin
    Child := AParent.Children[I];
    if (Child is TControl) and (TControl(Child).TagString <> '') then
      Exit(True);
    if SchemaFormHasFields(Child) then
      Exit(True);
  end;
end;

procedure ReplaceJsonString(Obj: TJSONObject; const Name, Value: string);
var
  Pair: TJSONPair;
begin
  Pair := Obj.RemovePair(Name);
  Pair.Free;
  Obj.AddPair(Name, Value);
end;

procedure ReplaceJsonBool(Obj: TJSONObject; const Name: string; Value: Boolean);
var
  Pair: TJSONPair;
begin
  Pair := Obj.RemovePair(Name);
  Pair.Free;
  Obj.AddPair(Name, NewJsonBool(Value));
end;

procedure ReplaceJsonValue(Obj: TJSONObject; const Name: string;
  Value: TJSONValue);
var
  Pair: TJSONPair;
begin
  Pair := Obj.RemovePair(Name);
  Pair.Free;
  Obj.AddPair(Name, Value);
end;

function WorkflowTextId(const Text: string): string;
var
  P: Integer;
begin
  P := Pos(' | ', Text);
  if P > 0 then
    Result := Copy(Text, 1, P - 1)
  else
    Result := Text;
end;

function WorkflowTextTool(const Text: string): string;
var
  P: Integer;
begin
  P := Pos(' | ', Text);
  if P > 0 then
    Result := Copy(Text, P + 3, MaxInt)
  else
    Result := '';
end;

function MemoryModelValue(const Text: string): string;
var
  P: Integer;
begin
  Result := Trim(Text);
  P := Pos(' (', Result);
  if P > 0 then
    Result := Trim(Copy(Result, 1, P - 1));
end;

function FsParentPath(const Path: string): string;
begin
  Result := ExcludeTrailingPathDelimiter(Path);
  Result := ExtractFileDir(Result);
end;

function FsJoinPath(const Base, Name: string): string;
begin
  if Base = '' then
    Result := Name
  else
    Result := System.IOUtils.TPath.Combine(Base, Name);
end;

function FsFileName(const Path: string): string;
var
  P: Integer;
  SafePath: string;
begin
  SafePath := ExcludeTrailingPathDelimiter(Path);
  P := LastDelimiter('/\', SafePath);
  if P > 0 then
    Result := Copy(SafePath, P + 1, MaxInt)
  else
    Result := SafePath;
  if Result = '' then
    Result := 'pasclaw-file.bin';
end;

function JsonPretty(Value: TJSONValue): string;
begin
  Result := '';
  if Value <> nil then
    Result := Value.ToJSON;
end;

function HtmlFragmentToText(const Html: string): string;
var
  C: Char;
  InTag: Boolean;
  S: string;
begin
  S := Html;
  S := StringReplace(S, '<br>', sLineBreak, [rfReplaceAll, rfIgnoreCase]);
  S := StringReplace(S, '<br/>', sLineBreak, [rfReplaceAll, rfIgnoreCase]);
  S := StringReplace(S, '<br />', sLineBreak, [rfReplaceAll, rfIgnoreCase]);
  S := StringReplace(S, '</pre>', sLineBreak, [rfReplaceAll, rfIgnoreCase]);
  S := StringReplace(S, '</div>', sLineBreak, [rfReplaceAll, rfIgnoreCase]);
  S := StringReplace(S, '</summary>', sLineBreak, [rfReplaceAll, rfIgnoreCase]);

  Result := '';
  InTag := False;
  for C in S do
  begin
    if C = '<' then
    begin
      InTag := True;
      Continue;
    end;
    if C = '>' then
    begin
      InTag := False;
      Continue;
    end;
    if not InTag then
      Result := Result + C;
  end;
  Result := TNetEncoding.HTML.Decode(Result);
  Result := Trim(Result);
end;

function ToolCardText(const Html: string; Expanded: Boolean): string;
var
  Body: string;
  CallText: string;
  HeaderClose: Integer;
  HeaderStart: Integer;
  LabelClose: Integer;
  LabelStart: Integer;
  P: Integer;
  PreClose: Integer;
  PreStart: Integer;
  Text: TStringBuilder;
begin
  CallText := '';
  P := Pos('class="tc-call"', Html);
  if P > 0 then
  begin
    P := PosEx('>', Html, P);
    HeaderClose := PosEx('</span>', Html, P + 1);
    if (P > 0) and (HeaderClose > P) then
      CallText := HtmlFragmentToText(Copy(Html, P + 1, HeaderClose - P - 1));
  end;
  if CallText = '' then
    CallText := 'tool call';

  Text := TStringBuilder.Create;
  try
    if Pos('tool-card err', Html) > 0 then
      Text.AppendLine('Tool Call: ' + CallText + '  [error]')
    else
      Text.AppendLine('Tool Call: ' + CallText);
    Text.AppendLine(StringOfChar('-', Length('Tool Call: ' + CallText)));
    if not Expanded then
      Exit(Trim(Text.ToString));

    P := 1;
    while True do
    begin
      PreStart := PosEx('<pre>', Html, P);
      if PreStart = 0 then
        Break;
      PreClose := PosEx('</pre>', Html, PreStart + 5);
      if PreClose = 0 then
        Break;

      HeaderStart := PosEx('class="tc-h"', Html, P);
      Body := '';
      if (HeaderStart > 0) and (HeaderStart < PreStart) then
      begin
        LabelStart := PosEx('>', Html, HeaderStart);
        LabelClose := PosEx('</div>', Html, LabelStart + 1);
        if (LabelStart > 0) and (LabelClose > LabelStart) and
          (LabelClose < PreStart) then
          Body := HtmlFragmentToText(Copy(Html, LabelStart + 1,
            LabelClose - LabelStart - 1));
      end;
      if Body <> '' then
      begin
        Text.AppendLine;
        Text.AppendLine(UpperCase(Body));
      end;
      Text.AppendLine(HtmlFragmentToText(Copy(Html, PreStart + 5,
        PreClose - PreStart - 5)));
      P := PreClose + Length('</pre>');
    end;

    if P = 1 then
    begin
      Body := HtmlFragmentToText(Html);
      if Body <> '' then
        Text.AppendLine(Body);
    end;
    Result := Trim(Text.ToString);
  finally
    Text.Free;
  end;
end;

function FormatChatDisplayText(const Value: string; ExpandedTools: Boolean = True): string;
var
  Card: string;
  P: Integer;
  Q: Integer;
  Start: Integer;
  Text: TStringBuilder;
begin
  if Pos('<details class="tool-card', Value) = 0 then
    Exit(Value);

  Text := TStringBuilder.Create;
  try
    Start := 1;
    while True do
    begin
      P := PosEx('<details class="tool-card', Value, Start);
      if P = 0 then
        Break;
      if P > Start then
        Text.Append(HtmlFragmentToText(Copy(Value, Start, P - Start)));
      Q := PosEx('</details>', Value, P);
      if Q = 0 then
        Break;
      Card := Copy(Value, P, Q + Length('</details>') - P);
      if Text.Length > 0 then
        Text.AppendLine;
      Text.AppendLine(ToolCardText(Card, ExpandedTools));
      Start := Q + Length('</details>');
    end;
    if Start <= Length(Value) then
    begin
      if Text.Length > 0 then
        Text.AppendLine;
      Text.Append(HtmlFragmentToText(Copy(Value, Start, MaxInt)));
    end;
    Result := Trim(Text.ToString);
  finally
    Text.Free;
  end;
end;

function MarkdownNeedsBlockRenderer(const Text: string): Boolean;
{ True when a body contains any construct AddBodyTextBlock / RenderBodyBlocks
  can lay out. Scans lines with the same rules the renderer applies, instead
  of sniffing a hand-listed set of substrings -- an inline predicate drifts
  out of sync with the parser the moment a new block type is added (which is
  exactly what happened: #### / + items / "2." / "1)" / *** rules parsed but
  never reached the block renderer). }
var
  I: Integer;
  LineText: string;
  Lines: TArray<string>;
  Body: string;
  K: Integer;
  Digits: Integer;

  function OnlyRuleChars(const Value, Ch: string): Boolean;
  begin
    Result := (Value <> '') and
      (StringReplace(Value, Ch, '', [rfReplaceAll]) = '');
  end;

begin
  Result := False;
  if Text = '' then
    Exit;
  { inline constructs anywhere in the body }
  if (Pos('`', Text) > 0) or (Pos('](', Text) > 0) or
    (Pos('**', Text) > 0) or (Pos('~~', Text) > 0) then
    Exit(True);

  Lines := Text.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
  for I := 0 to Length(Lines) - 1 do
  begin
    LineText := Trim(Lines[I]);
    if LineText = '' then
      Continue;
    { headings (any level), bullets (-, *, +), blockquotes, table rows }
    if StartsText('# ', LineText) or StartsText('## ', LineText) or
      StartsText('### ', LineText) or StartsText('#### ', LineText) or
      StartsText('- ', LineText) or StartsText('* ', LineText) or
      StartsText('+ ', LineText) or StartsText('>', LineText) or
      (Pos('|', LineText) > 0) then
      Exit(True);
    { horizontal rules: --- / *** / ___ }
    Body := StringReplace(LineText, ' ', '', [rfReplaceAll]);
    if (Length(Body) >= 3) and (OnlyRuleChars(Body, '-') or
      OnlyRuleChars(Body, '*') or OnlyRuleChars(Body, '_')) then
      Exit(True);
    { ordered items: any number, '.' or ')' }
    Digits := 0;
    K := 1;
    while (K <= Length(LineText)) and CharInSet(LineText[K], ['0'..'9']) do
    begin
      Inc(K);
      Inc(Digits);
    end;
    if (Digits > 0) and (K + 1 <= Length(LineText)) and
      CharInSet(LineText[K], ['.', ')']) and (LineText[K + 1] = ' ') then
      Exit(True);
  end;
end;

function RawToolDetailsToJson(Items: TStrings): string;
var
  Arr: TJSONArray;
  I: Integer;
  Value: TJSONValue;
begin
  Result := '';
  if (Items = nil) or (Items.Count = 0) then
    Exit;
  Arr := TJSONArray.Create;
  try
    for I := 0 to Items.Count - 1 do
    begin
      Value := TJSONObject.ParseJSONValue(Items[I]);
      if Value <> nil then
        Arr.AddElement(Value);
    end;
    if Arr.Count > 0 then
      Result := Arr.ToJSON;
  finally
    Arr.Free;
  end;
end;

function JsonEditorKind(Value: TJSONValue): string;
begin
  if Value is TJSONObject then
    Result := 'object'
  else if Value is TJSONArray then
    Result := 'array'
  else if Value is TJSONNumber then
    Result := 'number'
  else if (Value is TJSONTrue) or (Value is TJSONFalse) then
    Result := 'boolean'
  else if Value is TJSONNull then
    Result := 'null'
  else
    Result := 'string';
end;

function JsonEditorPreview(Value: TJSONValue): string;
begin
  Result := '';
  if Value = nil then
    Exit;
  if (Value is TJSONObject) or (Value is TJSONArray) then
    Result := JsonEditorKind(Value)
  else
    Result := Value.Value;
  if Length(Result) > 80 then
    Result := Copy(Result, 1, 77) + '...';
end;

function JsonValueFromEditorText(const Raw, ExistingKind: string): TJSONValue;
var
  N: Double;
  S: string;
begin
  S := Trim(Raw);
  Result := nil;
  if SameText(ExistingKind, 'string') then
    Exit(TJSONString.Create(Raw));
  if SameText(ExistingKind, 'boolean') then
    Exit(NewJsonBool(SameText(S, 'true') or SameText(S, 'yes') or (S = '1')));
  if SameText(ExistingKind, 'null') and (S = '') then
    Exit(TJSONNull.Create);
  if SameText(ExistingKind, 'number') then
  begin
    if TryStrToFloat(S, N) then
      Exit(TJSONNumber.Create(N));
  end;
  if S <> '' then
    Result := TJSONObject.ParseJSONValue(S);
  if Result = nil then
    Result := TJSONString.Create(Raw);
end;

function HexDumpText(const Bytes: TBytes; BaseOffset: Int64): string;
var
  Ascii: string;
  Hex: string;
  I: Integer;
  J: Integer;
  Text: TStringBuilder;
begin
  Text := TStringBuilder.Create;
  try
    I := 0;
    while I < Length(Bytes) do
    begin
      Hex := '';
      Ascii := '';
      for J := 0 to 15 do
      begin
        if I + J < Length(Bytes) then
        begin
          Hex := Hex + IntToHex(Bytes[I + J], 2) + ' ';
          if (Bytes[I + J] >= 32) and (Bytes[I + J] <= 126) then
            Ascii := Ascii + Char(Bytes[I + J])
          else
            Ascii := Ascii + '.';
        end
        else
          Hex := Hex + '   ';
        if J = 7 then
          Hex := Hex + ' ';
      end;
      Text.AppendLine(IntToHex(BaseOffset + I, 8) + '  ' + Hex + ' |' +
        Ascii + '|');
      Inc(I, 16);
    end;
    Result := Text.ToString;
  finally
    Text.Free;
  end;
end;

function WorkflowDefaultArgs(const Tool: string): string;
begin
  if SameText(Tool, 'llm') then
    Result := '{' + sLineBreak +
      '  "provider": "",' + sLineBreak +
      '  "model": "",' + sLineBreak +
      '  "prompt": "{{inputs.prompt}}"' + sLineBreak +
      '}'
  else if SameText(Tool, 'replicate') then
    Result := '{' + sLineBreak +
      '  "version": "",' + sLineBreak +
      '  "input": { "prompt": "{{inputs.prompt}}" }' + sLineBreak +
      '}'
  else
    Result := '{}';
end;

function QuoteProcessArg(const Value: string): string;
var
  S: string;
begin
  if Value = '' then
    Exit('""');
  S := StringReplace(Value, '"', '\"', [rfReplaceAll]);
  if (Pos(' ', S) > 0) or (Pos(#9, S) > 0) or (Pos('"', Value) > 0) then
    Result := '"' + S + '"'
  else
    Result := S;
end;

function ChatParamsSection(const SessionId: string): string;
var
  SafeId: string;
begin
  if SessionId = '' then
    Exit('chat_params.__last__');
  SafeId := StringReplace(SessionId, ']', '_', [rfReplaceAll]);
  Result := 'chat_params.' + SafeId;
end;

constructor TMasterDetailForm.Create(AOwner: TComponent);
begin
  inherited;
  Caption := 'PasClaw Studio';
  Width := 1180;
  Height := 760;

  FMode := 'build';
  { without this, TControl.Hint/ShowHint are inert -- the form gates hint
    display for every control on it }
  ShowHint := True;
  FSidebarVisible := True;
  FSessionDrawerWidth := 280;
  FChatParamsVisible := False;
  FChatToolsExpanded := False;
  FIconButtons := True;
  FDarkStyleEnabled := True;
  FFileHexPageSize := 16384;
  FRelayWorkerProcessHandle := 0;
  FRelayWorkerProcessId := 0;
  FConfigFile := System.IOUtils.TPath.Combine(
    System.IOUtils.TPath.GetDocumentsPath, 'pasclaw-studio.ini');
  { icon_buttons must be known BEFORE the interface is built: the styling
    walk blanks captions for icon-only buttons as it goes, and once a caption
    is gone ApplyButtonIcon cannot re-derive the mapping from it -- so a
    preference read afterwards (LoadLocalSettings) could switch icons off for
    future controls only, never restoring the ones already blanked. This is
    the sole setting consumed while the UI is being created; the rest load
    normally once it exists. }
  ReadIconButtonsPreference;
  FAttachments := TList<TChatAttachment>.Create;
  FQueuedPrompts := TQueue<string>.Create;
  FEndpointBodyMemos := TDictionary<string, TMemo>.Create;
  FEndpointEdits := TDictionary<string, TEdit>.Create;
  FEndpointMethodCombos := TDictionary<string, TComboBox>.Create;
  FPaneMemos := TDictionary<string, TMemo>.Create;
  FNavButtons := TDictionary<string, TButton>.Create;
  FSessionCache := TList<TPasClawSession>.Create;
  FTurns := TList<TChatTurn>.Create;
  FWorkflowNodePositions := TDictionary<string, TPointF>.Create;
  FWorkflowRunNodeOk := TDictionary<string, Boolean>.Create;
  FWorkflowRunNodePreview := TDictionary<string, string>.Create;
  FWorkflowToolSchemas := TDictionary<string, string>.Create;
  FStyleLookupCache := TDictionary<string, Boolean>.Create;
  FStyleBookTexts := TDictionary<TStyleBook, string>.Create;

  LoadStyleBooks;
  BuildInterface;
  { LoadStyleBooks' ApplyTheme runs BEFORE the UI exists, and the one inside
    BuildInterface fires partway through it, so neither walk reaches most
    controls. Re-apply once the full tree is built -- this is what actually
    styles the tabs' buttons (and now assigns their icons + hints). }
  ApplyTheme;
  LoadLocalSettings;
  RestyleCoreControls;
  RenderModeButton;
  { layout BEFORE the first render: LoadLocalSettings may have restored a
    hidden sidebar, and bubbles bake their width in at render time -- drawing
    them against the pre-layout measure would leave them stale }
  ApplyResponsiveLayout;
  RenderChat;
  RefreshClick(nil);
end;

destructor TMasterDetailForm.Destroy;
begin
  if FRelayWorkerTimer <> nil then
    FRelayWorkerTimer.Enabled := False;
  if FRelayWorkerProcessHandle <> 0 then
  begin
    if RelayWorkerRunning then
      WinTerminateProcess(FRelayWorkerProcessHandle, 0);
    WinCloseHandle(FRelayWorkerProcessHandle);
    FRelayWorkerProcessHandle := 0;
  end;
  SaveLocalSettings;
  FQueuedPrompts.Free;
  FAttachments.Free;
  FTurns.Free;
  FSessionCache.Free;
  FWorkflowNodePositions.Free;
  FWorkflowRunNodeOk.Free;
  FWorkflowRunNodePreview.Free;
  FWorkflowToolSchemas.Free;
  FStyleLookupCache.Free;
  FStyleBookTexts.Free;
  FNavButtons.Free;
  FPaneMemos.Free;
  FEndpointMethodCombos.Free;
  FEndpointEdits.Free;
  FEndpointBodyMemos.Free;
  inherited;
end;

procedure TMasterDetailForm.LoadStyleBooks;
var
  ExeDir: string;

  function LoadStyleBook(const FileName: string): TStyleBook;
  var
    Candidate: string;
    Candidates: TArray<string>;
  begin
    Result := nil;
    Candidates := [
      System.IOUtils.TPath.Combine(GetCurrentDir, FileName),
      System.IOUtils.TPath.Combine(ExeDir, FileName),
      System.IOUtils.TPath.GetFullPath(System.IOUtils.TPath.Combine(
        System.IOUtils.TPath.Combine(ExeDir, '..'),
        System.IOUtils.TPath.Combine('..', FileName)))
    ];

    for Candidate in Candidates do
      if TFile.Exists(Candidate) then
      begin
        Result := TStyleBook.Create(Self);
        try
          Result.LoadFromFile(Candidate);
          { keep the source text: StyleLookupExists probes it when the built
            style graph is not available to walk }
          FStyleBookTexts.AddOrSetValue(Result, TFile.ReadAllText(Candidate));
          Exit;
        except
          FreeAndNil(Result);
        end;
      end;
  end;

begin
  ExeDir := System.IOUtils.TPath.GetDirectoryName(ParamStr(0));
  FStyleBook := LoadStyleBook('PasclawDark.style');
  FLightStyleBook := LoadStyleBook('PasclawLight.style');
  ApplyTheme;
end;

procedure TMasterDetailForm.ApplyTheme;
begin
  { Hierarchy tokens first -- the walk below repaints with whatever these
    hold. Dark: chat text brightest, chrome stepped down. Light: inverted,
    chat text darkest and chrome greyed. }
  if FDarkStyleEnabled then
  begin
    UI_CHAT_TEXT       := $FFF4F7FB;
    UI_CHROME_TEXT     := $FFB9C2CE;
    UI_USER_FILL       := $FF1B2430;
    UI_USER_BORDER     := $FF2F4560;
    UI_COMPOSER_FILL   := $FF1A1E24;
    UI_COMPOSER_BORDER := $FF3BA7FF;
  end
  else
  begin
    UI_CHAT_TEXT       := $FF171615;
    UI_CHROME_TEXT     := $FF6F6B62;
    UI_USER_FILL       := $FFF2F0EC;
    UI_USER_BORDER     := $FFC3D5EA;
    UI_COMPOSER_FILL   := $FFF9F8F6;
    UI_COMPOSER_BORDER := $FF6E9ACC;
  end;

  if FDarkStyleEnabled then
    StyleBook := FStyleBook
  else if FLightStyleBook <> nil then
    StyleBook := FLightStyleBook
  else
    StyleBook := nil;

  if FThemeButton <> nil then
  begin
    FThemeButton.Enabled := (FStyleBook <> nil) or (FLightStyleBook <> nil);
    if FDarkStyleEnabled then
      FThemeButton.Text := 'Light'
    else
      FThemeButton.Text := 'Dark';
  end;
  { raw brushes are invisible to the restyle walk, so the theme pass has to
    repaint them by name }
  ApplyHeaderRuleTheme;
  ApplyOnboardingTheme;
  ReapplyChromeTheme(Self);
end;

procedure TMasterDetailForm.ThemeClick(Sender: TObject);
begin
  FDarkStyleEnabled := not FDarkStyleEnabled;
  ApplyTheme;                { palette globals + StyleBook swap only }
  SaveLocalSettings;
  { RestyleCoreControls is REQUIRED here -- ApplyTheme does not call it, and
    it is the only thing that repaints controls carrying an explicit colour
    (FPromptMemo would keep the dark theme's near-white ink on the light
    composer; none of the renders below touch it).

    All four run deferred: they free and rebuild hundreds of controls, and
    doing that while this button's own click event is still on the stack, in
    the middle of FMX's style-swap cascade, is the same hazard the walk
    itself had. Let the frame finish, then restyle, then re-render. }
  TThread.ForceQueue(nil,
    procedure
    begin
      RestyleCoreControls;
      RenderChat;
      RenderAttachments;
      RenderSessionList;
    end);
  if FDarkStyleEnabled then
    SetStatus('dark style enabled')
  else if FLightStyleBook <> nil then
    SetStatus('light style enabled')
  else
    SetStatus('default style enabled');
end;

procedure TMasterDetailForm.TokenToggleClick(Sender: TObject);
begin
  if FTokenEdit = nil then
    Exit;
  FTokenEdit.Password := not FTokenEdit.Password;
  if FTokenShowButton <> nil then
    if FTokenEdit.Password then
      FTokenShowButton.Text := 'Show'
    else
      FTokenShowButton.Text := 'Hide';
end;

procedure TMasterDetailForm.TokenClearClick(Sender: TObject);
begin
  if FTokenEdit <> nil then
    FTokenEdit.Text := '';
  SaveLocalSettings;
  SetStatus('gateway token cleared');
end;

procedure TMasterDetailForm.SetControlMargins(Control: TControl; Left, Top,
  Right, Bottom: Single);
begin
  Control.Margins.Left := Left;
  Control.Margins.Top := Top;
  Control.Margins.Right := Right;
  Control.Margins.Bottom := Bottom;
end;

procedure TMasterDetailForm.SetControlPadding(Control: TControl; Left, Top,
  Right, Bottom: Single);
begin
  Control.Padding.Left := Left;
  Control.Padding.Top := Top;
  Control.Padding.Right := Right;
  Control.Padding.Bottom := Bottom;
end;

function TMasterDetailForm.AddCardListItem(AList: TListBox; const TitleText,
  DetailText, TagText: string; AHeight: Single; Accent: Boolean): TListBoxItem;
var
  Card: TRectangle;
  DetailLabel: TLabel;
  FillColor: TAlphaColor;
  TitleLabel: TLabel;
begin
  Result := TListBoxItem.Create(AList);
  Result.Parent := AList;
  Result.Text := '';
  Result.TagString := TagText;
  Result.Height := AHeight;
  Result.HitTest := True;
  Result.OnClick := CardListItemClick;

  FillColor := UI_PANEL_ALT;
  if Accent then
    FillColor := UI_ACCENT_DIM;

  Card := TRectangle.Create(Result);
  Card.Parent := Result;
  Card.Align := TAlignLayout.Client;
  SetControlMargins(Card, GAP_XS, 3, GAP_XS, 3);
  StyleChromeRect(Card, FillColor, UI_BORDER, 6, True);
  Card.OnClick := CardListItemClick;
  if not Accent then
    Card.Fill.Kind := TBrushKind.None;

  TitleLabel := TLabel.Create(Card);
  TitleLabel.Parent := Card;
  TitleLabel.Align := TAlignLayout.Top;
  TitleLabel.Height := ROW_TEXT;
  TitleLabel.HitTest := False;
  TitleLabel.Text := TitleText;
  TitleLabel.TextSettings.VertAlign := TTextAlign.Center;
  SetControlMargins(TitleLabel, 10, GAP_S, 10, 0);
  { regular weight: a list where every title is bold has no emphasis at all }
  StyleLabel(TitleLabel, UI_TEXT, TXT_TITLE, False);

  DetailLabel := TLabel.Create(Card);
  DetailLabel.Parent := Card;
  DetailLabel.Align := TAlignLayout.Client;
  DetailLabel.HitTest := False;
  DetailLabel.WordWrap := True;
  DetailLabel.Text := DetailText;
  SetControlMargins(DetailLabel, 10, 0, 10, GAP_S);
  StyleLabel(DetailLabel, UI_MUTED, TXT_BODY, False);
end;

procedure TMasterDetailForm.CardListItemClick(Sender: TObject);
var
  Node: TFmxObject;
  Item: TListBoxItem;
  List: TListBox;
begin
  if not (Sender is TFmxObject) then
    Exit;

  Node := TFmxObject(Sender);
  while (Node <> nil) and not (Node is TListBoxItem) do
    Node := Node.Parent;
  if not (Node is TListBoxItem) then
    Exit;
  Item := TListBoxItem(Node);

  Node := Item.Parent;
  while (Node <> nil) and not (Node is TListBox) do
    Node := Node.Parent;
  if not (Node is TListBox) then
    Exit;
  List := TListBox(Node);

  if List.ItemIndex <> Item.Index then
    List.ItemIndex := Item.Index
  else if Assigned(List.OnChange) then
    List.OnChange(List);
end;

procedure TMasterDetailForm.AddPanelChrome(Control: TControl; Alt: Boolean);
var
  Chrome: TRectangle;
begin
  if Control = nil then
    Exit;
  Chrome := TRectangle.Create(Self);
  Chrome.Parent := Control;
  { Contents, NOT Client. A background has to FRAME the panel, and Client
    makes it compete with its own siblings for space -- it takes whatever is
    left over after the Top-aligned rows and outlines THAT. On Settings /
    Gateway the visible result was an empty rounded box sitting under the
    form instead of a border around it. Contents fills the parent's content
    rect and takes part in no such negotiation. }
  Chrome.Align := TAlignLayout.Contents;
  if Alt then
    StyleChromeRect(Chrome, UI_PANEL_ALT, UI_BORDER, 6, False)
  else
    StyleChromeRect(Chrome, UI_PANEL, UI_BORDER, 6, False);
  Chrome.Fill.Kind := TBrushKind.None;
  Chrome.SendToBack;
end;

function TMasterDetailForm.AddPaneSplitter(AParent: TFmxObject;
  AAlign: TAlignLayout): TSplitter;
begin
  Result := TSplitter.Create(Self);
  Result.Parent := AParent;
  Result.Align := AAlign;
  Result.MinSize := 120;
  Result.ShowGrip := True;
  if AAlign in [TAlignLayout.Left, TAlignLayout.Right] then
    Result.Width := 8
  else
    Result.Height := 8;
end;

procedure TMasterDetailForm.AddListEmptyState(List: TListBox;
  const Msg: string);
{ The sessions-list treatment for every list: an empty list must say what
  belongs in it and how to get one, because a silent blank column reads as
  a loading failure. Call after a render pass that produced no rows. }
var
  Item: TListBoxItem;
  Cap: TLabel;
begin
  if (List = nil) or (List.Count > 0) then
    Exit;
  Item := TListBoxItem.Create(List);
  Item.Parent := List;
  Item.Text := '';
  Item.Height := ROW_CARD;
  Item.HitTest := False;
  Cap := TLabel.Create(Item);
  Cap.Parent := Item;
  Cap.Align := TAlignLayout.Client;
  Cap.HitTest := False;
  Cap.WordWrap := True;
  Cap.Text := Msg;
  SetControlMargins(Cap, 10, GAP_S, 10, GAP_S);
  StyleLabel(Cap, UI_MUTED, TXT_BODY, False);
end;

function TMasterDetailForm.AddFormRow(AParent: TFmxObject;
  const LabelText: string; Control: TControl;
  ControlWidth: Single): TLayout;
{ One label + one input, on the shared grid.

  Fifty edits in this file each picked their own width and sat next to a
  label of whatever length, which is why no form in the app lines up. The
  label column is fixed at FORM_LABEL_W and right-aligned, so labels meet
  their inputs on a common edge no matter how long the text is.

  ControlWidth = 0 means "fill the row", which is what most inputs want;
  pass a width only for things that genuinely have a natural size (a
  spin-ish number, a short code). }
var
  Cap: TLabel;
begin
  Result := TLayout.Create(Self);
  Result.Parent := AParent;
  Result.Align := TAlignLayout.Top;
  Result.Height := ROW_FORM;
  SetControlMargins(Result, 0, 0, 0, GAP_XS);

  Cap := TLabel.Create(Result);
  Cap.Parent := Result;
  Cap.Align := TAlignLayout.Left;
  Cap.Width := FORM_LABEL_W;
  Cap.Height := ROW_FORM;
  Cap.HitTest := False;
  Cap.Text := LabelText;
  Cap.TextSettings.HorzAlign := TTextAlign.Trailing;
  Cap.TextSettings.VertAlign := TTextAlign.Center;
  SetControlMargins(Cap, 0, 0, GAP_M, 0);
  StyleLabel(Cap, UI_CHROME_TEXT, TXT_BODY, False);

  if Control <> nil then
  begin
    Control.Parent := Result;
    if ControlWidth > 0 then
    begin
      Control.Align := TAlignLayout.Left;
      Control.Width := ControlWidth;
    end
    else
      Control.Align := TAlignLayout.Client;
    Control.Height := H_INPUT;
    { centre the input in the taller row rather than letting it stretch }
    SetControlMargins(Control, 0, (ROW_FORM - H_INPUT) / 2, 0,
      (ROW_FORM - H_INPUT) / 2);
  end;
end;

function TMasterDetailForm.BuildDetailPane(AParent: TFmxObject;
  out TitleLabel, MetaLabel: TLabel): TLayout;
{ Title + meta + a body area, replacing the ASCII-underlined memo views.

  Thirty-one places in this file drew a heading by printing '====' under it
  into a read-only memo. That is terminal output pretending to be a UI: it
  cannot use the type scale, cannot be selected as a heading, and wraps at
  the wrong places. The caller fills the returned labels and parents its
  body control to the result. }
begin
  Result := TLayout.Create(Self);
  Result.Parent := AParent;
  Result.Align := TAlignLayout.Client;

  TitleLabel := TLabel.Create(Result);
  TitleLabel.Parent := Result;
  TitleLabel.Align := TAlignLayout.Top;
  TitleLabel.Height := ROW_LIST - GAP_M;
  TitleLabel.HitTest := False;
  TitleLabel.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(TitleLabel, UI_TEXT, TXT_TITLE, True);

  MetaLabel := TLabel.Create(Result);
  MetaLabel.Parent := Result;
  MetaLabel.Align := TAlignLayout.Top;
  MetaLabel.Height := ROW_FORM - GAP_S;
  MetaLabel.HitTest := False;
  MetaLabel.TextSettings.VertAlign := TTextAlign.Center;
  SetControlMargins(MetaLabel, 0, 0, 0, GAP_S);
  StyleLabel(MetaLabel, UI_MUTED, TXT_CAPTION, False);
end;

function TMasterDetailForm.AddSectionHeader(AParent: TFmxObject;
  const Text: string): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := AParent;
  Result.Align := TAlignLayout.Top;
  Result.Height := ROW_TEXT;
  Result.Text := Text;
  Result.TextSettings.VertAlign := TTextAlign.Center;
  SetControlMargins(Result, 0, 0, 0, GAP_XS);
  { chrome ink, not accent: accent-blue bold headers on every tab were the
    loudest global habit in the app. The accent is reserved for the primary
    action and live state. }
  StyleLabel(Result, UI_CHROME_TEXT, TXT_BODY, True);
end;

{ Chrome roles, remembered ON the rect so the theme pass can re-apply them.

  StyleChromeRect resolves colours at CALL time, and almost every chrome rect
  is built once in BuildInterface -- which runs BEFORE LoadLocalSettings reads
  ui.dark_style. So every static rect baked in the DARK palette and no later
  theme change repainted it: RestyleCoreControls walks labels and controls,
  not TRectangle brushes. The composer showed this as a black slab the moment
  the Align fix made its rect actually cover its panel.

  The role lives in the rect's Tag rather than in a registry of pointers. A
  registry would have to hold rects that ARE freed and rebuilt per render --
  chat cards, schema forms -- and would dangle the first time one went away.
  Data carried on the object dies with the object. Tag is otherwise unused in
  this unit. }
const
  CHROME_TAG_MAGIC = $C40000;

function ChromeRoleOf(Color: TAlphaColor): Integer;
{ The per-theme VAR tokens are tested FIRST: they are the ones that change
  value between themes, so misclassifying them survives a switch.

  Ordering is a heuristic, not a proof: classification is by VALUE, and two
  tokens can be equal -- in the dark palette UI_COMPOSER_BORDER and
  UI_ACCENT are both $FF3BA7FF, so a colour alone cannot say which was
  meant. Any call site styling with a token that collides must state its
  roles explicitly via SetChromeRoles after styling; the composer does. }
begin
  if Color = UI_COMPOSER_FILL then Result := 7
  else if Color = UI_COMPOSER_BORDER then Result := 8
  else if Color = UI_USER_FILL then Result := 9
  else if Color = UI_USER_BORDER then Result := 10
  else if Color = UI_BG then Result := 1
  else if Color = UI_PANEL then Result := 2
  else if Color = UI_PANEL_ALT then Result := 3
  else if Color = UI_ACCENT_DIM then Result := 4
  else if Color = UI_BORDER then Result := 5
  else if Color = UI_ACCENT then Result := 6
  else Result := 0;              { not a themed role: left exactly as given }
end;

function ChromeColorOf(Role: Integer): TAlphaColor;
begin
  case Role of
    1: Result := UI_BG;
    2: Result := UI_PANEL;
    3: Result := UI_PANEL_ALT;
    4: Result := UI_ACCENT_DIM;
    5: Result := UI_BORDER;
    6: Result := UI_ACCENT;
    7: Result := UI_COMPOSER_FILL;
    8: Result := UI_COMPOSER_BORDER;
    9: Result := UI_USER_FILL;
   10: Result := UI_USER_BORDER;
  else
    Result := 0;
  end;
end;

procedure TMasterDetailForm.StyleChromeRect(Rect: TRectangle;
  FillColor: TAlphaColor; StrokeColor: TAlphaColor; Radius: Single;
  Interactive: Boolean);
  function ThemeFill(Color: TAlphaColor): TAlphaColor;
  begin
    Result := Color;
    if FDarkStyleEnabled then
      Exit;
    if Color = UI_BG then
      Result := $FFF6F5F2
    else if Color = UI_PANEL then
      Result := $FFF9F8F6
    else if Color = UI_PANEL_ALT then
      Result := $FFF4F2EF
    else if Color = UI_ACCENT_DIM then
      Result := $FFF1EEEA;
  end;
  function ThemeStroke(Color: TAlphaColor): TAlphaColor;
  begin
    Result := Color;
    if FDarkStyleEnabled then
      Exit;
    if Color = UI_BORDER then
      Result := $FFE4E1DA
    else if Color = UI_ACCENT_DIM then
      Result := $FFA8C2E0
    else if Color = UI_BG then
      Result := $FFF9F8F6;
  end;
begin
  if Rect = nil then
    Exit;
  { record what this rect MEANT, so ReapplyChromeTheme can redo it }
  SetChromeRoles(Rect, ChromeRoleOf(FillColor), ChromeRoleOf(StrokeColor));
  Rect.HitTest := Interactive;
  Rect.Fill.Color := ThemeFill(FillColor);
  Rect.Stroke.Color := ThemeStroke(StrokeColor);
  if (FillColor = UI_BG) or (FillColor = UI_PANEL) or
    (FillColor = UI_PANEL_ALT) then
    Rect.Fill.Kind := TBrushKind.None
  else
    Rect.Fill.Kind := TBrushKind.Solid;
  Rect.XRadius := Radius;
  Rect.YRadius := Radius;
end;

function TMasterDetailForm.ThemePaintColor(Color: TAlphaColor): TAlphaColor;
{ The light-theme twin of StyleChromeRect's ThemeFill/ThemeStroke, for code
  that paints RAW CANVAS instead of styling rectangles. The workflow graph
  drew every frame with the dark UI_* constants no matter the theme -- which
  is why its canvas stayed black in light mode: nothing on that path ever
  consulted FDarkStyleEnabled. Any direct Canvas.Fill/Stroke color that uses
  the palette constants must come through here. }
begin
  Result := Color;
  if FDarkStyleEnabled then
    Exit;
  if Color = UI_BG then
    Result := $FFF6F5F2
  else if Color = UI_PANEL then
    Result := $FFF9F8F6
  else if Color = UI_PANEL_ALT then
    Result := $FFF4F2EF
  else if Color = UI_ACCENT_DIM then
    Result := $FFE0E9F4
  else if Color = UI_BORDER then
    Result := $FFE4E1DA
  else if Color = UI_TEXT then
    Result := $FF171615
  else if Color = UI_MUTED then
    Result := $FF6F6B62
  else if Color = UI_ACCENT then
    { the light book's retoned accent -- a Pascal-drawn accent has to be the
      same blue as a styled one, or the two disagree on the same screen }
    Result := $FF3B6EA8
  else if Color = UI_SEPARATOR then
    Result := $FFE6E2DA;
end;

function TMasterDetailForm.ThemePaintStroke(Color: TAlphaColor): TAlphaColor;
{ Stroke twin of ThemePaintColor, mirroring StyleChromeRect's deliberate
  fill/stroke split: an accent-dim SURFACE can be a whisper-pale tint, but an
  accent-dim LINE at that tint disappears into a white canvas -- which is
  exactly what happened to the workflow wires and IO outlines when both went
  through the fill mapping. Lines need the stronger ink. }
begin
  if (not FDarkStyleEnabled) and (Color = UI_ACCENT_DIM) then
    Result := $FFA8C2E0
  else
    Result := ThemePaintColor(Color);
end;

procedure TMasterDetailForm.UseStyledLabelColor(LabelControl: TLabel);
begin
  if LabelControl <> nil then
    LabelControl.StyledSettings := LabelControl.StyledSettings +
      [TStyledSetting.FontColor];
end;

procedure TMasterDetailForm.StyleLabel(LabelControl: TLabel; Color: TAlphaColor;
  Size: Single; Bold: Boolean);
begin
  if LabelControl = nil then
    Exit;
  LabelControl.StyledSettings := LabelControl.StyledSettings -
    [TStyledSetting.Size, TStyledSetting.Style];
  if (Color = UI_TEXT) or (Color = UI_MUTED) then
    LabelControl.StyledSettings := LabelControl.StyledSettings +
      [TStyledSetting.FontColor]
  else
  begin
    LabelControl.StyledSettings := LabelControl.StyledSettings -
      [TStyledSetting.FontColor];
    LabelControl.TextSettings.FontColor := Color;
  end;
  LabelControl.TextSettings.Font.Size := Size;
  if Bold then
    LabelControl.TextSettings.Font.Style := [TFontStyle.fsBold]
  else
    LabelControl.TextSettings.Font.Style := [];
end;

function TMasterDetailForm.StyleLookupExists(const LookupName: string): Boolean;
(* Does the ACTIVE style actually define this StyleLookup?

   The *toolbutton resources are Embarcadero platform-style names. The bundled
   PasclawDark/PasclawLight books define them (generated by
   scripts/gen-studio-icons.py), but a style book that does not would leave the
   button on the default style -- and blanking its caption for an icon-only
   face would render a blank button. Never trade a readable caption for a
   lookup that may not exist: probe first.

   StyleBook = nil means no custom book is applied, so the platform style is
   active and its PLATFORM icon resources are present -- but only those.
   PASCLAW_ONLY_LOOKUPS have no platform equivalent (there is no theme-toggle
   or tray-arrow glyph in Embarcadero's table), so on the fallback path -- a
   style file missing or failing to load -- they must answer False or the
   theme and import/export buttons would blank their captions and render as
   empty controls. With a custom book applied, look in the book's own STYLE
   GRAPH.

   Not in Root: that is TFmxObject.Root, the scene the book belongs to. These
   books are created with the form as owner and no parent, so Root is nil and
   the probe answered False for every lookup -- captions were kept forever and
   no icon could ever appear, however complete the style file was. When Root
   is non-nil it names the form, which is worse: it would search the live
   control tree instead of the style resources.

   TStyleBook.Style is the loaded graph. Its getter builds from the stored
   resource on demand, but if that yields nothing the raw file text (stashed
   by LoadStyleBooks) is still an exact probe -- a style entry is
   'StyleName = ''<lookup>''' and nothing else in the file spells that. *)
var
  Found: Boolean;
  Key: string;
  BookText: string;

  procedure Walk(Obj: TFmxObject);
  var
    I: Integer;
  begin
    if Found or (Obj = nil) then
      Exit;
    if SameText(Obj.StyleName, LookupName) then
    begin
      Found := True;
      Exit;
    end;
    for I := 0 to Obj.ChildrenCount - 1 do
    begin
      Walk(Obj.Children[I]);
      if Found then
        Exit;
    end;
  end;

begin
  if LookupName = '' then
    Exit(False);
  if StyleBook = nil then
    { platform style in use: its own icons exist, ours do not }
    Exit(not MatchText(LowerCase(LookupName), PASCLAW_ONLY_LOOKUPS));
  { Key on the book, not on FDarkStyleEnabled: they agree today, but a cache
    keyed off a second opinion is exactly how these drift. }
  Key := IntToHex(NativeInt(StyleBook), 16) + '|' + LowerCase(LookupName);
  if FStyleLookupCache.TryGetValue(Key, Found) then
    Exit(Found);
  Found := False;
  Walk(StyleBook.Style);
  if (not Found) and FStyleBookTexts.TryGetValue(StyleBook, BookText) then
    Found := ContainsText(BookText, 'StyleName = ' + QuotedStr(LookupName));
  FStyleLookupCache.Add(Key, Found);
  Result := Found;
end;

procedure TMasterDetailForm.ReadIconButtonsPreference;
{ The one setting read before BuildInterface -- see the call site in Create.
  LoadLocalSettings reads it again later, harmlessly: same key, same file. }
var
  Ini: TIniFile;
begin
  if not TFile.Exists(FConfigFile) then
    Exit;
  Ini := TIniFile.Create(FConfigFile);
  try
    FIconButtons := Ini.ReadBool('ui', 'icon_buttons', FIconButtons);
  finally
    Ini.Free;
  end;
end;

procedure TMasterDetailForm.UpdateClearAttachmentsButton;
{ The ONE place that decides whether the clear-attachments button shows.

  Two conditions, two owners, and they disagreed: ApplyResponsiveLayout hid
  it on a narrow window, while RenderAttachments and UpdateComposerState --
  which run on every keystroke and every attachment change -- showed it
  again from the attachment count alone, crowding the narrow composer within
  a frame of the layout pass hiding it. Both conditions live here now. }
begin
  if FClearAttachmentsButton = nil then
    Exit;
  FClearAttachmentsButton.Visible :=
    (FAttachments <> nil) and (FAttachments.Count > 0) and
    (ClientWidth >= UI_NARROW_W);
end;

procedure TMasterDetailForm.ApplyChatMeasure;
{ Centre the transcript and the composer on a fixed reading measure: past
  CHAT_MAX_W the surplus becomes equal margins rather than longer lines;
  below it the column fills the width and behaves like any responsive pane.

  This is the ONLY place the flow's width is decided. The first version set
  Padding on the scroll box while HandleResize and RenderTranscript each also
  set FChatFlow.Width from the scroll box's OUTER width -- two other places
  deciding the same thing, both blind to the padding. The user's screenshots
  showed the result: the column started at the left pad and overflowed the
  right one. Margins on the flow itself cannot disagree with its width, and
  the other two call sites now come here instead of doing their own maths.

  The cap holds whether or not the sessions drawer is open. A page does not
  change width because a side panel closed -- the extra room becomes margin,
  which is the whole point of a reading measure.

  Both columns are positioned from ONE pad measured from the TAB edge, then
  each container's own fixed insets are subtracted so the text lands on the
  same x. Setting "the same pad" on both, as the first version did, is not
  the same thing: the transcript already carried CHAT_TEXT_INSET that the
  composer did not, so the composer always ran 18px wider on the left and
  18px + the scroll bar wider on the right.

  What is deliberately NOT compensated for is the scroll bar's own gutter.
  Whether it costs the transcript any width depends on it being shown at
  all, so a fixed allowance is wrong whenever it is absent -- and wrong in
  the direction that makes the composer narrower than the column above it.
  The left edges are exact at every width; the right edge of the transcript
  sits inside the scroll gutter, which is what scrolling content looks
  like. }
var
  Avail: Single;
  FlowMargin: Single;
  MaxPad: Single;
  Pad: Single;
begin
  if (FChatScroll = nil) or (FChatFlow = nil) then
    Exit;
  { measure against the TAB, the one width both columns share; the scroll box
    is already inset by TranscriptBody's margins }
  Avail := FChatScroll.Width + CHAT_BODY_M * 2;
  if Avail <= CHAT_BODY_M * 2 then
    Exit;
  { CHAT_GUTTER is the PREFERRED inset once the window is narrower than the
    measure -- the column stops centring but still keeps off the frame, since
    text touching the window edge reads as a defect. It is not a hard floor,
    though: on a viewport narrower than CHAT_MIN_W + two gutters the column
    would be pushed past the right edge and clipped. Content wins over
    decoration, so the gutter gives way first and only collapses to nothing
    once even that is not enough. }
  Pad := (Avail - CHAT_MAX_W) / 2;
  if Pad < CHAT_GUTTER then
    Pad := CHAT_GUTTER;
  MaxPad := (Avail - CHAT_MIN_W - 8) / 2;
  if Pad > MaxPad then
    Pad := MaxPad;
  if Pad < 0 then
    Pad := 0;
  { The flow starts CHAT_TEXT_INSET in already, so it only adds the rest. If
    the pad is smaller than that inset the flow can give nothing back, so the
    composer adopts the inset instead -- still equal, just set by the floor. }
  FlowMargin := Pad - CHAT_TEXT_INSET;
  if FlowMargin < 0 then
  begin
    FlowMargin := 0;
    Pad := CHAT_TEXT_INSET;
  end;
  SetControlMargins(FChatFlow, FlowMargin, 0, FlowMargin, 0);
  FChatFlow.Width := Max(CHAT_MIN_W, FChatScroll.Width - FlowMargin * 2);
  { Vertical padding preserved. No scroll-gutter compensation here: whether
    that gutter costs the transcript any width depends on the scroll bar
    actually being shown, so a fixed allowance is wrong exactly half the
    time -- and when it is wrong it makes the composer NARROWER than the
    column, which reads as a defect. A gutter outside the text column is
    what scrolling content looks like everywhere. }
  if FComposerLayout <> nil then
    SetControlPadding(FComposerLayout, Pad, 6, Pad, 8);
end;

procedure TMasterDetailForm.ApplyButtonIcon(Button: TButton);
(* Give recognised buttons a platform icon and ALWAYS a hint.

   The StyleLookup names below are NOT free-form -- they are Embarcadero
   platform-style resources listed in "Using Styled and Colored Buttons on
   Target Platforms" on the RAD Studio DocWiki. Only names from that table
   with a Windows column AND an IconTintColor entry are used: the tint column
   is what distinguishes a lookup carrying a glyph from one that is merely a
   coloured button shape (DeleteToolButton and DoneToolButton are real names
   but tint-less, so an icon-only button using either renders blank).

   The bundled PasclawDark/PasclawLight style books define these lookups via
   scripts/gen-studio-icons.py; a style book WITHOUT them leaves the button on
   the default style -- which for an icon-only button means a blank face. Two
   safeguards:

     - the caption is kept in Hint verbatim, so a bare icon is never a
       mystery and a blank one is still identifiable by hover;
     - [ui] icon_buttons=false turns the feature off by preference. It is NOT
       the safety net: StyleLookupExists below refuses to blank a caption for
       a lookup the active style does not define, so a style without these
       resources degrades to plain text on its own.

   Mapping lives HERE only, keyed by the caption a button was created with,
   so icon + hint can never drift from each other or from the action. *)
var
  Cap: string;
  HintText: string;
  Lookup: string;
  IconOnly: Boolean;
begin
  if (Button = nil) or Button.TagString.StartsWith('noicon') then
    Exit;
  { Already iconified on an earlier pass (theme switch re-runs this walk):
    the face is blank and a hint is showing. Re-deriving from an empty caption
    would just clear the mapping, so stop here.
    NB: TagString is NOT usable as a caption stash -- chat-turn buttons encode
    their action in it ('copy'#9<index>) and ChatTurnActionClick parses it. }
  if (Button.Text = '') and Button.ShowHint then
    Exit;
  Cap := Trim(Button.Text);
  if Cap = '' then
    Exit;

  Lookup := '';
  IconOnly := False;
  HintText := Cap;
  { Tier 1 -- frequent, unambiguous verbs: icon only. }
  if SameText(Cap, 'Refresh')      then begin Lookup := 'refreshtoolbutton'; IconOnly := True; HintText := 'Refresh'; end
  else if SameText(Cap, 'Search')  then begin Lookup := 'searchtoolbutton';  IconOnly := True; HintText := 'Search'; end
  else if SameText(Cap, 'Delete')  then begin Lookup := 'trashtoolbutton';   IconOnly := True; HintText := 'Delete'; end
  else if SameText(Cap, 'Remove')  then begin Lookup := 'trashtoolbutton';   IconOnly := True; end
  else if SameText(Cap, 'Clear')   then begin Lookup := 'trashtoolbutton';   IconOnly := True; end
  else if SameText(Cap, 'Add')     then begin Lookup := 'addtoolbutton';     IconOnly := True; end
  else if SameText(Cap, 'New')     then begin Lookup := 'addtoolbutton';     IconOnly := True; end
  else if SameText(Cap, 'Copy')    then begin Lookup := 'actiontoolbutton';  IconOnly := True; HintText := 'Copy to clipboard'; end
  { Tier 2 -- tight rows where width is already squeezed. }
  else if SameText(Cap, 'Send')    then begin Lookup := 'arrowuptoolbutton'; IconOnly := True; HintText := 'Send (steers the turn while streaming)'; end
  else if SameText(Cap, 'Stop')    then begin Lookup := 'stoptoolbutton';    IconOnly := True; HintText := 'Stop the running turn'; end
  else if SameText(Cap, 'Undo')    then begin Lookup := 'arrowlefttoolbutton';  IconOnly := True; end
  else if SameText(Cap, 'Redo')    then begin Lookup := 'arrowrighttoolbutton'; IconOnly := True; end
  else if SameText(Cap, 'Edit')    then begin Lookup := 'composetoolbutton'; IconOnly := True; end
  else if SameText(Cap, 'Run')     then begin Lookup := 'playtoolbutton';    IconOnly := True; end
  else if SameText(Cap, 'Pause')   then begin Lookup := 'pausetoolbutton';   IconOnly := True; end
  else if SameText(Cap, 'Preview') then begin Lookup := 'detailstoolbutton'; IconOnly := True; HintText := 'Preview'; end
  { Chrome verbs whose captions were the loudest text on screen. sun/moon are
    Pasclaw-custom lookups (the platform table has no theme-toggle glyph);
    they are defined by gen-studio-icons.py in our own books, and the
    StyleLookupExists probe keeps captions on any style without them. }
  else if SameText(Cap, '+ Session') or (Cap = '+') then
    begin Lookup := 'addtoolbutton'; IconOnly := True; HintText := 'New session'; end
  else if SameText(Cap, 'Attach')  then begin Lookup := 'addtoolbutton';  IconOnly := True; HintText := 'Attach files'; end
  else if SameText(Cap, 'Light')   then begin Lookup := 'suntoolbutton';  IconOnly := True; HintText := 'Switch to the light style'; end
  else if SameText(Cap, 'Dark')    then begin Lookup := 'moontoolbutton'; IconOnly := True; HintText := 'Switch to the dark style'; end
  else if SameText(Cap, 'Delete Session') then
    begin Lookup := 'trashtoolbutton'; IconOnly := True; HintText := 'Delete session'; end
  else if SameText(Cap, 'Forget')  then begin Lookup := 'trashtoolbutton'; IconOnly := True; HintText := 'Forget this fact'; end
  else if Cap = 'X'                then begin Lookup := 'trashtoolbutton'; IconOnly := True; HintText := 'Remove'; end
  else if SameText(Cap, 'Up')      then begin Lookup := 'arrowuptoolbutton'; IconOnly := True; HintText := 'Up one directory'; end
  else if SameText(Cap, 'Import')  then begin Lookup := 'importtoolbutton'; IconOnly := True; HintText := 'Import a session export file'; end
  else if SameText(Cap, 'Export')  then begin Lookup := 'exporttoolbutton'; IconOnly := True; HintText := 'Export'; end
  else if SameText(Cap, 'Import Dir') then
    begin Lookup := 'organizetoolbutton'; IconOnly := True; HintText := 'Import a session directory (OpenCode)'; end
  { hex viewer pager }
  else if SameText(Cap, 'First')   then begin Lookup := 'priortoolbutton';  IconOnly := True; HintText := 'First page'; end
  else if SameText(Cap, 'Last')    then begin Lookup := 'nexttoolbutton';   IconOnly := True; HintText := 'Last page'; end
  else if SameText(Cap, 'Prev')    then begin Lookup := 'arrowlefttoolbutton';  IconOnly := True; HintText := 'Previous page'; end
  else if SameText(Cap, 'Next')    then begin Lookup := 'arrowrighttoolbutton'; IconOnly := True; HintText := 'Next page'; end
  { hint-only entries: these stay text (state/disclosure controls), but the
    caption alone does not explain what they disclose }
  { Params/mode captions carry their own hints (RenderParamsButton,
    RenderModeButton) -- they change with state, so a static table cannot
    describe them }
  else if SameText(Cap, 'Tools +')  then HintText := 'Show tool activity cards'
  else if SameText(Cap, 'Tools -')  then HintText := 'Hide tool activity cards'
  else if SameText(Cap, 'Files')   then begin Lookup := 'organizetoolbutton'; IconOnly := True; HintText := 'Workspace files'; end;
  { 'Save' deliberately has no icon: the platform table offers no save glyph,
    and DoneToolButton -- the near miss -- is one of the tint-less entries, so
    it would render as an empty coloured pill. A caption beats a wrong icon. }

  { Hint is set for EVERY button we recognise, icon or not -- ShowHint alone
    is what makes Hint do anything in FMX, and it was never enabled here. }
  Button.Hint := HintText;
  Button.ShowHint := True;
  if (Lookup = '') or (not FIconButtons) then
  begin
    if Button.Text = '' then
      Button.Text := Cap;   { restore when icons are switched off }
    Exit;
  end;
  { The caption is the fallback that keeps the UI usable, so only surrender it
    once the icon is known to exist. A missing lookup degrades to plain text
    automatically -- no diagnosis, no INI edit. }
  if not StyleLookupExists(Lookup) then
  begin
    Button.Text := Cap;
    Exit;
  end;
  Button.StyleLookup := Lookup;
  if IconOnly then
  begin
    Button.Text := '';
    { A face with no text should not keep the width its caption needed --
      "Copy" at 54px as a bare icon reads as a mis-sized control. Only ever
      SHRINK, so a deliberately large control keeps its footprint. }
    if Button.Width > ICON_BTN_W then
      Button.Width := ICON_BTN_W;
  end
  else
    Button.Text := Cap;
end;

procedure TMasterDetailForm.StyleButton(Button: TButton; Primary: Boolean);
begin
  if Button = nil then
    Exit;
  ApplyButtonIcon(Button);
  Button.StyledSettings := Button.StyledSettings - [TStyledSetting.Size];
  Button.StyledSettings := Button.StyledSettings +
    [TStyledSetting.FontColor, TStyledSetting.Style];
  Button.TextSettings.Font.Size := IfThen(Primary, 11.5, 11.0);
end;

procedure TMasterDetailForm.StyleTextControl(Control: TControl;
  Color: TAlphaColor; Size: Single);
begin
  if Control is TEdit then
  begin
    TEdit(Control).StyledSettings := TEdit(Control).StyledSettings -
      [TStyledSetting.Size];
    if (Color = UI_TEXT) or (Color = UI_MUTED) then
      TEdit(Control).StyledSettings := TEdit(Control).StyledSettings +
        [TStyledSetting.FontColor]
    else
    begin
      TEdit(Control).StyledSettings := TEdit(Control).StyledSettings -
        [TStyledSetting.FontColor];
      TEdit(Control).TextSettings.FontColor := Color;
    end;
    TEdit(Control).TextSettings.Font.Size := Size;
  end
  else if Control is TMemo then
  begin
    TMemo(Control).StyledSettings := TMemo(Control).StyledSettings -
      [TStyledSetting.Size];
    if (Color = UI_TEXT) or (Color = UI_MUTED) then
      TMemo(Control).StyledSettings := TMemo(Control).StyledSettings +
        [TStyledSetting.FontColor]
    else
    begin
      TMemo(Control).StyledSettings := TMemo(Control).StyledSettings -
        [TStyledSetting.FontColor];
      TMemo(Control).TextSettings.FontColor := Color;
    end;
    TMemo(Control).TextSettings.Font.Size := Size;
  end;
end;

procedure TMasterDetailForm.RestyleCoreControls;
{ Re-applies the palette to the whole control tree.

  The walk MUST NOT iterate a live children list. Every branch below can
  rebuild the control's applied style (assigning StyleLookup, StyledSettings,
  padding or font all mark it for re-application), and in FMX a control's
  applied style objects ARE its children -- so styling a node can destroy and
  re-create the very collection the loop is indexing. Assigning StyleBook, as
  ApplyTheme does immediately before calling this, marks every control in the
  form for exactly that rebuild.

  That is the theme-switch access violation: intermittent because it needs a
  rebuild to land inside the loop, and hard to repeat because by the second
  switch most controls are already settled. Snapshot the children after
  styling the node, then walk the snapshot, skipping anything the restyle
  detached. }
  procedure Walk(Obj: TFmxObject);
  var
    Button: TButton;
    Check: TCheckBox;
    Combo: TComboBox;
    I: Integer;
    Kids: TArray<TFmxObject>;
    LabelControl: TLabel;
    ListBox: TListBox;
  begin
    if Obj = nil then
      Exit;
    if Obj is TLabel then
    begin
      LabelControl := TLabel(Obj);
      if TStyledSetting.FontColor in LabelControl.StyledSettings then
        StyleLabel(LabelControl, UI_CHROME_TEXT, TXT_TITLE, False);   { tier 4 }
    end
    else if Obj is TButton then
    begin
      Button := TButton(Obj);
      StyleButton(Button, (Button = FSendButton) or (Button = FRefreshButton));
    end
    else if Obj is TCheckBox then
    begin
      Check := TCheckBox(Obj);
      Check.StyledSettings := Check.StyledSettings - [TStyledSetting.Size];
      Check.StyledSettings := Check.StyledSettings + [TStyledSetting.FontColor];
      Check.TextSettings.Font.Size := TXT_TITLE;
    end
    else if Obj is TComboBox then
    begin
      Combo := TComboBox(Obj);
      SetControlPadding(Combo, 2, 2, 2, 2);
    end
    else if Obj is TListBox then
    begin
      ListBox := TListBox(Obj);
      SetControlPadding(ListBox, 2, 2, 2, 2);
    end
    else if Obj is TEdit then
      StyleTextControl(TControl(Obj), UI_TEXT, TXT_TITLE)
    else if Obj = FPromptMemo then
      { tier 1 ink, not the style book's grey: what you are typing pulls the
        eye exactly like the chat text it is about to become }
      StyleTextControl(TControl(Obj), UI_CHAT_TEXT, TXT_TITLE)
    else if Obj is TMemo then
      StyleTextControl(TControl(Obj), UI_TEXT, TXT_TITLE);

    { snapshot AFTER styling Obj, so it reflects any style rebuild that just
      happened rather than the collection that rebuild replaced }
    SetLength(Kids, Obj.ChildrenCount);
    for I := 0 to Obj.ChildrenCount - 1 do
      Kids[I] := Obj.Children[I];
    for I := 0 to High(Kids) do
      { Parent still Obj means the node survived this pass; a style rebuild
        re-parents or drops its old objects, and those must not be followed }
      if (Kids[I] <> nil) and (Kids[I].Parent = Obj) then
        Walk(Kids[I]);
  end;
begin
  { A restyle can raise events that call back in here; a nested walk would
    style half the tree against a collection the outer walk is still holding }
  if FRestyling then
    Exit;
  FRestyling := True;
  try
    Walk(Self);
  finally
    FRestyling := False;
  end;
  UpdateNavButtons;
end;

procedure TMasterDetailForm.FormKeyDown(Sender: TObject; var Key: Word;
  var KeyChar: Char; Shift: TShiftState);
var
  ActiveTab: string;
begin
  if (Focused is TEdit) or (Focused is TMemo) or (Focused is TComboBox) then
    Exit;
  if (FTabControl = nil) or (FTabControl.TabIndex < 0) or
    (FTabControl.TabIndex >= FTabControl.TabCount) then
    Exit;
  ActiveTab := FTabControl.Tabs[FTabControl.TabIndex].Text;
  if not SameText(ActiveTab, 'Workflow') then
    Exit;

  { canvas shortcuts (n8n/ComfyUI conventions): Del removes the selection,
    Ctrl+D duplicates the selected node, F fits the view. Guarded above so
    none of them fire while typing in a field. }
  if (Key = vkDelete) or (Key = vkBack) then
  begin
    if (FWorkflowEdgesList <> nil) and (FWorkflowEdgesList.Selected <> nil) then
      WorkflowDeleteEdgeClick(nil)
    else if (FWorkflowNodesList <> nil) and
      (FWorkflowNodesList.Selected <> nil) then
      WorkflowDeleteNodeClick(nil)
    else
      Exit;
  end
  else if (ssCtrl in Shift) and
    ((Key = vkD) or (KeyChar = 'd') or (KeyChar = 'D')) then
    WorkflowDuplicateSelectedNode
  else if (Shift = []) and
    ((Key = vkF) or (KeyChar = 'f') or (KeyChar = 'F')) then
    WorkflowFitView
  else
    Exit;
  Key := 0;
  KeyChar := #0;
end;

procedure TMasterDetailForm.FormResize(Sender: TObject);
begin
  ApplyResponsiveLayout;
end;

procedure TMasterDetailForm.ApplyResponsiveLayout;
var
  ChatW: Single;
  Compact: Boolean;
  MaxDrawerWidth: Single;
  Narrow: Boolean;
  ToolbarCompact: Boolean;
  W: Single;
begin
  if (FTopBar = nil) or (FBodyLayout = nil) then
    Exit;

  W := ClientWidth;
  Narrow := W < UI_NARROW_W;
  Compact := W < 820;
  ApplyChatMeasure;
  FTopBar.Height := ROW_CARD;
  FHeaderRow.Height := ROW_BAR;

  if FTitleLabel <> nil then
  begin
    FTitleLabel.Visible := not Narrow;
    FTitleLabel.Width := IfThen(Compact, 118, 142);
  end;

  if FSessionToggleButton <> nil then
  begin
    FSessionToggleButton.Visible := True;
    SetButtonWidth(FSessionToggleButton, 42);
  end;

  { The drawer-header buttons are not resized here: the drawer's width does
    not track the window, and both are created at caption width so the
    icon-less fallback already fits. }
  if FRefreshButton <> nil then
  begin
    SetButtonWidth(FRefreshButton, IfThen(Narrow, 44, IfThen(Compact, 78, 92)));
    RenderConnectButton;   { caption follows connection state, not layout }
  end;
  if FThemeButton <> nil then
  begin
    FThemeButton.Visible := not Narrow;
    SetButtonWidth(FThemeButton, IfThen(Compact, 62, 70));
  end;
  if FStatusLabel <> nil then
    FStatusLabel.Visible := not Narrow;

  if FTokenEdit <> nil then
    FTokenEdit.Width := IfThen(Narrow, 122, IfThen(Compact, 160, 210));
  if FTokenShowButton <> nil then
  begin
    FTokenShowButton.Visible := not Narrow;
    SetButtonWidth(FTokenShowButton, IfThen(Compact, 52, 58));
  end;
  if FTokenClearButton <> nil then
  begin
    FTokenClearButton.Visible := not Narrow;
    SetButtonWidth(FTokenClearButton, IfThen(Compact, 52, 58));
  end;

  if FNavHost <> nil then
  begin
    FNavHost.Visible := False;
    FNavHost.Height := 0;
    SetControlMargins(FNavHost, 0, 0, 0, 0);
  end;

  if FSessionDrawer <> nil then
  begin
    if Compact then
      MaxDrawerWidth := Max(260.0, W - 48)
    else
      MaxDrawerWidth := Min(420.0, Max(260.0, W * 0.34));
    FSessionDrawerWidth := Min(Max(FSessionDrawerWidth,
      IfThen(Compact, 260.0, 220.0)), MaxDrawerWidth);
    FSessionDrawer.Width := FSessionDrawerWidth;
    FSessionDrawer.Height := FBodyLayout.Height;
    FSessionDrawer.TargetControl := FContentLayout;
    FSidebar.Align := TAlignLayout.Client;
    FSidebar.Visible := True;
    if FSessionSplitter <> nil then
    begin
      FSessionSplitter.Visible := (not Compact) and FSidebarVisible;
      FSessionSplitter.Align := TAlignLayout.Left;
      FSessionSplitter.Width := 8;
    end;

    if Compact then
    begin
      FSessionDrawer.Visible := True;
      FSessionDrawer.Align := TAlignLayout.None;
      FSessionDrawer.Width := FSessionDrawerWidth;
      FSessionDrawer.Position.X := 0;
      FSessionDrawer.Position.Y := 0;
      FSessionDrawer.Mode := TMultiViewMode.Drawer;
      FSessionDrawer.BringToFront;
      SetControlPadding(FSidebar, GAP_S, GAP_S, GAP_S, GAP_S);
      if FTabControl <> nil then
        SetControlMargins(FTabControl, GAP_S, GAP_S, GAP_S, GAP_S);
      if FSidebarVisible then
        FSessionDrawer.ShowMaster
      else
        FSessionDrawer.HideMaster;
    end
    else
    begin
      FSessionDrawer.Align := TAlignLayout.Left;
      FSessionDrawer.Mode := TMultiViewMode.Panel;
      SetControlPadding(FSidebar, 10, 10, GAP_S, 10);
      if FSidebarVisible then
      begin
        FSessionDrawer.Visible := True;
        FSessionDrawer.Width := FSessionDrawerWidth;
        FSessionDrawer.ShowMaster;
      end
      else
      begin
        FSessionDrawer.HideMaster;
        FSessionDrawer.Width := 0;
        FSessionDrawer.Visible := False;
      end;
      if FTabControl <> nil then
        SetControlMargins(FTabControl, 0, 10, 10, 10);
    end;
  end;

  ChatW := W;
  if (not Compact) and FSidebarVisible then
    ChatW := ChatW - FSessionDrawerWidth - 24;
  ToolbarCompact := ChatW < 980;
  if FNavScroll <> nil then
    FNavScroll.Visible := False;
  if FNavCombo <> nil then
    FNavCombo.Visible := False;

  if FModeButton <> nil then
    SetButtonWidth(FModeButton, IfThen(Narrow, 76, 94));
  if FModelCombo <> nil then
    FModelCombo.Width := IfThen(Narrow, 150, IfThen(Compact, 210, 260));
  if FParamsToggleButton <> nil then
    SetButtonWidth(FParamsToggleButton, IfThen(Narrow, 64, 82));
  if FToolsToggleButton <> nil then
  begin
    FToolsToggleButton.Visible := ChatW >= 560;
    SetButtonWidth(FToolsToggleButton, IfThen(Narrow, 72, 86));
  end;
  if FParamsSummaryLabel <> nil then
  begin
    FParamsSummaryLabel.Visible := ChatW >= 720;
    FParamsSummaryLabel.Width := IfThen(ChatW < 980, 110, 150);
  end;
  if FChatParamsLayout <> nil then
  begin
    FChatParamsLayout.Visible := FChatParamsVisible;
    if FChatParamsVisible then
      FChatParamsLayout.Height := IfThen(ToolbarCompact, 112, 126)
    else
      FChatParamsLayout.Height := 0;
  end;
  if FChatStatsLabel <> nil then
    UpdateFooterVisibility;   { one owner for the footer's size }
  if FSandboxLabel <> nil then
  begin
    FSandboxLabel.Visible := (ClientHeight >= 900) and (ChatW >= 860);
    FSandboxLabel.Height := IfThen(FSandboxLabel.Visible, 20, 0);
  end;
  if FChatTurnList <> nil then
  begin
    FChatTurnList.Visible := False;
    FChatTurnList.Width := 0;
  end;
  { flow width is ApplyChatMeasure's decision (called above) -- setting it
    here from the unpadded scroll width is what broke the centring }
  if FTemperatureLabel <> nil then
    FTemperatureLabel.Visible := not ToolbarCompact;
  if FTemperatureEdit <> nil then
  begin
    FTemperatureEdit.Visible := not ToolbarCompact;
    FTemperatureEdit.Width := IfThen(ToolbarCompact, 0, 70);
  end;
  if FTemperatureTrack <> nil then
    FTemperatureTrack.Width := IfThen(Narrow, 140, IfThen(Compact, 170, 210));
  UpdateComposerState;
  if FSendButton <> nil then
    SetButtonWidth(FSendButton, IfThen(Narrow, 78, 96));
  if FAttachButton <> nil then
    SetButtonWidth(FAttachButton, IfThen(Narrow, 76, 86));
  if FClearAttachmentsButton <> nil then
  begin
    UpdateClearAttachmentsButton;
    SetButtonWidth(FClearAttachmentsButton, IfThen(Compact, 64, 74));
  end;
  if FMaxTokensLabel <> nil then
    FMaxTokensLabel.Visible := not ToolbarCompact;
  if FMaxTokensEdit <> nil then
  begin
    FMaxTokensEdit.Visible := not ToolbarCompact;
    FMaxTokensEdit.Width := IfThen(ToolbarCompact, 0, 96);
  end;
  if FPromptPresetCombo <> nil then
    FPromptPresetCombo.Width := IfThen(Narrow, 132, IfThen(Compact, 160, 190));
  if FPresetNameEdit <> nil then
    FPresetNameEdit.Visible := not Narrow;
  if FPresetSaveButton <> nil then
    SetButtonWidth(FPresetSaveButton, IfThen(Narrow, 56, 62));
  if FParamsResetButton <> nil then
    SetButtonWidth(FParamsResetButton, IfThen(Narrow, 56, 62));
  if FPresetDeleteButton <> nil then
    SetButtonWidth(FPresetDeleteButton, IfThen(Narrow, 58, 68));
  if FUndoButton <> nil then
    SetButtonWidth(FUndoButton, IfThen(Narrow, 58, 70));
  if FRedoButton <> nil then
    SetButtonWidth(FRedoButton, IfThen(Narrow, 58, 70));
  if FChatCopyButton <> nil then
  begin
    FChatCopyButton.Visible := ChatW >= 760;
    SetButtonWidth(FChatCopyButton, IfThen(ToolbarCompact, 58, 62));
  end;
  if FChatTurnEdit <> nil then
    FChatTurnEdit.Width := IfThen(Narrow, 42, 52);
  if FProviderCombo <> nil then
    FProviderCombo.Width := IfThen(Narrow, 132, 170);
  if FProviderKeyEdit <> nil then
    FProviderKeyEdit.Width := IfThen(Narrow, 150, 240);
  if FProviderModelEdit <> nil then
    FProviderModelEdit.Width := IfThen(Narrow, 150, 230);
  if FProviderSecondaryCombo <> nil then
    FProviderSecondaryCombo.Width := IfThen(Narrow, 118, 160);
  if FProviderSecondaryKeyEdit <> nil then
    FProviderSecondaryKeyEdit.Width := IfThen(Narrow, 120, 190);
  if FProviderSecondaryModelEdit <> nil then
    FProviderSecondaryModelEdit.Width := IfThen(Narrow, 130, 220);
  if FProviderNotesLabel <> nil then
    FProviderNotesLabel.Visible := not Narrow;
  if FFileLeftPane <> nil then
  begin
    if Narrow then
    begin
      FFileLeftPane.Align := TAlignLayout.Top;
      FFileLeftPane.Height := 214;
      SetControlMargins(FFileLeftPane, 0, 0, 0, GAP_S);
    end
    else
    begin
      FFileLeftPane.Align := TAlignLayout.Left;
      FFileLeftPane.Width := IfThen(Compact, 300, 360);
      SetControlMargins(FFileLeftPane, 0, 0, GAP_S, 0);
    end;
  end;
  if FFilePaneSplitter <> nil then
  begin
    if Narrow then
    begin
      FFilePaneSplitter.Align := TAlignLayout.Top;
      FFilePaneSplitter.Height := 8;
    end
    else
    begin
      FFilePaneSplitter.Align := TAlignLayout.Left;
      FFilePaneSplitter.Width := 8;
    end;
  end;
  if FFileViewerPane <> nil then
    FFileViewerPane.Align := TAlignLayout.Client;
  if FFilePreviewImage <> nil then
    FFilePreviewImage.Align := TAlignLayout.Client;
  if FFileDetailMemo <> nil then
    FFileDetailMemo.Align := TAlignLayout.Client;
  if FFileRootsList <> nil then
    FFileRootsList.Height := IfThen(Narrow, 56, 76);
  if FMcpLeftPane <> nil then
  begin
    if Compact then
    begin
      FMcpLeftPane.Align := TAlignLayout.Top;
      FMcpLeftPane.Height := IfThen(Narrow, 170, 210);
      SetControlMargins(FMcpLeftPane, 0, 0, 0, GAP_S);
    end
    else
    begin
      FMcpLeftPane.Align := TAlignLayout.Left;
      FMcpLeftPane.Width := 340;
      SetControlMargins(FMcpLeftPane, 0, 0, GAP_S, 0);
    end;
  end;
  if FMcpSplitter <> nil then
  begin
    if Compact then
    begin
      FMcpSplitter.Align := TAlignLayout.Top;
      FMcpSplitter.Height := 8;
    end
    else
    begin
      FMcpSplitter.Align := TAlignLayout.Left;
      FMcpSplitter.Width := 8;
    end;
  end;
  if FMcpRightPane <> nil then
    FMcpRightPane.Align := TAlignLayout.Client;
  if FMcpSchemaPanel <> nil then
    FMcpSchemaPanel.Align := TAlignLayout.Client;
  if FMcpArgsPanel <> nil then
    FMcpArgsPanel.Height := IfThen(Narrow, 116, 150);
  if FMcpResultDetailMemo <> nil then
    FMcpResultDetailMemo.Height := IfThen(Narrow, 82, 110);
  if FMemoryBackendCombo <> nil then
    FMemoryBackendCombo.Width := IfThen(Narrow, 96, IfThen(Compact, 118, 132));
  if FMemoryRerankModelEdit <> nil then
    FMemoryRerankModelEdit.Width := IfThen(Narrow, 140, IfThen(Compact, 190, 230));
  if FMemoryModelCombo <> nil then
    FMemoryModelCombo.Width := IfThen(Narrow, 124, IfThen(Compact, 170, 220));
  if FMemoryDownloadEmbedCheck <> nil then
    FMemoryDownloadEmbedCheck.Width := IfThen(Narrow, 132, 180);
  if FMemoryDownloadRerankCheck <> nil then
    FMemoryDownloadRerankCheck.Width := IfThen(Narrow, 132, 180);
  if FMemoryFilesPane <> nil then
  begin
    if Narrow then
    begin
      FMemoryFilesPane.Align := TAlignLayout.Top;
      FMemoryFilesPane.Height := 220;
      SetControlMargins(FMemoryFilesPane, 0, 0, 0, GAP_S);
    end
    else
    begin
      FMemoryFilesPane.Align := TAlignLayout.Left;
      FMemoryFilesPane.Width := IfThen(Compact, 280, 340);
      SetControlMargins(FMemoryFilesPane, 0, 0, GAP_S, 0);
    end;
  end;
  if FMemoryFileDetailMemo <> nil then
    FMemoryFileDetailMemo.Align := TAlignLayout.Client;
  if FMemoryFactsPane <> nil then
    FMemoryFactsPane.Align := TAlignLayout.Client;
  if FKBResultsPane <> nil then
  begin
    FKBResultsPane.Align := TAlignLayout.Client;
    SetControlMargins(FKBResultsPane, 0, 0, IfThen(Narrow, 0, 8),
      IfThen(Narrow, 8, 0));
  end;
  if FKBSourcesPane <> nil then
  begin
    if Narrow then
    begin
      FKBSourcesPane.Align := TAlignLayout.Bottom;
      FKBSourcesPane.Height := 104;
      SetControlMargins(FKBSourcesPane, 0, GAP_S, 0, 0);
    end
    else
    begin
      FKBSourcesPane.Align := TAlignLayout.Right;
      FKBSourcesPane.Width := IfThen(Compact, 260, 330);
      SetControlMargins(FKBSourcesPane, 0, 0, 0, 0);
    end;
  end;
  if FVaultListPane <> nil then
  begin
    if Compact then
    begin
      FVaultListPane.Align := TAlignLayout.Top;
      FVaultListPane.Height := IfThen(Narrow, 150, 190);
      SetControlMargins(FVaultListPane, 0, 0, 0, GAP_S);
    end
    else
    begin
      FVaultListPane.Align := TAlignLayout.Left;
      FVaultListPane.Width := 320;
      SetControlMargins(FVaultListPane, 0, 0, GAP_S, 0);
    end;
  end;
  if FVaultList <> nil then
    FVaultList.Align := TAlignLayout.Client;
  if FVaultDetailPane <> nil then
    FVaultDetailPane.Align := TAlignLayout.Client;
  if FConfigListPane <> nil then
  begin
    if Compact then
    begin
      FConfigListPane.Align := TAlignLayout.Top;
      FConfigListPane.Height := 108;
      SetControlMargins(FConfigListPane, 0, 0, 0, GAP_S);
    end
    else
    begin
      FConfigListPane.Align := TAlignLayout.Left;
      FConfigListPane.Width := 360;
      SetControlMargins(FConfigListPane, 0, 0, GAP_S, 0);
    end;
  end;
  if FConfigEditorPane <> nil then
    FConfigEditorPane.Align := TAlignLayout.Client;
  if FStatsLeftPane <> nil then
  begin
    if Compact then
    begin
      FStatsLeftPane.Align := TAlignLayout.Top;
      FStatsLeftPane.Height := 140;
      SetControlMargins(FStatsLeftPane, 0, 0, 0, GAP_S);
    end
    else
    begin
      FStatsLeftPane.Align := TAlignLayout.Left;
      FStatsLeftPane.Width := 320;
      SetControlMargins(FStatsLeftPane, 0, 0, GAP_S, 0);
    end;
  end;
  if FStatsRightPane <> nil then
    FStatsRightPane.Align := TAlignLayout.Client;
  if FStatsAutoRefreshCheck <> nil then
    FStatsAutoRefreshCheck.Width := IfThen(Narrow, 92, 118);
  if FStatsProviderList <> nil then
    FStatsProviderList.Height := IfThen(Narrow, 96, IfThen(Compact, 112, 132));
  if FCheckpointListPane <> nil then
  begin
    if Compact then
    begin
      FCheckpointListPane.Align := TAlignLayout.Top;
      FCheckpointListPane.Height := IfThen(Narrow, 160, 210);
      SetControlMargins(FCheckpointListPane, 0, 0, 0, GAP_S);
    end
    else
    begin
      FCheckpointListPane.Align := TAlignLayout.Left;
      FCheckpointListPane.Width := 330;
      SetControlMargins(FCheckpointListPane, 0, 0, GAP_S, 0);
    end;
  end;
  if FCheckpointSplitter <> nil then
  begin
    if Compact then
    begin
      FCheckpointSplitter.Align := TAlignLayout.Top;
      FCheckpointSplitter.Height := 8;
    end
    else
    begin
      FCheckpointSplitter.Align := TAlignLayout.Left;
      FCheckpointSplitter.Width := 8;
    end;
  end;
  if FCheckpointList <> nil then
    FCheckpointList.Align := TAlignLayout.Client;
  if FCheckpointDetailPane <> nil then
    FCheckpointDetailPane.Align := TAlignLayout.Client;
  if FSkillLeftPane <> nil then
  begin
    if Compact then
    begin
      FSkillLeftPane.Align := TAlignLayout.Top;
      FSkillLeftPane.Height := IfThen(Narrow, 250, 290);
      SetControlMargins(FSkillLeftPane, 0, 0, 0, GAP_S);
    end
    else
    begin
      FSkillLeftPane.Align := TAlignLayout.Left;
      FSkillLeftPane.Width := 300;
      SetControlMargins(FSkillLeftPane, 0, 0, GAP_S, 0);
    end;
  end;
  if FSkillSplitter <> nil then
  begin
    if Compact then
    begin
      FSkillSplitter.Align := TAlignLayout.Top;
      FSkillSplitter.Height := 8;
    end
    else
    begin
      FSkillSplitter.Align := TAlignLayout.Left;
      FSkillSplitter.Width := 8;
    end;
  end;
  if FSkillInstalledPane <> nil then
    FSkillInstalledPane.Align := TAlignLayout.Client;
  if FSkillPendingPane <> nil then
  begin
    FSkillPendingPane.Align := TAlignLayout.Bottom;
    FSkillPendingPane.Height := IfThen(Narrow, 126, 190);
    SetControlMargins(FSkillPendingPane, 0, GAP_S, 0, 0);
  end;
  if FSkillCatalogPane <> nil then
    FSkillCatalogPane.Align := TAlignLayout.Client;
  if FSkillDetailMemo <> nil then
    FSkillDetailMemo.Height := IfThen(Narrow, 88, 130);
  if FRelayLeftPane <> nil then
  begin
    if Compact then
    begin
      FRelayLeftPane.Align := TAlignLayout.Top;
      FRelayLeftPane.Height := IfThen(Narrow, 180, 230);
      SetControlMargins(FRelayLeftPane, 0, 0, 0, GAP_S);
    end
    else
    begin
      FRelayLeftPane.Align := TAlignLayout.Left;
      FRelayLeftPane.Width := 320;
      SetControlMargins(FRelayLeftPane, 0, 0, GAP_S, 0);
    end;
  end;
  if FRelaySplitter <> nil then
  begin
    if Compact then
    begin
      FRelaySplitter.Align := TAlignLayout.Top;
      FRelaySplitter.Height := 8;
    end
    else
    begin
      FRelaySplitter.Align := TAlignLayout.Left;
      FRelaySplitter.Width := 8;
    end;
  end;
  if FRelayRightPane <> nil then
    FRelayRightPane.Align := TAlignLayout.Client;
  if FRelaySnippetsMemo <> nil then
    FRelaySnippetsMemo.Height := IfThen(Narrow, 90, IfThen(Compact, 112, 170));
  if FRelayWorkerDetailMemo <> nil then
    FRelayWorkerDetailMemo.Height := IfThen(Narrow, 78, 104);

  if FCronListPane <> nil then
  begin
    if Compact then
    begin
      FCronListPane.Align := TAlignLayout.Top;
      FCronListPane.Height := IfThen(Narrow, 170, 220);
      SetControlMargins(FCronListPane, 0, 0, 0, GAP_S);
    end
    else
    begin
      FCronListPane.Align := TAlignLayout.Left;
      FCronListPane.Width := 330;
      SetControlMargins(FCronListPane, 0, 0, GAP_S, 0);
    end;
  end;
  if FCronSplitter <> nil then
  begin
    if Compact then
    begin
      FCronSplitter.Align := TAlignLayout.Top;
      FCronSplitter.Height := 8;
    end
    else
    begin
      FCronSplitter.Align := TAlignLayout.Left;
      FCronSplitter.Width := 8;
    end;
  end;
  if FCronEditorPane <> nil then
    FCronEditorPane.Align := TAlignLayout.Client;
  if FCronList <> nil then
    FCronList.Align := TAlignLayout.Client;
  if FCronSpecEdit <> nil then
    FCronSpecEdit.Width := IfThen(Narrow, 108, IfThen(Compact, 132, 170));
  if FCronEnabledCheck <> nil then
    FCronEnabledCheck.Width := IfThen(Narrow, 74, 88);
  if FCronArgsEdit <> nil then
    FCronArgsEdit.Width := IfThen(Narrow, 132, IfThen(Compact, 210, 310));
  if FCronChannelKindEdit <> nil then
    FCronChannelKindEdit.Width := IfThen(Narrow, 104, 132);
  if FMcpServerArgsEdit <> nil then
    FMcpServerArgsEdit.Width := IfThen(Narrow, 150, IfThen(Compact, 210, 270));
  if FMcpServerEnabledCheck <> nil then
    FMcpServerEnabledCheck.Width := IfThen(Narrow, 70, 82);
  if FMcpPanel <> nil then
    FMcpPanel.Align := TAlignLayout.Client;
  if FMcpSchemaPanel <> nil then
    FMcpSchemaPanel.Height := IfThen(Narrow, 132, IfThen(Compact, 146, 156));
  if FMcpArgsPanel <> nil then
    FMcpArgsPanel.Height := IfThen(Narrow, 108, IfThen(Compact, 122, 132));
  if FMcpResultPanel <> nil then
    FMcpResultPanel.Height := IfThen(Narrow, 156, IfThen(Compact, 164, 176));
  if FMcpResultDetailMemo <> nil then
    FMcpResultDetailMemo.Height := IfThen(Narrow, 86, IfThen(Compact, 104, 128));
  if FRelayUrlEdit <> nil then
    FRelayUrlEdit.Width := IfThen(Narrow, 170, IfThen(Compact, 230, 300));
  if FRelayShowTokenButton <> nil then
    SetButtonWidth(FRelayShowTokenButton, IfThen(Narrow, 58, 68));
  if FRelayWorkerCommandEdit <> nil then
    FRelayWorkerCommandEdit.Width := IfThen(Narrow, 104, IfThen(Compact, 146, 190));
  if FRelayWorkerConnectButton <> nil then
    SetButtonWidth(FRelayWorkerConnectButton, IfThen(Narrow, 72, 82));
  if FRelayWorkerDisconnectButton <> nil then
    SetButtonWidth(FRelayWorkerDisconnectButton, IfThen(Narrow, 82, 92));
  if FRelayWorkerProfileCombo <> nil then
    FRelayWorkerProfileCombo.Width := IfThen(Narrow, 96, IfThen(Compact, 116, 136));
  if FRelayWorkerIdEdit <> nil then
    FRelayWorkerIdEdit.Width := IfThen(Narrow, 120, IfThen(Compact, 160, 240));
  if FWorkflowLlmProviderEdit <> nil then
    FWorkflowLlmProviderEdit.Width := IfThen(Narrow, 104, 142);
  if FWorkflowReplicateVersionEdit <> nil then
    FWorkflowReplicateVersionEdit.Width := IfThen(Narrow, 132, 172);
  if FWorkflowReplicateSearchEdit <> nil then
    FWorkflowReplicateSearchEdit.Width := IfThen(Narrow, 108, 140);
  if FWorkflowGraphMemo <> nil then
  begin
    FWorkflowGraphMemo.Visible := False;
    FWorkflowGraphMemo.Height := 0;
  end;
  if FWorkflowPickerCombo <> nil then
  begin
    FWorkflowPickerCombo.Visible := not Narrow;
    FWorkflowPickerCombo.Width := IfThen(Compact, 144, 180);
  end;
  if FMemoryTabs <> nil then
    FMemoryTabs.Align := TAlignLayout.Client;
  if FSettingsTabs <> nil then
    FSettingsTabs.Align := TAlignLayout.Client;
  if FWorkflowInputsEdit <> nil then
    FWorkflowInputsEdit.Width := IfThen(Narrow, 140, IfThen(Compact, 190, 270));
  if FWorkflowOutputsMemo <> nil then
    FWorkflowOutputsMemo.Width := IfThen(Narrow, 180, IfThen(Compact, 240, 340));
  if FWorkflowEditorPanel <> nil then
    FWorkflowEditorPanel.Align := TAlignLayout.Client;
  if FWorkflowLeftPane <> nil then
  begin
    FWorkflowLeftPane.Visible := not Narrow;
    FWorkflowLeftPane.Width := IfThen(Compact, 156, 180);
  end;
  if FWorkflowRightPane <> nil then
  begin
    if Compact then
    begin
      FWorkflowRightPane.Align := TAlignLayout.Bottom;
      FWorkflowRightPane.Height := IfThen(Narrow, 260, 220);
      SetControlMargins(FWorkflowRightPane, 0, GAP_S, 0, 0);
    end
    else
    begin
      FWorkflowRightPane.Align := TAlignLayout.Right;
      FWorkflowRightPane.Width := 280;
      SetControlMargins(FWorkflowRightPane, GAP_S, 0, 0, 0);
    end;
  end;
  if FWorkflowSchemaForm <> nil then
    FWorkflowSchemaForm.Height := IfThen(Narrow, 64, IfThen(Compact, 76, 88));
  if FWorkflowReplicateResultsList <> nil then
    FWorkflowReplicateResultsList.Height := IfThen(Narrow, 48, 56);
  if FWorkflowNodeArgsMemo <> nil then
    FWorkflowNodeArgsMemo.Height := IfThen(Narrow, 58, IfThen(Compact, 64, 72));
  if FWorkflowEdgesList <> nil then
    FWorkflowEdgesList.Height := IfThen(Compact, 54, 72);
  if FWorkflowRunInputsMemo <> nil then
    FWorkflowRunInputsMemo.Height := IfThen(Compact, 44, 50);
  if FWorkflowRunResultsList <> nil then
    FWorkflowRunResultsList.Height := IfThen(Narrow, 58, IfThen(Compact, 68, 88));
  if FWorkflowCanvas <> nil then
    FWorkflowCanvas.Repaint;
  if FOnboardingCard <> nil then
  begin
    FOnboardingCard.Width := Min(560, Max(300, ClientWidth - 32));
    FOnboardingCard.Height := IfThen(Narrow, 360, 320);
  end;
end;

procedure TMasterDetailForm.SessionSplitterMoved(Sender: TObject);
var
  Compact: Boolean;
  MaxDrawerWidth: Single;
  MinDrawerWidth: Single;
begin
  if FSessionDrawer = nil then
    Exit;

  Compact := ClientWidth < 820;
  if Compact then
  begin
    MinDrawerWidth := 260;
    MaxDrawerWidth := Max(260.0, ClientWidth - 48);
  end
  else
  begin
    MinDrawerWidth := 220;
    MaxDrawerWidth := Min(420.0, Max(260.0, ClientWidth * 0.34));
  end;

  FSessionDrawerWidth := Min(Max(FSessionDrawer.Width, MinDrawerWidth),
    MaxDrawerWidth);
  if Abs(FSessionDrawer.Width - FSessionDrawerWidth) > 0.5 then
    FSessionDrawer.Width := FSessionDrawerWidth;
end;

procedure TMasterDetailForm.SetSidebarVisible(Value: Boolean; Persist: Boolean);
{ The ONE way the sessions drawer opens or closes.

  A transition changes the width the chat is measured against, so it has to
  re-measure AND re-render: bubbles bake their width in at render time, so a
  measure change alone leaves them at the old width. (The 800px cap itself no
  longer depends on the drawer -- only the margins around it do -- but the
  re-render is needed either way.) Three callers used to flip FSidebarVisible
  by hand and only one of them re-measured, so picking a session on a compact
  layout left the transcript and the composer disagreeing.

  The refresh is deferred because at call time FChatScroll.Width is still the
  PRE-transition value; FMX applies the new alignment later in the frame. }
begin
  FSidebarVisible := Value;
  if FSessionDrawer <> nil then
  begin
    if Value then
      FSessionDrawer.ShowMaster
    else
      FSessionDrawer.HideMaster;
  end;
  ApplyResponsiveLayout;
  if Persist then
    SaveLocalSettings;
  TThread.ForceQueue(nil,
    procedure
    var
      PriorWidth: Single;
    begin
      { Re-measure always; re-RENDER only if the column actually moved.
        Since the cap stopped following the drawer, hiding it on any window
        wider than the measure changes the margins and nothing else -- the
        bubbles are already the right width. Rebuilding every one of them to
        discover that is what made the toggle lag. }
      PriorWidth := 0;
      if FChatFlow <> nil then
        PriorWidth := FChatFlow.Width;
      ApplyChatMeasure;
      if (FChatFlow <> nil) and (Abs(FChatFlow.Width - PriorWidth) > 0.5) then
        RenderChat;
    end);
end;

procedure TMasterDetailForm.ToggleSessionsClick(Sender: TObject);
begin
  SetSidebarVisible(not FSidebarVisible, True);
end;

procedure TMasterDetailForm.BuildInterface;
var
  Btn: TButton;
  Chrome: TRectangle;
  DrawerHeader: TLayout;
  EndpointBar: TLayout;
  LabelControl: TLabel;
  GatewayBody: TLayout;
  GatewayTab: TTabItem;
  LogMemo: TMemo;
  MemoryTab: TTabItem;
  MemoryTabs: TTabControl;
  NativeBar: TLayout;
  NavHost: TLayout;
  SessionButtons: TLayout;
  WorkspaceLabel: TLabel;
  ActionRow: TLayout;
  SettingsTab: TTabItem;
  SettingsTabs: TTabControl;
  TokenRow: TLayout;
  SearchLabel: TLabel;
begin
  Fill.Color := UI_BG;
  OnKeyDown := FormKeyDown;
  OnResize := FormResize;

  FTopBar := TLayout.Create(Self);
  FTopBar.Parent := Self;
  FTopBar.Align := TAlignLayout.Top;
  FTopBar.Height := ROW_CARD;
  SetControlPadding(FTopBar, 10, GAP_S, 10, GAP_S);

  { A separator, not a box. This was a full rectangle outline around the top
    bar: three of its four edges hug the window frame and the fourth reads as
    a stray dark rule under the title, which is exactly how it was reported.
    A header deserves a hairline beneath it, so that is all this draws -- and
    at UI_BORDER strength on a light ground it was too heavy, so it takes the
    softer separator tone. }
  FHeaderRule := TRectangle.Create(Self);
  FHeaderRule.Parent := FTopBar;
  FHeaderRule.Align := TAlignLayout.Bottom;
  FHeaderRule.Height := 1;
  FHeaderRule.HitTest := False;
  FHeaderRule.Stroke.Kind := TBrushKind.None;
  FHeaderRule.Fill.Kind := TBrushKind.Solid;
  FHeaderRule.SendToBack;
  { colour comes from ApplyTheme, not from here: BuildInterface runs while
    FDarkStyleEnabled is still True, so a colour resolved at this point is
    the DARK one, and a restored ui.dark_style=false would never repaint it
    -- RestyleCoreControls walks labels and controls, not TRectangle
    brushes. Held as a field so the theme pass can reach it. }
  ApplyHeaderRuleTheme;

  FHeaderRow := TLayout.Create(Self);
  FHeaderRow.Parent := FTopBar;
  FHeaderRow.Align := TAlignLayout.Top;
  FHeaderRow.Height := ROW_BAR;

  FSessionToggleButton := TButton.Create(Self);
  FSessionToggleButton.Parent := FHeaderRow;
  FSessionToggleButton.Align := TAlignLayout.Left;
  FSessionToggleButton.Width := 42;
  FSessionToggleButton.OnClick := ToggleSessionsClick;
  SetIconButton(FSessionToggleButton, 'menutoolbutton',
    'Show or hide the sessions drawer', #$2630);
  SetControlMargins(FSessionToggleButton, 0, 0, GAP_S, 0);

  LabelControl := TLabel.Create(Self);
  FTitleLabel := LabelControl;
  LabelControl.Parent := FHeaderRow;
  LabelControl.Align := TAlignLayout.Left;
  LabelControl.Width := 142;
  LabelControl.Text := 'PASCLAW STUDIO';
  LabelControl.TextSettings.HorzAlign := TTextAlign.Leading;
  LabelControl.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(LabelControl, UI_ACCENT, TXT_TITLE, True);

  FRefreshButton := TButton.Create(Self);
  FRefreshButton.Parent := FHeaderRow;
  FRefreshButton.Align := TAlignLayout.Right;
  FRefreshButton.Width := 92;
  RenderConnectButton;
  FRefreshButton.OnClick := RefreshClick;
  SetControlMargins(FRefreshButton, GAP_S, 0, 0, 0);

  FThemeButton := TButton.Create(Self);
  FThemeButton.Parent := FHeaderRow;
  FThemeButton.Align := TAlignLayout.Right;
  FThemeButton.Width := 70;
  FThemeButton.Text := 'Light';
  FThemeButton.OnClick := ThemeClick;
  SetControlMargins(FThemeButton, GAP_S, 0, 0, 0);
  ApplyTheme;

  FStatusLabel := TLabel.Create(Self);
  FStatusLabel.Parent := FHeaderRow;
  FStatusLabel.Align := TAlignLayout.Client;
  FStatusLabel.Text := 'offline';
  FStatusLabel.TextSettings.HorzAlign := TTextAlign.Trailing;
  FStatusLabel.TextSettings.VertAlign := TTextAlign.Center;
  FStatusLabel.StyledSettings := FStatusLabel.StyledSettings -
    [TStyledSetting.FontColor];
  UseStyledLabelColor(FStatusLabel);
  SetControlMargins(FStatusLabel, GAP_S, 0, GAP_M, 0);

  FConnectionRow := TLayout.Create(Self);
  FConnectionRow.Parent := Self;
  FConnectionRow.Align := TAlignLayout.None;
  FConnectionRow.Visible := False;
  FConnectionRow.Width := 1;
  FConnectionRow.Height := 1;

  FTokenEdit := TEdit.Create(Self);
  FTokenEdit.Parent := FConnectionRow;
  FTokenEdit.Align := TAlignLayout.Right;
  FTokenEdit.Width := 210;
  FTokenEdit.Password := True;
  FTokenEdit.TextPrompt := 'bearer token';
  FTokenEdit.OnChange := GatewaySettingsChange;

  FTokenShowButton := TButton.Create(Self);
  FTokenShowButton.Parent := FConnectionRow;
  FTokenShowButton.Align := TAlignLayout.Right;
  FTokenShowButton.Width := 58;
  FTokenShowButton.Text := 'Show';
  FTokenShowButton.OnClick := TokenToggleClick;

  FTokenClearButton := TButton.Create(Self);
  FTokenClearButton.Parent := FConnectionRow;
  FTokenClearButton.Align := TAlignLayout.Right;
  FTokenClearButton.Width := 58;
  FTokenClearButton.Text := 'Clear';
  FTokenClearButton.OnClick := TokenClearClick;

  FGatewayEdit := TEdit.Create(Self);
  FGatewayEdit.Parent := FConnectionRow;
  FGatewayEdit.Align := TAlignLayout.Client;
  FGatewayEdit.TextPrompt := 'gateway URL';
  FGatewayEdit.OnChange := GatewaySettingsChange;

  FBodyLayout := TLayout.Create(Self);
  FBodyLayout.Parent := Self;
  FBodyLayout.Align := TAlignLayout.Client;

  FSessionDrawer := TMultiView.Create(Self);
  FSessionDrawer.Parent := FBodyLayout;
  FSessionDrawer.Align := TAlignLayout.Left;
  FSessionDrawer.Width := FSessionDrawerWidth;
  FSessionDrawer.Mode := TMultiViewMode.Panel;

  FSidebar := TLayout.Create(Self);
  FSidebar.Parent := FSessionDrawer;
  FSidebar.Align := TAlignLayout.Client;
  SetControlPadding(FSidebar, GAP_M, GAP_M, 10, GAP_M);

  Chrome := TRectangle.Create(Self);
  Chrome.Parent := FSidebar;
  Chrome.Align := TAlignLayout.Contents;
  StyleChromeRect(Chrome, UI_PANEL, UI_BORDER, 0, False);
  Chrome.SendToBack;

  DrawerHeader := TLayout.Create(Self);
  DrawerHeader.Parent := FSidebar;
  DrawerHeader.Align := TAlignLayout.Top;
  DrawerHeader.Height := ROW_BAR;

  { Creating a session is a SESSIONS action, so it belongs to the sessions
    header, not the app-wide toolbar. Right-aligned children first, then the
    title as Client, so the title takes what is left. }
  Btn := TButton.Create(Self);
  FNewSessionButton := Btn;
  Btn.Parent := DrawerHeader;
  Btn.Align := TAlignLayout.Right;
  { Created at CAPTION width. ApplyButtonIcon only ever shrinks a button, so
    starting text-safe means the icon-less fallback -- [ui] icon_buttons=false,
    or a style without the glyph -- is readable instead of a clipped 34px
    stub, and iconification still lands on ICON_BTN_W. }
  Btn.Width := BTN_W_L;
  Btn.Text := '+ Session';      { ApplyButtonIcon swaps in the add glyph }
  Btn.OnClick := NewSessionClick;
  SetControlMargins(Btn, GAP_S, 2, 0, 2);

  FSessionSearchButton := TButton.Create(Self);
  FSessionSearchButton.Parent := DrawerHeader;
  FSessionSearchButton.Align := TAlignLayout.Right;
  FSessionSearchButton.Width := 84;      { caption width; see above }
  FSessionSearchButton.Text := 'Search';
  FSessionSearchButton.OnClick := SessionSearchToggleClick;
  SetControlMargins(FSessionSearchButton, GAP_S, 2, 0, 2);

  SearchLabel := TLabel.Create(Self);
  SearchLabel.Parent := DrawerHeader;
  SearchLabel.Align := TAlignLayout.Client;
  SearchLabel.Text := 'Sessions';
  SearchLabel.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(SearchLabel, UI_CHROME_TEXT, TXT_BODY, True);

  { the filter box is summoned by the search icon; a permanently open field
    is a control the list wears whether or not anyone is filtering }
  FSessionSearch := TEdit.Create(Self);
  FSessionSearch.Parent := FSidebar;
  FSessionSearch.Align := TAlignLayout.Top;
  FSessionSearch.TextPrompt := 'filter sessions';
  FSessionSearch.OnChange := SessionSearchChange;
  FSessionSearch.OnKeyDown := SessionSearchKeyDown;
  RenderSessionSearchBox;

  FSessionList := TListBox.Create(Self);
  FSessionList.Parent := FSidebar;
  FSessionList.Align := TAlignLayout.Client;
  FSessionList.OnChange := SessionListChange;

  SessionButtons := TLayout.Create(Self);
  SessionButtons.Parent := FSidebar;
  SessionButtons.Align := TAlignLayout.Bottom;
  SessionButtons.Height := ROW_LIST;
  SetControlMargins(SessionButtons, 0, GAP_S, 0, 0);

  FDeleteSessionButton := TButton.Create(Self);
  FDeleteSessionButton.Parent := SessionButtons;
  FDeleteSessionButton.Align := TAlignLayout.Client;
  FDeleteSessionButton.Text := 'Delete Session';
  FDeleteSessionButton.OnClick := DeleteSessionClick;

  { Web-UI parity: per-session export (portable JSON) + import (ChatGPT /
    Claude Code / Pi / OpenClaw / PasClaw exports, auto-detected server-side). }
  Btn := TButton.Create(Self);
  Btn.Parent := SessionButtons;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Export';
  Btn.OnClick := SessionExportClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := SessionButtons;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Import';
  Btn.OnClick := SessionImportClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  { OpenCode keeps a session split across per-message files, so it imports as
    a DIRECTORY rather than a single export blob. }
  Btn := TButton.Create(Self);
  Btn.Parent := SessionButtons;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Import Dir';
  Btn.OnClick := SessionImportDirClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FSessionSplitter := TSplitter.Create(Self);
  FSessionSplitter.Parent := FBodyLayout;
  FSessionSplitter.Align := TAlignLayout.Left;
  FSessionSplitter.Width := 8;
  FSessionSplitter.MinSize := 220;
  FSessionSplitter.ShowGrip := True;
  FSessionSplitter.OnMoved := SessionSplitterMoved;

  FContentLayout := TLayout.Create(Self);
  FContentLayout.Parent := FBodyLayout;
  FContentLayout.Align := TAlignLayout.Client;

  FTopBar.Parent := FContentLayout;
  FTopBar.Align := TAlignLayout.Top;

  NavHost := TLayout.Create(Self);
  NavHost.Parent := FContentLayout;
  NavHost.Align := TAlignLayout.Top;
  NavHost.Height := 0;
  NavHost.Visible := False;
  FNavHost := NavHost;
  SetControlMargins(NavHost, 0, 0, 0, 0);
  SetControlPadding(NavHost, 0, 0, 0, 0);

  Chrome := TRectangle.Create(Self);
  Chrome.Parent := NavHost;
  Chrome.Align := TAlignLayout.Contents;
  StyleChromeRect(Chrome, UI_PANEL, UI_BORDER, 6, False);
  Chrome.SendToBack;

  FNavScroll := THorzScrollBox.Create(Self);
  FNavScroll.Parent := NavHost;
  FNavScroll.Align := TAlignLayout.Client;

  FNavCombo := TComboBox.Create(Self);
  FNavCombo.Parent := NavHost;
  FNavCombo.Align := TAlignLayout.Client;
  FNavCombo.Visible := False;
  FNavCombo.OnChange := NavComboChange;

  FTabControl := TTabControl.Create(Self);
  FTabControl.Parent := FContentLayout;
  FTabControl.Align := TAlignLayout.Client;
  FTabControl.TabPosition := TTabPosition.Top;
  SetControlMargins(FTabControl, 0, 10, 10, 10);
  FSessionDrawer.TargetControl := FContentLayout;

  BuildChatTab;

  EndpointBar := BuildEndpointTab('memory', 'Memory', '/v1/memory',
    'Browse workspace memory files, facts, search results, and local reranking setup.');
  MemoryTabs := TTabControl.Create(Self);
  FMemoryTabs := MemoryTabs;
  MemoryTabs.Parent := EndpointBar.Parent;
  MemoryTabs.Align := TAlignLayout.Client;
  MemoryTabs.TabPosition := TTabPosition.Top;
  SetControlMargins(MemoryTabs, GAP_M, GAP_S, GAP_M, GAP_S);

  MemoryTab := TTabItem.Create(Self);
  MemoryTab.Parent := MemoryTabs;
  MemoryTab.Text := 'Notes';
  BuildMemoryBrowserPanel(MemoryTab);

  MemoryTab := TTabItem.Create(Self);
  MemoryTab.Parent := MemoryTabs;
  MemoryTab.Text := 'Facts';
  BuildMemoryFactsPanel(MemoryTab);

  MemoryTab := TTabItem.Create(Self);
  MemoryTab.Parent := MemoryTabs;
  MemoryTab.Text := 'Setup';
  BuildMemorySetupPanel(MemoryTab);
  MemoryTabs.TabIndex := 0;

  EndpointBar := BuildEndpointTab('kb', 'KB', '/v1/kb',
    'Knowledge-base sources and search. Edit the endpoint to /v1/kb/search?q=term.');
  BuildKbPanel(EndpointBar.Parent);

  EndpointBar := BuildEndpointTab('files', 'Files', '/v1/fs',
    'Workspace and launch-directory browser. Edit to /v1/fs/read?path=... for a file preview.');
  BuildFilesBrowserPanel(EndpointBar.Parent);

  EndpointBar := BuildEndpointTab('mcp', 'MCP', '/v1/mcp',
    'Configured MCP servers and available tools.');
  BuildMcpPanel(EndpointBar.Parent);

  EndpointBar := BuildEndpointTab('cron', 'Cron', '/v1/cron',
    'Scheduled skill and workflow jobs.');
  BuildCronPanel(EndpointBar.Parent);

  EndpointBar := BuildEndpointTab('skills', 'Skills', '/v1/skills',
    'Installed and pending skills. Search with /v1/skills/search?q=term.');
  BuildSkillsPanel(EndpointBar.Parent);

  EndpointBar := BuildEndpointTab('workflow', 'Workflow', '/v1/workflows',
    'Workflow definitions. Run a workflow from chat or edit the endpoint manually.');
  BuildWorkflowEditorPanel(EndpointBar.Parent);

  EndpointBar := BuildEndpointTab('vault', 'Vault', '/v1/vault?q=delphi',
    'Search the pasclaw.dev Code Vault for Delphi and Object Pascal libraries.');
  BuildVaultPanel(EndpointBar.Parent);

  EndpointBar := BuildEndpointTab('logs', 'Logs', '/v1/logs',
    'Tail the same /v1/logs Server-Sent Events stream used by the Web UI.');

  NativeBar := TLayout.Create(Self);
  NativeBar.Parent := EndpointBar.Parent;
  NativeBar.Align := TAlignLayout.Top;
  NativeBar.Height := ROW_BAR;
  SetControlMargins(NativeBar, GAP_M, 0, GAP_M, GAP_S);

  Btn := TButton.Create(Self);
  Btn.Parent := NativeBar;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Clear';
  Btn.OnClick := LogsClearClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := NativeBar;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Stop';
  Btn.TagString := 'stop';
  Btn.OnClick := LogsClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := NativeBar;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Tail';
  Btn.TagString := 'start';
  Btn.OnClick := LogsClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FLogsStatusLabel := TLabel.Create(Self);
  FLogsStatusLabel.Parent := NativeBar;
  FLogsStatusLabel.Align := TAlignLayout.Client;
  FLogsStatusLabel.Height := H_INPUT;
  FLogsStatusLabel.Text := 'disconnected';
  FLogsStatusLabel.TextSettings.VertAlign := TTextAlign.Center;
  FLogsStatusLabel.StyledSettings := FLogsStatusLabel.StyledSettings -
    [TStyledSetting.FontColor];
  UseStyledLabelColor(FLogsStatusLabel);
  SetControlMargins(FLogsStatusLabel, GAP_S, 0, GAP_S, GAP_XS);

  if FPaneMemos.TryGetValue('logs', LogMemo) then
  begin
    LogMemo.Parent := EndpointBar.Parent;
    LogMemo.Align := TAlignLayout.Client;
    LogMemo.Visible := True;
    SetControlMargins(LogMemo, GAP_M, 0, GAP_M, 10);
  end;

  EndpointBar := BuildEndpointTab('stats', 'Stats', '/v1/stats',
    'Token, turn, tool-call, provider, and model aggregate stats.');
  BuildStatsPanel(EndpointBar.Parent);

  EndpointBar := BuildEndpointTab('checkpoints', 'Checkpoints',
    '/v1/checkpoints',
    'Workspace undo and redo state scoped by X-PasClaw-Session when a chat is active.');
  BuildCheckpointPanel(EndpointBar.Parent);

  EndpointBar := BuildEndpointTab('relay', 'Relay', '/v1/relay/status',
    'Outbound relay worker status and queue depth.');
  BuildRelayPanel(EndpointBar.Parent);

  EndpointBar := BuildEndpointTab('settings', 'Settings', '/v1/config',
    'Raw gateway config. The native client reads config here and sends chat settings per request.');

  NativeBar := TLayout.Create(Self);
  NativeBar.Parent := EndpointBar.Parent;
  NativeBar.Align := TAlignLayout.Top;
  NativeBar.Height := ROW_BAR;
  SetControlMargins(NativeBar, GAP_M, 0, GAP_M, GAP_S);

  { name the row: three unrelated-looking buttons floating in a toolbar read
    as leftovers; under a label they read as the workspace section }
  WorkspaceLabel := TLabel.Create(Self);
  WorkspaceLabel.Parent := NativeBar;
  WorkspaceLabel.Align := TAlignLayout.Left;
  WorkspaceLabel.Width := 160;
  WorkspaceLabel.Text := 'Workspace backup';
  WorkspaceLabel.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(WorkspaceLabel, UI_CHROME_TEXT, TXT_BODY, True);

  Btn := TButton.Create(Self);
  Btn.Parent := NativeBar;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Save ZIP';
  Btn.OnClick := WorkspaceExportClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := NativeBar;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Import ZIP';
  Btn.OnClick := WorkspaceImportClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := NativeBar;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Onboard';
  Btn.OnClick := OnboardingShowClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  SettingsTabs := TTabControl.Create(Self);
  FSettingsTabs := SettingsTabs;
  SettingsTabs.Parent := EndpointBar.Parent;
  SettingsTabs.Align := TAlignLayout.Client;
  SettingsTabs.TabPosition := TTabPosition.Top;
  SetControlMargins(SettingsTabs, GAP_M, GAP_S, GAP_M, GAP_S);

  GatewayTab := TTabItem.Create(Self);
  GatewayTab.Parent := SettingsTabs;
  GatewayTab.Text := 'Gateway';

  { Phase 2 of docs/studio-metrics-plan.md. Was: one 104px panel guessing its
    own height, with a URL box, a Connect button, a token box, Show and a
    trash icon all crammed onto a single unlabelled row -- nothing said which
    box was which, and the fixed height had no relationship to the contents.

    Now two labelled rows on the shared form grid. The panel sizes itself
    from them, so the guess is gone, and each field is named. }
  GatewayBody := TLayout.Create(Self);
  GatewayBody.Parent := GatewayTab;
  GatewayBody.Align := TAlignLayout.Top;
  SetControlPadding(GatewayBody, GAP_M, GAP_M, GAP_M, GAP_M);
  AddPanelChrome(GatewayBody, False);
  AddSectionHeader(GatewayBody, 'Gateway connection');

  { FConnectionRow is a construction-time holder only: the four controls are
    created into it before the Settings tab exists, and every one of them is
    re-parented onto a form row below. It stays hidden on the form -- moving
    an emptied layout into the panel would add a phantom row. }
  AddFormRow(GatewayBody, 'Server URL', FGatewayEdit);
  TokenRow := AddFormRow(GatewayBody, 'Bearer token', nil);

  FTokenEdit.Parent := TokenRow;
  FTokenEdit.Align := TAlignLayout.Client;
  FTokenEdit.Height := H_INPUT;
  SetControlMargins(FTokenEdit, 0, GAP_XS div 2, 0, GAP_XS div 2);

  FTokenShowButton.Parent := TokenRow;
  FTokenShowButton.Align := TAlignLayout.Right;
  SetControlMargins(FTokenShowButton, GAP_S, GAP_XS div 2, 0, GAP_XS div 2);

  FTokenClearButton.Parent := TokenRow;
  FTokenClearButton.Align := TAlignLayout.Right;
  SetControlMargins(FTokenClearButton, GAP_S, GAP_XS div 2, 0, GAP_XS div 2);

  ActionRow := TLayout.Create(Self);
  ActionRow.Parent := GatewayBody;
  ActionRow.Align := TAlignLayout.Top;
  ActionRow.Height := ROW_BAR;
  SetControlMargins(ActionRow, FORM_LABEL_W + GAP_M, GAP_XS, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := ActionRow;
  Btn.Align := TAlignLayout.Left;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Connect';
  Btn.OnClick := RefreshClick;

  { header + three rows + the panel's own vertical padding, so the panel can
    never disagree with what it contains }
  GatewayBody.Height := ROW_TEXT + GAP_XS + ROW_FORM * 2 + ROW_BAR +
                        GAP_XS * 3 + GAP_M * 2;

  SettingsTab := TTabItem.Create(Self);
  SettingsTab.Parent := SettingsTabs;
  SettingsTab.Text := 'Providers';
  BuildProviderSetupPanel(SettingsTab);

  SettingsTab := TTabItem.Create(Self);
  SettingsTab.Parent := SettingsTabs;
  { 'Advanced', not 'Config': it is the raw gateway JSON, and naming it
    plainly keeps casual visitors in the Gateway/Providers forms }
  SettingsTab.Text := 'Advanced';
  BuildConfigEditorPanel(SettingsTab);
  SettingsTabs.TabIndex := 0;

  BuildOnboardingOverlay;
  FTabControl.TabIndex := 0;
  FLastActivatedTab := 'Chat';
  FTabControl.OnChange := TabControlChange;
  UpdateNavButtons;
end;

procedure TMasterDetailForm.BuildChatTab;
var
  Btn: TButton;
  Chrome: TRectangle;
  Composer: TLayout;
  Params: TLayout;
  PresetRow: TLayout;
  SamplingRow: TLayout;
  SendPanel: TLayout;
  Tab: TTabItem;
  TopLine: TLayout;
  TranscriptBody: TLayout;
  L: TLabel;
begin
  Tab := TTabItem.Create(Self);
  Tab.Parent := FTabControl;
  Tab.Text := 'Chat';
  AddNavigationButton(Tab.Text);

  TopLine := TLayout.Create(Self);
  TopLine.Parent := Tab;
  TopLine.Align := TAlignLayout.Top;
  TopLine.Height := ROW_LIST;
  SetControlPadding(TopLine, 10, 5, 10, 3);

  { No chrome rect behind the chat toolbar: with the buttons iconified it
    framed mostly empty space, and an outlined box holding nothing reads as
    a control that failed to load. The row needs no ground of its own. }
  FParamsToggleButton := TButton.Create(Self);
  FParamsToggleButton.Parent := TopLine;
  { far right, captioned like the drop-down it actually is }
  FParamsToggleButton.Align := TAlignLayout.Right;
  FParamsToggleButton.Width := 92;
  FParamsToggleButton.OnClick := ParamsToggleClick;
  SetControlMargins(FParamsToggleButton, GAP_S, 0, 0, 0);
  RenderParamsButton;

  FToolsToggleButton := TButton.Create(Self);
  FToolsToggleButton.Parent := TopLine;
  FToolsToggleButton.Align := TAlignLayout.Left;
  FToolsToggleButton.Width := 86;
  FToolsToggleButton.OnClick := ChatToolsToggleClick;
  RenderToolsButton;
  SetControlMargins(FToolsToggleButton, 0, 0, GAP_S, 0);

  FParamsSummaryLabel := TLabel.Create(Self);
  FParamsSummaryLabel.Parent := TopLine;
  FParamsSummaryLabel.Align := TAlignLayout.Left;
  FParamsSummaryLabel.Width := 150;
  FParamsSummaryLabel.Text := 'defaults';
  FParamsSummaryLabel.TextSettings.VertAlign := TTextAlign.Center;
  FParamsSummaryLabel.StyledSettings := FParamsSummaryLabel.StyledSettings -
    [TStyledSetting.FontColor];
  FParamsSummaryLabel.TextSettings.FontColor := $FFB5C3D5;
  SetControlMargins(FParamsSummaryLabel, 0, 0, GAP_S, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := TopLine;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Files';
  Btn.OnClick := ChatFilesClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FRedoButton := TButton.Create(Self);
  FRedoButton.Parent := TopLine;
  FRedoButton.Align := TAlignLayout.Right;
  FRedoButton.Width := 70;
  FRedoButton.Text := 'Redo';
  FRedoButton.TagString := 'redo';
  FRedoButton.OnClick := ChatCheckpointClick;
  SetControlMargins(FRedoButton, GAP_S, 0, 0, 0);

  FUndoButton := TButton.Create(Self);
  FUndoButton.Parent := TopLine;
  FUndoButton.Align := TAlignLayout.Right;
  FUndoButton.Width := 70;
  FUndoButton.Text := 'Undo';
  FUndoButton.TagString := 'undo';
  FUndoButton.OnClick := ChatCheckpointClick;
  SetControlMargins(FUndoButton, GAP_S, 0, 0, 0);

  Params := TLayout.Create(Self);
  FChatParamsLayout := Params;
  Params.Parent := Tab;
  Params.Align := TAlignLayout.Top;
  Params.Height := IfThen(FChatParamsVisible, 126, 0);
  Params.Visible := FChatParamsVisible;
  SetControlPadding(Params, 10, GAP_XS, 10, GAP_S);

  Chrome := TRectangle.Create(Self);
  Chrome.Parent := Params;
  Chrome.Align := TAlignLayout.Contents;
  StyleChromeRect(Chrome, UI_PANEL, UI_BORDER, 6, False);
  Chrome.SendToBack;

  PresetRow := TLayout.Create(Self);
  PresetRow.Parent := Params;
  PresetRow.Align := TAlignLayout.Top;
  PresetRow.Height := ROW_BAR;
  SetControlPadding(PresetRow, 0, 0, 0, GAP_S);

  FPromptPresetCombo := TComboBox.Create(Self);
  FPromptPresetCombo.Parent := PresetRow;
  FPromptPresetCombo.Align := TAlignLayout.Left;
  FPromptPresetCombo.Width := 190;
  FPromptPresetCombo.Items.Add('Preset -');
  FPromptPresetCombo.ItemIndex := 0;
  FPromptPresetCombo.OnChange := PromptPresetChange;
  SetControlMargins(FPromptPresetCombo, 0, 0, GAP_S, 0);

  FPresetDeleteButton := TButton.Create(Self);
  FPresetDeleteButton.Parent := PresetRow;
  FPresetDeleteButton.Align := TAlignLayout.Right;
  FPresetDeleteButton.Width := 68;
  FPresetDeleteButton.Text := 'Delete';
  FPresetDeleteButton.OnClick := DeletePresetClick;
  SetControlMargins(FPresetDeleteButton, GAP_S, 0, 0, 0);

  FPresetSaveButton := TButton.Create(Self);
  FPresetSaveButton.Parent := PresetRow;
  FPresetSaveButton.Align := TAlignLayout.Right;
  FPresetSaveButton.Width := 62;
  FPresetSaveButton.Text := 'Save';
  FPresetSaveButton.OnClick := SavePresetClick;
  SetControlMargins(FPresetSaveButton, GAP_S, 0, 0, 0);

  FParamsResetButton := TButton.Create(Self);
  FParamsResetButton.Parent := PresetRow;
  FParamsResetButton.Align := TAlignLayout.Right;
  FParamsResetButton.Width := 62;
  FParamsResetButton.Text := 'Reset';
  FParamsResetButton.OnClick := ResetParamsClick;
  SetControlMargins(FParamsResetButton, GAP_S, 0, 0, 0);

  FPresetNameEdit := TEdit.Create(Self);
  FPresetNameEdit.Parent := PresetRow;
  FPresetNameEdit.Align := TAlignLayout.Client;
  FPresetNameEdit.TextPrompt := 'preset name';

  SamplingRow := TLayout.Create(Self);
  SamplingRow.Parent := Params;
  SamplingRow.Align := TAlignLayout.Top;
  SamplingRow.Height := ROW_BAR;
  SetControlMargins(SamplingRow, 0, GAP_XS, 0, GAP_S);

  L := TLabel.Create(Self);
  L.Parent := SamplingRow;
  L.Align := TAlignLayout.Left;
  L.Width := 96;
  L.Text := 'Temperature';
  L.TextSettings.VertAlign := TTextAlign.Center;
  L.TextSettings.HorzAlign := TTextAlign.Trailing;
  StyleLabel(L, UI_MUTED, TXT_BODY, False);
  SetControlMargins(L, 0, 0, 10, 0);

  FTemperatureTrack := TTrackBar.Create(Self);
  FTemperatureTrack.Parent := SamplingRow;
  FTemperatureTrack.Align := TAlignLayout.Left;
  FTemperatureTrack.Width := 220;
  FTemperatureTrack.Min := 0;
  FTemperatureTrack.Max := 2;
  FTemperatureTrack.Value := 1;
  FTemperatureTrack.OnChange := TemperatureTrackChange;
  SetControlMargins(FTemperatureTrack, 0, 0, GAP_M, 0);

  L := TLabel.Create(Self);
  FTemperatureLabel := L;
  L.Parent := SamplingRow;
  L.Align := TAlignLayout.Left;
  L.Width := 42;
  L.Text := 'Temp';
  L.TextSettings.VertAlign := TTextAlign.Center;
  L.TextSettings.HorzAlign := TTextAlign.Trailing;
  StyleLabel(L, UI_MUTED, TXT_BODY, False);
  SetControlMargins(L, 0, 0, GAP_S, 0);

  FTemperatureEdit := TEdit.Create(Self);
  FTemperatureEdit.Parent := SamplingRow;
  FTemperatureEdit.Align := TAlignLayout.Left;
  FTemperatureEdit.Width := 68;
  FTemperatureEdit.KeyboardType := TVirtualKeyboardType.DecimalNumberPad;
  FTemperatureEdit.TextPrompt := 'auto';
  FTemperatureEdit.OnChange := ChatParamsChanged;
  SetControlMargins(FTemperatureEdit, 0, 0, 10, 0);

  L := TLabel.Create(Self);
  FMaxTokensLabel := L;
  L.Parent := SamplingRow;
  L.Align := TAlignLayout.Left;
  L.Width := 74;
  L.Text := 'Max tokens';
  L.TextSettings.VertAlign := TTextAlign.Center;
  L.TextSettings.HorzAlign := TTextAlign.Trailing;
  StyleLabel(L, UI_MUTED, TXT_BODY, False);
  SetControlMargins(L, 0, 0, GAP_S, 0);

  FMaxTokensEdit := TEdit.Create(Self);
  FMaxTokensEdit.Parent := SamplingRow;
  FMaxTokensEdit.Align := TAlignLayout.Left;
  FMaxTokensEdit.Width := 88;
  FMaxTokensEdit.KeyboardType := TVirtualKeyboardType.NumberPad;
  FMaxTokensEdit.TextPrompt := 'default';
  FMaxTokensEdit.OnChange := ChatParamsChanged;
  SetControlMargins(FMaxTokensEdit, 0, 0, GAP_M, 0);

  FSystemMemo := TMemo.Create(Self);
  FSystemMemo.Parent := Params;
  FSystemMemo.Align := TAlignLayout.Client;
  FSystemMemo.TextPrompt := 'System prompt override for this chat';
  FSystemMemo.WordWrap := True;
  FSystemMemo.OnChange := ChatParamsChanged;
  LoadPromptPresets;

  { A window-level footer, not a tab child: 'below the composer' still left
    it inside the chat tab's padding, a little adrift. On the form's bottom
    edge it is unambiguously the last line on screen. It belongs to the
    chat, so UpdateFooterVisibility hides it on every other tab. }
  FChatStatsLabel := TLabel.Create(Self);
  FChatStatsLabel.Parent := Self;
  FChatStatsLabel.Align := TAlignLayout.Bottom;
  FChatStatsLabel.Height := ROW_TEXT;
  FChatStatsLabel.Text := '0 turns';
  FChatStatsLabel.TextSettings.HorzAlign := TTextAlign.Center;
  FChatStatsLabel.TextSettings.VertAlign := TTextAlign.Center;
  FChatStatsLabel.StyledSettings := FChatStatsLabel.StyledSettings -
    [TStyledSetting.FontColor];
  FChatStatsLabel.TextSettings.FontColor := UI_MUTED;
  SetControlMargins(FChatStatsLabel, GAP_S, 0, GAP_S, 0);

  FSandboxLabel := TLabel.Create(Self);
  FSandboxLabel.Parent := Tab;
  FSandboxLabel.Align := TAlignLayout.Top;
  FSandboxLabel.Height := ROW_TEXT;
  FSandboxLabel.Text := 'shell: unknown';
  FSandboxLabel.TextSettings.VertAlign := TTextAlign.Center;
  FSandboxLabel.StyledSettings := FSandboxLabel.StyledSettings -
    [TStyledSetting.FontColor];
  FSandboxLabel.TextSettings.FontColor := $FFFFD166;
  SetControlMargins(FSandboxLabel, GAP_S, 0, GAP_S, 0);

  TranscriptBody := TLayout.Create(Self);
  TranscriptBody.Parent := Tab;
  TranscriptBody.Align := TAlignLayout.Client;
  SetControlMargins(TranscriptBody, 10, 0, 10, GAP_S);
  { no chrome rect here: the transcript is open canvas, not a boxed panel --
    an outline around the scroll area just competes with the chat text }

  FChatTurnList := TListBox.Create(Self);
  FChatTurnList.Parent := TranscriptBody;
  FChatTurnList.Align := TAlignLayout.Left;
  FChatTurnList.Width := 0;
  FChatTurnList.Visible := False;
  FChatTurnList.OnChange := ChatTurnListChange;
  SetControlMargins(FChatTurnList, 0, 0, 0, 0);

  FChatScroll := TVertScrollBox.Create(Self);
  FChatScroll.Parent := TranscriptBody;
  FChatScroll.Align := TAlignLayout.Client;
  FChatScroll.ShowScrollBars := True;

  FChatFlow := TFlowLayout.Create(Self);
  FChatFlow.Parent := FChatScroll;
  FChatFlow.Align := TAlignLayout.Top;
  FChatFlow.FlowDirection := TFlowDirection.LeftToRight;
  FChatFlow.Width := 640;
  FChatFlow.Height := 0;
  SetControlPadding(FChatFlow, GAP_S, GAP_S, GAP_S, GAP_S);

  FChatList := TListBox.Create(Self);
  FChatList.Parent := TranscriptBody;
  FChatList.Align := TAlignLayout.None;
  FChatList.Width := 0;
  FChatList.Height := 0;
  FChatList.Visible := False;
  FChatList.OnChange := ChatTranscriptChange;

  Composer := TLayout.Create(Self);
  FComposerLayout := Composer;
  Composer.Parent := Tab;
  Composer.Align := TAlignLayout.Bottom;
  Composer.Height := 176;
  SetControlPadding(Composer, 10, GAP_S, 10, GAP_S);

  Chrome := TRectangle.Create(Self);
  Chrome.Parent := Composer;
  Chrome.Align := TAlignLayout.Contents;
  { tier 3 -- the composer is where you act next, so it reads as live: a
    lifted ground and an accent border rather than the same panel chrome as
    every inert surface. }
  StyleChromeRect(Chrome, UI_COMPOSER_FILL, UI_COMPOSER_BORDER, 6, False);
  { stated explicitly: in the dark palette UI_COMPOSER_BORDER equals
    UI_ACCENT by VALUE, so classification alone records the wrong stroke
    role and a theme switch would repaint this border bright accent blue }
  SetChromeRoles(Chrome, 7, 8);
  Chrome.SendToBack;

  FQueueLabel := TLabel.Create(Self);
  FQueueLabel.Parent := Composer;
  FQueueLabel.Align := TAlignLayout.Top;
  FQueueLabel.Height := ROW_TEXT;
  FQueueLabel.Visible := False;
  FQueueLabel.TextSettings.VertAlign := TTextAlign.Center;
  FQueueLabel.StyledSettings := FQueueLabel.StyledSettings -
    [TStyledSetting.FontColor];
  FQueueLabel.TextSettings.FontColor := $FFFFD166;

  FAttachmentLabel := TLabel.Create(Self);
  FAttachmentLabel.Parent := Composer;
  FAttachmentLabel.Align := TAlignLayout.Top;
  FAttachmentLabel.Height := ROW_TEXT;
  FAttachmentLabel.Visible := False;
  FAttachmentLabel.TextSettings.VertAlign := TTextAlign.Center;
  FAttachmentLabel.StyledSettings := FAttachmentLabel.StyledSettings -
    [TStyledSetting.FontColor];
  FAttachmentLabel.TextSettings.FontColor := $FF20F6FF;

  FAttachmentStrip := THorzScrollBox.Create(Self);
  FAttachmentStrip.Parent := Composer;
  FAttachmentStrip.Align := TAlignLayout.Top;
  FAttachmentStrip.Height := 0;
  FAttachmentStrip.Visible := False;
  SetControlPadding(FAttachmentStrip, 0, 1, 0, 3);

  SendPanel := TLayout.Create(Self);
  SendPanel.Parent := Composer;
  SendPanel.Align := TAlignLayout.Bottom;
  SendPanel.Height := 42;
  SetControlPadding(SendPanel, 0, GAP_S, 0, 0);

  FModeButton := TButton.Create(Self);
  FModeButton.Parent := SendPanel;
  FModeButton.Align := TAlignLayout.Left;
  FModeButton.Width := 96;
  FModeButton.OnClick := ModeClick;
  SetControlMargins(FModeButton, 0, 0, GAP_S, 0);

  FAttachButton := TButton.Create(Self);
  FAttachButton.Parent := SendPanel;
  FAttachButton.Align := TAlignLayout.Left;
  FAttachButton.Width := 82;
  FAttachButton.Text := 'Attach';
  FAttachButton.OnClick := AttachFilesClick;
  SetControlMargins(FAttachButton, 0, 0, GAP_S, 0);

  FModelCombo := TComboBox.Create(Self);
  FModelCombo.Parent := SendPanel;
  FModelCombo.Align := TAlignLayout.Left;
  FModelCombo.Width := 260;
  FModelCombo.Items.Add('default model');
  FModelCombo.ItemIndex := 0;
  FModelCombo.OnChange := ModelComboChange;
  SetControlMargins(FModelCombo, 0, 0, GAP_S, 0);

  FSendButton := TButton.Create(Self);
  FSendButton.Parent := SendPanel;
  FSendButton.Align := TAlignLayout.Right;
  FSendButton.Width := 96;
  FSendButton.Text := 'Send';
  FSendButton.OnClick := SendClick;

  FClearAttachmentsButton := TButton.Create(Self);
  FClearAttachmentsButton.Parent := SendPanel;
  FClearAttachmentsButton.Align := TAlignLayout.Right;
  FClearAttachmentsButton.Width := 74;
  FClearAttachmentsButton.Text := 'Clear';
  FClearAttachmentsButton.Visible := False;   { appears with attachments }
  FClearAttachmentsButton.OnClick := ClearAttachmentsClick;
  SetControlMargins(FClearAttachmentsButton, GAP_S, 0, 0, 0);

  FComposerStatusLabel := TLabel.Create(Self);
  FComposerStatusLabel.Parent := SendPanel;
  FComposerStatusLabel.Align := TAlignLayout.Client;
  FComposerStatusLabel.Text := 'Ready';
  FComposerStatusLabel.TextSettings.VertAlign := TTextAlign.Center;
  FComposerStatusLabel.StyledSettings := FComposerStatusLabel.StyledSettings -
    [TStyledSetting.FontColor];
  FComposerStatusLabel.TextSettings.FontColor := UI_MUTED;

  FPromptMemo := TMemo.Create(Self);
  FPromptMemo.Parent := Composer;
  FPromptMemo.Align := TAlignLayout.Client;
  FPromptMemo.TextPrompt := 'Message PasClaw...';
  FPromptMemo.WordWrap := True;
  FPromptMemo.OnChange := PromptChange;
  FPromptMemo.OnKeyDown := PromptKeyDown;

  FSlashPopup := TPopup.Create(Self);
  FSlashPopup.Parent := Composer;
  FSlashPopup.PlacementTarget := FPromptMemo;
  FSlashPopup.Placement := TPlacement.Top;
  FSlashPopup.Width := 460;
  FSlashPopup.Height := 220;

  FSlashList := TListBox.Create(Self);
  FSlashList.Parent := FSlashPopup;
  FSlashList.Align := TAlignLayout.Client;

  FChatFilesPopup := TPopup.Create(Self);
  FChatFilesPopup.Parent := Tab;
  FChatFilesPopup.Placement := TPlacement.Bottom;
  FChatFilesPopup.Width := 520;
  FChatFilesPopup.Height := 280;

  FChatFilesList := TListBox.Create(Self);
  FChatFilesList.Parent := FChatFilesPopup;
  FChatFilesList.Align := TAlignLayout.Client;

  RenderQueue;
  RenderAttachments;
  UpdateComposerState;
end;

function TMasterDetailForm.BuildEndpointTab(const Key, Caption, Endpoint,
  Description: string): TLayout;
var
  Bar: TLayout;
  BodyLabel: TLabel;
  BodyMemo: TMemo;
  BodyPanel: TLayout;
  Btn: TButton;
  Edit: TEdit;
  Info: TLabel;
  MethodCombo: TComboBox;
  Memo: TMemo;
  ResponseLabel: TLabel;
  ResponsePanel: TLayout;
  Tab: TTabItem;
begin
  Tab := TTabItem.Create(Self);
  Tab.Parent := FTabControl;
  Tab.Text := Caption;
  AddNavigationButton(Tab.Text);

  { no chrome rect around the tab body: a border around an entire tab is a
    box around boxes -- borders mark interactive or elevated surfaces only }
  Info := TLabel.Create(Self);
  Info.Parent := Tab;
  Info.Align := TAlignLayout.Top;
  Info.Height := 0;
  Info.Visible := False;
  Info.Text := Description;
  Info.WordWrap := True;
  Info.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(Info, UI_MUTED, TXT_BODY, False);
  SetControlMargins(Info, 0, 0, 0, 0);

  Bar := TLayout.Create(Self);
  Bar.Parent := Tab;
  Bar.Align := TAlignLayout.Top;
  Bar.Height := 0;
  Bar.Visible := False;
  SetControlPadding(Bar, 10, 3, 10, 3);

  Btn := TButton.Create(Self);
  Btn.Parent := Bar;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Run';
  Btn.TagString := Key;
  Btn.OnClick := EndpointRunClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  MethodCombo := TComboBox.Create(Self);
  MethodCombo.Parent := Bar;
  MethodCombo.Align := TAlignLayout.Right;
  MethodCombo.Width := 92;
  MethodCombo.Items.Add('GET');
  MethodCombo.Items.Add('POST');
  MethodCombo.Items.Add('PUT');
  MethodCombo.Items.Add('DELETE');
  MethodCombo.ItemIndex := 0;
  SetControlMargins(MethodCombo, GAP_S, 0, 0, 0);
  FEndpointMethodCombos.Add(Key, MethodCombo);

  Edit := TEdit.Create(Self);
  Edit.Parent := Bar;
  Edit.Align := TAlignLayout.Client;
  Edit.Text := Endpoint;
  FEndpointEdits.Add(Key, Edit);

  BodyPanel := TLayout.Create(Self);
  BodyPanel.Parent := Tab;
  BodyPanel.Align := TAlignLayout.Bottom;
  BodyPanel.Height := 0;
  BodyPanel.Visible := False;
  SetControlMargins(BodyPanel, GAP_M, 0, GAP_M, 10);
  SetControlPadding(BodyPanel, 10, GAP_S, 10, GAP_S);
  AddPanelChrome(BodyPanel, True);

  BodyLabel := TLabel.Create(Self);
  BodyLabel.Parent := BodyPanel;
  BodyLabel.Align := TAlignLayout.Top;
  BodyLabel.Height := ROW_TEXT;
  BodyLabel.Text := 'Request body';
  BodyLabel.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(BodyLabel, UI_MUTED, TXT_BODY, True);

  BodyMemo := TMemo.Create(Self);
  BodyMemo.Parent := BodyPanel;
  BodyMemo.Align := TAlignLayout.Client;
  BodyMemo.TextPrompt := 'JSON body for POST/PUT. GET /v1/config loads editable JSON here.';
  BodyMemo.WordWrap := False;
  SetControlMargins(BodyMemo, 0, GAP_XS, 0, 0);
  FEndpointBodyMemos.Add(Key, BodyMemo);

  ResponsePanel := TLayout.Create(Self);
  ResponsePanel.Parent := Tab;
  ResponsePanel.Align := TAlignLayout.None;
  ResponsePanel.Height := 0;
  ResponsePanel.Visible := False;
  SetControlMargins(ResponsePanel, GAP_M, 0, GAP_M, 10);
  SetControlPadding(ResponsePanel, 10, GAP_S, 10, 10);
  AddPanelChrome(ResponsePanel, False);

  ResponseLabel := TLabel.Create(Self);
  ResponseLabel.Parent := ResponsePanel;
  ResponseLabel.Align := TAlignLayout.Top;
  ResponseLabel.Height := ROW_TEXT;
  ResponseLabel.Text := 'Response';
  ResponseLabel.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(ResponseLabel, UI_MUTED, TXT_BODY, True);

  Memo := TMemo.Create(Self);
  Memo.Parent := ResponsePanel;
  Memo.Align := TAlignLayout.Client;
  Memo.WordWrap := False;
  Memo.Lines.Text := Description + sLineBreak + sLineBreak +
    'Endpoint: ' + Endpoint;
  SetControlMargins(Memo, 0, GAP_XS, 0, 0);
  FPaneMemos.Add(Key, Memo);

  Result := Bar;
end;

procedure TMasterDetailForm.AddNavigationButton(const Caption: string);
var
  Btn: TButton;
  Key: string;
begin
  if (FNavScroll = nil) or (FNavButtons = nil) then
    Exit;
  Key := LowerCase(Caption);
  if FNavButtons.ContainsKey(Key) then
    Exit;

  Btn := TButton.Create(Self);
  Btn.Parent := FNavScroll;
  Btn.Align := TAlignLayout.Left;
  Btn.Width := Max(76, 34 + Length(Caption) * 8);
  Btn.Height := ROW_FORM;
  Btn.Text := Caption;
  Btn.TagString := Caption;
  Btn.OnClick := NavButtonClick;
  SetControlMargins(Btn, 0, 0, GAP_S, 0);
  StyleButton(Btn, False);
  FNavButtons.Add(Key, Btn);
  if (FNavCombo <> nil) and (FNavCombo.Items.IndexOf(Caption) < 0) then
    FNavCombo.Items.Add(Caption);
end;

procedure TMasterDetailForm.NavButtonClick(Sender: TObject);
begin
  if Sender is TButton then
    SelectTabByText(TButton(Sender).TagString);
end;

procedure TMasterDetailForm.NavComboChange(Sender: TObject);
begin
  if (FNavCombo <> nil) and (FNavCombo.ItemIndex >= 0) and
    (FNavCombo.ItemIndex < FNavCombo.Items.Count) then
    SelectTabByText(FNavCombo.Items[FNavCombo.ItemIndex]);
end;

procedure TMasterDetailForm.TabControlChange(Sender: TObject);
begin
  UpdateNavButtons;
  UpdateFooterVisibility;
  ActivateCurrentTab(False);
end;

procedure TMasterDetailForm.ActivateCurrentTab(AForce: Boolean);
var
  ActiveCaption: string;
begin
  if (FTabControl = nil) or (FTabControl.TabIndex < 0) or
    (FTabControl.TabIndex >= FTabControl.TabCount) then
    Exit;
  ActiveCaption := FTabControl.Tabs[FTabControl.TabIndex].Text;
  if (not AForce) and SameText(FLastActivatedTab, ActiveCaption) then
    Exit;
  FLastActivatedTab := ActiveCaption;

  if SameText(ActiveCaption, 'Chat') then
  begin
    if FSessionCache.Count = 0 then
      LoadSessions;
    Exit;
  end;
  if SameText(ActiveCaption, 'Memory') then
  begin
    if (FMemoryTabs <> nil) and (FMemoryTabs.TabIndex = 1) then
      MemoryFactsLoadClick(nil)
    else if (FMemoryTabs <> nil) and (FMemoryTabs.TabIndex = 2) then
      MemorySetupLoadClick(nil)
    else
      MemoryFilesLoadClick(nil);
    Exit;
  end;
  if SameText(ActiveCaption, 'KB') then
  begin
    KbSourcesLoadClick(nil);
    Exit;
  end;
  if SameText(ActiveCaption, 'Files') then
  begin
    if FFilePathEdit <> nil then
      FilesOpenPath(Trim(FFilePathEdit.Text))
    else
      FilesOpenPath('');
    Exit;
  end;
  if SameText(ActiveCaption, 'MCP') then
  begin
    McpRefreshClick(nil);
    Exit;
  end;
  if SameText(ActiveCaption, 'Cron') then
  begin
    CronRefreshClick(nil);
    Exit;
  end;
  if SameText(ActiveCaption, 'Skills') then
  begin
    SkillsRefreshClick(nil);
    Exit;
  end;
  if SameText(ActiveCaption, 'Workflow') then
  begin
    WorkflowLoadClick(nil);
    Exit;
  end;
  if SameText(ActiveCaption, 'Vault') then
  begin
    VaultSearchClick(nil);
    Exit;
  end;
  if SameText(ActiveCaption, 'Logs') then
  begin
    LogsClick(nil);
    Exit;
  end;
  if SameText(ActiveCaption, 'Stats') then
  begin
    StatsRefreshClick(nil);
    Exit;
  end;
  if SameText(ActiveCaption, 'Checkpoints') then
  begin
    CheckpointRefreshClick(nil);
    Exit;
  end;
  if SameText(ActiveCaption, 'Relay') then
  begin
    RelayRefreshClick(nil);
    Exit;
  end;
  if SameText(ActiveCaption, 'Settings') then
  begin
    ConfigRefreshClick(nil);
    Exit;
  end;
end;

procedure TMasterDetailForm.UpdateNavButtons;
var
  ActiveCaption: string;
  Pair: TPair<string, TButton>;
begin
  if (FNavButtons = nil) or (FTabControl = nil) then
    Exit;
  ActiveCaption := '';
  if (FTabControl.TabIndex >= 0) and (FTabControl.TabIndex < FTabControl.TabCount) then
    ActiveCaption := FTabControl.Tabs[FTabControl.TabIndex].Text;
  for Pair in FNavButtons do
    StyleButton(Pair.Value, SameText(Pair.Value.TagString, ActiveCaption));
  if FNavCombo <> nil then
  begin
    FNavCombo.OnChange := nil;
    try
      FNavCombo.ItemIndex := FNavCombo.Items.IndexOf(ActiveCaption);
    finally
      FNavCombo.OnChange := NavComboChange;
    end;
  end;
end;

procedure TMasterDetailForm.BuildFilesBrowserPanel(AParent: TFmxObject);
var
  Body: TLayout;
  Btn: TButton;
  LeftPane: TLayout;
  Panel: TLayout;
  RightPane: TLayout;
  Row: TLayout;
begin
  Panel := TLayout.Create(Self);
  Panel.Parent := AParent;
  Panel.Align := TAlignLayout.Client;
  SetControlPadding(Panel, GAP_M, GAP_S, GAP_M, 10);
  AddPanelChrome(Panel, False);

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_L;
  Btn.Text := 'Download';
  Btn.OnClick := FilesDownloadSelectedClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Preview';
  Btn.OnClick := FilesBrowseClick;
  Btn.TagString := 'read';
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Up';
  Btn.OnClick := FilesBrowseClick;
  Btn.TagString := 'up';
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Browse';
  Btn.OnClick := FilesBrowseClick;
  Btn.TagString := 'browse';
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FFilePathEdit := TEdit.Create(Self);
  FFilePathEdit.Parent := Row;
  FFilePathEdit.Align := TAlignLayout.Client;
  FFilePathEdit.TextPrompt := 'directory or file path';

  Body := TLayout.Create(Self);
  Body.Parent := Panel;
  Body.Align := TAlignLayout.Client;
  SetControlMargins(Body, 0, GAP_S, 0, 0);

  LeftPane := TLayout.Create(Self);
  LeftPane.Parent := Body;
  LeftPane.Align := TAlignLayout.Left;
  LeftPane.Width := 320;
  FFileLeftPane := LeftPane;
  SetControlMargins(LeftPane, 0, 0, GAP_S, 0);
  SetControlPadding(LeftPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(LeftPane, True);
  AddSectionHeader(LeftPane, 'Roots');

  FFileRootsList := TListBox.Create(Self);
  FFileRootsList.Parent := LeftPane;
  FFileRootsList.Align := TAlignLayout.Top;
  FFileRootsList.Height := 76;
  FFileRootsList.OnChange := FilesRootClick;

  FFileViewerStatusLabel := TLabel.Create(Self);
  FFileViewerStatusLabel.Parent := LeftPane;
  FFileViewerStatusLabel.Align := TAlignLayout.Top;
  FFileViewerStatusLabel.Height := H_INPUT;
  FFileViewerStatusLabel.Text := '(home)';
  FFileViewerStatusLabel.TextSettings.VertAlign := TTextAlign.Center;
  FFileViewerStatusLabel.StyledSettings := FFileViewerStatusLabel.StyledSettings -
    [TStyledSetting.FontColor];
  UseStyledLabelColor(FFileViewerStatusLabel);
  SetControlMargins(FFileViewerStatusLabel, 0, GAP_S, 0, 2);

  FFileList := TListBox.Create(Self);
  FFileList.Parent := LeftPane;
  FFileList.Align := TAlignLayout.Client;
  FFileList.OnChange := FilesListChange;

  FFilePaneSplitter := AddPaneSplitter(Body, TAlignLayout.Left);

  RightPane := TLayout.Create(Self);
  RightPane.Parent := Body;
  RightPane.Align := TAlignLayout.Client;
  FFileViewerPane := RightPane;
  SetControlPadding(RightPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(RightPane, True);

  Row := TLayout.Create(Self);
  Row.Parent := RightPane;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Copy';
  Btn.OnClick := FileDetailCopyClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Hex';
  Btn.OnClick := FilesBrowseClick;
  Btn.TagString := 'peek';
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FFileHexLabel := TLabel.Create(Self);
  FFileHexLabel.Parent := Row;
  FFileHexLabel.Align := TAlignLayout.Client;
  FFileHexLabel.Text := 'Preview';
  FFileHexLabel.StyledSettings := FFileHexLabel.StyledSettings -
    [TStyledSetting.FontColor];
  UseStyledLabelColor(FFileHexLabel);
  FFileHexLabel.TextSettings.VertAlign := TTextAlign.Center;

  FFileHexToolbar := TLayout.Create(Self);
  FFileHexToolbar.Parent := RightPane;
  FFileHexToolbar.Align := TAlignLayout.Top;
  FFileHexToolbar.Height := ROW_BAR;
  FFileHexToolbar.Visible := False;
  SetControlMargins(FFileHexToolbar, 0, GAP_S, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := FFileHexToolbar;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Last';
  Btn.OnClick := FilesHexLastClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := FFileHexToolbar;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Next';
  Btn.OnClick := FilesHexNextClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := FFileHexToolbar;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Prev';
  Btn.OnClick := FilesHexPrevClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := FFileHexToolbar;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'First';
  Btn.OnClick := FilesHexFirstClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FFilePreviewImage := TImage.Create(Self);
  FFilePreviewImage.Parent := RightPane;
  FFilePreviewImage.Align := TAlignLayout.Client;
  FFilePreviewImage.Visible := False;
  FFilePreviewImage.WrapMode := TImageWrapMode.Fit;
  SetControlMargins(FFilePreviewImage, 0, GAP_S, 0, 0);

  FFileDetailMemo := TMemo.Create(Self);
  FFileDetailMemo.Parent := RightPane;
  FFileDetailMemo.Align := TAlignLayout.Client;
  FFileDetailMemo.ReadOnly := True;
  FFileDetailMemo.WordWrap := False;
  FFileDetailMemo.Lines.Text := 'Select a file from the browser to preview text, images, or binary hex pages here.';
  SetControlMargins(FFileDetailMemo, 0, GAP_S, 0, 0);

  AddPaneSplitter(AParent, TAlignLayout.Top);
end;

procedure TMasterDetailForm.BuildMemoryBrowserPanel(AParent: TFmxObject);
var
  Body: TLayout;
  Btn: TButton;
  FilesPane: TLayout;
  Panel: TLayout;
  Row: TLayout;
  ViewerPane: TLayout;
begin
  Panel := TLayout.Create(Self);
  Panel.Parent := AParent;
  Panel.Align := TAlignLayout.Client;
  SetControlPadding(Panel, GAP_M, GAP_S, GAP_M, 10);
  AddPanelChrome(Panel, False);

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Search';
  Btn.OnClick := MemorySearchClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Refresh';
  Btn.OnClick := MemoryFilesLoadClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FMemorySearchEdit := TEdit.Create(Self);
  FMemorySearchEdit.Parent := Row;
  FMemorySearchEdit.Align := TAlignLayout.Client;
  FMemorySearchEdit.TextPrompt := 'Search notes, facts, and indexed memory';

  Body := TLayout.Create(Self);
  Body.Parent := Panel;
  Body.Align := TAlignLayout.Client;
  SetControlMargins(Body, 0, GAP_S, 0, 0);

  FilesPane := TLayout.Create(Self);
  FilesPane.Parent := Body;
  FilesPane.Align := TAlignLayout.Left;
  FilesPane.Width := 320;
  FMemoryFilesPane := FilesPane;
  SetControlMargins(FilesPane, 0, 0, GAP_S, 0);
  SetControlPadding(FilesPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(FilesPane, True);
  AddSectionHeader(FilesPane, 'Memory files');

  FMemoryFileList := TListBox.Create(Self);
  FMemoryFileList.Parent := FilesPane;
  FMemoryFileList.Align := TAlignLayout.Client;
  FMemoryFileList.OnChange := MemoryListChange;

  AddPaneSplitter(Body, TAlignLayout.Left);

  ViewerPane := TLayout.Create(Self);
  ViewerPane.Parent := Body;
  ViewerPane.Align := TAlignLayout.Client;
  FMemoryFactsPane := ViewerPane;
  SetControlPadding(ViewerPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(ViewerPane, True);

  Row := TLayout.Create(Self);
  Row.Parent := ViewerPane;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_FORM;

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Copy';
  Btn.OnClick := MemoryFileDetailCopyClick;

  FMemoryNotesStatusLabel := TLabel.Create(Self);
  FMemoryNotesStatusLabel.Parent := Row;
  FMemoryNotesStatusLabel.Align := TAlignLayout.Client;
  FMemoryNotesStatusLabel.Text := 'Select a file or run a search';
  FMemoryNotesStatusLabel.TextSettings.VertAlign := TTextAlign.Center;
  FMemoryNotesStatusLabel.StyledSettings :=
    FMemoryNotesStatusLabel.StyledSettings - [TStyledSetting.FontColor];
  UseStyledLabelColor(FMemoryNotesStatusLabel);
  FMemoryBrowseStatusLabel := FMemoryNotesStatusLabel;

  FMemoryFileDetailMemo := TMemo.Create(Self);
  FMemoryFileDetailMemo.Parent := ViewerPane;
  FMemoryFileDetailMemo.Align := TAlignLayout.Client;
  FMemoryFileDetailMemo.ReadOnly := True;
  FMemoryFileDetailMemo.WordWrap := False;
  FMemoryFileDetailMemo.Lines.Text := 'Select a memory file or search result to preview it here.';
  SetControlMargins(FMemoryFileDetailMemo, 0, GAP_S, 0, 0);
end;

procedure TMasterDetailForm.BuildMemoryFactsPanel(AParent: TFmxObject);
var
  Btn: TButton;
  Panel: TLayout;
  Row: TLayout;
begin
  Panel := TLayout.Create(Self);
  Panel.Parent := AParent;
  Panel.Align := TAlignLayout.Client;
  SetControlPadding(Panel, GAP_M, GAP_S, GAP_M, 10);
  AddPanelChrome(Panel, False);

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Add';
  Btn.OnClick := MemoryFactAddClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FMemoryFactEdit := TEdit.Create(Self);
  FMemoryFactEdit.Parent := Row;
  FMemoryFactEdit.Align := TAlignLayout.Client;
  FMemoryFactEdit.TextPrompt := 'Add a fact PasClaw should remember';

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;
  SetControlMargins(Row, 0, GAP_S, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Forget';
  Btn.OnClick := MemoryFactDeleteClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Export';
  Btn.OnClick := MemoryFactsExportClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Refresh';
  Btn.OnClick := MemoryFactsLoadClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FMemoryFactsStatusLabel := TLabel.Create(Self);
  FMemoryFactsStatusLabel.Parent := Row;
  FMemoryFactsStatusLabel.Align := TAlignLayout.Client;
  FMemoryFactsStatusLabel.Text := 'Distilled facts';
  FMemoryFactsStatusLabel.TextSettings.VertAlign := TTextAlign.Center;
  FMemoryFactsStatusLabel.StyledSettings :=
    FMemoryFactsStatusLabel.StyledSettings - [TStyledSetting.FontColor];
  UseStyledLabelColor(FMemoryFactsStatusLabel);

  FMemoryFactsList := TListBox.Create(Self);
  FMemoryFactsList.Parent := Panel;
  FMemoryFactsList.Align := TAlignLayout.Client;
  SetControlMargins(FMemoryFactsList, 0, GAP_S, 0, 0);
end;

procedure TMasterDetailForm.BuildKbPanel(AParent: TFmxObject);
var
  Body: TLayout;
  Btn: TButton;
  Panel: TLayout;
  ResultsPane: TLayout;
  Row: TLayout;
  SourcesPane: TLayout;
begin
  Panel := TLayout.Create(Self);
  Panel.Parent := AParent;
  Panel.Align := TAlignLayout.Client;
  SetControlPadding(Panel, GAP_M, GAP_S, GAP_M, 10);
  AddPanelChrome(Panel, False);

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Upload';
  Btn.OnClick := KbUploadClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Sources';
  Btn.OnClick := KbSourcesLoadClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Search';
  Btn.OnClick := KbSearchClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FKBSearchEdit := TEdit.Create(Self);
  FKBSearchEdit.Parent := Row;
  FKBSearchEdit.Align := TAlignLayout.Client;
  FKBSearchEdit.TextPrompt := 'search the knowledge base';

  FKBStatusLabel := TLabel.Create(Self);
  FKBStatusLabel.Parent := Panel;
  FKBStatusLabel.Align := TAlignLayout.Top;
  FKBStatusLabel.Height := ROW_TEXT;
  FKBStatusLabel.Text := 'Load KB sources or run a search.';
  FKBStatusLabel.TextSettings.VertAlign := TTextAlign.Center;
  FKBStatusLabel.StyledSettings := FKBStatusLabel.StyledSettings -
    [TStyledSetting.FontColor];
  UseStyledLabelColor(FKBStatusLabel);

  Body := TLayout.Create(Self);
  Body.Parent := Panel;
  Body.Align := TAlignLayout.Client;
  SetControlMargins(Body, 0, GAP_XS, 0, 0);

  ResultsPane := TLayout.Create(Self);
  ResultsPane.Parent := Body;
  ResultsPane.Align := TAlignLayout.Client;
  FKBResultsPane := ResultsPane;
  SetControlMargins(ResultsPane, 0, 0, GAP_S, 0);
  SetControlPadding(ResultsPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(ResultsPane, True);
  AddSectionHeader(ResultsPane, 'Search results');

  FKBResultsList := TListBox.Create(Self);
  FKBResultsList.Parent := ResultsPane;
  FKBResultsList.Align := TAlignLayout.Client;
  FKBResultsList.OnChange := KbResultsChange;

  { Click-through parity with the web UI: a hit is only useful if you can get
    to the file it came from. Opens the Files tab at the hit's path. }
  Btn := TButton.Create(Self);
  Btn.Parent := ResultsPane;
  Btn.Align := TAlignLayout.Bottom;
  Btn.Height := ROW_FORM;
  Btn.Text := 'Open in Files';
  Btn.OnClick := KbResultOpenFileClick;
  SetControlMargins(Btn, 0, GAP_S, 0, 0);

  SourcesPane := TLayout.Create(Self);
  SourcesPane.Parent := Body;
  SourcesPane.Align := TAlignLayout.Right;
  SourcesPane.Width := 330;
  FKBSourcesPane := SourcesPane;
  SetControlPadding(SourcesPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(SourcesPane, True);
  AddSectionHeader(SourcesPane, 'Indexed sources');

  FKBSourceList := TListBox.Create(Self);
  FKBSourceList.Parent := SourcesPane;
  FKBSourceList.Align := TAlignLayout.Client;
  FKBSourceList.OnChange := KbSourcesChange;

  AddPaneSplitter(AParent, TAlignLayout.Top);
end;

procedure TMasterDetailForm.BuildCronPanel(AParent: TFmxObject);
var
  Body: TLayout;
  Btn: TButton;
  EditorPane: TLayout;
  ListPane: TLayout;
  Panel: TLayout;
  Row: TLayout;
begin
  Panel := TLayout.Create(Self);
  Panel.Parent := AParent;
  Panel.Align := TAlignLayout.Client;
  SetControlPadding(Panel, GAP_M, GAP_S, GAP_M, 10);
  AddPanelChrome(Panel, False);

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Refresh';
  Btn.OnClick := CronRefreshClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Remove';
  Btn.OnClick := CronRemoveClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Save';
  Btn.OnClick := CronSaveClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'New';
  Btn.OnClick := CronClearClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FCronStatusLabel := TLabel.Create(Self);
  FCronStatusLabel.Parent := Row;
  FCronStatusLabel.Align := TAlignLayout.Client;
  FCronStatusLabel.Text := 'Load, edit, save, and remove scheduled jobs.';
  FCronStatusLabel.TextSettings.VertAlign := TTextAlign.Center;
  FCronStatusLabel.StyledSettings := FCronStatusLabel.StyledSettings -
    [TStyledSetting.FontColor];
  UseStyledLabelColor(FCronStatusLabel);

  Body := TLayout.Create(Self);
  Body.Parent := Panel;
  Body.Align := TAlignLayout.Client;
  SetControlMargins(Body, 0, GAP_S, 0, 0);

  ListPane := TLayout.Create(Self);
  ListPane.Parent := Body;
  ListPane.Align := TAlignLayout.Left;
  ListPane.Width := 330;
  FCronListPane := ListPane;
  SetControlMargins(ListPane, 0, 0, GAP_S, 0);
  SetControlPadding(ListPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(ListPane, True);
  AddSectionHeader(ListPane, 'Schedules');

  FCronList := TListBox.Create(Self);
  FCronList.Parent := ListPane;
  FCronList.Align := TAlignLayout.Client;
  FCronList.OnChange := CronListChange;

  FCronSplitter := AddPaneSplitter(Body, TAlignLayout.Left);

  EditorPane := TLayout.Create(Self);
  EditorPane.Parent := Body;
  EditorPane.Align := TAlignLayout.Client;
  FCronEditorPane := EditorPane;
  SetControlPadding(EditorPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(EditorPane, True);
  AddSectionHeader(EditorPane, 'Job editor');

  Row := TLayout.Create(Self);
  Row.Parent := EditorPane;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;

  FCronEnabledCheck := TCheckBox.Create(Self);
  FCronEnabledCheck.Parent := Row;
  FCronEnabledCheck.Align := TAlignLayout.Right;
  FCronEnabledCheck.Width := 88;
  FCronEnabledCheck.Text := 'Enabled';
  FCronEnabledCheck.IsChecked := True;
  SetControlMargins(FCronEnabledCheck, GAP_S, 0, 0, 0);

  FCronSpecEdit := TEdit.Create(Self);
  FCronSpecEdit.Parent := Row;
  FCronSpecEdit.Align := TAlignLayout.Right;
  FCronSpecEdit.Width := 170;
  FCronSpecEdit.TextPrompt := 'cron spec';
  SetControlMargins(FCronSpecEdit, GAP_S, 0, 0, 0);

  FCronIdEdit := TEdit.Create(Self);
  FCronIdEdit.Parent := Row;
  FCronIdEdit.Align := TAlignLayout.Client;
  FCronIdEdit.TextPrompt := 'job id';

  Row := TLayout.Create(Self);
  Row.Parent := EditorPane;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;
  SetControlMargins(Row, 0, GAP_S, 0, 0);

  FCronArgsEdit := TEdit.Create(Self);
  FCronArgsEdit.Parent := Row;
  FCronArgsEdit.Align := TAlignLayout.Right;
  FCronArgsEdit.Width := 310;
  FCronArgsEdit.TextPrompt := 'args string or JSON text';
  SetControlMargins(FCronArgsEdit, GAP_S, 0, 0, 0);

  FCronSkillEdit := TEdit.Create(Self);
  FCronSkillEdit.Parent := Row;
  FCronSkillEdit.Align := TAlignLayout.Client;
  FCronSkillEdit.TextPrompt := 'skill name or workflow id';

  Row := TLayout.Create(Self);
  Row.Parent := EditorPane;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;
  SetControlMargins(Row, 0, GAP_S, 0, 0);

  FCronChannelKindEdit := TEdit.Create(Self);
  FCronChannelKindEdit.Parent := Row;
  FCronChannelKindEdit.Align := TAlignLayout.Left;
  FCronChannelKindEdit.Width := 132;
  FCronChannelKindEdit.TextPrompt := 'channel kind';
  SetControlMargins(FCronChannelKindEdit, 0, 0, GAP_S, 0);

  FCronChannelTargetEdit := TEdit.Create(Self);
  FCronChannelTargetEdit.Parent := Row;
  FCronChannelTargetEdit.Align := TAlignLayout.Client;
  FCronChannelTargetEdit.TextPrompt := 'channel target';

  AddSectionHeader(EditorPane, 'Selected job');

  FCronDetailTitleLabel := TLabel.Create(Self);
  FCronDetailTitleLabel.Parent := EditorPane;
  FCronDetailTitleLabel.Align := TAlignLayout.Top;
  FCronDetailTitleLabel.Height := H_INPUT;
  FCronDetailTitleLabel.Text := 'Cron Detail';
  FCronDetailTitleLabel.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(FCronDetailTitleLabel, UI_ACCENT, TXT_TITLE, True);

  FCronDetailMetaLabel := TLabel.Create(Self);
  FCronDetailMetaLabel.Parent := EditorPane;
  FCronDetailMetaLabel.Align := TAlignLayout.Top;
  FCronDetailMetaLabel.Height := ROW_TEXT;
  FCronDetailMetaLabel.Text := 'Select a cron job';
  FCronDetailMetaLabel.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(FCronDetailMetaLabel, UI_MUTED, TXT_BODY, False);

  FCronDetailMemo := TMemo.Create(Self);
  FCronDetailMemo.Parent := EditorPane;
  FCronDetailMemo.Align := TAlignLayout.Client;
  FCronDetailMemo.ReadOnly := True;
  FCronDetailMemo.WordWrap := True;
  SetControlMargins(FCronDetailMemo, 0, GAP_S, 0, 0);

  AddPaneSplitter(AParent, TAlignLayout.Top);
end;

procedure TMasterDetailForm.BuildStatsPanel(AParent: TFmxObject);
var
  Body: TLayout;
  Btn: TButton;
  LeftPane: TLayout;
  Panel: TLayout;
  RightPane: TLayout;
  Row: TLayout;
begin
  Panel := TLayout.Create(Self);
  Panel.Parent := AParent;
  Panel.Align := TAlignLayout.Client;
  SetControlPadding(Panel, GAP_M, GAP_S, GAP_M, 10);
  AddPanelChrome(Panel, False);

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Refresh';
  Btn.OnClick := StatsRefreshClick;

  FStatsAutoRefreshCheck := TCheckBox.Create(Self);
  FStatsAutoRefreshCheck.Parent := Row;
  FStatsAutoRefreshCheck.Align := TAlignLayout.Right;
  FStatsAutoRefreshCheck.Width := 118;
  FStatsAutoRefreshCheck.Text := 'Auto refresh';
  FStatsAutoRefreshCheck.OnClick := StatsRefreshClick;
  SetControlMargins(FStatsAutoRefreshCheck, GAP_S, 0, 0, 0);

  FStatsStatusLabel := TLabel.Create(Self);
  FStatsStatusLabel.Parent := Row;
  FStatsStatusLabel.Align := TAlignLayout.Client;
  FStatsStatusLabel.Text := 'Session, token, cache, provider, and model usage.';
  FStatsStatusLabel.TextSettings.VertAlign := TTextAlign.Center;
  FStatsStatusLabel.StyledSettings := FStatsStatusLabel.StyledSettings -
    [TStyledSetting.FontColor];
  UseStyledLabelColor(FStatsStatusLabel);

  Body := TLayout.Create(Self);
  Body.Parent := Panel;
  Body.Align := TAlignLayout.Client;
  SetControlMargins(Body, 0, GAP_S, 0, 0);

  LeftPane := TLayout.Create(Self);
  LeftPane.Parent := Body;
  LeftPane.Align := TAlignLayout.Left;
  LeftPane.Width := 320;
  FStatsLeftPane := LeftPane;
  SetControlMargins(LeftPane, 0, 0, GAP_S, 0);
  SetControlPadding(LeftPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(LeftPane, True);
  AddSectionHeader(LeftPane, 'Summary');

  { a GRID of metric cards, not a single column -- TListBox does this
    natively via Columns. TWO, not the plan's three: the pane is a fixed
    320px, and after its padding, the scrollbar and each card's own padding,
    three columns leave ~75px per caption -- 'Output tokens' clips. Two
    leave ~124px, which holds every caption AddSummary renders. }
  FStatsSummaryList := TListBox.Create(Self);
  FStatsSummaryList.Columns := 2;
  FStatsSummaryList.Parent := LeftPane;
  FStatsSummaryList.Align := TAlignLayout.Client;
  FStatsSummaryList.ShowCheckboxes := False;

  AddPaneSplitter(Body, TAlignLayout.Left);

  RightPane := TLayout.Create(Self);
  RightPane.Parent := Body;
  RightPane.Align := TAlignLayout.Client;
  FStatsRightPane := RightPane;
  SetControlPadding(RightPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(RightPane, True);
  AddSectionHeader(RightPane, 'Tokens by provider');

  FStatsProviderList := TListBox.Create(Self);
  FStatsProviderList.Parent := RightPane;
  FStatsProviderList.Align := TAlignLayout.Top;
  FStatsProviderList.Height := 132;

  AddSectionHeader(RightPane, 'Tokens by model');

  FStatsModelList := TListBox.Create(Self);
  FStatsModelList.Parent := RightPane;
  FStatsModelList.Align := TAlignLayout.Client;

  FStatsTimer := TTimer.Create(Self);
  FStatsTimer.Interval := 10000;
  FStatsTimer.Enabled := False;
  FStatsTimer.OnTimer := StatsTimerTick;
end;

procedure TMasterDetailForm.BuildCheckpointPanel(AParent: TFmxObject);
var
  Body: TLayout;
  Btn: TButton;
  DetailPane: TLayout;
  ListPane: TLayout;
  Panel: TLayout;
  Row: TLayout;
begin
  Panel := TLayout.Create(Self);
  Panel.Parent := AParent;
  Panel.Align := TAlignLayout.Client;
  SetControlPadding(Panel, GAP_M, GAP_S, GAP_M, 10);
  AddPanelChrome(Panel, False);

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Revert';
  Btn.TagString := 'revert';
  Btn.OnClick := CheckpointActionClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Redo';
  Btn.TagString := 'redo';
  Btn.OnClick := CheckpointActionClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Undo';
  Btn.TagString := 'undo';
  Btn.OnClick := CheckpointActionClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Refresh';
  Btn.OnClick := CheckpointRefreshClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FCheckpointStatusLabel := TLabel.Create(Self);
  FCheckpointStatusLabel.Parent := Row;
  FCheckpointStatusLabel.Align := TAlignLayout.Client;
  FCheckpointStatusLabel.Text := 'Per-chat undo, redo, revert, and changed-file checkpoints.';
  FCheckpointStatusLabel.TextSettings.VertAlign := TTextAlign.Center;
  FCheckpointStatusLabel.StyledSettings :=
    FCheckpointStatusLabel.StyledSettings - [TStyledSetting.FontColor];
  UseStyledLabelColor(FCheckpointStatusLabel);

  Body := TLayout.Create(Self);
  Body.Parent := Panel;
  Body.Align := TAlignLayout.Client;
  SetControlMargins(Body, 0, GAP_S, 0, 0);

  ListPane := TLayout.Create(Self);
  ListPane.Parent := Body;
  ListPane.Align := TAlignLayout.Left;
  ListPane.Width := 330;
  FCheckpointListPane := ListPane;
  SetControlMargins(ListPane, 0, 0, GAP_S, 0);
  SetControlPadding(ListPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(ListPane, True);
  AddSectionHeader(ListPane, 'Checkpoint timeline');

  FCheckpointList := TListBox.Create(Self);
  FCheckpointList.Parent := ListPane;
  FCheckpointList.Align := TAlignLayout.Client;
  FCheckpointList.OnChange := CheckpointListChange;

  FCheckpointSplitter := AddPaneSplitter(Body, TAlignLayout.Left);

  DetailPane := TLayout.Create(Self);
  DetailPane.Parent := Body;
  DetailPane.Align := TAlignLayout.Client;
  FCheckpointDetailPane := DetailPane;
  SetControlPadding(DetailPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(DetailPane, True);
  AddSectionHeader(DetailPane, 'Selected checkpoint');

  FCheckpointDetailMemo := TMemo.Create(Self);
  FCheckpointDetailMemo.Parent := DetailPane;
  FCheckpointDetailMemo.Align := TAlignLayout.Client;
  FCheckpointDetailMemo.ReadOnly := True;
  FCheckpointDetailMemo.WordWrap := True;
  FCheckpointDetailMemo.Lines.Text := 'Select a checkpoint to inspect changed files and metadata.';
end;

procedure TMasterDetailForm.BuildRelayPanel(AParent: TFmxObject);
var
  Body: TLayout;
  Btn: TButton;
  LeftPane: TLayout;
  Panel: TLayout;
  RightPane: TLayout;
  Row: TLayout;
begin
  Panel := TLayout.Create(Self);
  Panel.Parent := AParent;
  Panel.Align := TAlignLayout.Client;
  SetControlPadding(Panel, GAP_M, GAP_S, GAP_M, 10);
  AddPanelChrome(Panel, False);

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := 112;
  Btn.Text := 'Worker Token';
  Btn.OnClick := RelayTokenClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Refresh';
  Btn.OnClick := RelayRefreshClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FRelayAutoRefreshCheck := TCheckBox.Create(Self);
  FRelayAutoRefreshCheck.Parent := Row;
  FRelayAutoRefreshCheck.Align := TAlignLayout.Right;
  FRelayAutoRefreshCheck.Width := 118;
  FRelayAutoRefreshCheck.Text := 'Auto refresh';
  FRelayAutoRefreshCheck.OnClick := RelayRefreshClick;
  SetControlMargins(FRelayAutoRefreshCheck, GAP_S, 0, 0, 0);

  FRelayStatusLabel := TLabel.Create(Self);
  FRelayStatusLabel.Parent := Row;
  FRelayStatusLabel.Align := TAlignLayout.Client;
  FRelayStatusLabel.Text := 'Relay workers, scoped access, and local runtime setup.';
  FRelayStatusLabel.TextSettings.VertAlign := TTextAlign.Center;
  FRelayStatusLabel.StyledSettings := FRelayStatusLabel.StyledSettings -
    [TStyledSetting.FontColor];
  UseStyledLabelColor(FRelayStatusLabel);

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;
  SetControlMargins(Row, 0, GAP_S, 0, 0);

  FRelayUrlEdit := TEdit.Create(Self);
  FRelayUrlEdit.Parent := Row;
  FRelayUrlEdit.Align := TAlignLayout.Left;
  FRelayUrlEdit.Width := 300;
  FRelayUrlEdit.TextPrompt := 'relay gateway URL';
  FRelayUrlEdit.OnChange := RelayRenderSnippets;
  SetControlMargins(FRelayUrlEdit, 0, 0, GAP_S, 0);

  FRelayShowTokenButton := TButton.Create(Self);
  FRelayShowTokenButton.Parent := Row;
  FRelayShowTokenButton.Align := TAlignLayout.Right;
  FRelayShowTokenButton.Width := 68;
  FRelayShowTokenButton.Text := 'Show';
  FRelayShowTokenButton.OnClick := RelayTokenToggleClick;
  SetControlMargins(FRelayShowTokenButton, GAP_S, 0, 0, 0);

  FRelayTokenEdit := TEdit.Create(Self);
  FRelayTokenEdit.Parent := Row;
  FRelayTokenEdit.Align := TAlignLayout.Client;
  FRelayTokenEdit.Password := True;
  FRelayTokenEdit.TextPrompt := 'relay-scoped token';

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;
  SetControlMargins(Row, 0, GAP_S, 0, 0);

  FRelayWorkerCommandEdit := TEdit.Create(Self);
  FRelayWorkerCommandEdit.Parent := Row;
  FRelayWorkerCommandEdit.Align := TAlignLayout.Left;
  FRelayWorkerCommandEdit.Width := 190;
  FRelayWorkerCommandEdit.Text := 'pasclaw';
  FRelayWorkerCommandEdit.TextPrompt := 'worker command';
  FRelayWorkerCommandEdit.OnChange := RelayRenderSnippets;
  SetControlMargins(FRelayWorkerCommandEdit, 0, 0, GAP_S, 0);

  FRelayWorkerDisconnectButton := TButton.Create(Self);
  FRelayWorkerDisconnectButton.Parent := Row;
  FRelayWorkerDisconnectButton.Align := TAlignLayout.Right;
  FRelayWorkerDisconnectButton.Width := 92;
  FRelayWorkerDisconnectButton.Text := 'Disconnect';
  FRelayWorkerDisconnectButton.OnClick := RelayWorkerDisconnectClick;
  SetControlMargins(FRelayWorkerDisconnectButton, GAP_S, 0, 0, 0);

  FRelayWorkerConnectButton := TButton.Create(Self);
  FRelayWorkerConnectButton.Parent := Row;
  FRelayWorkerConnectButton.Align := TAlignLayout.Right;
  FRelayWorkerConnectButton.Width := 82;
  FRelayWorkerConnectButton.Text := 'Connect';
  FRelayWorkerConnectButton.OnClick := RelayWorkerConnectClick;
  SetControlMargins(FRelayWorkerConnectButton, GAP_S, 0, 0, 0);

  FRelayWorkerProviderEdit := TEdit.Create(Self);
  FRelayWorkerProviderEdit.Parent := Row;
  FRelayWorkerProviderEdit.Align := TAlignLayout.Client;
  FRelayWorkerProviderEdit.TextPrompt := 'provider (optional)';
  FRelayWorkerProviderEdit.OnChange := RelayRenderSnippets;

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;
  SetControlMargins(Row, 0, GAP_S, 0, 0);

  FRelayWorkerProfileCombo := TComboBox.Create(Self);
  FRelayWorkerProfileCombo.Parent := Row;
  FRelayWorkerProfileCombo.Align := TAlignLayout.Left;
  FRelayWorkerProfileCombo.Width := 136;
  FRelayWorkerProfileCombo.Items.Add('Custom');
  FRelayWorkerProfileCombo.Items.Add('LocalPal');
  FRelayWorkerProfileCombo.ItemIndex := 0;
  FRelayWorkerProfileCombo.OnChange := RelayWorkerProfileChange;
  SetControlMargins(FRelayWorkerProfileCombo, 0, 0, GAP_S, 0);

  FRelayWorkerIdEdit := TEdit.Create(Self);
  FRelayWorkerIdEdit.Parent := Row;
  FRelayWorkerIdEdit.Align := TAlignLayout.Left;
  FRelayWorkerIdEdit.Width := 240;
  FRelayWorkerIdEdit.Text := 'fmx-' + IntToStr(WinGetCurrentProcessId);
  FRelayWorkerIdEdit.TextPrompt := 'worker id';
  FRelayWorkerIdEdit.OnChange := RelayRenderSnippets;
  SetControlMargins(FRelayWorkerIdEdit, 0, 0, GAP_S, 0);

  FRelayWorkerModelEdit := TEdit.Create(Self);
  FRelayWorkerModelEdit.Parent := Row;
  FRelayWorkerModelEdit.Align := TAlignLayout.Client;
  FRelayWorkerModelEdit.TextPrompt := 'model or capability, * for wildcard';
  FRelayWorkerModelEdit.OnChange := RelayRenderSnippets;

  FRelayWorkerLogMemo := TMemo.Create(Self);
  FRelayWorkerLogMemo.Parent := Panel;
  FRelayWorkerLogMemo.Align := TAlignLayout.Top;
  FRelayWorkerLogMemo.Height := 96;
  FRelayWorkerLogMemo.ReadOnly := True;
  FRelayWorkerLogMemo.WordWrap := False;
  FRelayWorkerLogMemo.Lines.Text := 'Local relay worker idle.';
  SetControlMargins(FRelayWorkerLogMemo, 0, GAP_S, 0, 0);

  Body := TLayout.Create(Self);
  Body.Parent := Panel;
  Body.Align := TAlignLayout.Client;
  SetControlMargins(Body, 0, GAP_S, 0, 0);

  LeftPane := TLayout.Create(Self);
  LeftPane.Parent := Body;
  LeftPane.Align := TAlignLayout.Left;
  LeftPane.Width := 320;
  FRelayLeftPane := LeftPane;
  SetControlMargins(LeftPane, 0, 0, GAP_S, 0);
  SetControlPadding(LeftPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(LeftPane, True);
  AddSectionHeader(LeftPane, 'Status and Setup');

  FRelaySnippetsMemo := TMemo.Create(Self);
  FRelaySnippetsMemo.Parent := LeftPane;
  FRelaySnippetsMemo.Align := TAlignLayout.Bottom;
  FRelaySnippetsMemo.Height := 170;
  FRelaySnippetsMemo.ReadOnly := True;
  FRelaySnippetsMemo.WordWrap := False;
  SetControlMargins(FRelaySnippetsMemo, 0, GAP_S, 0, 0);

  Row := TLayout.Create(Self);
  Row.Parent := LeftPane;
  Row.Align := TAlignLayout.Bottom;
  Row.Height := ROW_FORM;
  SetControlMargins(Row, 0, GAP_S, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Copy';
  Btn.OnClick := RelaySnippetCopyClick;

  FRelayStatsList := TListBox.Create(Self);
  FRelayStatsList.Columns := 2;   { same 320px pane arithmetic as Stats }
  FRelayStatsList.Parent := LeftPane;
  FRelayStatsList.Align := TAlignLayout.Client;

  RelayRenderSnippets(nil);

  FRelaySplitter := AddPaneSplitter(Body, TAlignLayout.Left);

  RightPane := TLayout.Create(Self);
  RightPane.Parent := Body;
  RightPane.Align := TAlignLayout.Client;
  FRelayRightPane := RightPane;
  SetControlPadding(RightPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(RightPane, True);
  AddSectionHeader(RightPane, 'Workers');

  FRelayWorkerDetailMemo := TMemo.Create(Self);
  FRelayWorkerDetailMemo.Parent := RightPane;
  FRelayWorkerDetailMemo.Align := TAlignLayout.Bottom;
  FRelayWorkerDetailMemo.Height := 104;
  FRelayWorkerDetailMemo.ReadOnly := True;
  FRelayWorkerDetailMemo.WordWrap := True;
  FRelayWorkerDetailMemo.Lines.Text := 'Select a worker to inspect activity and advertised capabilities.';
  SetControlMargins(FRelayWorkerDetailMemo, 0, GAP_S, 0, 0);

  FRelayWorkerDetailMetaLabel := TLabel.Create(Self);
  FRelayWorkerDetailMetaLabel.Parent := RightPane;
  FRelayWorkerDetailMetaLabel.Align := TAlignLayout.Bottom;
  FRelayWorkerDetailMetaLabel.Height := ROW_TEXT;
  FRelayWorkerDetailMetaLabel.Text := 'Select a worker';
  FRelayWorkerDetailMetaLabel.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(FRelayWorkerDetailMetaLabel, UI_MUTED, TXT_BODY, False);

  FRelayWorkerDetailTitleLabel := TLabel.Create(Self);
  FRelayWorkerDetailTitleLabel.Parent := RightPane;
  FRelayWorkerDetailTitleLabel.Align := TAlignLayout.Bottom;
  FRelayWorkerDetailTitleLabel.Height := H_INPUT;
  FRelayWorkerDetailTitleLabel.Text := 'Worker Detail';
  FRelayWorkerDetailTitleLabel.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(FRelayWorkerDetailTitleLabel, UI_ACCENT, TXT_TITLE, True);

  FRelayWorkersList := TListBox.Create(Self);
  FRelayWorkersList.Parent := RightPane;
  FRelayWorkersList.Align := TAlignLayout.Client;
  FRelayWorkersList.OnChange := RelayWorkerListChange;

  FRelayTimer := TTimer.Create(Self);
  FRelayTimer.Interval := 5000;
  FRelayTimer.Enabled := False;
  FRelayTimer.OnTimer := RelayTimerTick;

  FRelayWorkerTimer := TTimer.Create(Self);
  FRelayWorkerTimer.Interval := 1000;
  FRelayWorkerTimer.Enabled := False;
  FRelayWorkerTimer.OnTimer := RelayWorkerTimerTick;
  RelayWorkerUpdateControls('local worker idle');
end;

procedure TMasterDetailForm.BuildOnboardingOverlay;
var
  Btn: TButton;
  Card: TRectangle;
  Row: TLayout;
  Shade: TRectangle;
  Title: TLabel;
begin
  FOnboardingOverlay := TLayout.Create(Self);
  FOnboardingOverlay.Parent := Self;
  FOnboardingOverlay.Align := TAlignLayout.Contents;
  FOnboardingOverlay.Visible := False;
  FOnboardingOverlay.HitTest := True;

  Shade := TRectangle.Create(Self);
  Shade.Parent := FOnboardingOverlay;
  Shade.Align := TAlignLayout.Contents;
  Shade.Fill.Color := $E6000000;
  Shade.Stroke.Kind := TBrushKind.None;

  { The web card's structure: a welcome header with a close, ONE step at a
    time, and right-aligned ghost-skip + primary actions -- not three loose
    full-width buttons doing tab navigation with no narrative. The real
    provider and memory FORMS stay where they live (Settings/Providers and
    Memory/Setup): duplicating them into the overlay would make two owners
    of one form, which is the defect class this codebase keeps paying for.
    The overlay is the GUIDE; the step buttons take you to the real form,
    and ProviderSaveClick brings you back for step two. }
  Card := TRectangle.Create(Self);
  FOnboardingCard := Card;
  Card.Parent := FOnboardingOverlay;
  Card.Align := TAlignLayout.Center;
  Card.Width := 460;
  Card.Height := 250;
  { NOT StyleChromeRect: the panel role resolves its fill to Kind=None
    (panels normally sit on the window ground), but a floating card over the
    shade must PAINT its ground or the shade bleeds through -- and the role
    re-apply on theme change would put Kind=None back. Named repaint instead,
    same pattern as the header rule. }
  Card.XRadius := 8;
  Card.YRadius := 8;
  Card.HitTest := False;
  ApplyOnboardingTheme;
  SetControlPadding(Card, 22, 20, 22, 20);

  Row := TLayout.Create(Self);
  Row.Parent := Card;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_LIST;

  Title := TLabel.Create(Self);
  Title.Parent := Row;
  Title.Align := TAlignLayout.Client;
  Title.Text := 'Welcome to PasClaw';
  Title.StyledSettings := Title.StyledSettings -
    [TStyledSetting.FontColor, TStyledSetting.Style, TStyledSetting.Size];
  UseStyledLabelColor(Title);
  Title.TextSettings.Font.Style := [TFontStyle.fsBold];
  Title.TextSettings.Font.Size := TXT_DISPLAY;

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := ICON_BTN_W;
  Btn.Text := #$2715;
  Btn.TagString := 'noicon';
  Btn.Hint := 'Configure later in Settings';
  Btn.ShowHint := True;
  Btn.OnClick := OnboardingFinishClick;

  FOnboardingStatusLabel := TLabel.Create(Self);
  FOnboardingStatusLabel.Parent := Card;
  FOnboardingStatusLabel.Align := TAlignLayout.Client;
  FOnboardingStatusLabel.WordWrap := True;
  FOnboardingStatusLabel.TextSettings.VertAlign := TTextAlign.Leading;
  FOnboardingStatusLabel.StyledSettings :=
    FOnboardingStatusLabel.StyledSettings - [TStyledSetting.FontColor];
  UseStyledLabelColor(FOnboardingStatusLabel);
  SetControlMargins(FOnboardingStatusLabel, 0, GAP_S, 0, GAP_S);

  Row := TLayout.Create(Self);
  Row.Parent := Card;
  Row.Align := TAlignLayout.Bottom;
  Row.Height := ROW_BAR;

  FOnboardingPrimaryButton := TButton.Create(Self);
  FOnboardingPrimaryButton.Parent := Row;
  FOnboardingPrimaryButton.Align := TAlignLayout.Right;
  FOnboardingPrimaryButton.Width := 150;
  SetControlMargins(FOnboardingPrimaryButton, GAP_S, 0, 0, 0);

  FOnboardingSkipButton := TButton.Create(Self);
  FOnboardingSkipButton.Parent := Row;
  FOnboardingSkipButton.Align := TAlignLayout.Right;
  FOnboardingSkipButton.Width := BTN_W_S;
  FOnboardingSkipButton.Text := 'Skip';
  FOnboardingSkipButton.TagString := 'noicon';
  FOnboardingSkipButton.OnClick := OnboardingSkipClick;

  RenderOnboardingStep;
end;

procedure TMasterDetailForm.RenderOnboardingStep;
{ ONE owner for what the card says and does, mirroring the web wizard's two
  steps. The copy is the web card's copy so the two clients read the same. }
begin
  if FOnboardingStatusLabel = nil then
    Exit;
  if FOnboardingStep <= 0 then
  begin
    FOnboardingStatusLabel.Text :=
      'No model provider is configured yet. Pick one and add your API key ' +
      'to start chatting - saved straight to the gateway, no restart needed.';
    if FOnboardingPrimaryButton <> nil then
    begin
      FOnboardingPrimaryButton.Text := 'Set up provider';
      FOnboardingPrimaryButton.OnClick := OnboardingProviderClick;
    end;
    { every branch owns the WHOLE card. Step two renames Skip to Finish, so
      reopening the wizard at step one showed a Finish button whose click
      actually advanced -- a caption lying about its action. }
    if FOnboardingSkipButton <> nil then
      FOnboardingSkipButton.Text := 'Skip';
  end
  else
  begin
    FOnboardingStatusLabel.Text :=
      'Optional: local memory search lets the agent recall past notes and ' +
      'files semantically - on-device embeddings, nothing leaves the host. ' +
      'Reranking sharpens the results.';
    if FOnboardingPrimaryButton <> nil then
    begin
      FOnboardingPrimaryButton.Text := 'Memory setup';
      FOnboardingPrimaryButton.OnClick := OnboardingMemoryClick;
    end;
    if FOnboardingSkipButton <> nil then
      FOnboardingSkipButton.Text := 'Finish';
  end;
end;

procedure TMasterDetailForm.OnboardingSkipClick(Sender: TObject);
{ Skip on step one advances to step two, matching the web wizard; skip on
  step two (captioned Finish) ends onboarding. }
begin
  if FOnboardingStep <= 0 then
  begin
    FOnboardingStep := 1;
    RenderOnboardingStep;
  end
  else
    OnboardingFinishClick(Sender);
end;

procedure TMasterDetailForm.BuildMcpPanel(AParent: TFmxObject);
var
  ArgsPanel: TLayout;
  Body: TLayout;
  Btn: TButton;
  LeftPane: TLayout;
  Panel: TLayout;
  ResultPanel: TLayout;
  RightPane: TLayout;
  Row: TLayout;
  SchemaPanel: TLayout;
  ServerTab: TTabItem;
  Tabs: TTabControl;
  ToolTab: TTabItem;
  ResultTab: TTabItem;
begin
  Panel := TLayout.Create(Self);
  Panel.Parent := AParent;
  Panel.Align := TAlignLayout.Client;
  FMcpPanel := Panel;
  SetControlPadding(Panel, GAP_M, GAP_S, GAP_M, 10);
  AddPanelChrome(Panel, False);

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := 124;
  Btn.Text := 'Load Tools';
  Btn.OnClick := McpToolsClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := 132;
  Btn.Text := 'Load Servers';
  Btn.OnClick := McpRefreshClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  AddSectionHeader(Row, 'MCP servers and tools');

  Body := TLayout.Create(Self);
  Body.Parent := Panel;
  Body.Align := TAlignLayout.Client;
  SetControlMargins(Body, 0, GAP_S, 0, 0);

  LeftPane := TLayout.Create(Self);
  LeftPane.Parent := Body;
  LeftPane.Align := TAlignLayout.Left;
  LeftPane.Width := 340;
  FMcpLeftPane := LeftPane;
  SetControlMargins(LeftPane, 0, 0, GAP_S, 0);
  SetControlPadding(LeftPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(LeftPane, True);
  AddSectionHeader(LeftPane, 'Registry');

  FMcpList := TListBox.Create(Self);
  FMcpList.Parent := LeftPane;
  FMcpList.Align := TAlignLayout.Client;
  FMcpList.OnChange := McpToolChange;

  FMcpSplitter := AddPaneSplitter(Body, TAlignLayout.Left);

  RightPane := TLayout.Create(Self);
  RightPane.Parent := Body;
  RightPane.Align := TAlignLayout.Client;
  FMcpRightPane := RightPane;
  SetControlPadding(RightPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(RightPane, True);

  Tabs := TTabControl.Create(Self);
  Tabs.Parent := RightPane;
  Tabs.Align := TAlignLayout.Client;
  FMcpTabs := Tabs;

  ServerTab := TTabItem.Create(Self);
  ServerTab.Parent := Tabs;
  ServerTab.Text := 'Server';

  { Phase 2 of docs/studio-metrics-plan.md. Was: name, Enabled, New, Save and
    Remove all on one row, then command and args sharing a second, none of
    them labelled -- and 'args' at a hand-picked 280px next to a Client-width
    'command' so the two moved independently on resize.

    Fields on the grid, actions on their own bar. The action row goes LAST so
    the form reads top-down as name, command, args, then what to do with
    them. }
  FMcpServerNameEdit := TEdit.Create(Self);
  FMcpServerNameEdit.TextPrompt := 'MCP server name';
  AddFormRow(ServerTab, 'Name', FMcpServerNameEdit);

  FMcpServerCmdEdit := TEdit.Create(Self);
  FMcpServerCmdEdit.TextPrompt := 'command';
  AddFormRow(ServerTab, 'Command', FMcpServerCmdEdit);

  FMcpServerArgsEdit := TEdit.Create(Self);
  FMcpServerArgsEdit.TextPrompt := 'args';
  AddFormRow(ServerTab, 'Args', FMcpServerArgsEdit);

  FMcpServerEnabledCheck := TCheckBox.Create(Self);
  FMcpServerEnabledCheck.Text := 'Enabled';
  FMcpServerEnabledCheck.IsChecked := True;
  AddFormRow(ServerTab, 'State', FMcpServerEnabledCheck, 140);

  Row := TLayout.Create(Self);
  Row.Parent := ServerTab;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;
  SetControlMargins(Row, FORM_LABEL_W + GAP_M, GAP_XS, 0, GAP_S);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Left;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Save Server';
  Btn.OnClick := McpServerSaveClick;
  SetControlMargins(Btn, 0, 0, GAP_S, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Left;
  Btn.Width := BTN_W_S;
  Btn.Text := 'New';
  Btn.OnClick := McpServerClearClick;
  SetControlMargins(Btn, 0, 0, GAP_S, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Left;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Remove';
  Btn.OnClick := McpServerRemoveClick;

  AddSectionHeader(ServerTab, 'Environment');

  FMcpServerEnvMemo := TMemo.Create(Self);
  FMcpServerEnvMemo.Parent := ServerTab;
  FMcpServerEnvMemo.Align := TAlignLayout.Client;
  FMcpServerEnvMemo.WordWrap := False;
  FMcpServerEnvMemo.TextPrompt := 'env string, JSON, or KEY=VALUE lines';
  SetControlMargins(FMcpServerEnvMemo, 0, GAP_XS, 0, 0);

  ToolTab := TTabItem.Create(Self);
  ToolTab.Parent := Tabs;
  ToolTab.Text := 'Tool';

  Row := TLayout.Create(Self);
  Row.Parent := ToolTab;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;
  SetControlMargins(Row, 0, GAP_S, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Invoke';
  Btn.OnClick := McpToolInvokeClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := 118;
  Btn.Text := 'Apply Form';
  Btn.OnClick := McpSchemaApplyClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FMcpToolCombo := TComboBox.Create(Self);
  FMcpToolCombo.Parent := Row;
  FMcpToolCombo.Align := TAlignLayout.Client;
  FMcpToolCombo.OnChange := McpToolChange;

  ArgsPanel := TLayout.Create(Self);
  ArgsPanel.Parent := ToolTab;
  ArgsPanel.Align := TAlignLayout.Bottom;
  ArgsPanel.Height := 150;
  FMcpArgsPanel := ArgsPanel;
  SetControlMargins(ArgsPanel, 0, GAP_S, 0, 0);
  SetControlPadding(ArgsPanel, 0, 0, 0, 0);
  AddSectionHeader(ArgsPanel, 'Arguments JSON');

  FMcpToolArgsMemo := TMemo.Create(Self);
  FMcpToolArgsMemo.Parent := ArgsPanel;
  FMcpToolArgsMemo.Align := TAlignLayout.Client;
  FMcpToolArgsMemo.WordWrap := False;
  FMcpToolArgsMemo.Lines.Text := '{}';

  SchemaPanel := TLayout.Create(Self);
  SchemaPanel.Parent := ToolTab;
  SchemaPanel.Align := TAlignLayout.Client;
  FMcpSchemaPanel := SchemaPanel;
  SetControlMargins(SchemaPanel, 0, GAP_S, 0, 0);
  SetControlPadding(SchemaPanel, 0, 0, 0, 0);
  AddSectionHeader(SchemaPanel, 'Tool form');

  FMcpSchemaForm := TVertScrollBox.Create(Self);
  FMcpSchemaForm.Parent := SchemaPanel;
  FMcpSchemaForm.Align := TAlignLayout.Client;

  ResultTab := TTabItem.Create(Self);
  ResultTab.Parent := Tabs;
  ResultTab.Text := 'Result';

  ResultPanel := TLayout.Create(Self);
  ResultPanel.Parent := ResultTab;
  ResultPanel.Align := TAlignLayout.Client;
  FMcpResultPanel := ResultPanel;
  SetControlMargins(ResultPanel, 0, GAP_S, 0, 0);

  Row := TLayout.Create(Self);
  Row.Parent := ResultPanel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_FORM;

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Copy';
  Btn.OnClick := McpResultCopyClick;

  FMcpResultStatusLabel := TLabel.Create(Self);
  FMcpResultStatusLabel.Parent := Row;
  FMcpResultStatusLabel.Align := TAlignLayout.Client;
  FMcpResultStatusLabel.Text := 'MCP invoke result';
  FMcpResultStatusLabel.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(FMcpResultStatusLabel, UI_ACCENT, TXT_TITLE, True);

  FMcpResultDetailMemo := TMemo.Create(Self);
  FMcpResultDetailMemo.Parent := ResultPanel;
  FMcpResultDetailMemo.Align := TAlignLayout.Bottom;
  FMcpResultDetailMemo.Height := 128;
  FMcpResultDetailMemo.ReadOnly := True;
  FMcpResultDetailMemo.WordWrap := True;
  FMcpResultDetailMemo.Lines.Text := 'Invoke a tool to inspect its result.';
  SetControlMargins(FMcpResultDetailMemo, 0, GAP_S, 0, 0);

  FMcpResultList := TListBox.Create(Self);
  FMcpResultList.Parent := ResultPanel;
  FMcpResultList.Align := TAlignLayout.Client;
  FMcpResultList.OnChange := McpResultSelect;
  AddCardListItem(FMcpResultList, 'No result yet',
    'Invoke a selected MCP tool to see native result cards.', '', 48, False);

  Tabs.TabIndex := 0;
end;

procedure TMasterDetailForm.BuildSkillsPanel(AParent: TFmxObject);
var
  Body: TLayout;
  Btn: TButton;
  CatalogPane: TLayout;
  InstalledPane: TLayout;
  LeftPane: TLayout;
  PendingPane: TLayout;
  Panel: TLayout;
  Row: TLayout;
begin
  Panel := TLayout.Create(Self);
  Panel.Parent := AParent;
  Panel.Align := TAlignLayout.Client;
  SetControlPadding(Panel, GAP_M, GAP_S, GAP_M, 10);
  AddPanelChrome(Panel, False);

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Remove';
  Btn.OnClick := SkillsRemoveClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Install';
  Btn.OnClick := SkillsInstallClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Refresh';
  Btn.OnClick := SkillsRefreshClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FSkillInstallEdit := TEdit.Create(Self);
  FSkillInstallEdit.Parent := Row;
  FSkillInstallEdit.Align := TAlignLayout.Client;
  FSkillInstallEdit.TextPrompt := 'install: owner/repo, hub:slug, clawhub:slug, or bare slug';

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;
  SetControlMargins(Row, 0, GAP_S, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := 108;
  Btn.Text := 'Install Selected';
  Btn.OnClick := SkillsInstallClick;
  Btn.TagString := 'catalog';
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Search';
  Btn.OnClick := SkillsSearchClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FSkillSearchEdit := TEdit.Create(Self);
  FSkillSearchEdit.Parent := Row;
  FSkillSearchEdit.Align := TAlignLayout.Client;
  FSkillSearchEdit.TextPrompt := 'search skill catalog';

  Body := TLayout.Create(Self);
  Body.Parent := Panel;
  Body.Align := TAlignLayout.Client;
  SetControlMargins(Body, 0, GAP_S, 0, 0);

  LeftPane := TLayout.Create(Self);
  LeftPane.Parent := Body;
  LeftPane.Align := TAlignLayout.Left;
  LeftPane.Width := 300;
  FSkillLeftPane := LeftPane;
  SetControlMargins(LeftPane, 0, 0, GAP_S, 0);
  SetControlPadding(LeftPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(LeftPane, True);

  PendingPane := TLayout.Create(Self);
  PendingPane.Parent := LeftPane;
  PendingPane.Align := TAlignLayout.Bottom;
  PendingPane.Height := 190;
  FSkillPendingPane := PendingPane;
  SetControlMargins(PendingPane, 0, GAP_S, 0, 0);
  AddSectionHeader(PendingPane, 'Pending approvals');

  Row := TLayout.Create(Self);
  Row.Parent := PendingPane;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Reject';
  Btn.OnClick := SkillsRejectClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Approve';
  Btn.OnClick := SkillsApproveClick;

  FSkillPendingList := TListBox.Create(Self);
  FSkillPendingList.Parent := PendingPane;
  FSkillPendingList.Align := TAlignLayout.Client;
  FSkillPendingList.OnChange := SkillsListChange;
  SetControlMargins(FSkillPendingList, 0, GAP_S, 0, 0);

  InstalledPane := TLayout.Create(Self);
  InstalledPane.Parent := LeftPane;
  InstalledPane.Align := TAlignLayout.Client;
  FSkillInstalledPane := InstalledPane;
  AddSectionHeader(InstalledPane, 'Installed');

  FSkillList := TListBox.Create(Self);
  FSkillList.Parent := InstalledPane;
  FSkillList.Align := TAlignLayout.Client;
  FSkillList.OnChange := SkillsListChange;

  FSkillSplitter := AddPaneSplitter(Body, TAlignLayout.Left);

  CatalogPane := TLayout.Create(Self);
  CatalogPane.Parent := Body;
  CatalogPane.Align := TAlignLayout.Client;
  FSkillCatalogPane := CatalogPane;
  SetControlPadding(CatalogPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(CatalogPane, True);
  AddSectionHeader(CatalogPane, 'Catalog results');

  FSkillDetailMemo := TMemo.Create(Self);
  FSkillDetailMemo.Parent := CatalogPane;
  FSkillDetailMemo.Align := TAlignLayout.Bottom;
  FSkillDetailMemo.Height := 130;
  FSkillDetailMemo.ReadOnly := True;
  FSkillDetailMemo.WordWrap := True;
  FSkillDetailMemo.Lines.Text := '';
  SetControlMargins(FSkillDetailMemo, 0, GAP_S, 0, 0);

  FSkillDetailMetaLabel := TLabel.Create(Self);
  FSkillDetailMetaLabel.Parent := CatalogPane;
  FSkillDetailMetaLabel.Align := TAlignLayout.Bottom;
  FSkillDetailMetaLabel.Height := ROW_TEXT;
  FSkillDetailMetaLabel.Text := 'Select a skill';
  FSkillDetailMetaLabel.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(FSkillDetailMetaLabel, UI_MUTED, TXT_BODY, False);

  FSkillDetailTitleLabel := TLabel.Create(Self);
  FSkillDetailTitleLabel.Parent := CatalogPane;
  FSkillDetailTitleLabel.Align := TAlignLayout.Bottom;
  FSkillDetailTitleLabel.Height := H_INPUT;
  FSkillDetailTitleLabel.Text := 'Skill Detail';
  FSkillDetailTitleLabel.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(FSkillDetailTitleLabel, UI_ACCENT, TXT_TITLE, True);

  FSkillCatalogList := TListBox.Create(Self);
  FSkillCatalogList.Parent := CatalogPane;
  FSkillCatalogList.Align := TAlignLayout.Client;
  FSkillCatalogList.OnChange := SkillsListChange;

  AddPaneSplitter(AParent, TAlignLayout.Top);
end;

procedure TMasterDetailForm.BuildVaultPanel(AParent: TFmxObject);
var
  Body: TLayout;
  Btn: TButton;
  DetailPane: TLayout;
  ListPane: TLayout;
  Panel: TLayout;
  Row: TLayout;
  Title: TLabel;
begin
  Panel := TLayout.Create(Self);
  Panel.Parent := AParent;
  Panel.Align := TAlignLayout.Client;
  SetControlPadding(Panel, GAP_M, GAP_S, GAP_M, 10);
  AddPanelChrome(Panel, False);

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Build With';
  Btn.OnClick := VaultBuildWithClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Search';
  Btn.OnClick := VaultSearchClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FVaultSearchEdit := TEdit.Create(Self);
  FVaultSearchEdit.Parent := Row;
  FVaultSearchEdit.Align := TAlignLayout.Client;
  FVaultSearchEdit.Text := 'delphi';
  FVaultSearchEdit.TextPrompt := 'search Code Vault';

  Body := TLayout.Create(Self);
  Body.Parent := Panel;
  Body.Align := TAlignLayout.Client;
  SetControlMargins(Body, 0, GAP_S, 0, 0);

  ListPane := TLayout.Create(Self);
  ListPane.Parent := Body;
  ListPane.Align := TAlignLayout.Left;
  ListPane.Width := 320;
  FVaultListPane := ListPane;
  SetControlMargins(ListPane, 0, 0, GAP_S, 0);
  SetControlPadding(ListPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(ListPane, True);
  AddSectionHeader(ListPane, 'Search results');

  FVaultList := TListBox.Create(Self);
  FVaultList.Parent := ListPane;
  FVaultList.Align := TAlignLayout.Client;
  FVaultList.OnChange := VaultListChange;

  AddPaneSplitter(Body, TAlignLayout.Left);

  DetailPane := TLayout.Create(Self);
  DetailPane.Parent := Body;
  DetailPane.Align := TAlignLayout.Client;
  FVaultDetailPane := DetailPane;
  SetControlPadding(DetailPane, 10, GAP_S, 10, GAP_S);
  AddPanelChrome(DetailPane, True);

  FVaultTitleLabel := TLabel.Create(Self);
  FVaultTitleLabel.Parent := DetailPane;
  FVaultTitleLabel.Align := TAlignLayout.Top;
  FVaultTitleLabel.Height := H_INPUT;
  FVaultTitleLabel.Text := 'Select a vault entry';
  FVaultTitleLabel.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(FVaultTitleLabel, UI_ACCENT, TXT_TITLE, True);

  FVaultMetaLabel := TLabel.Create(Self);
  FVaultMetaLabel.Parent := DetailPane;
  FVaultMetaLabel.Align := TAlignLayout.Top;
  FVaultMetaLabel.Height := ROW_BAR;
  FVaultMetaLabel.Text := 'Search Code Vault and choose a result.';
  FVaultMetaLabel.WordWrap := True;
  StyleLabel(FVaultMetaLabel, UI_MUTED, TXT_BODY, False);

  Row := TLayout.Create(Self);
  Row.Parent := DetailPane;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_FORM;
  SetControlMargins(Row, 0, GAP_XS, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Copy';
  Btn.OnClick := VaultDetailCopyClick;

  Title := TLabel.Create(Self);
  Title.Parent := Row;
  Title.Align := TAlignLayout.Client;
  Title.Text := 'Detail';
  Title.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(Title, UI_ACCENT, TXT_TITLE, True);

  FVaultDetailMemo := TMemo.Create(Self);
  FVaultDetailMemo.Parent := DetailPane;
  FVaultDetailMemo.Align := TAlignLayout.Client;
  FVaultDetailMemo.ReadOnly := True;
  FVaultDetailMemo.WordWrap := True;
  FVaultDetailMemo.Lines.Text := '';

  AddPaneSplitter(AParent, TAlignLayout.Top);
end;

procedure TMasterDetailForm.BuildMemorySetupPanel(AParent: TFmxObject);
var
  Btn: TButton;
  Panel: TLayout;
  Row: TLayout;
  Title: TLabel;
begin
  Panel := TLayout.Create(Self);
  Panel.Parent := AParent;
  Panel.Align := TAlignLayout.Client;
  SetControlPadding(Panel, GAP_M, GAP_S, GAP_M, 10);
  AddPanelChrome(Panel, False);

  Title := AddSectionHeader(Panel, 'Memory and reranking setup');
  Title.Height := H_INPUT;

  Title := TLabel.Create(Self);
  Title.Parent := Panel;
  Title.Align := TAlignLayout.Top;
  Title.Height := ROW_LIST;
  Title.Text := 'Configure local semantic search, reranking, and model downloads for this workspace.';
  Title.WordWrap := True;
  Title.TextSettings.VertAlign := TTextAlign.Center;
  Title.StyledSettings := Title.StyledSettings - [TStyledSetting.FontColor];
  UseStyledLabelColor(Title);
  SetControlMargins(Title, 0, 0, 0, GAP_S);

  { Phase 2 of docs/studio-metrics-plan.md. Was: a checkbox, two combos and
    an edit sharing ONE row at four hand-picked widths, with nothing naming
    any of them -- the plan called this the poster child, and it was. Each
    control now sits on a labelled row of the shared grid. }
  FMemoryVectorCheck := TCheckBox.Create(Self);
  FMemoryVectorCheck.Text := 'Enabled';
  FMemoryVectorCheck.IsChecked := True;
  AddFormRow(Panel, 'Vector search', FMemoryVectorCheck, 140);

  FMemoryBackendCombo := TComboBox.Create(Self);
  FMemoryBackendCombo.Items.Add('off');
  FMemoryBackendCombo.Items.Add('local');
  FMemoryBackendCombo.Items.Add('llm');
  FMemoryBackendCombo.Items.Add('auto');
  FMemoryBackendCombo.ItemIndex := 3;
  AddFormRow(Panel, 'Backend', FMemoryBackendCombo, 140);

  FMemoryModelCombo := TComboBox.Create(Self);
  FMemoryModelCombo.Items.Add('bge-reranker-base');
  FMemoryModelCombo.ItemIndex := 0;
  FMemoryModelCombo.OnChange := MemoryModelChoiceChange;
  AddFormRow(Panel, 'Reranker', FMemoryModelCombo, 220);

  FMemoryRerankModelEdit := TEdit.Create(Self);
  FMemoryRerankModelEdit.Text := 'bge-reranker-base';
  FMemoryRerankModelEdit.TextPrompt := 'local reranker model';
  AddFormRow(Panel, 'Model name', FMemoryRerankModelEdit);

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_LIST;
  SetControlMargins(Row, 0, GAP_S, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := 116;
  Btn.Text := 'Save && download';
  Btn.OnClick := MemorySetupSaveClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Load Setup';
  Btn.OnClick := MemorySetupLoadClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FMemoryDownloadEmbedCheck := TCheckBox.Create(Self);
  FMemoryDownloadEmbedCheck.Parent := Row;
  FMemoryDownloadEmbedCheck.Align := TAlignLayout.Left;
  FMemoryDownloadEmbedCheck.Width := 180;
  FMemoryDownloadEmbedCheck.Text := 'Download embedder';
  FMemoryDownloadEmbedCheck.IsChecked := True;
  SetControlMargins(FMemoryDownloadEmbedCheck, 0, 0, GAP_S, 0);

  FMemoryDownloadRerankCheck := TCheckBox.Create(Self);
  FMemoryDownloadRerankCheck.Parent := Row;
  FMemoryDownloadRerankCheck.Align := TAlignLayout.Left;
  FMemoryDownloadRerankCheck.Width := 180;
  FMemoryDownloadRerankCheck.Text := 'Download reranker';
  FMemoryDownloadRerankCheck.IsChecked := True;

  FMemoryStatusLabel := TLabel.Create(Self);
  FMemoryStatusLabel.Parent := Panel;
  FMemoryStatusLabel.Align := TAlignLayout.Client;
  FMemoryStatusLabel.Text := 'Load setup to inspect embedder, reranker, ONNX runtime, and download job state.';
  FMemoryStatusLabel.WordWrap := True;
  FMemoryStatusLabel.StyledSettings := FMemoryStatusLabel.StyledSettings -
    [TStyledSetting.FontColor];
  UseStyledLabelColor(FMemoryStatusLabel);
end;

procedure TMasterDetailForm.BuildConfigEditorPanel(AParent: TFmxObject);
var
  Body: TLayout;
  Btn: TButton;
  EditorPane: TLayout;
  ListPane: TLayout;
  Panel: TLayout;
  Row: TLayout;
  Title: TLabel;
begin
  Panel := TLayout.Create(Self);
  Panel.Parent := AParent;
  Panel.Align := TAlignLayout.Top;
  Panel.Height := 390;
  SetControlPadding(Panel, GAP_M, GAP_S, GAP_M, 10);
  AddPanelChrome(Panel, False);

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Delete';
  Btn.OnClick := ConfigDeleteValueClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Add Item';
  Btn.OnClick := ConfigAddArrayItemClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Apply';
  Btn.OnClick := ConfigApplyValueClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Refresh';
  Btn.OnClick := ConfigRefreshClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Title := TLabel.Create(Self);
  Title.Parent := Row;
  Title.Align := TAlignLayout.Client;
  Title.Text := 'Settings: edit gateway config values, secrets, providers, MCP servers, cron jobs, and sandbox policy.';
  Title.TextSettings.VertAlign := TTextAlign.Center;
  Title.StyledSettings := Title.StyledSettings - [TStyledSetting.FontColor];
  UseStyledLabelColor(Title);

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;
  SetControlMargins(Row, 0, GAP_S, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Models';
  Btn.TagString := 'default_model';
  Btn.OnClick := ConfigQuickSectionClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Router';
  Btn.TagString := 'auto_router';
  Btn.OnClick := ConfigQuickSectionClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Sandbox';
  Btn.TagString := 'sandbox';
  Btn.OnClick := ConfigQuickSectionClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Cron';
  Btn.TagString := 'cron';
  Btn.OnClick := ConfigQuickSectionClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'MCP';
  Btn.TagString := 'mcp_servers';
  Btn.OnClick := ConfigQuickSectionClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Providers';
  Btn.TagString := 'providers';
  Btn.OnClick := ConfigQuickSectionClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Title := TLabel.Create(Self);
  Title.Parent := Row;
  Title.Align := TAlignLayout.Client;
  Title.Text := 'Quick sections';
  Title.TextSettings.VertAlign := TTextAlign.Center;
  Title.StyledSettings := Title.StyledSettings - [TStyledSetting.FontColor];
  UseStyledLabelColor(Title);

  Body := TLayout.Create(Self);
  Body.Parent := Panel;
  Body.Align := TAlignLayout.Client;
  SetControlMargins(Body, 0, GAP_S, 0, 0);

  ListPane := TLayout.Create(Self);
  ListPane.Parent := Body;
  ListPane.Align := TAlignLayout.Left;
  ListPane.Width := 360;
  FConfigListPane := ListPane;
  SetControlMargins(ListPane, 0, 0, GAP_S, 0);
  SetControlPadding(ListPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(ListPane, True);
  AddSectionHeader(ListPane, 'Config tree');

  FConfigList := TListBox.Create(Self);
  FConfigList.Parent := ListPane;
  FConfigList.Align := TAlignLayout.Client;
  FConfigList.OnChange := ConfigListChange;

  AddPaneSplitter(Body, TAlignLayout.Left);

  EditorPane := TLayout.Create(Self);
  EditorPane.Parent := Body;
  EditorPane.Align := TAlignLayout.Client;
  FConfigEditorPane := EditorPane;
  SetControlPadding(EditorPane, GAP_S, GAP_S, GAP_S, GAP_S);
  AddPanelChrome(EditorPane, True);
  AddSectionHeader(EditorPane, 'Selected value');

  FConfigPathEdit := TEdit.Create(Self);
  FConfigPathEdit.Parent := EditorPane;
  FConfigPathEdit.Align := TAlignLayout.Top;
  FConfigPathEdit.Height := ROW_BAR;
  FConfigPathEdit.TextPrompt := 'selected config path';
  FConfigPathEdit.ReadOnly := True;

  FConfigValueMemo := TMemo.Create(Self);
  FConfigValueMemo.Parent := EditorPane;
  FConfigValueMemo.Align := TAlignLayout.Client;
  FConfigValueMemo.WordWrap := False;
  FConfigValueMemo.TextPrompt := 'selected value JSON or scalar text';
  SetControlMargins(FConfigValueMemo, 0, GAP_S, 0, 0);
end;

procedure TMasterDetailForm.BuildProviderSetupPanel(AParent: TFmxObject);
var
  Btn: TButton;
  Panel: TLayout;
  Row: TLayout;
begin
  Panel := TLayout.Create(Self);
  Panel.Parent := AParent;
  Panel.Align := TAlignLayout.Client;
  SetControlPadding(Panel, GAP_M, GAP_S, GAP_M, 10);
  AddPanelChrome(Panel, False);

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;

  FProviderCombo := TComboBox.Create(Self);
  FProviderCombo.Parent := Row;
  FProviderCombo.Align := TAlignLayout.Left;
  FProviderCombo.Width := 170;
  FProviderCombo.OnChange := ProviderComboChange;
  SetControlMargins(FProviderCombo, 0, 0, GAP_S, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := 108;
  Btn.Text := 'Save Provider';
  Btn.OnClick := ProviderSaveClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := 112;
  Btn.Text := 'Load Catalog';
  Btn.OnClick := ProviderCatalogClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FProviderNotesLabel := TLabel.Create(Self);
  FProviderNotesLabel.Parent := Row;
  FProviderNotesLabel.Align := TAlignLayout.Client;
  FProviderNotesLabel.Text := 'Pick a provider catalog entry to configure the gateway.';
  FProviderNotesLabel.WordWrap := True;
  FProviderNotesLabel.StyledSettings := FProviderNotesLabel.StyledSettings -
    [TStyledSetting.FontColor];
  UseStyledLabelColor(FProviderNotesLabel);

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;
  SetControlMargins(Row, 0, GAP_S, 0, 0);

  FProviderModelEdit := TEdit.Create(Self);
  FProviderModelEdit.Parent := Row;
  FProviderModelEdit.Align := TAlignLayout.Right;
  FProviderModelEdit.Width := 230;
  FProviderModelEdit.TextPrompt := 'model';
  SetControlMargins(FProviderModelEdit, GAP_S, 0, 0, 0);

  FProviderKeyEdit := TEdit.Create(Self);
  FProviderKeyEdit.Parent := Row;
  FProviderKeyEdit.Align := TAlignLayout.Left;
  FProviderKeyEdit.Width := 240;
  FProviderKeyEdit.Password := True;
  FProviderKeyEdit.TextPrompt := 'API key';
  SetControlMargins(FProviderKeyEdit, 0, 0, GAP_S, 0);

  FProviderBaseEdit := TEdit.Create(Self);
  FProviderBaseEdit.Parent := Row;
  FProviderBaseEdit.Align := TAlignLayout.Client;
  FProviderBaseEdit.TextPrompt := 'API base URL';

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;
  SetControlMargins(Row, 0, GAP_S, 0, 0);

  FProviderSecondaryCombo := TComboBox.Create(Self);
  FProviderSecondaryCombo.Parent := Row;
  FProviderSecondaryCombo.Align := TAlignLayout.Left;
  FProviderSecondaryCombo.Width := 160;
  FProviderSecondaryCombo.Items.Add('(none)');
  FProviderSecondaryCombo.ItemIndex := 0;
  FProviderSecondaryCombo.OnChange := ProviderSecondaryComboChange;
  SetControlMargins(FProviderSecondaryCombo, 0, 0, GAP_S, 0);

  FProviderSecondaryKeyEdit := TEdit.Create(Self);
  FProviderSecondaryKeyEdit.Parent := Row;
  FProviderSecondaryKeyEdit.Align := TAlignLayout.Right;
  FProviderSecondaryKeyEdit.Width := 190;
  FProviderSecondaryKeyEdit.Password := True;
  FProviderSecondaryKeyEdit.TextPrompt := 'secondary key';
  SetControlMargins(FProviderSecondaryKeyEdit, GAP_S, 0, 0, 0);

  FProviderSecondaryModelEdit := TEdit.Create(Self);
  FProviderSecondaryModelEdit.Parent := Row;
  FProviderSecondaryModelEdit.Align := TAlignLayout.Right;
  FProviderSecondaryModelEdit.Width := 220;
  FProviderSecondaryModelEdit.TextPrompt := 'secondary model';
  SetControlMargins(FProviderSecondaryModelEdit, GAP_S, 0, 0, 0);

  FProviderSecondaryBaseEdit := TEdit.Create(Self);
  FProviderSecondaryBaseEdit.Parent := Row;
  FProviderSecondaryBaseEdit.Align := TAlignLayout.Client;
  FProviderSecondaryBaseEdit.TextPrompt := 'secondary base URL';

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;
  SetControlMargins(Row, 0, GAP_S, 0, 0);

  FProviderRouteCheck := TCheckBox.Create(Self);
  FProviderRouteCheck.Parent := Row;
  FProviderRouteCheck.Align := TAlignLayout.Left;
  FProviderRouteCheck.Width := 238;
  FProviderRouteCheck.Text := 'Route easy turns to secondary';
  SetControlMargins(FProviderRouteCheck, 0, 0, GAP_S, 0);

  FProviderFallbackCheck := TCheckBox.Create(Self);
  FProviderFallbackCheck.Parent := Row;
  FProviderFallbackCheck.Align := TAlignLayout.Left;
  FProviderFallbackCheck.Width := 238;
  FProviderFallbackCheck.Text := 'Use secondary as fallback';

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Client;
  SetControlMargins(Row, 0, GAP_XS, 0, 0);

  FProviderNotesLabel := TLabel.Create(Self);
  FProviderNotesLabel.Parent := Row;
  FProviderNotesLabel.Align := TAlignLayout.Client;
  FProviderNotesLabel.WordWrap := True;
  FProviderNotesLabel.Text := 'Provider setup writes /v1/config and hot-reloads models when the gateway accepts it.';
  FProviderNotesLabel.StyledSettings := FProviderNotesLabel.StyledSettings -
    [TStyledSetting.FontColor];
  UseStyledLabelColor(FProviderNotesLabel);
end;

procedure TMasterDetailForm.BuildWorkflowEditorPanel(AParent: TFmxObject);
var
  Body: TLayout;
  Btn: TButton;
  Chrome: TRectangle;
  EdgeRow: TLayout;
  LeftPane: TLayout;
  MiddlePane: TLayout;
  Panel: TLayout;
  RightPane: TLayout;
  Row: TLayout;
  SettingsPane: TVertScrollBox;
  SettingsTab: TTabItem;
  DesignerTab: TTabItem;
  Title: TLabel;
  WorkflowTabs: TTabControl;
begin
  Panel := TLayout.Create(Self);
  Panel.Parent := AParent;
  Panel.Align := TAlignLayout.Client;
  FWorkflowEditorPanel := Panel;
  SetControlPadding(Panel, 10, GAP_S, 10, 10);
  Chrome := TRectangle.Create(Self);
  Chrome.Parent := Panel;
  Chrome.Align := TAlignLayout.Contents;
  StyleChromeRect(Chrome, UI_PANEL, UI_BORDER, 6, False);
  Chrome.SendToBack;

  Row := TLayout.Create(Self);
  Row.Parent := Panel;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_LIST;

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Delete';
  Btn.OnClick := WorkflowDeleteClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Run';
  Btn.OnClick := WorkflowRunClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Save';
  Btn.OnClick := WorkflowSaveClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Load';
  Btn.OnClick := WorkflowLoadClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_L;
  Btn.Text := 'Load Tools';
  Btn.OnClick := WorkflowLoadToolsClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'New';
  Btn.OnClick := WorkflowNewClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Fit';
  Btn.Hint := 'Bring the whole graph back into view';
  Btn.ShowHint := True;
  Btn.OnClick := WorkflowFitViewClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FWorkflowPickerCombo := TComboBox.Create(Self);
  FWorkflowPickerCombo.Parent := Row;
  FWorkflowPickerCombo.Align := TAlignLayout.Left;
  FWorkflowPickerCombo.Width := 160;
  FWorkflowPickerCombo.OnChange := WorkflowPickerChange;
  SetControlMargins(FWorkflowPickerCombo, 0, 0, GAP_S, 0);

  FWorkflowNameEdit := TEdit.Create(Self);
  FWorkflowNameEdit.Parent := Row;
  FWorkflowNameEdit.Align := TAlignLayout.Client;
  FWorkflowNameEdit.TextPrompt := 'workflow name';

  WorkflowTabs := TTabControl.Create(Self);
  WorkflowTabs.Parent := Panel;
  WorkflowTabs.Align := TAlignLayout.Client;
  SetControlMargins(WorkflowTabs, 0, GAP_S, 0, 0);

  DesignerTab := TTabItem.Create(Self);
  DesignerTab.Parent := WorkflowTabs;
  DesignerTab.Text := 'Designer';

  SettingsTab := TTabItem.Create(Self);
  SettingsTab.Parent := WorkflowTabs;
  SettingsTab.Text := 'Settings';

  SettingsPane := TVertScrollBox.Create(Self);
  SettingsPane.Parent := SettingsTab;
  SettingsPane.Align := TAlignLayout.Client;
  SetControlPadding(SettingsPane, GAP_S, GAP_S, GAP_S, 10);

  Row := TLayout.Create(Self);
  Row.Parent := SettingsPane;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;
  SetControlMargins(Row, 0, 0, 0, 0);

  FWorkflowInputsEdit := TEdit.Create(Self);
  FWorkflowInputsEdit.Parent := Row;
  FWorkflowInputsEdit.Align := TAlignLayout.Right;
  FWorkflowInputsEdit.Width := 270;
  FWorkflowInputsEdit.Text := 'prompt';
  FWorkflowInputsEdit.TextPrompt := 'inputs, comma separated';
  SetControlMargins(FWorkflowInputsEdit, GAP_S, 0, 0, 0);

  { where runs land on disk (engine default: workflows/<id> when empty).
    A visible contract, not a hidden convention. }
  FWorkflowOutputDirEdit := TEdit.Create(Self);
  FWorkflowOutputDirEdit.Parent := Row;
  FWorkflowOutputDirEdit.Align := TAlignLayout.Right;
  FWorkflowOutputDirEdit.Width := 200;
  FWorkflowOutputDirEdit.TextPrompt := 'output folder (workflows/<id>)';
  SetControlMargins(FWorkflowOutputDirEdit, GAP_S, 0, 0, 0);

  FWorkflowDescEdit := TEdit.Create(Self);
  FWorkflowDescEdit.Parent := Row;
  FWorkflowDescEdit.Align := TAlignLayout.Client;
  FWorkflowDescEdit.TextPrompt := 'description';

  Row := TLayout.Create(Self);
  Row.Parent := SettingsPane;
  Row.Align := TAlignLayout.Top;
  Row.Height := 72;
  SetControlMargins(Row, 0, GAP_S, 0, 0);

  FWorkflowOutputsMemo := TMemo.Create(Self);
  FWorkflowOutputsMemo.Parent := Row;
  FWorkflowOutputsMemo.Align := TAlignLayout.Left;
  FWorkflowOutputsMemo.Width := 360;
  FWorkflowOutputsMemo.WordWrap := False;
  FWorkflowOutputsMemo.TextPrompt := 'outputs, one per line: name = {{nodes.node.output}}';
  SetControlMargins(FWorkflowOutputsMemo, 0, 0, GAP_S, 0);

  FWorkflowLoopMemo := TMemo.Create(Self);
  FWorkflowLoopMemo.Parent := Row;
  FWorkflowLoopMemo.Align := TAlignLayout.Client;
  FWorkflowLoopMemo.WordWrap := False;
  FWorkflowLoopMemo.TextPrompt := 'loop: max = 5, until = {{nodes.judge.done}}, output -> input';

  Body := TLayout.Create(Self);
  Body.Parent := DesignerTab;
  Body.Align := TAlignLayout.Client;
  SetControlMargins(Body, 0, GAP_S, 0, 0);

  LeftPane := TLayout.Create(Self);
  LeftPane.Parent := Body;
  LeftPane.Align := TAlignLayout.Left;
  LeftPane.Width := 180;
  FWorkflowLeftPane := LeftPane;
  SetControlMargins(LeftPane, 0, 0, GAP_S, 0);
  SetControlPadding(LeftPane, GAP_S, GAP_S, GAP_S, GAP_S);
  Chrome := TRectangle.Create(Self);
  Chrome.Parent := LeftPane;
  Chrome.Align := TAlignLayout.Contents;
  StyleChromeRect(Chrome, UI_PANEL_ALT, UI_BORDER, 6, False);
  Chrome.SendToBack;

  Title := TLabel.Create(Self);
  Title.Parent := LeftPane;
  Title.Align := TAlignLayout.Top;
  Title.Height := ROW_TEXT;
  Title.Text := 'Nodes';
  Title.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(Title, UI_ACCENT, TXT_TITLE, True);

  FWorkflowNodesList := TListBox.Create(Self);
  FWorkflowNodesList.Parent := LeftPane;
  FWorkflowNodesList.Align := TAlignLayout.Client;
  FWorkflowNodesList.OnChange := WorkflowNodeSelect;

  AddPaneSplitter(Body, TAlignLayout.Left);

  MiddlePane := TLayout.Create(Self);
  MiddlePane.Parent := Body;
  MiddlePane.Align := TAlignLayout.Client;
  SetControlPadding(MiddlePane, GAP_S, GAP_S, GAP_S, GAP_S);
  Chrome := TRectangle.Create(Self);
  Chrome.Parent := MiddlePane;
  Chrome.Align := TAlignLayout.Contents;
  StyleChromeRect(Chrome, UI_PANEL_ALT, UI_BORDER, 6, False);
  Chrome.SendToBack;

  { Phase 4: the node editor packed a combo, an edit and three buttons onto
    one row; nothing was labelled. Fields on the grid, actions on a bar. }
  FWorkflowToolCombo := TComboBox.Create(Self);
  FWorkflowToolCombo.Items.Add('llm');
  FWorkflowToolCombo.Items.Add('replicate');
  FWorkflowToolCombo.ItemIndex := 0;
  FWorkflowToolCombo.OnChange := WorkflowToolChange;
  AddFormRow(SettingsPane, 'Tool', FWorkflowToolCombo, 168);

  FWorkflowNodeIdEdit := TEdit.Create(Self);
  FWorkflowNodeIdEdit.TextPrompt := 'node id';
  AddFormRow(SettingsPane, 'Node id', FWorkflowNodeIdEdit);

  Row := TLayout.Create(Self);
  Row.Parent := SettingsPane;
  Row.Align := TAlignLayout.Top;
  Row.Height := ROW_BAR;
  SetControlMargins(Row, FORM_LABEL_W + GAP_M, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Left;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Add';
  Btn.OnClick := WorkflowAddNodeClick;
  SetControlMargins(Btn, 0, 0, GAP_S, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Left;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Update';
  Btn.OnClick := WorkflowUpdateNodeClick;
  SetControlMargins(Btn, 0, 0, GAP_S, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := Row;
  Btn.Align := TAlignLayout.Left;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Delete';
  Btn.OnClick := WorkflowDeleteNodeClick;

  Row := TLayout.Create(Self);
  Row.Parent := SettingsPane;
  Row.Align := TAlignLayout.Top;
  { mode label + 2 llm rows + 3 replicate rows + action bar + prompt memo +
    the panel's own padding. Summed, not guessed: the schema group panel
    already taught this file what a guessed container height does. }
  Row.Height := ROW_TEXT + (ROW_FORM + GAP_XS) * 5 + ROW_BAR + GAP_XS +
                72 + GAP_S * 3;
  SetControlMargins(Row, 0, GAP_S, 0, 0);
  SetControlPadding(Row, GAP_S, GAP_S, GAP_S, GAP_S);
  Chrome := TRectangle.Create(Self);
  Chrome.Parent := Row;
  Chrome.Align := TAlignLayout.Contents;
  StyleChromeRect(Chrome, UI_PANEL, UI_BORDER, 6, False);
  Chrome.SendToBack;

  FWorkflowInspectorModeLabel := TLabel.Create(Self);
  FWorkflowInspectorModeLabel.Parent := Row;
  FWorkflowInspectorModeLabel.Align := TAlignLayout.Top;
  FWorkflowInspectorModeLabel.Height := ROW_TEXT;
  FWorkflowInspectorModeLabel.Text := 'LLM inspector';
  FWorkflowInspectorModeLabel.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(FWorkflowInspectorModeLabel, UI_ACCENT, TXT_TITLE, True);

  { provider + model each on a labelled row; Apply/Providers move to a bar
    at the bottom of the inspector rather than crowding the provider row }
  FWorkflowLlmProviderEdit := TEdit.Create(Self);
  FWorkflowLlmProviderEdit.TextPrompt := 'provider';
  AddFormRow(Row, 'Provider', FWorkflowLlmProviderEdit, 150);

  FWorkflowLlmModelEdit := TEdit.Create(Self);
  FWorkflowLlmModelEdit.TextPrompt := 'model';
  AddFormRow(Row, 'Model', FWorkflowLlmModelEdit);

  EdgeRow := TLayout.Create(Self);
  EdgeRow.Parent := Row;
  EdgeRow.Align := TAlignLayout.Bottom;
  EdgeRow.Height := ROW_BAR;
  SetControlMargins(EdgeRow, FORM_LABEL_W + GAP_M, GAP_XS, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := EdgeRow;
  Btn.Align := TAlignLayout.Left;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Apply Form';
  Btn.OnClick := WorkflowApplyInspectorClick;
  SetControlMargins(Btn, 0, 0, GAP_S, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := EdgeRow;
  Btn.Align := TAlignLayout.Left;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Providers';
  Btn.OnClick := WorkflowProviderModelClick;

  FWorkflowLlmPromptMemo := TMemo.Create(Self);
  FWorkflowLlmPromptMemo.Parent := Row;
  FWorkflowLlmPromptMemo.Align := TAlignLayout.Client;
  FWorkflowLlmPromptMemo.TextPrompt := 'LLM prompt, e.g. {{inputs.prompt}}';
  FWorkflowLlmPromptMemo.WordWrap := True;
  SetControlMargins(FWorkflowLlmPromptMemo, 0, GAP_S, 0, 0);

  { replicate fields: version and prompt on labelled rows; the model search
    keeps its edit + button pair on the search row }
  FWorkflowReplicateVersionEdit := TEdit.Create(Self);
  FWorkflowReplicateVersionEdit.TextPrompt := 'replicate version';
  AddFormRow(Row, 'Version', FWorkflowReplicateVersionEdit);

  FWorkflowReplicatePromptEdit := TEdit.Create(Self);
  FWorkflowReplicatePromptEdit.TextPrompt := 'replicate input.prompt';
  AddFormRow(Row, 'Prompt', FWorkflowReplicatePromptEdit);

  EdgeRow := AddFormRow(Row, 'Search', nil);

  Btn := TButton.Create(Self);
  Btn.Parent := EdgeRow;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Search';
  Btn.TagString := 'noicon';
  Btn.OnClick := WorkflowReplicateSearchClick;
  SetControlMargins(Btn, GAP_S, 1, 0, 1);

  FWorkflowReplicateSearchEdit := TEdit.Create(Self);
  FWorkflowReplicateSearchEdit.Parent := EdgeRow;
  FWorkflowReplicateSearchEdit.Align := TAlignLayout.Client;
  FWorkflowReplicateSearchEdit.Height := H_INPUT;
  FWorkflowReplicateSearchEdit.TextPrompt := 'model search';
  SetControlMargins(FWorkflowReplicateSearchEdit, 0, 1, 0, 1);

  FWorkflowReplicateResultsList := TListBox.Create(Self);
  FWorkflowReplicateResultsList.Parent := SettingsPane;
  FWorkflowReplicateResultsList.Align := TAlignLayout.Top;
  FWorkflowReplicateResultsList.Height := ROW_CARD;
  FWorkflowReplicateResultsList.OnChange := WorkflowReplicatePickClick;
  SetControlMargins(FWorkflowReplicateResultsList, 0, GAP_S, 0, 0);

  FWorkflowSchemaForm := TVertScrollBox.Create(Self);
  FWorkflowSchemaForm.Parent := SettingsPane;
  FWorkflowSchemaForm.Align := TAlignLayout.Top;
  FWorkflowSchemaForm.Height := 88;
  SetControlMargins(FWorkflowSchemaForm, 0, GAP_S, 0, 0);

  Title := TLabel.Create(Self);
  Title.Parent := SettingsPane;
  Title.Align := TAlignLayout.Top;
  Title.Height := ROW_TEXT;
  Title.Text := 'Node args JSON';
  Title.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(Title, UI_ACCENT, TXT_TITLE, True);
  SetControlMargins(Title, 0, GAP_S, 0, 0);

  FWorkflowNodeArgsMemo := TMemo.Create(Self);
  FWorkflowNodeArgsMemo.Parent := SettingsPane;
  FWorkflowNodeArgsMemo.Align := TAlignLayout.Top;
  FWorkflowNodeArgsMemo.Height := 72;
  FWorkflowNodeArgsMemo.WordWrap := False;
  FWorkflowNodeArgsMemo.Lines.Text := WorkflowDefaultArgs('llm');
  SetControlMargins(FWorkflowNodeArgsMemo, 0, GAP_XS, 0, 0);
  WorkflowLoadInspectorFromNode('llm', FWorkflowNodeArgsMemo.Lines.Text);

  RightPane := TLayout.Create(Self);
  RightPane.Parent := Body;
  RightPane.Align := TAlignLayout.Right;
  RightPane.Width := 280;
  FWorkflowRightPane := RightPane;
  SetControlMargins(RightPane, GAP_S, 0, 0, 0);
  SetControlPadding(RightPane, GAP_S, GAP_S, GAP_S, GAP_S);
  Chrome := TRectangle.Create(Self);
  Chrome.Parent := RightPane;
  Chrome.Align := TAlignLayout.Contents;
  StyleChromeRect(Chrome, UI_PANEL_ALT, UI_BORDER, 6, False);
  Chrome.SendToBack;

  AddPaneSplitter(Body, TAlignLayout.Right);

  EdgeRow := TLayout.Create(Self);
  EdgeRow.Parent := RightPane;
  EdgeRow.Align := TAlignLayout.Top;
  EdgeRow.Height := ROW_BAR;

  Btn := TButton.Create(Self);
  Btn.Parent := EdgeRow;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_M;
  Btn.Text := 'Delete';
  Btn.OnClick := WorkflowDeleteEdgeClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := EdgeRow;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Add';
  Btn.OnClick := WorkflowAddEdgeClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  FWorkflowEdgeToEdit := TEdit.Create(Self);
  FWorkflowEdgeToEdit.Parent := EdgeRow;
  FWorkflowEdgeToEdit.Align := TAlignLayout.Right;
  FWorkflowEdgeToEdit.Width := 92;
  FWorkflowEdgeToEdit.TextPrompt := 'to';
  SetControlMargins(FWorkflowEdgeToEdit, GAP_S, 0, 0, 0);

  FWorkflowEdgeFromEdit := TEdit.Create(Self);
  FWorkflowEdgeFromEdit.Parent := EdgeRow;
  FWorkflowEdgeFromEdit.Align := TAlignLayout.Client;
  FWorkflowEdgeFromEdit.TextPrompt := 'from node';

  FWorkflowEdgesList := TListBox.Create(Self);
  FWorkflowEdgesList.Parent := RightPane;
  FWorkflowEdgesList.Align := TAlignLayout.Top;
  FWorkflowEdgesList.Height := 72;
  FWorkflowEdgesList.OnChange := WorkflowEdgeSelect;
  SetControlMargins(FWorkflowEdgesList, 0, GAP_S, 0, 0);

  EdgeRow := TLayout.Create(Self);
  EdgeRow.Parent := RightPane;
  EdgeRow.Align := TAlignLayout.Top;
  EdgeRow.Height := ROW_FORM;
  SetControlMargins(EdgeRow, 0, GAP_S, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := EdgeRow;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_L;
  Btn.Text := 'Refresh Inputs';
  Btn.OnClick := WorkflowRunInputsClick;
  SetControlMargins(Btn, GAP_S, 0, 0, 0);

  Title := TLabel.Create(Self);
  Title.Parent := EdgeRow;
  Title.Align := TAlignLayout.Client;
  Title.Text := 'Run inputs';
  Title.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(Title, UI_ACCENT, TXT_TITLE, True);

  FWorkflowRunInputsMemo := TMemo.Create(Self);
  FWorkflowRunInputsMemo.Parent := RightPane;
  FWorkflowRunInputsMemo.Align := TAlignLayout.Top;
  FWorkflowRunInputsMemo.Height := 50;
  FWorkflowRunInputsMemo.WordWrap := False;
  FWorkflowRunInputsMemo.Lines.Text := '{"prompt": ""}';
  SetControlMargins(FWorkflowRunInputsMemo, 0, GAP_S, 0, 0);

  FWorkflowRunStatusLabel := TLabel.Create(Self);
  FWorkflowRunStatusLabel.Parent := RightPane;
  FWorkflowRunStatusLabel.Align := TAlignLayout.Top;
  FWorkflowRunStatusLabel.Height := ROW_TEXT;
  FWorkflowRunStatusLabel.Text := 'Run results';
  FWorkflowRunStatusLabel.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(FWorkflowRunStatusLabel, UI_ACCENT, TXT_TITLE, True);
  SetControlMargins(FWorkflowRunStatusLabel, 0, GAP_S, 0, 0);

  FWorkflowRunResultsList := TListBox.Create(Self);
  FWorkflowRunResultsList.Parent := RightPane;
  FWorkflowRunResultsList.Align := TAlignLayout.Top;
  FWorkflowRunResultsList.Height := 92;
  FWorkflowRunResultsList.OnChange := WorkflowRunResultSelect;
  AddCardListItem(FWorkflowRunResultsList, 'No run yet',
    'Run a saved workflow to inspect output and node status.', '', 56, False);

  EdgeRow := TLayout.Create(Self);
  EdgeRow.Parent := RightPane;
  EdgeRow.Align := TAlignLayout.Top;
  EdgeRow.Height := ROW_FORM;
  SetControlMargins(EdgeRow, 0, GAP_S, 0, 0);

  Btn := TButton.Create(Self);
  Btn.Parent := EdgeRow;
  Btn.Align := TAlignLayout.Right;
  Btn.Width := BTN_W_S;
  Btn.Text := 'Copy';
  Btn.OnClick := WorkflowRunResultCopyClick;

  Title := TLabel.Create(Self);
  Title.Parent := EdgeRow;
  Title.Align := TAlignLayout.Client;
  Title.Text := 'Selected result';
  Title.TextSettings.VertAlign := TTextAlign.Center;
  StyleLabel(Title, UI_ACCENT, TXT_TITLE, True);

  FWorkflowRunDetailMemo := TMemo.Create(Self);
  FWorkflowRunDetailMemo.Parent := RightPane;
  FWorkflowRunDetailMemo.Align := TAlignLayout.Client;
  FWorkflowRunDetailMemo.Height := 74;
  FWorkflowRunDetailMemo.ReadOnly := True;
  FWorkflowRunDetailMemo.WordWrap := True;
  FWorkflowRunDetailMemo.Lines.Text := 'Select a workflow run result to inspect full output.';
  SetControlMargins(FWorkflowRunDetailMemo, 0, GAP_XS, 0, 0);

  FWorkflowGraphMemo := TMemo.Create(Self);
  FWorkflowGraphMemo.Parent := RightPane;
  FWorkflowGraphMemo.Align := TAlignLayout.Bottom;
  FWorkflowGraphMemo.Height := ROW_CARD;
  FWorkflowGraphMemo.WordWrap := True;
  SetControlMargins(FWorkflowGraphMemo, 0, GAP_S, 0, 0);

  Title := TLabel.Create(Self);
  Title.Parent := MiddlePane;
  Title.Align := TAlignLayout.Top;
  Title.Height := ROW_TEXT;
  Title.Text := 'Graph canvas';
  Title.TextSettings.VertAlign := TTextAlign.Center;
  Title.StyledSettings := Title.StyledSettings - [TStyledSetting.FontColor];
  UseStyledLabelColor(Title);
  SetControlMargins(Title, 0, GAP_S, 0, 0);

  FWorkflowCanvas := TPaintBox.Create(Self);
  FWorkflowCanvas.Parent := MiddlePane;
  FWorkflowCanvas.Align := TAlignLayout.Client;
  FWorkflowCanvas.HitTest := True;
  FWorkflowCanvas.OnPaint := WorkflowCanvasPaint;
  FWorkflowCanvas.OnMouseDown := WorkflowCanvasMouseDown;
  FWorkflowCanvas.OnMouseMove := WorkflowCanvasMouseMove;
  FWorkflowCanvas.OnMouseUp := WorkflowCanvasMouseUp;
  SetControlMargins(FWorkflowCanvas, 0, GAP_S, 0, 0);

  WorkflowTabs.TabIndex := 0;
  WorkflowRenderGraph;
end;

procedure TMasterDetailForm.BuildSchemaForm(AParent: TFmxObject;
  const SchemaText, ArgsText: string; InsideInput: Boolean);
var
  ArgsRoot: TJSONValue;
  Check: TCheckBox;
  Combo: TComboBox;
  Control: TControl;
  Doomed: TFmxObject;
  Edit: TEdit;
  FieldType: string;
  FocusObj: TFmxObject;
  I: Integer;
  GroupPanel: TLayout;
  InitObj: TJSONObject;
  InitValue: TJSONValue;
  InputValue: TJSONValue;
  ItemObj: TJSONObject;
  ItemType: string;
  LabelControl: TLabel;
  Memo: TMemo;
  NestedHeight: Single;
  NestedInitObj: TJSONObject;
  NestedInitValue: TJSONValue;
  NestedPair: TJSONPair;
  NestedPropObj: TJSONObject;
  NestedProps: TJSONObject;
  NestedReq: TJSONArray;
  NestedRequired: Boolean;
  NestedRow: TLayout;
  NestedType: string;
  Pair: TJSONPair;
  PropObj: TJSONObject;
  Props: TJSONObject;
  Req: TJSONArray;
  Required: Boolean;
  Root: TJSONValue;
  Row: TLayout;
  SchemaObj: TJSONObject;
  Value: TJSONValue;
begin
  if AParent = nil then
    Exit;
  { This runs from click handlers (workflow New/node select), and freeing a
    control while an event involving it is still on the stack is the classic
    FMX access violation -- especially when focus sits in one of the schema
    edits being destroyed. Drop focus if it lives anywhere under this parent,
    unparent NOW so the rebuild sees a clean slate, and let Release defer the
    actual destruction to after the current event. }
  FocusObj := nil;
  if Focused <> nil then
    FocusObj := Focused.GetObject;
  while (FocusObj <> nil) and (FocusObj <> AParent) do
    FocusObj := FocusObj.Parent;
  if (FocusObj <> nil) and (FocusObj = AParent) then
    Focused := nil;
  while AParent.ChildrenCount > 0 do
  begin
    Doomed := AParent.Children[0];
    Doomed.Parent := nil;
    Doomed.Release;
  end;

  Root := TJSONObject.ParseJSONValue(SchemaText);
  ArgsRoot := TJSONObject.ParseJSONValue(ArgsText);
  try
    Props := nil;
    Req := nil;
    if Root is TJSONObject then
    begin
      SchemaObj := TJSONObject(Root);
      Value := SchemaObj.GetValue('inputSchema');
      if Value is TJSONObject then
        SchemaObj := TJSONObject(Value);
      Value := SchemaObj.GetValue('parameters');
      if Value is TJSONObject then
        SchemaObj := TJSONObject(Value);
      Value := SchemaObj.GetValue('schema');
      if Value is TJSONObject then
        SchemaObj := TJSONObject(Value);
      Value := SchemaObj.GetValue('required');
      if Value is TJSONArray then
        Req := TJSONArray(Value);
      Value := SchemaObj.GetValue('properties');
      if Value is TJSONObject then
        Props := TJSONObject(Value);
    end;

    InitObj := nil;
    if ArgsRoot is TJSONObject then
    begin
      InitObj := TJSONObject(ArgsRoot);
      if InsideInput then
      begin
        InputValue := InitObj.GetValue('input');
        if InputValue is TJSONObject then
          InitObj := TJSONObject(InputValue);
      end;
    end;

    if Props = nil then
    begin
      Row := TLayout.Create(Self);
      Row.Parent := AParent;
      Row.Align := TAlignLayout.Top;
      Row.Height := ROW_FORM;
      LabelControl := TLabel.Create(Self);
      LabelControl.Parent := Row;
      LabelControl.Align := TAlignLayout.Client;
      LabelControl.Text := 'No schema fields. Edit raw JSON below.';
      LabelControl.TextSettings.VertAlign := TTextAlign.Center;
      LabelControl.StyledSettings := LabelControl.StyledSettings -
        [TStyledSetting.FontColor];
      UseStyledLabelColor(LabelControl);
      Exit;
    end;

    for Pair in Props do
    begin
      if not (Pair.JsonValue is TJSONObject) then
        Continue;
      PropObj := TJSONObject(Pair.JsonValue);
      Required := False;
      if Req <> nil then
        for I := 0 to Req.Count - 1 do
          if SameText(Req.Items[I].Value, Pair.JsonString.Value) then
          begin
            Required := True;
            Break;
          end;
      FieldType := JsonAsString(PropObj, 'type');
      if FieldType = '' then
        FieldType := 'string';
      InitValue := nil;
      if InitObj <> nil then
        InitValue := InitObj.GetValue(Pair.JsonString.Value);
      if InitValue = nil then
        InitValue := PropObj.GetValue('default');

      Value := PropObj.GetValue('properties');
      if SameText(FieldType, 'object') and (Value is TJSONObject) then
      begin
        NestedProps := TJSONObject(Value);
        NestedReq := nil;
        Value := PropObj.GetValue('required');
        if Value is TJSONArray then
          NestedReq := TJSONArray(Value);
        NestedInitObj := nil;
        if InitValue is TJSONObject then
          NestedInitObj := TJSONObject(InitValue);
        GroupPanel := TLayout.Create(Self);
        GroupPanel.Parent := AParent;
        GroupPanel.Align := TAlignLayout.Top;
        { Height is assigned AFTER the rows exist, from what they actually
          consumed. It used to be predicted as 38 + n*38, which stopped
          matching the moment the rows moved onto the row rhythm: they now
          stride ROW_BAR + GAP_XS = 40, so the panel fell 2px short per
          property and its last control overflowed into the next form row.
          A container that guesses its children's size is the same defect
          the tool cards had; measuring cannot drift. }
        NestedHeight := 0;
        SetControlMargins(GroupPanel, 0, 0, 0, GAP_S);
        SetControlPadding(GroupPanel, GAP_S, GAP_S, GAP_S, GAP_S);
        AddPanelChrome(GroupPanel, True);

        LabelControl := TLabel.Create(Self);
        LabelControl.Parent := GroupPanel;
        LabelControl.Align := TAlignLayout.Top;
        LabelControl.Height := ROW_TEXT;
        LabelControl.Text := Pair.JsonString.Value;
        if Required then
          LabelControl.Text := LabelControl.Text + ' *';
        LabelControl.TextSettings.VertAlign := TTextAlign.Center;
        StyleLabel(LabelControl, UI_ACCENT, TXT_TITLE, True);

        for NestedPair in NestedProps do
        begin
          if not (NestedPair.JsonValue is TJSONObject) then
            Continue;
          NestedPropObj := TJSONObject(NestedPair.JsonValue);
          NestedRequired := False;
          if NestedReq <> nil then
            for I := 0 to NestedReq.Count - 1 do
              if SameText(NestedReq.Items[I].Value,
                NestedPair.JsonString.Value) then
              begin
                NestedRequired := True;
                Break;
              end;
          NestedType := JsonAsString(NestedPropObj, 'type');
          if NestedType = '' then
            NestedType := 'string';
          NestedInitValue := nil;
          if NestedInitObj <> nil then
            NestedInitValue := NestedInitObj.GetValue(NestedPair.JsonString.Value);
          if NestedInitValue = nil then
            NestedInitValue := NestedPropObj.GetValue('default');

          NestedRow := TLayout.Create(Self);
          NestedRow.Parent := GroupPanel;
          NestedRow.Align := TAlignLayout.Top;
          NestedRow.Height := ROW_BAR;
          SetControlMargins(NestedRow, 0, 0, 0, GAP_XS);
          NestedHeight := NestedHeight + ROW_BAR + GAP_XS;

          LabelControl := TLabel.Create(Self);
          LabelControl.Parent := NestedRow;
          LabelControl.Align := TAlignLayout.Left;
          { slightly narrower than FORM_LABEL_W: the group panel's own
            padding already indents the row, and the shared gutter is
            measured from the TAB edge, not the group's }
          LabelControl.Width := FORM_LABEL_W - GAP_S;
          LabelControl.TextSettings.HorzAlign := TTextAlign.Trailing;
          SetControlMargins(LabelControl, 0, 0, GAP_M, 0);
          LabelControl.Text := NestedPair.JsonString.Value;
          if NestedRequired then
            LabelControl.Text := LabelControl.Text + ' *';
          LabelControl.TextSettings.VertAlign := TTextAlign.Center;
          UseStyledLabelColor(LabelControl);

          Value := NestedPropObj.GetValue('enum');
          if Value is TJSONArray then
          begin
            Combo := TComboBox.Create(Self);
            Combo.Parent := NestedRow;
            Combo.Align := TAlignLayout.Client;
            Combo.TagString := Pair.JsonString.Value + '/' +
              NestedPair.JsonString.Value + #9 + NestedType + #9 +
              BoolToStr(NestedRequired, True);
            for I := 0 to TJSONArray(Value).Count - 1 do
              Combo.Items.Add(TJSONArray(Value).Items[I].Value);
            if NestedInitValue <> nil then
              Combo.ItemIndex := Combo.Items.IndexOf(NestedInitValue.Value);
            if (Combo.ItemIndex < 0) and (Combo.Items.Count > 0) then
              Combo.ItemIndex := 0;
            Control := Combo;
          end
          else if SameText(NestedType, 'boolean') then
          begin
            Check := TCheckBox.Create(Self);
            Check.Parent := NestedRow;
            Check.Align := TAlignLayout.Client;
            Check.Text := JsonAsString(NestedPropObj, 'description');
            Check.TagString := Pair.JsonString.Value + '/' +
              NestedPair.JsonString.Value + #9 + NestedType + #9 +
              BoolToStr(NestedRequired, True);
            if NestedInitValue <> nil then
              Check.IsChecked := SameText(NestedInitValue.Value, 'true');
            Control := Check;
          end
          else
          begin
            Edit := TEdit.Create(Self);
            Edit.Parent := NestedRow;
            Edit.Align := TAlignLayout.Client;
            Edit.TagString := Pair.JsonString.Value + '/' +
              NestedPair.JsonString.Value + #9 + NestedType + #9 +
              BoolToStr(NestedRequired, True);
            Edit.TextPrompt := JsonAsString(NestedPropObj, 'description');
            if NestedInitValue <> nil then
              if SameText(NestedType, 'object') or SameText(NestedType, 'array') then
                Edit.Text := NestedInitValue.ToJSON
              else
                Edit.Text := NestedInitValue.Value;
            Control := Edit;
          end;
          Control.HitTest := True;
        end;
        { header + the panel's own vertical padding + the rows }
        GroupPanel.Height := Max(ROW_LIST,
          ROW_TEXT + GAP_S * 2 + NestedHeight);
        Continue;
      end;

      ItemObj := nil;
      ItemType := '';
      if SameText(FieldType, 'array') then
      begin
        Value := PropObj.GetValue('items');
        if Value is TJSONObject then
        begin
          ItemObj := TJSONObject(Value);
          ItemType := JsonAsString(ItemObj, 'type');
          if ItemType = '' then
            ItemType := 'string';
        end;
      end;

      Row := TLayout.Create(Self);
      Row.Parent := AParent;
      Row.Align := TAlignLayout.Top;
      if SameText(FieldType, 'object') or SameText(FieldType, 'array') then
        Row.Height := 94
      else
        Row.Height := ROW_BAR;
      SetControlMargins(Row, 0, 0, 0, GAP_XS);

      { the SHARED form gutter: a generated schema row must be
        indistinguishable from a hand-built AddFormRow one }
      LabelControl := TLabel.Create(Self);
      LabelControl.Parent := Row;
      LabelControl.Align := TAlignLayout.Left;
      LabelControl.Width := FORM_LABEL_W;
      LabelControl.TextSettings.HorzAlign := TTextAlign.Trailing;
      SetControlMargins(LabelControl, 0, 0, GAP_M, 0);
      LabelControl.Text := Pair.JsonString.Value;
      if SameText(FieldType, 'array') and
        (SameText(ItemType, 'string') or SameText(ItemType, 'number') or
        SameText(ItemType, 'integer') or SameText(ItemType, 'boolean')) then
        LabelControl.Text := LabelControl.Text + ' list'
      else if SameText(FieldType, 'object') or SameText(FieldType, 'array') then
        LabelControl.Text := LabelControl.Text + ' JSON';
      if Required then
        LabelControl.Text := LabelControl.Text + ' *';
      LabelControl.TextSettings.VertAlign := TTextAlign.Center;
      LabelControl.StyledSettings := LabelControl.StyledSettings -
        [TStyledSetting.FontColor];
      UseStyledLabelColor(LabelControl);

      Value := PropObj.GetValue('enum');
      if Value is TJSONArray then
      begin
        Combo := TComboBox.Create(Self);
        Combo.Parent := Row;
        Combo.Align := TAlignLayout.Client;
        Combo.TagString := Pair.JsonString.Value + #9 + FieldType + #9 +
          BoolToStr(Required, True);
        for I := 0 to TJSONArray(Value).Count - 1 do
          Combo.Items.Add(TJSONArray(Value).Items[I].Value);
        if InitValue <> nil then
          Combo.ItemIndex := Combo.Items.IndexOf(InitValue.Value);
        if (Combo.ItemIndex < 0) and (Combo.Items.Count > 0) then
          Combo.ItemIndex := 0;
        Control := Combo;
      end
      else if SameText(FieldType, 'boolean') then
      begin
        Check := TCheckBox.Create(Self);
        Check.Parent := Row;
        Check.Align := TAlignLayout.Client;
        Check.Text := JsonAsString(PropObj, 'description');
        Check.TagString := Pair.JsonString.Value + #9 + FieldType + #9 +
          BoolToStr(Required, True);
        if InitValue <> nil then
          Check.IsChecked := SameText(InitValue.Value, 'true');
        Control := Check;
      end
      else if SameText(FieldType, 'object') or SameText(FieldType, 'array') then
      begin
        Memo := TMemo.Create(Self);
        Memo.Parent := Row;
        Memo.Align := TAlignLayout.Client;
        if SameText(FieldType, 'array') and
          (SameText(ItemType, 'string') or SameText(ItemType, 'number') or
          SameText(ItemType, 'integer') or SameText(ItemType, 'boolean')) then
          Memo.TagString := Pair.JsonString.Value + #9 + 'array:' + ItemType +
            #9 + BoolToStr(Required, True)
        else
          Memo.TagString := Pair.JsonString.Value + #9 + FieldType + #9 +
            BoolToStr(Required, True);
        Memo.WordWrap := False;
        if SameText(FieldType, 'array') and
          (SameText(ItemType, 'string') or SameText(ItemType, 'number') or
          SameText(ItemType, 'integer') or SameText(ItemType, 'boolean')) then
        begin
          Memo.TextPrompt := 'one ' + ItemType + ' value per line';
          if InitValue is TJSONArray then
            for I := 0 to TJSONArray(InitValue).Count - 1 do
              Memo.Lines.Add(TJSONArray(InitValue).Items[I].Value);
        end
        else if InitValue <> nil then
          Memo.Lines.Text := InitValue.ToJSON
        else if SameText(FieldType, 'object') then
          Memo.Lines.Text := '{}'
        else
          Memo.Lines.Text := '[]';
        StyleTextControl(Memo, UI_TEXT, TXT_TITLE);
        Control := Memo;
      end
      else
      begin
        Edit := TEdit.Create(Self);
        Edit.Parent := Row;
        Edit.Align := TAlignLayout.Client;
        Edit.TagString := Pair.JsonString.Value + #9 + FieldType + #9 +
          BoolToStr(Required, True);
        Edit.TextPrompt := JsonAsString(PropObj, 'description');
        if InitValue <> nil then
          Edit.Text := InitValue.Value;
        Control := Edit;
      end;
      Control.HitTest := True;
    end;
  finally
    Root.Free;
    ArgsRoot.Free;
  end;
end;

function TMasterDetailForm.CollectSchemaForm(AParent: TFmxObject;
  InsideInput: Boolean): TJSONObject;
var
  Root: TJSONObject;
  Target: TJSONObject;

  procedure AddCollectedValue(const FieldPath: string; JsonValue: TJSONValue);
  var
    Existing: TJSONValue;
    I: Integer;
    Obj: TJSONObject;
    Pair: TJSONPair;
    Parts: TArray<string>;
    Segment: string;
  begin
    if (FieldPath = '') or (JsonValue = nil) then
    begin
      JsonValue.Free;
      Exit;
    end;
    Parts := FieldPath.Split(['/']);
    Obj := Target;
    for I := 0 to Length(Parts) - 2 do
    begin
      Segment := Parts[I];
      Existing := Obj.GetValue(Segment);
      if not (Existing is TJSONObject) then
      begin
        Pair := Obj.RemovePair(Segment);
        Pair.Free;
        Existing := TJSONObject.Create;
        Obj.AddPair(Segment, Existing);
      end;
      Obj := TJSONObject(Existing);
    end;
    Segment := Parts[High(Parts)];
    Pair := Obj.RemovePair(Segment);
    Pair.Free;
    Obj.AddPair(Segment, JsonValue);
  end;

  procedure ProcessControl(Control: TControl);
  var
    Arr: TJSONArray;
    FieldName: string;
    FieldType: string;
    I: Integer;
    ItemType: string;
    LineText: string;
    PairParts: TArray<string>;
    Raw: string;
    RequiredField: Boolean;
    Value: TJSONValue;
  begin
    if (Control = nil) or (Control.TagString = '') then
      Exit;
    PairParts := Control.TagString.Split([#9]);
    if Length(PairParts) < 2 then
      Exit;
    FieldName := PairParts[0];
    FieldType := PairParts[1];
    RequiredField := (Length(PairParts) > 2) and
      SameText(PairParts[2], 'True');

    if Control is TCheckBox then
    begin
      AddCollectedValue(FieldName, NewJsonBool(TCheckBox(Control).IsChecked));
      Exit;
    end;
    if Control is TComboBox then
      Raw := ComboSelectedText(TComboBox(Control))
    else if Control is TEdit then
      Raw := Trim(TEdit(Control).Text)
    else if Control is TMemo then
      Raw := Trim(TMemo(Control).Lines.Text)
    else
      Raw := '';
    if Raw = '' then
    begin
      if RequiredField then
        SetStatus('required schema field is empty: ' + FieldName);
      Exit;
    end;

    if SameText(FieldType, 'integer') then
      AddCollectedValue(FieldName, TJSONNumber.Create(StrToIntDef(Raw, 0)))
    else if SameText(FieldType, 'number') then
      AddCollectedValue(FieldName, TJSONNumber.Create(StrToFloatDef(Raw, 0)))
    else if StartsText('array:', FieldType) then
    begin
      ItemType := Copy(FieldType, Length('array:') + 1, MaxInt);
      Arr := TJSONArray.Create;
      for I := 0 to TMemo(Control).Lines.Count - 1 do
      begin
        LineText := Trim(TMemo(Control).Lines[I]);
        if LineText = '' then
          Continue;
        if SameText(ItemType, 'integer') then
          Arr.AddElement(TJSONNumber.Create(StrToIntDef(LineText, 0)))
        else if SameText(ItemType, 'number') then
          Arr.AddElement(TJSONNumber.Create(StrToFloatDef(LineText, 0)))
        else if SameText(ItemType, 'boolean') then
          Arr.AddElement(NewJsonBool(SameText(LineText, 'true') or
            SameText(LineText, 'yes') or (LineText = '1')))
        else
          Arr.Add(LineText);
      end;
      AddCollectedValue(FieldName, Arr);
    end
    else if SameText(FieldType, 'object') or SameText(FieldType, 'array') then
    begin
      Value := TJSONObject.ParseJSONValue(Raw);
      if Value = nil then
      begin
        SetStatus('schema JSON is invalid: ' + FieldName);
        Exit;
      end;
      if SameText(FieldType, 'object') and not (Value is TJSONObject) then
      begin
        Value.Free;
        SetStatus('schema field expects an object: ' + FieldName);
        Exit;
      end;
      if SameText(FieldType, 'array') and not (Value is TJSONArray) then
      begin
        Value.Free;
        SetStatus('schema field expects an array: ' + FieldName);
        Exit;
      end;
      AddCollectedValue(FieldName, Value);
    end
    else
      AddCollectedValue(FieldName, TJSONString.Create(Raw));
  end;

  procedure WalkControls(Container: TFmxObject);
  var
    I: Integer;
    Obj: TFmxObject;
  begin
    if Container = nil then
      Exit;
    for I := 0 to Container.ChildrenCount - 1 do
    begin
      Obj := Container.Children[I];
      if Obj is TControl then
        ProcessControl(TControl(Obj));
      WalkControls(Obj);
    end;
  end;

begin
  Root := TJSONObject.Create;
  if InsideInput then
  begin
    Target := TJSONObject.Create;
    Root.AddPair('input', Target);
  end
  else
    Target := Root;

  WalkControls(AParent);
  Result := Root;
end;

function TMasterDetailForm.ConfigFindValue(Root: TJSONValue; const Path: string;
  out Parent: TJSONValue; out Segment: string): TJSONValue;
var
  I: Integer;
  Index: Integer;
  Part: string;
  Parts: TArray<string>;
begin
  Parent := nil;
  Segment := '';
  Result := Root;
  if Root = nil then
    Exit;
  if Trim(Path) = '' then
    Exit;

  Parts := Path.Split(['/']);
  for I := 0 to Length(Parts) - 1 do
  begin
    Part := Parts[I];
    if Part = '' then
      Continue;
    Parent := Result;
    Segment := Part;
    if Parent is TJSONObject then
      Result := TJSONObject(Parent).GetValue(Part)
    else if Parent is TJSONArray then
    begin
      Index := StrToIntDef(Part, -1);
      if (Index < 0) or (Index >= TJSONArray(Parent).Count) then
        Exit(nil);
      Result := TJSONArray(Parent).Items[Index];
    end
    else
      Exit(nil);
    if Result = nil then
      Exit;
  end;
end;

procedure TMasterDetailForm.ConfigRenderEditor;
var
  BodyMemo: TMemo;
  Root: TJSONValue;

  procedure AddNode(const Path, Caption: string; Value: TJSONValue;
    Depth: Integer);
  var
    Arr: TJSONArray;
    ChildPath: string;
    I: Integer;
    Item: TListBoxItem;
    Obj: TJSONObject;
    Pair: TJSONPair;
    Prefix: string;
  begin
    if Value = nil then
      Exit;
    Item := TListBoxItem.Create(FConfigList);
    Item.Parent := FConfigList;
    Prefix := StringOfChar(' ', Depth * 2);
    Item.Text := Prefix + Caption + '  [' + JsonEditorKind(Value) + ']';
    if JsonEditorPreview(Value) <> '' then
      Item.Text := Item.Text + '  ' + JsonEditorPreview(Value);
    Item.TagString := Path + #9 + JsonEditorKind(Value);
    Item.Height := ROW_FORM;

    if Value is TJSONObject then
    begin
      Obj := TJSONObject(Value);
      for Pair in Obj do
      begin
        if Path = '' then
          ChildPath := Pair.JsonString.Value
        else
          ChildPath := Path + '/' + Pair.JsonString.Value;
        AddNode(ChildPath, Pair.JsonString.Value, Pair.JsonValue, Depth + 1);
      end;
    end
    else if Value is TJSONArray then
    begin
      Arr := TJSONArray(Value);
      for I := 0 to Arr.Count - 1 do
      begin
        if Path = '' then
          ChildPath := I.ToString
        else
          ChildPath := Path + '/' + I.ToString;
        AddNode(ChildPath, '[' + I.ToString + ']', Arr.Items[I], Depth + 1);
      end;
    end;
  end;

begin
  if FConfigList <> nil then
    FConfigList.Clear;
  if FConfigPathEdit <> nil then
    FConfigPathEdit.Text := '';
  if FConfigValueMemo <> nil then
    FConfigValueMemo.Lines.Clear;

  if not FEndpointBodyMemos.TryGetValue('settings', BodyMemo) then
    Exit;
  if Trim(BodyMemo.Lines.Text) = '' then
  begin
    SetStatus('load /v1/config before using the config editor');
    Exit;
  end;

  Root := TJSONObject.ParseJSONValue(BodyMemo.Lines.Text);
  try
    if Root = nil then
    begin
      SetStatus('config editor: raw JSON is invalid');
      Exit;
    end;
    AddNode('', '(root)', Root, 0);
    if (FConfigList <> nil) and (FConfigList.Count > 0) then
      FConfigList.ItemIndex := 0;
    SetStatus('config editor refreshed');
  finally
    Root.Free;
  end;
end;

procedure TMasterDetailForm.ConfigQuickSectionClick(Sender: TObject);
var
  I: Integer;
  ItemPath: string;
  Parts: TArray<string>;
  Path: string;
begin
  if not (Sender is TButton) then
    Exit;
  Path := TButton(Sender).TagString;
  if FConfigList = nil then
    Exit;

  if FConfigList.Count = 0 then
  begin
    ConfigRefreshClick(nil);
    SetStatus('loading config before selecting ' + Path);
    Exit;
  end;

  for I := 0 to FConfigList.Count - 1 do
  begin
    Parts := FConfigList.ListItems[I].TagString.Split([#9]);
    ItemPath := '';
    if Length(Parts) > 0 then
      ItemPath := Parts[0];
    if SameText(ItemPath, Path) then
    begin
      FConfigList.ItemIndex := I;
      ConfigListChange(FConfigList);
      SetStatus('config section: ' + Path);
      Exit;
    end;
  end;

  SetStatus('config section not found: ' + Path);
end;

procedure TMasterDetailForm.ConfigRefreshClick(Sender: TObject);
var
  BodyMemo: TMemo;
begin
  if FEndpointBodyMemos.TryGetValue('settings', BodyMemo) and
    (Trim(BodyMemo.Lines.Text) <> '') then
    ConfigRenderEditor
  else
    FetchEndpoint('settings', 'GET', '/v1/config', '');
end;

procedure TMasterDetailForm.ConfigListChange(Sender: TObject);
var
  BodyMemo: TMemo;
  Kind: string;
  Parent: TJSONValue;
  Parts: TArray<string>;
  Path: string;
  Root: TJSONValue;
  Segment: string;
  Value: TJSONValue;
begin
  if (FConfigList = nil) or (FConfigList.Selected = nil) then
    Exit;
  Parts := FConfigList.Selected.TagString.Split([#9]);
  Path := '';
  Kind := '';
  if Length(Parts) > 0 then
    Path := Parts[0];
  if Length(Parts) > 1 then
    Kind := Parts[1];
  if FConfigPathEdit <> nil then
    FConfigPathEdit.Text := Path;
  if not FEndpointBodyMemos.TryGetValue('settings', BodyMemo) then
    Exit;
  Root := TJSONObject.ParseJSONValue(BodyMemo.Lines.Text);
  try
    Value := ConfigFindValue(Root, Path, Parent, Segment);
    if (Value <> nil) and (FConfigValueMemo <> nil) then
    begin
      if SameText(Kind, 'string') then
        FConfigValueMemo.Lines.Text := Value.Value
      else
        FConfigValueMemo.Lines.Text := Value.ToJSON;
    end;
  finally
    Root.Free;
  end;
end;

procedure TMasterDetailForm.ConfigApplyValueClick(Sender: TObject);
var
  Arr: TJSONArray;
  BodyMemo: TMemo;
  I: Integer;
  Index: Integer;
  ItemValue: TJSONValue;
  Kind: string;
  NewItems: TList<TJSONValue>;
  NewValue: TJSONValue;
  Pair: TJSONPair;
  Parent: TJSONValue;
  Parts: TArray<string>;
  Path: string;
  Root: TJSONValue;
  Segment: string;
  Value: TJSONValue;
begin
  if (FConfigList = nil) or (FConfigList.Selected = nil) or
    (FConfigValueMemo = nil) then
    Exit;
  if not FEndpointBodyMemos.TryGetValue('settings', BodyMemo) then
    Exit;
  Parts := FConfigList.Selected.TagString.Split([#9]);
  Path := '';
  Kind := 'string';
  if Length(Parts) > 0 then
    Path := Parts[0];
  if Length(Parts) > 1 then
    Kind := Parts[1];

  Root := TJSONObject.ParseJSONValue(BodyMemo.Lines.Text);
  NewValue := nil;
  try
    if Root = nil then
    begin
      SetStatus('config apply blocked: raw JSON is invalid');
      Exit;
    end;
    NewValue := JsonValueFromEditorText(FConfigValueMemo.Lines.Text, Kind);
    if Path = '' then
    begin
      BodyMemo.Lines.Text := NewValue.ToJSON;
      FreeAndNil(NewValue);
    end
    else
    begin
      Value := ConfigFindValue(Root, Path, Parent, Segment);
      if Value = nil then
      begin
        SetStatus('config apply blocked: path not found');
        Exit;
      end;
      if Parent is TJSONObject then
      begin
        Pair := TJSONObject(Parent).RemovePair(Segment);
        Pair.Free;
        TJSONObject(Parent).AddPair(Segment, NewValue);
        NewValue := nil;
        BodyMemo.Lines.Text := Root.ToJSON;
      end
      else if Parent is TJSONArray then
      begin
        Arr := TJSONArray(Parent);
        Index := StrToIntDef(Segment, -1);
        if (Index < 0) or (Index >= Arr.Count) then
        begin
          SetStatus('config apply blocked: array index not found');
          Exit;
        end;
        NewItems := TList<TJSONValue>.Create;
        try
          for I := 0 to Arr.Count - 1 do
            if I = Index then
            begin
              NewItems.Add(NewValue);
              NewValue := nil;
            end
            else
            begin
              ItemValue := CloneJsonValue(Arr.Items[I]);
              if ItemValue <> nil then
                NewItems.Add(ItemValue);
            end;
          while Arr.Count > 0 do
            Arr.Remove(0).Free;
          for I := 0 to NewItems.Count - 1 do
            Arr.AddElement(NewItems[I]);
          NewItems.Clear;
          BodyMemo.Lines.Text := Root.ToJSON;
        finally
          for I := 0 to NewItems.Count - 1 do
            NewItems[I].Free;
          NewItems.Free;
        end;
      end
      else
      begin
        SetStatus('config apply blocked: parent is not editable');
        Exit;
      end;
    end;
    ConfigRenderEditor;
    SetStatus('config value applied; use Save to update gateway');
  finally
    NewValue.Free;
    Root.Free;
  end;
end;

procedure TMasterDetailForm.ConfigAddArrayItemClick(Sender: TObject);
var
  Arr: TJSONArray;
  BodyMemo: TMemo;
  Parent: TJSONValue;
  Parts: TArray<string>;
  Path: string;
  Root: TJSONValue;
  Segment: string;
  Value: TJSONValue;
begin
  if (FConfigList = nil) or (FConfigList.Selected = nil) then
    Exit;
  if not FEndpointBodyMemos.TryGetValue('settings', BodyMemo) then
    Exit;
  Parts := FConfigList.Selected.TagString.Split([#9]);
  Path := '';
  if Length(Parts) > 0 then
    Path := Parts[0];

  Root := TJSONObject.ParseJSONValue(BodyMemo.Lines.Text);
  try
    if Root = nil then
    begin
      SetStatus('config add blocked: raw JSON is invalid');
      Exit;
    end;
    Value := ConfigFindValue(Root, Path, Parent, Segment);
    Arr := nil;
    if Value is TJSONArray then
      Arr := TJSONArray(Value)
    else if Parent is TJSONArray then
      Arr := TJSONArray(Parent);
    if Arr = nil then
    begin
      SetStatus('select an array or array item first');
      Exit;
    end;
    Arr.AddElement(TJSONObject.Create);
    BodyMemo.Lines.Text := Root.ToJSON;
    ConfigRenderEditor;
    SetStatus('array item added; use Save to update gateway');
  finally
    Root.Free;
  end;
end;

procedure TMasterDetailForm.ConfigDeleteValueClick(Sender: TObject);
var
  BodyMemo: TMemo;
  Index: Integer;
  Pair: TJSONPair;
  Parent: TJSONValue;
  Parts: TArray<string>;
  Path: string;
  Removed: TJSONValue;
  Root: TJSONValue;
  Segment: string;
  Value: TJSONValue;
begin
  if (FConfigList = nil) or (FConfigList.Selected = nil) then
    Exit;
  if not FEndpointBodyMemos.TryGetValue('settings', BodyMemo) then
    Exit;
  Parts := FConfigList.Selected.TagString.Split([#9]);
  Path := '';
  if Length(Parts) > 0 then
    Path := Parts[0];
  if Path = '' then
  begin
    SetStatus('config delete blocked: cannot delete root');
    Exit;
  end;

  Root := TJSONObject.ParseJSONValue(BodyMemo.Lines.Text);
  try
    if Root = nil then
    begin
      SetStatus('config delete blocked: raw JSON is invalid');
      Exit;
    end;
    Value := ConfigFindValue(Root, Path, Parent, Segment);
    if Value = nil then
    begin
      SetStatus('config delete blocked: path not found');
      Exit;
    end;
    if Parent is TJSONObject then
    begin
      Pair := TJSONObject(Parent).RemovePair(Segment);
      Pair.Free;
    end
    else if Parent is TJSONArray then
    begin
      Index := StrToIntDef(Segment, -1);
      if (Index < 0) or (Index >= TJSONArray(Parent).Count) then
      begin
        SetStatus('config delete blocked: array index not found');
        Exit;
      end;
      Removed := TJSONArray(Parent).Remove(Index);
      Removed.Free;
    end
    else
    begin
      SetStatus('config delete blocked: parent is not editable');
      Exit;
    end;
    BodyMemo.Lines.Text := Root.ToJSON;
    ConfigRenderEditor;
    SetStatus('config value deleted; use Save to update gateway');
  finally
    Root.Free;
  end;
end;

procedure TMasterDetailForm.ProviderCatalogClick(Sender: TObject);
var
  Base: string;
  Token: string;
  SessionId: string;
begin
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('loading providers...');
  if FProviderCombo <> nil then
  begin
    FProviderCombo.Items.Clear;
    FProviderCombo.Items.Add('loading');
    FProviderCombo.ItemIndex := 0;
  end;
  if FProviderSecondaryCombo <> nil then
  begin
    FProviderSecondaryCombo.Items.Clear;
    FProviderSecondaryCombo.Items.Add('(none)');
    FProviderSecondaryCombo.ItemIndex := 0;
  end;

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET',
          '/v1/providers/catalog', '', '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('providers HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Arr: TJSONArray;
          I: Integer;
          Item: TJSONValue;
          Kind: string;
          Obj: TJSONObject;
          PreferredIndex: Integer;
          Root: TJSONValue;
          Value: TJSONValue;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('provider catalog failed: ' + ErrorText);
            if FProviderCombo <> nil then
              FProviderCombo.Items.Clear;
            Exit;
          end;

          FProviderCatalogJson := ResponseText;
          if FPaneMemos.ContainsKey('settings') then
            FPaneMemos['settings'].Lines.Text := 'GET /v1/providers/catalog' +
              sLineBreak + sLineBreak + FormatProviderText(ResponseText);

          if FProviderCombo = nil then
            Exit;
          FProviderCombo.Items.BeginUpdate;
          if FProviderSecondaryCombo <> nil then
            FProviderSecondaryCombo.Items.BeginUpdate;
          try
            FProviderCombo.Items.Clear;
            if FProviderSecondaryCombo <> nil then
            begin
              FProviderSecondaryCombo.Items.Clear;
              FProviderSecondaryCombo.Items.Add('(none)');
            end;
            PreferredIndex := -1;
            Root := TJSONObject.ParseJSONValue(ResponseText);
            try
              if Root is TJSONObject then
              begin
                Value := TJSONObject(Root).GetValue('data');
                if Value is TJSONArray then
                begin
                  Arr := TJSONArray(Value);
                  for I := 0 to Arr.Count - 1 do
                  begin
                    Item := Arr.Items[I];
                    if not (Item is TJSONObject) then
                      Continue;
                    Obj := TJSONObject(Item);
                    if JsonAsBool(Obj, 'placeholder') then
                      Continue;
                    Kind := JsonAsString(Obj, 'kind');
                    if Kind = '' then
                      Continue;
                    FProviderCombo.Items.Add(Kind);
                    if FProviderSecondaryCombo <> nil then
                      FProviderSecondaryCombo.Items.Add(Kind);
                    if SameText(Kind, 'anthropic') then
                      PreferredIndex := FProviderCombo.Items.Count - 1;
                  end;
                end;
              end;
            finally
              Root.Free;
            end;
            if FProviderCombo.Items.Count > 0 then
            begin
              if PreferredIndex < 0 then
                PreferredIndex := 0;
              FProviderCombo.ItemIndex := PreferredIndex;
            end;
            if (FProviderSecondaryCombo <> nil) and
              (FProviderSecondaryCombo.Items.Count > 0) then
              FProviderSecondaryCombo.ItemIndex := 0;
          finally
            FProviderCombo.Items.EndUpdate;
            if FProviderSecondaryCombo <> nil then
              FProviderSecondaryCombo.Items.EndUpdate;
          end;
          ProviderComboChange(nil);
          ProviderSecondaryComboChange(nil);
          SetStatus('provider catalog loaded');
        end);
    end);
end;

procedure TMasterDetailForm.ProviderComboChange(Sender: TObject);
var
  Arr: TJSONArray;
  I: Integer;
  Kind: string;
  NeedsModel: Boolean;
  Obj: TJSONObject;
  Root: TJSONValue;
  Value: TJSONValue;
begin
  Kind := ComboSelectedText(FProviderCombo);
  if (Kind = '') or SameText(Kind, 'loading') or
    (FProviderCatalogJson = '') then
    Exit;

  Root := TJSONObject.ParseJSONValue(FProviderCatalogJson);
  try
    if not (Root is TJSONObject) then
      Exit;
    Value := TJSONObject(Root).GetValue('data');
    if not (Value is TJSONArray) then
      Exit;
    Arr := TJSONArray(Value);
    for I := 0 to Arr.Count - 1 do
      if Arr.Items[I] is TJSONObject then
      begin
        Obj := TJSONObject(Arr.Items[I]);
        if not SameText(JsonAsString(Obj, 'kind'), Kind) then
          Continue;
        if FProviderBaseEdit <> nil then
        begin
          FProviderBaseEdit.Text := JsonAsString(Obj, 'default_base');
          FProviderBaseEdit.Enabled := JsonAsBool(Obj, 'needs_base') or
            (FProviderBaseEdit.Text <> '');
        end;
        if FProviderModelEdit <> nil then
        begin
          FProviderModelEdit.Text := JsonAsString(Obj, 'default_model');
          Value := Obj.GetValue('needs_model');
          NeedsModel := not ((Value <> nil) and SameText(Value.Value, 'false'));
          FProviderModelEdit.Enabled := NeedsModel;
        end;
        if FProviderKeyEdit <> nil then
        begin
          FProviderKeyEdit.Text := '';
          FProviderKeyEdit.Enabled := JsonAsBool(Obj, 'needs_key');
        end;
        if FProviderNotesLabel <> nil then
          FProviderNotesLabel.Text := JsonAsString(Obj, 'display_name') +
            ' - ' + JsonAsString(Obj, 'notes');
        Break;
      end;
  finally
    Root.Free;
  end;
  ProviderSecondaryComboChange(nil);
end;

procedure TMasterDetailForm.ProviderSecondaryComboChange(Sender: TObject);
var
  Arr: TJSONArray;
  I: Integer;
  Kind: string;
  NeedsModel: Boolean;
  Obj: TJSONObject;
  Root: TJSONValue;
  SameAsPrimary: Boolean;
  Value: TJSONValue;
begin
  Kind := ComboSelectedText(FProviderSecondaryCombo);
  if SameText(Kind, '(none)') then
    Kind := '';

  SameAsPrimary := (Kind <> '') and SameText(Kind, ComboSelectedText(FProviderCombo));
  if FProviderSecondaryBaseEdit <> nil then
  begin
    FProviderSecondaryBaseEdit.Text := '';
    FProviderSecondaryBaseEdit.Enabled := False;
  end;
  if FProviderSecondaryKeyEdit <> nil then
  begin
    FProviderSecondaryKeyEdit.Text := '';
    FProviderSecondaryKeyEdit.Enabled := False;
  end;
  if FProviderSecondaryModelEdit <> nil then
  begin
    FProviderSecondaryModelEdit.Enabled := Kind <> '';
    if Kind = '' then
      FProviderSecondaryModelEdit.Text := '';
  end;
  if FProviderRouteCheck <> nil then
    FProviderRouteCheck.Enabled := Kind <> '';
  if FProviderFallbackCheck <> nil then
    FProviderFallbackCheck.Enabled := Kind <> '';
  if (Kind = '') or (FProviderCatalogJson = '') then
    Exit;

  Root := TJSONObject.ParseJSONValue(FProviderCatalogJson);
  try
    if not (Root is TJSONObject) then
      Exit;
    Value := TJSONObject(Root).GetValue('data');
    if not (Value is TJSONArray) then
      Exit;
    Arr := TJSONArray(Value);
    for I := 0 to Arr.Count - 1 do
      if Arr.Items[I] is TJSONObject then
      begin
        Obj := TJSONObject(Arr.Items[I]);
        if not SameText(JsonAsString(Obj, 'kind'), Kind) then
          Continue;
        if FProviderSecondaryBaseEdit <> nil then
        begin
          FProviderSecondaryBaseEdit.Text := JsonAsString(Obj, 'default_base');
          FProviderSecondaryBaseEdit.Enabled := (not SameAsPrimary) and
            (JsonAsBool(Obj, 'needs_base') or
            (FProviderSecondaryBaseEdit.Text <> ''));
        end;
        if FProviderSecondaryKeyEdit <> nil then
          FProviderSecondaryKeyEdit.Enabled := (not SameAsPrimary) and
            JsonAsBool(Obj, 'needs_key');
        if FProviderSecondaryModelEdit <> nil then
        begin
          Value := Obj.GetValue('needs_model');
          NeedsModel := not ((Value <> nil) and SameText(Value.Value, 'false'));
          FProviderSecondaryModelEdit.Enabled := NeedsModel;
          if not SameAsPrimary then
            FProviderSecondaryModelEdit.Text := JsonAsString(Obj, 'default_model');
        end;
        if FProviderNotesLabel <> nil then
          FProviderNotesLabel.Text :=
            'Secondary provider can power auto_router.easy_* and fallback_models. ' +
            'Use the same provider with a smaller model, or a different provider with its own credentials.';
        Break;
      end;
  finally
    Root.Free;
  end;
end;

procedure TMasterDetailForm.ProviderSaveClick(Sender: TObject);
var
  Base: string;
  EndpointBase: string;
  Kind: string;
  KeyText: string;
  Model: string;
  SecondaryBase: string;
  SecondaryKey: string;
  SecondaryKind: string;
  SecondaryModel: string;
  Token: string;
  UseFallback: Boolean;
  UseRoute: Boolean;
  SessionId: string;
begin
  Kind := ComboSelectedText(FProviderCombo);
  if (Kind = '') or SameText(Kind, 'loading') then
  begin
    SetStatus('select a provider first');
    Exit;
  end;

  EndpointBase := Trim(FProviderBaseEdit.Text);
  KeyText := Trim(FProviderKeyEdit.Text);
  Model := Trim(FProviderModelEdit.Text);
  SecondaryKind := ComboSelectedText(FProviderSecondaryCombo);
  if SameText(SecondaryKind, '(none)') then
    SecondaryKind := '';
  SecondaryBase := Trim(FProviderSecondaryBaseEdit.Text);
  SecondaryKey := Trim(FProviderSecondaryKeyEdit.Text);
  SecondaryModel := Trim(FProviderSecondaryModelEdit.Text);
  UseRoute := (FProviderRouteCheck <> nil) and FProviderRouteCheck.IsChecked and
    (SecondaryKind <> '') and (SecondaryModel <> '');
  UseFallback := (FProviderFallbackCheck <> nil) and
    FProviderFallbackCheck.IsChecked and (SecondaryKind <> '');
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('saving provider...');

  TTask.Run(
    procedure
    var
      BodyText: string;
      Clone: TJSONValue;
      Config: TJSONObject;
      ConfigText: string;
      ErrorText: string;
      ExistingKey: string;
      ExistingSecondaryKey: string;
      FallbackModelsList: TList<string>;
      FallbacksList: TList<string>;
      I: Integer;
      Index: Integer;
      Item: TJSONValue;
      ItemKind: string;
      ItemName: string;
      Obj: TJSONObject;
      Router: TJSONObject;
      SameSecondary: Boolean;
      SavedSecondaryKey: string;
      NewFallbackModels: TJSONArray;
      NewFallbacks: TJSONArray;
      Providers: TJSONArray;
      ResponseText: string;
      Root: TJSONValue;
      SavedKey: string;
      Status: Integer;
      Value: TJSONValue;
    begin
      Root := nil;
      Providers := nil;
      NewFallbacks := nil;
      NewFallbackModels := nil;
      FallbacksList := nil;
      FallbackModelsList := nil;
      try
        ConfigText := HttpText(Base, Token, SessionId, 'GET', '/v1/config', '',
          '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('config HTTP %d: %s', [Status, ConfigText]);

        Root := TJSONObject.ParseJSONValue(ConfigText);
        if Root is TJSONObject then
          Config := TJSONObject(Root)
        else
        begin
          Root.Free;
          Config := TJSONObject.Create;
          Root := Config;
        end;

        ExistingKey := '';
        ExistingSecondaryKey := '';
        SameSecondary := (SecondaryKind <> '') and SameText(SecondaryKind, Kind);
        Providers := TJSONArray.Create;
        Value := Config.GetValue('providers');
        if Value is TJSONArray then
          for I := 0 to TJSONArray(Value).Count - 1 do
          begin
            Item := TJSONArray(Value).Items[I];
            if Item is TJSONObject then
            begin
              Obj := TJSONObject(Item);
              ItemName := JsonAsString(Obj, 'name');
              ItemKind := JsonAsString(Obj, 'kind');
              if SameText(ItemName, Kind) or SameText(ItemKind, Kind) then
              begin
                ExistingKey := JsonAsString(Obj, 'api_key');
                Continue;
              end;
              if (SecondaryKind <> '') and not SameSecondary and
                (SameText(ItemName, SecondaryKind) or
                SameText(ItemKind, SecondaryKind)) then
              begin
                ExistingSecondaryKey := JsonAsString(Obj, 'api_key');
                Continue;
              end;
            end;
            Clone := CloneJsonValue(Item);
            if Clone <> nil then
              Providers.AddElement(Clone);
          end;

        SavedKey := KeyText;
        if (SavedKey = '') and (ExistingKey <> '') then
          SavedKey := ExistingKey;

        Obj := TJSONObject.Create;
        Obj.AddPair('name', Kind);
        Obj.AddPair('kind', Kind);
        Obj.AddPair('api_base', EndpointBase);
        Obj.AddPair('api_key', SavedKey);
        Obj.AddPair('model', Model);
        Providers.AddElement(Obj);

        if (SecondaryKind <> '') and not SameSecondary then
        begin
          SavedSecondaryKey := SecondaryKey;
          if (SavedSecondaryKey = '') and (ExistingSecondaryKey <> '') then
            SavedSecondaryKey := ExistingSecondaryKey;
          Obj := TJSONObject.Create;
          Obj.AddPair('name', SecondaryKind);
          Obj.AddPair('kind', SecondaryKind);
          Obj.AddPair('api_base', SecondaryBase);
          Obj.AddPair('api_key', SavedSecondaryKey);
          Obj.AddPair('model', SecondaryModel);
          Providers.AddElement(Obj);
        end;

        ReplaceJsonValue(Config, 'providers', Providers);
        Providers := nil;
        ReplaceJsonString(Config, 'default_provider', Kind);
        ReplaceJsonString(Config, 'default_model', Model);

        if UseRoute then
        begin
          Value := Config.GetValue('auto_router');
          if Value is TJSONObject then
            Router := TJSONObject(CloneJsonValue(Value))
          else
            Router := TJSONObject.Create;
          try
            ReplaceJsonBool(Router, 'enabled', True);
            ReplaceJsonString(Router, 'easy_provider', SecondaryKind);
            ReplaceJsonString(Router, 'easy_model', SecondaryModel);
            ReplaceJsonValue(Config, 'auto_router', Router);
            Router := nil;
          finally
            Router.Free;
          end;
        end;

        if UseFallback then
        begin
          FallbacksList := TList<string>.Create;
          FallbackModelsList := TList<string>.Create;
          Value := Config.GetValue('fallbacks');
          if Value is TJSONArray then
            for I := 0 to TJSONArray(Value).Count - 1 do
              FallbacksList.Add(TJSONArray(Value).Items[I].Value);
          Value := Config.GetValue('fallback_models');
          if Value is TJSONArray then
            for I := 0 to TJSONArray(Value).Count - 1 do
              FallbackModelsList.Add(TJSONArray(Value).Items[I].Value);
          while FallbackModelsList.Count < FallbacksList.Count do
            FallbackModelsList.Add('');

          Index := FallbacksList.IndexOf(SecondaryKind);
          if Index < 0 then
          begin
            FallbacksList.Add(SecondaryKind);
            FallbackModelsList.Add(SecondaryModel);
          end
          else if SecondaryModel <> '' then
            FallbackModelsList[Index] := SecondaryModel;

          NewFallbacks := TJSONArray.Create;
          for I := 0 to FallbacksList.Count - 1 do
            NewFallbacks.AddElement(TJSONString.Create(FallbacksList[I]));
          NewFallbackModels := TJSONArray.Create;
          for I := 0 to FallbackModelsList.Count - 1 do
            NewFallbackModels.AddElement(TJSONString.Create(FallbackModelsList[I]));
          ReplaceJsonValue(Config, 'fallbacks', NewFallbacks);
          NewFallbacks := nil;
          ReplaceJsonValue(Config, 'fallback_models', NewFallbackModels);
          NewFallbackModels := nil;
        end;

        BodyText := Config.ToJSON;
        ResponseText := HttpText(Base, Token, SessionId, 'PUT', '/v1/config',
          BodyText, 'application/json', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('save HTTP %d: %s', [Status, ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      FallbackModelsList.Free;
      FallbacksList.Free;
      NewFallbackModels.Free;
      NewFallbacks.Free;
      Providers.Free;
      Root.Free;

      TThread.Queue(nil,
        procedure
        var
          BodyMemo: TMemo;
          Memo: TMemo;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('provider save failed: ' + ErrorText);
            Exit;
          end;
          if FEndpointBodyMemos.TryGetValue('settings', BodyMemo) then
            BodyMemo.Lines.Text := BodyText;
          if FPaneMemos.TryGetValue('settings', Memo) then
            Memo.Lines.Text := 'PUT /v1/config' + sLineBreak + 'HTTP ' +
              Status.ToString + sLineBreak + sLineBreak + ResponseText;
          SetStatus('provider saved');
          { the web wizard advances to its memory step once the provider is
            saved; mirror that instead of leaving onboarding dangling }
          LoadModels;
          { the web wizard advances to its memory step once the provider is
            saved; mirror that instead of leaving onboarding dangling }
          if not FOnboardingDismissed then
          begin
            FOnboardingStep := 1;
            ShowOnboarding;
          end;
        end);
    end);
end;

function TMasterDetailForm.FormatConfigText(const JsonText: string): string;
var
  Arr: TJSONArray;
  I: Integer;
  Obj: TJSONObject;
  Root: TJSONValue;
  Row: TJSONObject;
  Text: TStringBuilder;
  Value: TJSONValue;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Text.AppendLine('Configuration');
      Text.AppendLine;
      Text.AppendLine('Defaults:');
      Text.AppendLine(Format('%-22s %s', ['Provider', JsonAsString(Obj, 'default_provider')]));
      Text.AppendLine(Format('%-22s %s', ['Model', JsonAsString(Obj, 'default_model')]));
      Text.AppendLine;

      Text.AppendLine('Providers:');
      Value := Obj.GetValue('providers');
      if Value is TJSONArray then
      begin
        Arr := TJSONArray(Value);
        if Arr.Count = 0 then
          Text.AppendLine('(none)')
        else
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              Row := TJSONObject(Arr.Items[I]);
              Text.AppendLine(JsonAsString(Row, 'name'));
              Text.AppendLine('  kind:  ' + JsonAsString(Row, 'kind'));
              if JsonAsString(Row, 'model') <> '' then
                Text.AppendLine('  model: ' + JsonAsString(Row, 'model'));
              if JsonAsString(Row, 'base_url') <> '' then
                Text.AppendLine('  base:  ' + JsonAsString(Row, 'base_url'));
              if JsonAsBool(Row, 'placeholder') then
                Text.AppendLine('  status: placeholder');
            end;
      end
      else
        Text.AppendLine('(none)');

      Text.AppendLine;
      Text.AppendLine('Memory and retrieval:');
      if Obj.GetValue('memory_search_enabled') <> nil then
        Text.AppendLine(Format('%-22s %s', ['Memory search', BoolToStr(JsonAsBool(Obj, 'memory_search_enabled'), True)]));
      if Obj.GetValue('vector_search_enabled') <> nil then
        Text.AppendLine(Format('%-22s %s', ['Vector search', BoolToStr(JsonAsBool(Obj, 'vector_search_enabled'), True)]));
      if Obj.GetValue('rerank_search_enabled') <> nil then
        Text.AppendLine(Format('%-22s %s', ['Reranking', BoolToStr(JsonAsBool(Obj, 'rerank_search_enabled'), True)]));
      if JsonAsString(Obj, 'rerank_backend') <> '' then
        Text.AppendLine(Format('%-22s %s', ['Rerank backend', JsonAsString(Obj, 'rerank_backend')]));
      if JsonAsString(Obj, 'rerank_model') <> '' then
        Text.AppendLine(Format('%-22s %s', ['Rerank model', JsonAsString(Obj, 'rerank_model')]));

      Text.AppendLine;
      Text.AppendLine('Runtime features:');
      if Obj.GetValue('stats_collection_enabled') <> nil then
        Text.AppendLine(Format('%-22s %s', ['Stats collection', BoolToStr(JsonAsBool(Obj, 'stats_collection_enabled'), True)]));
      if Obj.GetValue('checkpoints_enabled') <> nil then
        Text.AppendLine(Format('%-22s %s', ['Checkpoints', BoolToStr(JsonAsBool(Obj, 'checkpoints_enabled'), True)]));
      if JsonAsString(Obj, 'checkpoints_backend') <> '' then
        Text.AppendLine(Format('%-22s %s', ['Checkpoint backend', JsonAsString(Obj, 'checkpoints_backend')]));

      Value := Obj.GetValue('fallbacks');
      if Value is TJSONArray then
      begin
        Text.AppendLine;
        Text.AppendLine('Fallbacks:');
        Arr := TJSONArray(Value);
        if Arr.Count = 0 then
          Text.AppendLine('(none)')
        else
          for I := 0 to Arr.Count - 1 do
            Text.AppendLine('- ' + Arr.Items[I].Value);
      end;

      Value := Obj.GetValue('mcp_servers');
      if Value is TJSONArray then
      begin
        Text.AppendLine;
        Text.AppendLine('MCP servers:');
        Arr := TJSONArray(Value);
        if Arr.Count = 0 then
          Text.AppendLine('(none)')
        else
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              Row := TJSONObject(Arr.Items[I]);
              Text.AppendLine(JsonAsString(Row, 'name'));
              Text.AppendLine('  command: ' + JsonAsString(Row, 'cmd'));
              if JsonAsString(Row, 'args') <> '' then
                Text.AppendLine('  args:    ' + JsonAsString(Row, 'args'));
              Text.AppendLine('  enabled: ' + BoolToStr(JsonAsBool(Row, 'enabled'), True));
            end;
      end;

      Text.AppendLine;
      Text.AppendLine('Raw JSON:');
      Text.Append(JsonText);
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatMemoryProvisionText(
  const JsonText: string): string;
var
  Job: TJSONObject;
  Obj: TJSONObject;
  Root: TJSONValue;
  Text: TStringBuilder;
  Value: TJSONValue;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Text.AppendLine('Memory and Reranking Setup');
      Text.AppendLine;
      Text.AppendLine('Semantic memory:');
      Text.AppendLine(Format('%-24s %s', ['Vector search',
        BoolToStr(JsonAsBool(Obj, 'vector_search_enabled'), True)]));
      Text.AppendLine(Format('%-24s %s', ['Embedder downloaded',
        BoolToStr(JsonAsBool(Obj, 'embed_provisioned'), True)]));
      Text.AppendLine(Format('%-24s %s', ['ONNX runtime loadable',
        BoolToStr(JsonAsBool(Obj, 'ort_loadable'), True)]));

      Text.AppendLine;
      Text.AppendLine('Reranking:');
      Text.AppendLine(Format('%-24s %s', ['Enabled',
        BoolToStr(JsonAsBool(Obj, 'rerank_search_enabled'), True)]));
      Text.AppendLine(Format('%-24s %s', ['Backend',
        JsonAsString(Obj, 'rerank_backend')]));
      Text.AppendLine(Format('%-24s %s', ['Model',
        JsonAsString(Obj, 'rerank_model')]));
      Text.AppendLine(Format('%-24s %s', ['Reranker downloaded',
        BoolToStr(JsonAsBool(Obj, 'rerank_provisioned'), True)]));
      if JsonAsString(Obj, 'reranker_keys') <> '' then
        Text.AppendLine(Format('%-24s %s', ['Available local models',
          JsonAsString(Obj, 'reranker_keys')]));

      Text.AppendLine;
      Text.AppendLine('Provisioning job:');
      Value := Obj.GetValue('job');
      if Value is TJSONObject then
      begin
        Job := TJSONObject(Value);
        Text.AppendLine(Format('%-24s %s', ['Phase',
          JsonAsString(Job, 'phase')]));
        Text.AppendLine(Format('%-24s %s', ['Step',
          JsonAsString(Job, 'step')]));
        Text.AppendLine(Format('%-24s %s', ['Error',
          JsonAsString(Job, 'error')]));
      end
      else
        Text.AppendLine('(idle)');

      Text.AppendLine;
      Text.AppendLine('Raw JSON:');
      Text.Append(JsonText);
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatModelsText(const JsonText: string): string;
var
  Arr: TJSONArray;
  I: Integer;
  Obj: TJSONObject;
  Root: TJSONValue;
  Row: TJSONObject;
  Text: TStringBuilder;
  Value: TJSONValue;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Text.AppendLine('Models');
      Text.AppendLine;
      Value := Obj.GetValue('data');
      if Value is TJSONArray then
      begin
        Arr := TJSONArray(Value);
        Text.AppendLine(Format('%d model(s)', [Arr.Count]));
        Text.AppendLine;
        if Arr.Count = 0 then
          Text.AppendLine('(none)')
        else
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              Row := TJSONObject(Arr.Items[I]);
              Text.AppendLine(JsonAsString(Row, 'id'));
              Text.AppendLine('  owned by: ' + JsonAsString(Row, 'owned_by'));
              Text.AppendLine('  created:  ' + JsonAsInt64(Row, 'created').ToString);
              Text.AppendLine;
            end;
      end
      else
        Text.AppendLine('(model data missing)');

      Text.AppendLine('Raw JSON:');
      Text.Append(JsonText);
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatProviderText(const JsonText: string): string;
var
  Arr: TJSONArray;
  I: Integer;
  Obj: TJSONObject;
  Root: TJSONValue;
  Row: TJSONObject;
  Text: TStringBuilder;
  Value: TJSONValue;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Value := Obj.GetValue('data');
      if Value is TJSONArray then
      begin
        Text.AppendLine('Provider Catalog');
        Text.AppendLine;
        Arr := TJSONArray(Value);
        Text.AppendLine(Format('%d provider kind(s)', [Arr.Count]));
        Text.AppendLine;
        for I := 0 to Arr.Count - 1 do
          if Arr.Items[I] is TJSONObject then
          begin
            Row := TJSONObject(Arr.Items[I]);
            Text.AppendLine(JsonAsString(Row, 'display_name') + ' (' +
              JsonAsString(Row, 'kind') + ')');
            Text.AppendLine('  model:       ' + JsonAsString(Row, 'default_model'));
            Text.AppendLine('  base:        ' + JsonAsString(Row, 'default_base'));
            Text.AppendLine('  auth:        ' + JsonAsString(Row, 'auth'));
            Text.AppendLine('  needs key:   ' +
              BoolToStr(JsonAsBool(Row, 'needs_key'), True));
            Text.AppendLine('  needs base:  ' +
              BoolToStr(JsonAsBool(Row, 'needs_base'), True));
            Text.AppendLine('  needs model: ' +
              BoolToStr(JsonAsBool(Row, 'needs_model'), True));
            if JsonAsBool(Row, 'placeholder') then
              Text.AppendLine('  placeholder: true');
            if JsonAsString(Row, 'notes') <> '' then
              Text.AppendLine('  notes:       ' + JsonAsString(Row, 'notes'));
            Text.AppendLine;
          end;
      end
      else
      begin
        Text.AppendLine('Configured Providers');
        Text.AppendLine;
        Text.AppendLine(Format('%-14s %s', ['Default',
          JsonAsString(Obj, 'default')]));
        Text.AppendLine;
        Value := Obj.GetValue('providers');
        if Value is TJSONArray then
        begin
          Arr := TJSONArray(Value);
          if Arr.Count = 0 then
            Text.AppendLine('(none)')
          else
            for I := 0 to Arr.Count - 1 do
              if Arr.Items[I] is TJSONObject then
              begin
                Row := TJSONObject(Arr.Items[I]);
                Text.AppendLine(JsonAsString(Row, 'name'));
                Text.AppendLine('  kind:  ' + JsonAsString(Row, 'kind'));
                Text.AppendLine('  model: ' + JsonAsString(Row, 'model'));
                Text.AppendLine;
              end;
        end
        else
          Text.AppendLine('(provider list missing)');
      end;

      Text.AppendLine('Raw JSON:');
      Text.Append(JsonText);
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatStatusText(const JsonText: string): string;
var
  Obj: TJSONObject;
  Root: TJSONValue;
  Text: TStringBuilder;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Text.AppendLine('Gateway Status');
      Text.AppendLine;
      Text.AppendLine(Format('%-18s %s', ['Provider',
        JsonAsString(Obj, 'default_provider')]));
      Text.AppendLine(Format('%-18s %s', ['Model',
        JsonAsString(Obj, 'default_model')]));
      Text.AppendLine;
      Text.AppendLine('Configured Surface:');
      Text.AppendLine(Format('%-18s %s', ['Providers',
        JsonAsInt64(Obj, 'providers').ToString]));
      Text.AppendLine(Format('%-18s %s', ['MCP servers',
        JsonAsInt64(Obj, 'mcp_servers').ToString]));
      Text.AppendLine(Format('%-18s %s', ['Tools',
        JsonAsInt64(Obj, 'tools').ToString]));
      Text.AppendLine(Format('%-18s %s', ['Cron jobs',
        JsonAsInt64(Obj, 'crons').ToString]));
      Text.AppendLine(Format('%-18s %s', ['Skills',
        JsonAsInt64(Obj, 'skills').ToString]));
      Text.AppendLine;
      Text.AppendLine('Raw JSON:');
      Text.Append(JsonText);
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatMemoryText(const JsonText: string): string;
var
  Arr: TJSONArray;
  I: Integer;
  Obj: TJSONObject;
  Root: TJSONValue;
  Row: TJSONObject;
  Text: TStringBuilder;
  Value: TJSONValue;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Value := Obj.GetValue('files');
      if Value is TJSONArray then
      begin
        Text.AppendLine('Memory Files');
        Text.AppendLine;
        Arr := TJSONArray(Value);
        Text.AppendLine(Format('%d file(s)', [Arr.Count]));
        Text.AppendLine;
        if Arr.Count = 0 then
          Text.AppendLine('(none)')
        else
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              Row := TJSONObject(Arr.Items[I]);
              Text.AppendLine(Format('%-36s %s',
                [JsonAsString(Row, 'name'),
                FormatBytes(JsonAsInt64(Row, 'size'))]));
            end;
      end
      else
      begin
        Value := Obj.GetValue('hits');
        if Value is TJSONArray then
        begin
          Text.AppendLine('Memory Search Results');
          Text.AppendLine;
          Arr := TJSONArray(Value);
          Text.AppendLine(Format('%d hit(s)', [Arr.Count]));
          Text.AppendLine;
          if Arr.Count = 0 then
            Text.AppendLine('(none)')
          else
            for I := 0 to Arr.Count - 1 do
              if Arr.Items[I] is TJSONObject then
              begin
                Row := TJSONObject(Arr.Items[I]);
                Text.AppendLine(JsonAsString(Row, 'path'));
                Text.AppendLine('  score:   ' + JsonAsString(Row, 'score'));
                Text.AppendLine('  snippet: ' + JsonAsString(Row, 'snippet'));
                Text.AppendLine;
              end;
        end
        else
        begin
          Value := Obj.GetValue('facts');
          if Value is TJSONArray then
          begin
            Text.AppendLine('Distilled Facts');
            Text.AppendLine;
            Text.AppendLine('Enabled: ' + BoolToStr(JsonAsBool(Obj, 'enabled'), True));
            Text.AppendLine;
            Arr := TJSONArray(Value);
            Text.AppendLine(Format('%d fact(s)', [Arr.Count]));
            Text.AppendLine;
            if Arr.Count = 0 then
              Text.AppendLine('(none)')
            else
              for I := 0 to Arr.Count - 1 do
                if Arr.Items[I] is TJSONObject then
                begin
                  Row := TJSONObject(Arr.Items[I]);
                  Text.AppendLine('#' + JsonAsInt64(Row, 'id').ToString + '  ' +
                    JsonAsString(Row, 'kind') + '/' + JsonAsString(Row, 'scope'));
                  if JsonAsString(Row, 'event_date') <> '' then
                    Text.AppendLine('  event:      ' + JsonAsString(Row, 'event_date'));
                  if JsonAsString(Row, 'expires') <> '' then
                    Text.AppendLine('  expires:    ' + JsonAsString(Row, 'expires'));
                  if JsonAsBool(Row, 'superseded') then
                    Text.AppendLine('  superseded: true');
                  Text.AppendLine('  text:       ' + JsonAsString(Row, 'text'));
                  Text.AppendLine;
                end;
          end
          else
            Text.AppendLine(JsonText);
        end;
      end;

      Text.AppendLine;
      Text.AppendLine('Raw JSON:');
      Text.Append(JsonText);
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatKbSourcesText(const JsonText: string): string;
var
  Arr: TJSONArray;
  I: Integer;
  Obj: TJSONObject;
  Root: TJSONValue;
  Row: TJSONObject;
  Stats: TJSONObject;
  Text: TStringBuilder;
  Value: TJSONValue;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Text.AppendLine('Knowledge Base');
      Text.AppendLine;
      Value := Obj.GetValue('stats');
      if Value is TJSONObject then
      begin
        Stats := TJSONObject(Value);
        Text.AppendLine('Stats:');
        Text.AppendLine(Format('%-18s %s', ['Sources', JsonAsInt64(Stats, 'sources').ToString]));
        Text.AppendLine(Format('%-18s %s', ['Files', JsonAsInt64(Stats, 'files').ToString]));
        Text.AppendLine(Format('%-18s %s', ['Chunks', JsonAsInt64(Stats, 'chunks').ToString]));
        Text.AppendLine(Format('%-18s %s', ['Vector index', BoolToStr(JsonAsBool(Stats, 'vector_ready'), True)]));
        Text.AppendLine;
      end;

      Text.AppendLine('Sources:');
      Value := Obj.GetValue('sources');
      if Value is TJSONArray then
      begin
        Arr := TJSONArray(Value);
        if Arr.Count = 0 then
          Text.AppendLine('(none)')
        else
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              Row := TJSONObject(Arr.Items[I]);
              Text.AppendLine(JsonAsString(Row, 'root'));
              Text.AppendLine('  files:  ' + JsonAsInt64(Row, 'files').ToString);
              Text.AppendLine('  chunks: ' + JsonAsInt64(Row, 'chunks').ToString);
            end;
      end
      else
        Text.AppendLine('(none)');

      Text.AppendLine;
      Text.AppendLine('Raw JSON:');
      Text.Append(JsonText);
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatKbSearchText(const JsonText: string): string;
var
  Arr: TJSONArray;
  I: Integer;
  Obj: TJSONObject;
  Root: TJSONValue;
  Row: TJSONObject;
  Snippet: string;
  Text: TStringBuilder;
  Value: TJSONValue;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Text.AppendLine('Knowledge Base Search');
      Text.AppendLine;
      Value := Obj.GetValue('hits');
      if not (Value is TJSONArray) then
        Value := Obj.GetValue('results');
      if Value is TJSONArray then
      begin
        Arr := TJSONArray(Value);
        if Arr.Count = 0 then
          Text.AppendLine('(no matches)')
        else
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              Row := TJSONObject(Arr.Items[I]);
              Snippet := JsonAsString(Row, 'snippet');
              Text.AppendLine(JsonAsString(Row, 'path'));
              if JsonAsString(Row, 'chunk') <> '' then
                Text.AppendLine('  chunk: ' + JsonAsString(Row, 'chunk'));
              if JsonAsString(Row, 'score') <> '' then
                Text.AppendLine('  score: ' + JsonAsString(Row, 'score'));
              if Snippet <> '' then
              begin
                Text.AppendLine('  snippet:');
                Text.AppendLine('    ' + StringReplace(Snippet, sLineBreak, sLineBreak + '    ', [rfReplaceAll]));
              end;
              Text.AppendLine;
            end;
      end
      else
        Text.AppendLine(JsonText);

      Text.AppendLine('Raw JSON:');
      Text.Append(JsonText);
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

procedure TMasterDetailForm.MemoryModelChoiceChange(Sender: TObject);
var
  Choice: string;
begin
  Choice := MemoryModelValue(ComboSelectedText(FMemoryModelCombo));
  if (Choice <> '') and (FMemoryRerankModelEdit <> nil) then
    FMemoryRerankModelEdit.Text := Choice;
end;

procedure TMasterDetailForm.MemorySetupLoadClick(Sender: TObject);
var
  Base: string;
  Token: string;
  SessionId: string;
begin
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('loading memory setup...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET',
          '/v1/memory/provision', '', '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('memory setup HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Backend: string;
          BodyMemo: TMemo;
          I: Integer;
          JobPhase: string;
          JobStep: string;
          Keys: TArray<string>;
          KeyText: string;
          Memo: TMemo;
          ModelIndex: Integer;
          Obj: TJSONObject;
          Root: TJSONValue;
          SelectedModel: string;
          StatusText: string;
          Value: TJSONValue;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('memory setup failed: ' + ErrorText);
            Exit;
          end;

          Root := TJSONObject.ParseJSONValue(ResponseText);
          try
            if Root is TJSONObject then
            begin
              Obj := TJSONObject(Root);
              if FMemoryVectorCheck <> nil then
                FMemoryVectorCheck.IsChecked := JsonAsBool(Obj,
                  'vector_search_enabled');
              Backend := JsonAsString(Obj, 'rerank_backend');
              if not JsonAsBool(Obj, 'rerank_search_enabled') then
                Backend := 'off'
              else if Backend = '' then
                Backend := 'auto';
              if FMemoryBackendCombo <> nil then
              begin
                FMemoryBackendCombo.ItemIndex :=
                  FMemoryBackendCombo.Items.IndexOf(Backend);
                if FMemoryBackendCombo.ItemIndex < 0 then
                  FMemoryBackendCombo.ItemIndex := 3;
              end;
              SelectedModel := JsonAsString(Obj, 'rerank_model');
              if SelectedModel = '' then
                SelectedModel := 'bge-reranker-base';
              if FMemoryRerankModelEdit <> nil then
              begin
                FMemoryRerankModelEdit.Text := SelectedModel;
              end;
              if FMemoryModelCombo <> nil then
              begin
                FMemoryModelCombo.OnChange := nil;
                FMemoryModelCombo.Items.BeginUpdate;
                try
                  FMemoryModelCombo.Items.Clear;
                  KeyText := JsonAsString(Obj, 'reranker_keys');
                  Keys := KeyText.Split([',']);
                  for I := 0 to Length(Keys) - 1 do
                    if Trim(Keys[I]) <> '' then
                      FMemoryModelCombo.Items.Add(Trim(Keys[I]));
                  if FMemoryModelCombo.Items.Count = 0 then
                    FMemoryModelCombo.Items.Add(SelectedModel);
                  ModelIndex := -1;
                  for I := 0 to FMemoryModelCombo.Items.Count - 1 do
                    if SameText(MemoryModelValue(FMemoryModelCombo.Items[I]),
                      SelectedModel) then
                    begin
                      ModelIndex := I;
                      Break;
                    end;
                  if ModelIndex < 0 then
                  begin
                    FMemoryModelCombo.Items.Add(SelectedModel);
                    ModelIndex := FMemoryModelCombo.Items.Count - 1;
                  end;
                  FMemoryModelCombo.ItemIndex := ModelIndex;
                finally
                  FMemoryModelCombo.Items.EndUpdate;
                  FMemoryModelCombo.OnChange := MemoryModelChoiceChange;
                end;
              end;
              if FMemoryDownloadEmbedCheck <> nil then
                FMemoryDownloadEmbedCheck.IsChecked :=
                  FMemoryVectorCheck.IsChecked and not JsonAsBool(Obj,
                    'embed_provisioned');
              if FMemoryDownloadRerankCheck <> nil then
                FMemoryDownloadRerankCheck.IsChecked :=
                  ((Backend = 'local') or (Backend = 'auto')) and
                  not JsonAsBool(Obj, 'rerank_provisioned');
              if FMemoryStatusLabel <> nil then
              begin
                StatusText := 'Embedder downloaded: ' +
                  BoolToStr(JsonAsBool(Obj, 'embed_provisioned'), True) +
                  '  |  Reranker downloaded: ' +
                  BoolToStr(JsonAsBool(Obj, 'rerank_provisioned'), True) +
                  '  |  ONNX runtime loadable: ' +
                  BoolToStr(JsonAsBool(Obj, 'ort_loadable'), True);
                Value := Obj.GetValue('job');
                if Value is TJSONObject then
                begin
                  JobPhase := JsonAsString(TJSONObject(Value), 'phase');
                  JobStep := JsonAsString(TJSONObject(Value), 'step');
                  if (JobPhase <> '') and not SameText(JobPhase, 'idle') then
                    StatusText := StatusText + '  |  Job: ' + JobPhase +
                      ' ' + JobStep;
                end;
                FMemoryStatusLabel.Text := StatusText;
              end;
            end;
          finally
            Root.Free;
          end;

          if FEndpointBodyMemos.TryGetValue('memory', BodyMemo) then
            BodyMemo.Lines.Text := ResponseText;
          if FPaneMemos.TryGetValue('memory', Memo) then
            Memo.Lines.Text := 'GET /v1/memory/provision' + sLineBreak +
              'HTTP ' + Status.ToString + sLineBreak + sLineBreak +
              FormatMemoryProvisionText(ResponseText);
          SetStatus('memory setup loaded');
        end);
    end);
end;

procedure TMasterDetailForm.MemorySetupSaveClick(Sender: TObject);
var
  Backend: string;
  Body: string;
  Obj: TJSONObject;
begin
  Backend := ComboSelectedText(FMemoryBackendCombo);
  if Backend = '' then
    Backend := 'auto';

  Obj := TJSONObject.Create;
  try
    AddJsonBool(Obj, 'vector_search_enabled',
      (FMemoryVectorCheck <> nil) and FMemoryVectorCheck.IsChecked);
    AddJsonBool(Obj, 'rerank_search_enabled', Backend <> 'off');
    if Backend = 'off' then
      Obj.AddPair('rerank_backend', 'auto')
    else
      Obj.AddPair('rerank_backend', Backend);
    Obj.AddPair('rerank_model', Trim(FMemoryRerankModelEdit.Text));
    AddJsonBool(Obj, 'download_embed',
      (FMemoryDownloadEmbedCheck <> nil) and
      FMemoryDownloadEmbedCheck.IsChecked);
    AddJsonBool(Obj, 'download_rerank',
      (Backend <> 'off') and (FMemoryDownloadRerankCheck <> nil) and
      FMemoryDownloadRerankCheck.IsChecked);
    Body := Obj.ToJSON;
  finally
    Obj.Free;
  end;

  if FEndpointBodyMemos.ContainsKey('memory') then
    FEndpointBodyMemos['memory'].Lines.Text := Body;
  SetStatus('saving memory setup...');
  FetchEndpoint('memory', 'POST', '/v1/memory/provision', Body);
end;

procedure TMasterDetailForm.MemoryFileDetailCopyClick(Sender: TObject);
var
  Clipboard: IFMXClipboardService;
begin
  if (FMemoryFileDetailMemo = nil) or
    (Trim(FMemoryFileDetailMemo.Lines.Text) = '') then
  begin
    SetStatus('no memory file detail to copy');
    Exit;
  end;
  if TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService,
    IInterface(Clipboard)) then
  begin
    Clipboard.SetClipboard(TValue.From<string>(FMemoryFileDetailMemo.Lines.Text));
    SetStatus('memory file detail copied');
  end
  else
    SetStatus('clipboard service unavailable');
end;

procedure TMasterDetailForm.MemoryFilesLoadClick(Sender: TObject);
var
  Base: string;
  SessionId: string;
  Token: string;
begin
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  if FEndpointEdits.ContainsKey('memory') then
    FEndpointEdits['memory'].Text := '/v1/memory';
  SetStatus('loading memory files...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET',
          '/v1/memory', '', '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('memory HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Arr: TJSONArray;
          I: Integer;
          Memo: TMemo;
          Obj: TJSONObject;
          Root: TJSONValue;
          Row: TJSONObject;
          Value: TJSONValue;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('memory files failed: ' + ErrorText);
            Exit;
          end;
          if FMemoryFileList <> nil then
          begin
            FMemoryFileList.Clear;
            Root := TJSONObject.ParseJSONValue(ResponseText);
            try
              if Root is TJSONObject then
              begin
                Obj := TJSONObject(Root);
                Value := Obj.GetValue('files');
                if Value is TJSONArray then
                begin
                  Arr := TJSONArray(Value);
                  for I := 0 to Arr.Count - 1 do
                    if Arr.Items[I] is TJSONObject then
                    begin
                      Row := TJSONObject(Arr.Items[I]);
                      AddCardListItem(FMemoryFileList, JsonAsString(Row, 'name'),
                        FormatBytes(JsonAsInt64(Row, 'size')), 'file' + #9 +
                        JsonAsString(Row, 'name'), 58, False);
                    end;
                end;
              end;
            finally
              Root.Free;
            end;
          end;
          if FMemoryNotesStatusLabel <> nil then
            FMemoryNotesStatusLabel.Text := Format('%d memory file(s)',
              [IfThen(FMemoryFileList <> nil, FMemoryFileList.Count, 0)]);
          if FPaneMemos.TryGetValue('memory', Memo) then
            Memo.Lines.Text := 'GET /v1/memory' + sLineBreak + 'HTTP ' +
              Status.ToString + sLineBreak + sLineBreak +
              FormatMemoryText(ResponseText);
          SetStatus('memory files loaded');
        end);
    end);
end;

procedure TMasterDetailForm.MemorySearchClick(Sender: TObject);
var
  Base: string;
  Query: string;
  SessionId: string;
  Token: string;
begin
  Query := '';
  if FMemorySearchEdit <> nil then
    Query := Trim(FMemorySearchEdit.Text);
  if Query = '' then
  begin
    MemoryFilesLoadClick(Sender);
    Exit;
  end;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  if FEndpointEdits.ContainsKey('memory') then
    FEndpointEdits['memory'].Text := '/v1/memory/search?q=' +
      UrlEncode(Query);
  SetStatus('searching memory...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET',
          '/v1/memory/search?q=' + UrlEncode(Query), '', '',
          'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('memory search HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Arr: TJSONArray;
          I: Integer;
          Memo: TMemo;
          Name: string;
          Path: string;
          Root: TJSONValue;
          Row: TJSONObject;
          Snippet: string;
          Value: TJSONValue;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('memory search failed: ' + ErrorText);
            Exit;
          end;
          if FMemoryFileList <> nil then
          begin
            FMemoryFileList.Clear;
            Root := TJSONObject.ParseJSONValue(ResponseText);
            try
              if Root is TJSONObject then
              begin
                Value := TJSONObject(Root).GetValue('hits');
                if Value is TJSONArray then
                begin
                  Arr := TJSONArray(Value);
                  for I := 0 to Arr.Count - 1 do
                    if Arr.Items[I] is TJSONObject then
                    begin
                      Row := TJSONObject(Arr.Items[I]);
                      Path := JsonAsString(Row, 'path');
                      Name := ExtractFileName(StringReplace(Path, '/',
                        PathDelim, [rfReplaceAll]));
                      if Name = '' then
                        Name := Path;
                      Snippet := JsonAsString(Row, 'snippet');
                      AddCardListItem(FMemoryFileList, Name,
                        'score ' + JsonAsString(Row, 'score') + sLineBreak +
                        Copy(Snippet, 1, 140), 'file' + #9 + Path, 72,
                        False);
                    end;
                end;
              end;
            finally
              Root.Free;
            end;
          end;
          if FMemoryNotesStatusLabel <> nil then
            FMemoryNotesStatusLabel.Text := Format('%d memory hit(s)',
              [IfThen(FMemoryFileList <> nil, FMemoryFileList.Count, 0)]);
          if FPaneMemos.TryGetValue('memory', Memo) then
            Memo.Lines.Text := 'GET /v1/memory/search?q=' + Query +
              sLineBreak + 'HTTP ' + Status.ToString + sLineBreak +
              sLineBreak + FormatMemoryText(ResponseText);
          SetStatus('memory search complete');
        end);
    end);
end;

procedure TMasterDetailForm.MemoryListChange(Sender: TObject);
var
  Base: string;
  Name: string;
  Parts: TArray<string>;
  SessionId: string;
  Token: string;
begin
  if (FMemoryFileList = nil) or (FMemoryFileList.Selected = nil) then
    Exit;
  Parts := FMemoryFileList.Selected.TagString.Split([#9]);
  if (Length(Parts) < 2) or (Parts[0] <> 'file') then
    Exit;
  Name := Parts[1];
  if Name = '' then
    Exit;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  if FEndpointEdits.ContainsKey('memory') then
    FEndpointEdits['memory'].Text := '/v1/memory/' + UrlEncode(Name);
  SetStatus('reading memory file...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET',
          '/v1/memory/' + UrlEncode(Name), '', '', 'application/json',
          Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('memory read HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Content: string;
          Memo: TMemo;
          Obj: TJSONObject;
          Root: TJSONValue;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('memory read failed: ' + ErrorText);
            Exit;
          end;
          Content := ResponseText;
          Root := TJSONObject.ParseJSONValue(ResponseText);
          try
            if Root is TJSONObject then
            begin
              Obj := TJSONObject(Root);
              Content := JsonAsString(Obj, 'content');
              if Name = '' then
                Name := JsonAsString(Obj, 'name');
            end;
          finally
            Root.Free;
          end;
          if FPaneMemos.TryGetValue('memory', Memo) then
            Memo.Lines.Text := 'GET /v1/memory/' + Name + sLineBreak +
              'HTTP ' + Status.ToString + sLineBreak + sLineBreak +
              'Memory File: ' + Name + sLineBreak + sLineBreak + Content;
          if FMemoryFileDetailMemo <> nil then
            FMemoryFileDetailMemo.Lines.Text := 'Memory File: ' + Name +
              sLineBreak + sLineBreak +
              Content;
          SetStatus('memory file loaded');
        end);
    end);
end;

procedure TMasterDetailForm.MemoryFactsLoadClick(Sender: TObject);
var
  Base: string;
  SessionId: string;
  Token: string;
begin
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  if FEndpointEdits.ContainsKey('memory') then
    FEndpointEdits['memory'].Text := '/v1/memory/facts';
  SetStatus('loading memory facts...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET',
          '/v1/memory/facts', '', '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('facts HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Arr: TJSONArray;
          Enabled: Boolean;
          I: Integer;
          Memo: TMemo;
          Root: TJSONValue;
          Row: TJSONObject;
          Text: string;
          Value: TJSONValue;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('facts failed: ' + ErrorText);
            Exit;
          end;
          Enabled := False;
          if FMemoryFactsList <> nil then
            FMemoryFactsList.Clear;
          Root := TJSONObject.ParseJSONValue(ResponseText);
          try
            if Root is TJSONObject then
            begin
              Enabled := JsonAsBool(TJSONObject(Root), 'enabled');
              Value := TJSONObject(Root).GetValue('facts');
              if (Value is TJSONArray) and (FMemoryFactsList <> nil) then
              begin
                Arr := TJSONArray(Value);
                for I := 0 to Arr.Count - 1 do
                  if Arr.Items[I] is TJSONObject then
                  begin
                    Row := TJSONObject(Arr.Items[I]);
                    Text := JsonAsString(Row, 'text');
                    AddCardListItem(FMemoryFactsList,
                      '#' + JsonAsString(Row, 'id') + '  ' +
                      JsonAsString(Row, 'kind') + '/' + JsonAsString(Row,
                      'scope'), Copy(Text, 1, 180), JsonAsString(Row, 'id'),
                      72, False);
                  end;
              end;
            end;
          finally
            Root.Free;
          end;
          if FMemoryFactsStatusLabel <> nil then
          begin
            FMemoryFactsStatusLabel.Text := Format('%d active fact(s)',
              [IfThen(FMemoryFactsList <> nil, FMemoryFactsList.Count, 0)]);
            if not Enabled then
              FMemoryFactsStatusLabel.Text :=
                FMemoryFactsStatusLabel.Text + ' - distillation disabled';
          end;
          if FPaneMemos.TryGetValue('memory', Memo) then
            Memo.Lines.Text := 'GET /v1/memory/facts' + sLineBreak +
              'HTTP ' + Status.ToString + sLineBreak + sLineBreak +
              FormatMemoryText(ResponseText);
          AddListEmptyState(FMemoryFactsList,
            'No facts yet. The agent distils them from conversations, or add one below.');
          SetStatus('memory facts loaded');
        end);
    end);
end;

procedure TMasterDetailForm.MemoryFactAddClick(Sender: TObject);
var
  Base: string;
  Body: string;
  Obj: TJSONObject;
  SessionId: string;
  Text: string;
  Token: string;
begin
  Text := '';
  if FMemoryFactEdit <> nil then
    Text := Trim(FMemoryFactEdit.Text);
  if Text = '' then
  begin
    SetStatus('fact text is required');
    Exit;
  end;

  Obj := TJSONObject.Create;
  try
    Obj.AddPair('text', Text);
    Body := Obj.ToJSON;
  finally
    Obj.Free;
  end;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  if FEndpointBodyMemos.ContainsKey('memory') then
    FEndpointBodyMemos['memory'].Lines.Text := Body;
  SetStatus('adding memory fact...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'POST',
          '/v1/memory/facts', Body, 'application/json', 'application/json',
          Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('add fact HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Memo: TMemo;
        begin
          if FPaneMemos.TryGetValue('memory', Memo) then
            if ErrorText <> '' then
              Memo.Lines.Text := 'POST /v1/memory/facts' + sLineBreak +
                'Error: ' + ErrorText
            else
              Memo.Lines.Text := 'POST /v1/memory/facts' + sLineBreak +
                'HTTP ' + Status.ToString + sLineBreak + sLineBreak +
                ResponseText;
          if ErrorText <> '' then
          begin
            SetStatus('add fact failed');
            Exit;
          end;
          if FMemoryFactEdit <> nil then
            FMemoryFactEdit.Text := '';
          SetStatus('memory fact added');
          MemoryFactsLoadClick(nil);
        end);
    end);
end;

procedure TMasterDetailForm.MemoryFactDeleteClick(Sender: TObject);
var
  Base: string;
  Id: string;
  SessionId: string;
  Token: string;
begin
  if (FMemoryFactsList = nil) or (FMemoryFactsList.Selected = nil) then
  begin
    SetStatus('select a fact first');
    Exit;
  end;
  Id := Trim(FMemoryFactsList.Selected.TagString);
  if Id = '' then
    Exit;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('forgetting memory fact...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'DELETE',
          '/v1/memory/facts/' + UrlEncode(Id), '', '', 'application/json',
          Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('delete fact HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Memo: TMemo;
        begin
          if FPaneMemos.TryGetValue('memory', Memo) then
            if ErrorText <> '' then
              Memo.Lines.Text := 'DELETE /v1/memory/facts/' + Id +
                sLineBreak + 'Error: ' + ErrorText
            else
              Memo.Lines.Text := 'DELETE /v1/memory/facts/' + Id +
                sLineBreak + 'HTTP ' + Status.ToString + sLineBreak +
                sLineBreak + ResponseText;
          if ErrorText <> '' then
          begin
            SetStatus('forget fact failed');
            Exit;
          end;
          SetStatus('memory fact forgotten');
          MemoryFactsLoadClick(nil);
        end);
    end);
end;

procedure TMasterDetailForm.MemoryFactsExportClick(Sender: TObject);
var
  Base: string;
  Dialog: TSaveDialog;
  FilePath: string;
  SessionId: string;
  Token: string;
begin
  Dialog := TSaveDialog.Create(Self);
  try
    Dialog.Filter := 'Markdown|*.md|All files|*.*';
    Dialog.FileName := 'memory-facts.md';
    if not Dialog.Execute then
      Exit;
    FilePath := Dialog.FileName;
  finally
    Dialog.Free;
  end;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('exporting memory facts...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET',
          '/v1/memory/facts/export', '', '', 'text/markdown, text/plain',
          Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('facts export HTTP %d: %s', [Status,
            ResponseText]);
        TFile.WriteAllText(FilePath, ResponseText, TEncoding.UTF8);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Memo: TMemo;
        begin
          if FPaneMemos.TryGetValue('memory', Memo) then
            if ErrorText <> '' then
              Memo.Lines.Text := 'GET /v1/memory/facts/export' +
                sLineBreak + 'Error: ' + ErrorText
            else
              Memo.Lines.Text := 'GET /v1/memory/facts/export' +
                sLineBreak + 'HTTP ' + Status.ToString + sLineBreak +
                'saved to ' + FilePath + sLineBreak + sLineBreak +
                ResponseText;
          if ErrorText <> '' then
            SetStatus('facts export failed')
          else
            SetStatus('facts exported');
        end);
    end);
end;

procedure TMasterDetailForm.SteerActiveTurn(const SteerText: string);
var
  Base: string;
  Body: string;
  Payload: TJSONObject;
  SessionId: string;
  Token: string;
begin
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  if SessionId = '' then
  begin
    SetStatus('steer needs an active session');
    Exit;
  end;
  Payload := TJSONObject.Create;
  try
    Payload.AddPair('text', SteerText);
    Body := Payload.ToJSON;
  finally
    Payload.Free;
  end;
  SetStatus('steering...');
  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'POST', '/v1/steer',
          Body, 'application/json', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('steer HTTP %d: %s',
            [Status, ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;
      TThread.Queue(nil,
        procedure
        begin
          if ErrorText <> '' then
            SetStatus('steer failed: ' + ErrorText)
          else
            SetStatus('steering sent (folds into the running turn)');
        end);
    end);
end;

procedure TMasterDetailForm.SessionExportClick(Sender: TObject);
var
  Base: string;
  Dialog: TSaveDialog;
  FilePath: string;
  SessionId: string;
  Token: string;
begin
  SessionId := FActiveSessionId;
  if SessionId = '' then
  begin
    SetStatus('select a session to export');
    Exit;
  end;
  Dialog := TSaveDialog.Create(Self);
  try
    Dialog.Filter := 'Session JSON|*.json|All files|*.*';
    Dialog.FileName := SessionId + '.json';
    if not Dialog.Execute then
      Exit;
    FilePath := Dialog.FileName;
  finally
    Dialog.Free;
  end;
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SetStatus('exporting session...');
  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET',
          '/v1/sessions/' + SessionId + '/export', '', '',
          'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('session export HTTP %d: %s',
            [Status, ResponseText]);
        TFile.WriteAllText(FilePath, ResponseText, TEncoding.UTF8);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;
      TThread.Queue(nil,
        procedure
        begin
          if ErrorText <> '' then
            SetStatus('session export failed: ' + ErrorText)
          else
            SetStatus('session exported to ' + FilePath);
        end);
    end);
end;

procedure TMasterDetailForm.SessionImportClick(Sender: TObject);
var
  Base: string;
  Dialog: TOpenDialog;
  FilePath: string;
  SessionId: string;
  Token: string;
begin
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Filter :=
      'Chat exports|*.json;*.jsonl|JSON|*.json|JSONL|*.jsonl|All files|*.*';
    if not Dialog.Execute then
      Exit;
    FilePath := Dialog.FileName;
  finally
    Dialog.Free;
  end;
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('importing sessions...');
  TTask.Run(
    procedure
    var
      Body: string;
      CountText: string;
      ErrorText: string;
      ResponseText: string;
      Root: TJSONValue;
      Status: Integer;
    begin
      CountText := '';
      try
        { Read on the worker, not the UI thread: a full ChatGPT
          conversations.json can be hundreds of MB, which would freeze the
          form -- and read/decode failures belong inside this try so they
          surface as a status message instead of escaping. }
        Body := TFile.ReadAllText(FilePath, TEncoding.UTF8);
        ResponseText := HttpText(Base, Token, SessionId, 'POST',
          '/v1/sessions/import', Body, 'application/json',
          'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('session import HTTP %d: %s',
            [Status, ResponseText]);
        Root := TJSONObject.ParseJSONValue(ResponseText);
        try
          if Root is TJSONObject then
            CountText := JsonAsString(TJSONObject(Root), 'imported');
        finally
          Root.Free;
        end;
      except
        on E: Exception do
          ErrorText := E.Message;
      end;
      TThread.Queue(nil,
        procedure
        begin
          if ErrorText <> '' then
            SetStatus('session import failed: ' + ErrorText)
          else
          begin
            if CountText = '' then
              CountText := '?';
            SetStatus('imported ' + CountText + ' session(s)');
            LoadSessions;
          end;
        end);
    end);
end;

procedure TMasterDetailForm.SessionImportDirClick(Sender: TObject);
{ Import an OpenCode data directory (~/.local/share/opencode). The gateway
  reads the directory itself -- OpenCode fragments a session across
  storage/session + storage/message + storage/part files, so there is no
  single body to POST. The path is therefore resolved on the GATEWAY HOST,
  which is the desktop-studio-against-localhost case; a remote gateway needs
  a path that exists on the server. }
var
  Base: string;
  Body: string;
  DirPath: string;
  Payload: TJSONObject;
  Token: string;
begin
  DirPath := '';
  if not SelectDirectory('Select the OpenCode data directory', '', DirPath) then
    Exit;
  DirPath := Trim(DirPath);
  if DirPath = '' then
    Exit;
  Payload := TJSONObject.Create;
  try
    Payload.AddPair('path', DirPath);
    Body := Payload.ToJSON;
  finally
    Payload.Free;
  end;
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SetStatus('importing OpenCode sessions...');
  TTask.Run(
    procedure
    var
      CountText: string;
      ErrorText: string;
      ResponseText: string;
      Root: TJSONValue;
      Status: Integer;
    begin
      CountText := '';
      try
        ResponseText := HttpText(Base, Token, '', 'POST',
          '/v1/sessions/import-dir', Body, 'application/json',
          'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('import-dir HTTP %d: %s',
            [Status, ResponseText]);
        Root := TJSONObject.ParseJSONValue(ResponseText);
        try
          if Root is TJSONObject then
            CountText := JsonAsString(TJSONObject(Root), 'imported');
        finally
          Root.Free;
        end;
      except
        on E: Exception do
          ErrorText := E.Message;
      end;
      TThread.Queue(nil,
        procedure
        begin
          if ErrorText <> '' then
            SetStatus('OpenCode import failed: ' + ErrorText)
          else
          begin
            if CountText = '' then
              CountText := '?';
            SetStatus('imported ' + CountText + ' OpenCode session(s)');
            LoadSessions;
          end;
        end);
    end);
end;

procedure TMasterDetailForm.WorkflowNewClick(Sender: TObject);
begin
  if FWorkflowNameEdit <> nil then
    FWorkflowNameEdit.Text := '';
  if FWorkflowDescEdit <> nil then
    FWorkflowDescEdit.Text := '';
  if FWorkflowInputsEdit <> nil then
    FWorkflowInputsEdit.Text := 'prompt';
  if FWorkflowNodesList <> nil then
    FWorkflowNodesList.Clear;
  if FWorkflowEdgesList <> nil then
    FWorkflowEdgesList.Clear;
  if FWorkflowNodePositions <> nil then
    FWorkflowNodePositions.Clear;
  if FWorkflowRunNodeOk <> nil then
    FWorkflowRunNodeOk.Clear;
  if FWorkflowRunNodePreview <> nil then
    FWorkflowRunNodePreview.Clear;
  FWorkflowDraggingId := '';
  FWorkflowConnectFromId := '';
  FWorkflowSelectedEdge := '';
  FWorkflowHoverEdge := '';
  WorkflowHidePalette;
  if FWorkflowToolCombo <> nil then
    FWorkflowToolCombo.ItemIndex := FWorkflowToolCombo.Items.IndexOf('llm');
  if FWorkflowNodeIdEdit <> nil then
    FWorkflowNodeIdEdit.Text := '';
  if FWorkflowNodeArgsMemo <> nil then
    FWorkflowNodeArgsMemo.Lines.Text := WorkflowDefaultArgs('llm');
  WorkflowLoadInspectorFromNode('llm', WorkflowDefaultArgs('llm'));
  if FWorkflowRunInputsMemo <> nil then
    FWorkflowRunInputsMemo.Lines.Text := '{"prompt": ""}';
  WorkflowRenderGraph;
  SetStatus('new workflow');
end;

procedure TMasterDetailForm.WorkflowAddNodeClick(Sender: TObject);
var
  Args: string;
  BaseId: string;
  Found: Boolean;
  Id: string;
  I: Integer;
  Item: TListBoxItem;
  N: Integer;
  Tool: string;
begin
  Tool := ComboSelectedText(FWorkflowToolCombo);
  if Tool = '' then
    Tool := 'llm';
  Id := Trim(FWorkflowNodeIdEdit.Text);
  if Id = '' then
  begin
    BaseId := LowerCase(Tool);
    BaseId := StringReplace(BaseId, ' ', '', [rfReplaceAll]);
    BaseId := StringReplace(BaseId, '/', '_', [rfReplaceAll]);
    if Length(BaseId) > 10 then
      BaseId := Copy(BaseId, 1, 10);
    if BaseId = '' then
      BaseId := 'node';
    Id := BaseId;
    N := 1;
    repeat
      Found := False;
      for I := 0 to FWorkflowNodesList.Count - 1 do
        if (FWorkflowNodesList.ListItems[I] <> nil) and
          SameText(WorkflowTextId(FWorkflowNodesList.ListItems[I].Text), Id) then
        begin
          Found := True;
          Break;
        end;
      if not Found then
        Break;
      Inc(N);
      Id := BaseId + N.ToString;
    until False;
  end;

  for I := 0 to FWorkflowNodesList.Count - 1 do
    if (FWorkflowNodesList.ListItems[I] <> nil) and
      SameText(WorkflowTextId(FWorkflowNodesList.ListItems[I].Text), Id) then
    begin
      SetStatus('node id already exists');
      Exit;
    end;

  Args := Trim(FWorkflowNodeArgsMemo.Lines.Text);
  if Args = '' then
    Args := WorkflowDefaultArgs(Tool);

  Item := AddCardListItem(FWorkflowNodesList, Id, Tool + ' node', Args, 58,
    True);
  Item.Text := Id + ' | ' + Tool;
  { a brand-new node has never run -- shed any badge a same-named
    predecessor left behind }
  if FWorkflowRunNodeOk <> nil then
    FWorkflowRunNodeOk.Remove(Id);
  if FWorkflowRunNodePreview <> nil then
    FWorkflowRunNodePreview.Remove(Id);
  FWorkflowNodesList.ItemIndex := FWorkflowNodesList.Count - 1;
  { Do NOT seed a position here. WorkflowEnsureNodePosition (reached via
    WorkflowCanvasNodeRect on the next paint, which WorkflowRenderGraph
    triggers below) is the single source of auto-placement and is the only
    one that reserves the INPUT-box gutter -- the old hardcoded x=20 seed
    put the first node straight under the derived INPUT box, and because
    WorkflowEnsureNodePosition exits when a position already exists, the
    gutter-aware path never ran for newly added nodes. }
  FWorkflowNodeIdEdit.Text := Id;
  WorkflowRenderGraph;
end;

procedure TMasterDetailForm.WorkflowNodeSelect(Sender: TObject);
var
  Id: string;
  Index: Integer;
  Item: TListBoxItem;
  Tool: string;
begin
  if (FWorkflowNodesList = nil) or (FWorkflowNodesList.Selected = nil) then
    Exit;
  Item := FWorkflowNodesList.Selected;
  if Item = nil then
    Exit;
  Id := WorkflowTextId(Item.Text);
  Tool := WorkflowTextTool(Item.Text);
  if Tool = '' then
    Tool := 'llm';
  if FWorkflowNodeIdEdit <> nil then
    FWorkflowNodeIdEdit.Text := Id;
  if FWorkflowNodeArgsMemo <> nil then
    FWorkflowNodeArgsMemo.Lines.Text := Item.TagString;
  if FWorkflowToolCombo <> nil then
  begin
    FWorkflowToolCombo.OnChange := nil;
    try
      Index := FWorkflowToolCombo.Items.IndexOf(Tool);
      if Index < 0 then
      begin
        FWorkflowToolCombo.Items.Add(Tool);
        Index := FWorkflowToolCombo.Items.Count - 1;
      end;
      FWorkflowToolCombo.ItemIndex := Index;
    finally
      FWorkflowToolCombo.OnChange := WorkflowToolChange;
    end;
  end;
  WorkflowLoadInspectorFromNode(Tool, Item.TagString);
  if FWorkflowEdgeFromEdit <> nil then
    FWorkflowEdgeFromEdit.Text := Id;
  WorkflowRenderGraph;
end;

function TMasterDetailForm.WorkflowNodeIndexById(const NodeId: string): Integer;
begin
  Result := -1;
  if FWorkflowNodesList = nil then
    Exit;
  for Result := 0 to FWorkflowNodesList.Count - 1 do
    if (FWorkflowNodesList.ListItems[Result] <> nil) and
      SameText(WorkflowTextId(FWorkflowNodesList.ListItems[Result].Text),
      NodeId) then
      Exit;
  Result := -1;
end;

function TMasterDetailForm.WorkflowNodeIndexAtPoint(X, Y, CanvasWidth: Single;
  RequireInputPort: Boolean): Integer;
var
  I: Integer;
  MidY: Single;
  PortR: TRectF;
  R: TRectF;
begin
  Result := -1;
  if FWorkflowNodesList = nil then
    Exit;
  for I := 0 to FWorkflowNodesList.Count - 1 do
  begin
    R := WorkflowCanvasNodeRect(I, CanvasWidth);
    MidY := (R.Top + R.Bottom) / 2;
    if RequireInputPort then
    begin
      PortR := RectF(R.Left - 10, MidY - 10, R.Left + 10, MidY + 10);
      if (X >= PortR.Left) and (X <= PortR.Right) and
        (Y >= PortR.Top) and (Y <= PortR.Bottom) then
        Exit(I);
    end
    else if (X >= R.Left) and (X <= R.Right) and (Y >= R.Top) and
      (Y <= R.Bottom) then
      Exit(I);
  end;
end;

procedure TMasterDetailForm.WorkflowLoadInspectorFromNode(const Tool,
  Args: string);
var
  InputObj: TJSONObject;
  Obj: TJSONObject;
  Root: TJSONValue;
  SchemaText: string;
  Value: TJSONValue;
begin
  if FWorkflowInspectorModeLabel = nil then
    Exit;

  FWorkflowInspectorModeLabel.Text := 'Tool args inspector';
  if FWorkflowLlmProviderEdit <> nil then
  begin
    FWorkflowLlmProviderEdit.Text := '';
    FWorkflowLlmProviderEdit.Enabled := SameText(Tool, 'llm');
  end;
  if FWorkflowLlmModelEdit <> nil then
  begin
    FWorkflowLlmModelEdit.Text := '';
    FWorkflowLlmModelEdit.Enabled := SameText(Tool, 'llm');
  end;
  if FWorkflowLlmPromptMemo <> nil then
  begin
    FWorkflowLlmPromptMemo.Lines.Text := '';
    FWorkflowLlmPromptMemo.Enabled := SameText(Tool, 'llm');
  end;
  if FWorkflowReplicateVersionEdit <> nil then
  begin
    FWorkflowReplicateVersionEdit.Text := '';
    FWorkflowReplicateVersionEdit.Enabled := SameText(Tool, 'replicate');
  end;
  if FWorkflowReplicatePromptEdit <> nil then
  begin
    FWorkflowReplicatePromptEdit.Text := '';
    FWorkflowReplicatePromptEdit.Enabled := SameText(Tool, 'replicate');
  end;
  if FWorkflowSchemaForm <> nil then
    BuildSchemaForm(FWorkflowSchemaForm, '{}', '{}', False);

  Root := TJSONObject.ParseJSONValue(Args);
  try
    if Root is TJSONObject then
      Obj := TJSONObject(Root)
    else
      Obj := nil;

    if SameText(Tool, 'llm') then
    begin
      FWorkflowInspectorModeLabel.Text := 'LLM inspector';
      if Obj <> nil then
      begin
        if FWorkflowLlmProviderEdit <> nil then
          FWorkflowLlmProviderEdit.Text := JsonAsString(Obj, 'provider');
        if FWorkflowLlmModelEdit <> nil then
          FWorkflowLlmModelEdit.Text := JsonAsString(Obj, 'model');
        if FWorkflowLlmPromptMemo <> nil then
          FWorkflowLlmPromptMemo.Lines.Text := JsonAsString(Obj, 'prompt');
      end;
      if (FWorkflowLlmPromptMemo <> nil) and
        (FWorkflowLlmPromptMemo.Lines.Text = '') then
        FWorkflowLlmPromptMemo.Lines.Text := '{{inputs.prompt}}';
    end
    else if SameText(Tool, 'replicate') then
    begin
      FWorkflowInspectorModeLabel.Text := 'Replicate inspector';
      if Obj <> nil then
      begin
        if FWorkflowReplicateVersionEdit <> nil then
          FWorkflowReplicateVersionEdit.Text := JsonAsString(Obj, 'version');
        Value := Obj.GetValue('input');
        if Value is TJSONObject then
        begin
          InputObj := TJSONObject(Value);
          if FWorkflowReplicatePromptEdit <> nil then
            FWorkflowReplicatePromptEdit.Text := JsonAsString(InputObj,
              'prompt');
        end;
      end;
      if (FWorkflowReplicatePromptEdit <> nil) and
        (FWorkflowReplicatePromptEdit.Text = '') then
        FWorkflowReplicatePromptEdit.Text := '{{inputs.prompt}}';
    end
    else
    begin
      FWorkflowInspectorModeLabel.Text :=
        'Tool args inspector - generated from MCP schema';
      if (FWorkflowToolSchemas <> nil) and
        FWorkflowToolSchemas.TryGetValue(Tool, SchemaText) and
        (FWorkflowSchemaForm <> nil) then
        BuildSchemaForm(FWorkflowSchemaForm, SchemaText, Args, False);
    end;
  finally
    Root.Free;
  end;
end;

procedure TMasterDetailForm.WorkflowApplyInspectorClick(Sender: TObject);
var
  InputObj: TJSONObject;
  Obj: TJSONObject;
  Tool: string;
  Value: TJSONValue;
begin
  Tool := ComboSelectedText(FWorkflowToolCombo);
  if Tool = '' then
    Tool := 'llm';

  Obj := nil;
  try
    if SameText(Tool, 'llm') then
    begin
      Obj := TJSONObject.Create;
      Obj.AddPair('provider', Trim(FWorkflowLlmProviderEdit.Text));
      Obj.AddPair('model', Trim(FWorkflowLlmModelEdit.Text));
      Obj.AddPair('prompt', FWorkflowLlmPromptMemo.Lines.Text);
    end
    else if SameText(Tool, 'replicate') then
    begin
      if SchemaFormHasFields(FWorkflowSchemaForm) then
        Obj := CollectSchemaForm(FWorkflowSchemaForm, True)
      else
      begin
        Obj := TJSONObject.Create;
        InputObj := TJSONObject.Create;
        InputObj.AddPair('prompt', Trim(FWorkflowReplicatePromptEdit.Text));
        Obj.AddPair('input', InputObj);
      end;
      Obj.AddPair('version', Trim(FWorkflowReplicateVersionEdit.Text));
    end
    else
    begin
      if SchemaFormHasFields(FWorkflowSchemaForm) then
        Obj := CollectSchemaForm(FWorkflowSchemaForm, False)
      else
      begin
        Value := TJSONObject.ParseJSONValue(FWorkflowNodeArgsMemo.Lines.Text);
        if Value is TJSONObject then
          Obj := TJSONObject(Value)
        else
        begin
          Value.Free;
          Obj := TJSONObject.Create;
        end;
      end;
    end;
    if FWorkflowNodeArgsMemo <> nil then
      FWorkflowNodeArgsMemo.Lines.Text := Obj.ToJSON;
  finally
    Obj.Free;
  end;

  if (FWorkflowNodesList <> nil) and (FWorkflowNodesList.Selected <> nil) then
    WorkflowUpdateNodeClick(nil)
  else
    SetStatus('workflow args updated');
end;

procedure TMasterDetailForm.WorkflowToolChange(Sender: TObject);
var
  Tool: string;
begin
  Tool := ComboSelectedText(FWorkflowToolCombo);
  if Tool = '' then
    Tool := 'llm';
  if ((FWorkflowNodesList = nil) or (FWorkflowNodesList.Selected = nil)) and
    (FWorkflowNodeArgsMemo <> nil) then
    FWorkflowNodeArgsMemo.Lines.Text := WorkflowDefaultArgs(Tool);
  if FWorkflowNodeArgsMemo <> nil then
    WorkflowLoadInspectorFromNode(Tool, FWorkflowNodeArgsMemo.Lines.Text);
end;

procedure TMasterDetailForm.WorkflowProviderModelClick(Sender: TObject);
var
  Base: string;
  SessionId: string;
  Token: string;
begin
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('loading workflow providers and models...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ModelsText: string;
      ProvidersText: string;
      StatusModels: Integer;
      StatusProviders: Integer;
    begin
      try
        ProvidersText := HttpText(Base, Token, SessionId, 'GET',
          '/v1/providers', '', '', 'application/json', StatusProviders);
        if not IsHttpOk(StatusProviders) then
          raise Exception.CreateFmt('providers HTTP %d: %s', [StatusProviders,
            ProvidersText]);
        ModelsText := HttpText(Base, Token, SessionId, 'GET', '/v1/models', '',
          '', 'application/json', StatusModels);
        if not IsHttpOk(StatusModels) then
          raise Exception.CreateFmt('models HTTP %d: %s', [StatusModels,
            ModelsText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Arr: TJSONArray;
          I: Integer;
          Memo: TMemo;
          ModelName: string;
          Obj: TJSONObject;
          ProviderName: string;
          Root: TJSONValue;
          Row: TJSONObject;
          Value: TJSONValue;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('workflow provider/model load failed: ' + ErrorText);
            Exit;
          end;

          ProviderName := '';
          Root := TJSONObject.ParseJSONValue(ProvidersText);
          try
            if Root is TJSONObject then
            begin
              Obj := TJSONObject(Root);
              ProviderName := JsonAsString(Obj, 'default_provider');
              if ProviderName = '' then
                ProviderName := JsonAsString(Obj, 'provider');
              Value := Obj.GetValue('providers');
              if (ProviderName = '') and (Value is TJSONArray) then
              begin
                Arr := TJSONArray(Value);
                for I := 0 to Arr.Count - 1 do
                  if Arr.Items[I] is TJSONObject then
                  begin
                    Row := TJSONObject(Arr.Items[I]);
                    ProviderName := JsonAsString(Row, 'name');
                    if ProviderName = '' then
                      ProviderName := JsonAsString(Row, 'kind');
                    if ProviderName <> '' then
                      Break;
                  end;
              end;
            end;
          finally
            Root.Free;
          end;

          ModelName := CurrentModel;
          if SameText(ModelName, 'default model') then
            ModelName := '';
          Root := TJSONObject.ParseJSONValue(ModelsText);
          try
            if Root is TJSONObject then
            begin
              Obj := TJSONObject(Root);
              if ModelName = '' then
                ModelName := JsonAsString(Obj, 'default_model');
              if ModelName = '' then
                ModelName := JsonAsString(Obj, 'model');
              Value := Obj.GetValue('data');
              if not (Value is TJSONArray) then
                Value := Obj.GetValue('models');
              if (ModelName = '') and (Value is TJSONArray) then
              begin
                Arr := TJSONArray(Value);
                for I := 0 to Arr.Count - 1 do
                begin
                  if Arr.Items[I] is TJSONObject then
                  begin
                    Row := TJSONObject(Arr.Items[I]);
                    ModelName := JsonAsString(Row, 'id');
                    if ModelName = '' then
                      ModelName := JsonAsString(Row, 'name');
                  end
                  else
                    ModelName := Arr.Items[I].Value;
                  if ModelName <> '' then
                    Break;
                end;
              end;
            end;
          finally
            Root.Free;
          end;

          if (FWorkflowLlmProviderEdit <> nil) and (ProviderName <> '') then
            FWorkflowLlmProviderEdit.Text := ProviderName;
          if (FWorkflowLlmModelEdit <> nil) and (ModelName <> '') then
            FWorkflowLlmModelEdit.Text := ModelName;
          if FPaneMemos.TryGetValue('workflow', Memo) then
            Memo.Lines.Text := 'GET /v1/providers' + sLineBreak + 'HTTP ' +
              StatusProviders.ToString + sLineBreak + sLineBreak +
              FormatProviderText(ProvidersText) + sLineBreak + sLineBreak +
              'GET /v1/models' + sLineBreak + 'HTTP ' +
              StatusModels.ToString + sLineBreak + sLineBreak +
              FormatModelsText(ModelsText);
          SetStatus('workflow provider/model loaded; Apply Form updates node args');
        end);
    end);
end;

procedure TMasterDetailForm.WorkflowReplicateSearchClick(Sender: TObject);
var
  Base: string;
  Query: string;
  SessionId: string;
  Token: string;
begin
  if FWorkflowReplicateSearchEdit = nil then
    Exit;
  Query := Trim(FWorkflowReplicateSearchEdit.Text);
  if Query = '' then
  begin
    SetStatus('enter a Replicate model search');
    Exit;
  end;
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('searching Replicate models...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET',
          '/v1/replicate/search?q=' + UrlEncode(Query), '', '',
          'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('replicate search HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Arr: TJSONArray;
          I: Integer;
          Item: TListBoxItem;
          Obj: TJSONObject;
          Owner: string;
          Name: string;
          Root: TJSONValue;
          Row: TJSONObject;
          Version: string;
          Value: TJSONValue;
        begin
          if FWorkflowReplicateResultsList <> nil then
            FWorkflowReplicateResultsList.Clear;
          if ErrorText <> '' then
          begin
            SetStatus('Replicate search failed: ' + ErrorText);
            Exit;
          end;
          Root := TJSONObject.ParseJSONValue(ResponseText);
          try
            Arr := nil;
            if Root is TJSONObject then
            begin
              Obj := TJSONObject(Root);
              Value := Obj.GetValue('models');
              if Value is TJSONArray then
                Arr := TJSONArray(Value);
              if Arr = nil then
              begin
                Value := Obj.GetValue('results');
                if Value is TJSONArray then
                  Arr := TJSONArray(Value);
              end;
              if Arr = nil then
              begin
                Value := Obj.GetValue('data');
                if Value is TJSONArray then
                  Arr := TJSONArray(Value);
              end;
              if Arr = nil then
              begin
                Value := Obj.GetValue('result');
                if Value is TJSONObject then
                begin
                  Value := TJSONObject(Value).GetValue('models');
                  if Value is TJSONArray then
                    Arr := TJSONArray(Value);
                end;
              end;
            end;
            if (Arr <> nil) and (FWorkflowReplicateResultsList <> nil) then
              for I := 0 to Min(Arr.Count - 1, 11) do
                if Arr.Items[I] is TJSONObject then
                begin
                  Row := TJSONObject(Arr.Items[I]);
                  Owner := JsonAsString(Row, 'owner');
                  Name := JsonAsString(Row, 'name');
                  if (Owner = '') and (Pos('/', JsonAsString(Row, 'id')) > 0) then
                  begin
                    Owner := Copy(JsonAsString(Row, 'id'), 1,
                      Pos('/', JsonAsString(Row, 'id')) - 1);
                    Name := Copy(JsonAsString(Row, 'id'),
                      Pos('/', JsonAsString(Row, 'id')) + 1, MaxInt);
                  end;
                  if (Owner = '') or (Name = '') then
                    Continue;
                  Version := JsonAsString(Row, 'version');
                  Item := TListBoxItem.Create(FWorkflowReplicateResultsList);
                  Item.Parent := FWorkflowReplicateResultsList;
                  Item.Text := Owner + '/' + Name;
                  if JsonAsString(Row, 'description') <> '' then
                    Item.Text := Item.Text + sLineBreak +
                      Copy(JsonAsString(Row, 'description'), 1, 120);
                  Item.TagString := Owner + #9 + Name + #9 + Version;
                  Item.Height := 46;
                  Item.HitTest := True;
                  Item.OnClick := CardListItemClick;
                end;
          finally
            Root.Free;
          end;
          if FPaneMemos.ContainsKey('workflow') then
            FPaneMemos['workflow'].Lines.Text :=
              'GET /v1/replicate/search?q=' + Query + sLineBreak +
              'HTTP ' + Status.ToString + sLineBreak + sLineBreak +
              ResponseText;
          SetStatus('Replicate search loaded');
        end);
    end);
end;

procedure TMasterDetailForm.WorkflowReplicatePickClick(Sender: TObject);
var
  Base: string;
  Name: string;
  Owner: string;
  Parts: TArray<string>;
  SessionId: string;
  Token: string;
begin
  if (FWorkflowReplicateResultsList = nil) or
    (FWorkflowReplicateResultsList.Selected = nil) then
    Exit;
  Parts := FWorkflowReplicateResultsList.Selected.TagString.Split([#9]);
  if Length(Parts) < 2 then
    Exit;
  Owner := Parts[0];
  Name := Parts[1];
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('loading Replicate model schema...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET',
          '/v1/replicate/model?owner=' + UrlEncode(Owner) + '&name=' +
          UrlEncode(Name), '', '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('replicate model HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          InputSchema: TJSONValue;
          Latest: TJSONObject;
          ModelObj: TJSONObject;
          Obj: TJSONObject;
          Root: TJSONValue;
          SchemaObj: TJSONObject;
          Version: string;
          Value: TJSONValue;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('Replicate model failed: ' + ErrorText);
            Exit;
          end;
          Root := TJSONObject.ParseJSONValue(ResponseText);
          try
            Obj := nil;
            if Root is TJSONObject then
            begin
              Obj := TJSONObject(Root);
              Value := Obj.GetValue('result');
              if Value is TJSONObject then
                Obj := TJSONObject(Value);
              Value := Obj.GetValue('structuredContent');
              if Value is TJSONObject then
                Obj := TJSONObject(Value);
            end;

            Version := '';
            InputSchema := nil;
            if Obj <> nil then
            begin
              Latest := nil;
              Value := Obj.GetValue('latest_version');
              if Value is TJSONObject then
                Latest := TJSONObject(Value);
              if Latest = nil then
              begin
                Value := Obj.GetValue('model');
                if Value is TJSONObject then
                begin
                  ModelObj := TJSONObject(Value);
                  Value := ModelObj.GetValue('latest_version');
                  if Value is TJSONObject then
                    Latest := TJSONObject(Value);
                end;
              end;
              if Latest <> nil then
              begin
                Version := JsonAsString(Latest, 'id');
                Value := Latest.GetValue('openapi_schema');
                if Value is TJSONObject then
                begin
                  SchemaObj := TJSONObject(Value);
                  Value := SchemaObj.GetValue('components');
                  if Value is TJSONObject then
                  begin
                    Value := TJSONObject(Value).GetValue('schemas');
                    if Value is TJSONObject then
                    begin
                      Value := TJSONObject(Value).GetValue('Input');
                      if Value is TJSONObject then
                        InputSchema := Value;
                    end;
                  end;
                end;
              end;
            end;
            if (Version <> '') and (FWorkflowReplicateVersionEdit <> nil) then
              FWorkflowReplicateVersionEdit.Text := Version;
            if (InputSchema <> nil) and (FWorkflowSchemaForm <> nil) then
              BuildSchemaForm(FWorkflowSchemaForm, InputSchema.ToJSON,
                FWorkflowNodeArgsMemo.Lines.Text, True);
            if FPaneMemos.ContainsKey('workflow') then
              FPaneMemos['workflow'].Lines.Text :=
                'GET /v1/replicate/model ' + Owner + '/' + Name +
                sLineBreak + 'HTTP ' + Status.ToString + sLineBreak +
                sLineBreak + ResponseText;
          finally
            Root.Free;
          end;
          SetStatus('Replicate model loaded');
        end);
    end);
end;

procedure TMasterDetailForm.WorkflowCanvasPaint(Sender: TObject;
  Canvas: TCanvas);
var
  Box: TPaintBox;
  EdgeEnd: TPointF;
  EdgeStart: TPointF;
  EdgeText: string;
  FromId: string;
  FromIndex: Integer;
  GridX: Single;
  GridY: Single;
  I: Integer;
  NodeId: string;
  NodeText: string;
  NodeTool: string;
  P: Integer;
  PortR: TRectF;
  R: TRectF;
  RFrom: TRectF;
  RTo: TRectF;
  IoNames: TStringList;
  IoParts: TArray<string>;
  IoRect: TRectF;
  OutRect: TRectF;
  RunOk: Boolean;
  RunPreview: string;
  Selected: Boolean;
  SelectedId: string;
  TextR: TRectF;
  ToId: string;
  ToIndex: Integer;
begin
  if not (Sender is TPaintBox) then
    Exit;
  Box := TPaintBox(Sender);
  R := RectF(0, 0, Box.Width, Box.Height);
  Canvas.Fill.Color := ThemePaintColor(UI_BG);
  Canvas.FillRect(R, 6, 6, [], 1);

  Canvas.Stroke.Color := ThemePaintStroke(UI_BORDER);
  Canvas.Stroke.Thickness := 1;
  { the grid moves with the pan (mod its pitch), which is what makes the
    space read as moving rather than the content sliding over a static mat }
  GridX := 24 + FWorkflowPan.X - Int(FWorkflowPan.X / 24) * 24 - 24;
  if GridX < 0 then GridX := GridX + 24;
  while GridX < Box.Width do
  begin
    Canvas.DrawLine(PointF(GridX, 0), PointF(GridX, Box.Height), 0.35);
    GridX := GridX + 24;
  end;
  GridY := 24 + FWorkflowPan.Y - Int(FWorkflowPan.Y / 24) * 24 - 24;
  if GridY < 0 then GridY := GridY + 24;
  while GridY < Box.Height do
  begin
    Canvas.DrawLine(PointF(0, GridY), PointF(Box.Width, GridY), 0.35);
    GridY := GridY + 24;
  end;

  Canvas.Stroke.Color := ThemePaintStroke(UI_BORDER);
  Canvas.Stroke.Thickness := 1.2;
  Canvas.DrawRect(RectF(R.Left + 0.5, R.Top + 0.5, R.Right - 0.5,
    R.Bottom - 0.5), 6, 6, [], 1);

  if (FWorkflowNodesList = nil) or (FWorkflowNodesList.Count = 0) then
  begin
    Canvas.Fill.Color := ThemePaintColor(UI_MUTED);
    Canvas.Font.Size := TXT_BODY;
    Canvas.FillText(RectF(R.Left + 14, R.Top + 14, R.Right - 14,
      R.Bottom - 14), 'Add workflow nodes to build a runnable graph', False, 1,
      [], TTextAlign.Center, TTextAlign.Center);
    Exit;
  end;

  SelectedId := '';
  if FWorkflowNodesList.Selected <> nil then
    SelectedId := WorkflowTextId(FWorkflowNodesList.Selected.Text);

  { ---- derived INPUT / OUTPUT boxes (web UI parity) ----
    The boxes are not nodes: they visualise the workflow's declared inputs
    and outputs. Dashed wires are derived from graph topology -- INPUT feeds
    every ROOT node (no incoming edge), every LEAF node (no outgoing edge)
    feeds OUTPUT -- so the canvas shows where data enters and leaves. }
  IoNames := TStringList.Create;
  try
    { INPUT box }
    IoNames.Clear;
    if FWorkflowInputsEdit <> nil then
    begin
      IoParts := FWorkflowInputsEdit.Text.Split([',']);
      for I := 0 to Length(IoParts) - 1 do
      begin
        EdgeText := Trim(IoParts[I]);
        if EdgeText <> '' then
          IoNames.Add(EdgeText);
      end;
    end;
    IoRect := WorkflowIORect(WF_ID_INPUT, Box.Width, Box.Height);
    IoRect.Bottom := IoRect.Top + Max(46, 26 + IoNames.Count * 15);
    Canvas.Fill.Color := ThemePaintColor(UI_PANEL);
    Canvas.FillRect(IoRect, 6, 6, [], 0.85);
    Canvas.Stroke.Color := ThemePaintStroke(UI_ACCENT_DIM);
    Canvas.Stroke.Thickness := 1.2;
    Canvas.Stroke.Dash := TStrokeDash.Dash;
    Canvas.DrawRect(IoRect, 6, 6, [], 1);
    Canvas.Stroke.Dash := TStrokeDash.Solid;
    Canvas.Fill.Color := ThemePaintColor(UI_ACCENT);
    Canvas.Font.Size := TXT_CAPTION;
    Canvas.FillText(RectF(IoRect.Left + 8, IoRect.Top + 4, IoRect.Right - 8,
      IoRect.Top + 20), 'INPUT', False, 1, [], TTextAlign.Leading,
      TTextAlign.Center);
    Canvas.Fill.Color := ThemePaintColor(UI_MUTED);
    for I := 0 to IoNames.Count - 1 do
      Canvas.FillText(RectF(IoRect.Left + 8, IoRect.Top + 22 + I * 15,
        IoRect.Right - 6, IoRect.Top + 37 + I * 15), IoNames[I], False, 1, [],
        TTextAlign.Leading, TTextAlign.Center);

    { OUTPUT box }
    IoNames.Clear;
    if FWorkflowOutputsMemo <> nil then
      for I := 0 to FWorkflowOutputsMemo.Lines.Count - 1 do
      begin
        EdgeText := Trim(FWorkflowOutputsMemo.Lines[I]);
        P := Pos('=', EdgeText);
        if P > 0 then
          EdgeText := Trim(Copy(EdgeText, 1, P - 1));
        if EdgeText <> '' then
          IoNames.Add(EdgeText);
      end;
    OutRect := WorkflowIORect(WF_ID_OUTPUT, Box.Width, Box.Height);
    OutRect := RectF(OutRect.Left, OutRect.Top, OutRect.Left + WF_IO_W,
      OutRect.Top + Max(46, 26 + IoNames.Count * 15));
    Canvas.Fill.Color := ThemePaintColor(UI_PANEL);
    Canvas.FillRect(OutRect, 6, 6, [], 0.85);
    Canvas.Stroke.Color := ThemePaintStroke(UI_ACCENT_DIM);
    Canvas.Stroke.Thickness := 1.2;
    Canvas.Stroke.Dash := TStrokeDash.Dash;
    Canvas.DrawRect(OutRect, 6, 6, [], 1);
    Canvas.Stroke.Dash := TStrokeDash.Solid;
    Canvas.Fill.Color := ThemePaintColor(UI_ACCENT);
    Canvas.Font.Size := TXT_CAPTION;
    Canvas.FillText(RectF(OutRect.Left + 8, OutRect.Top + 4, OutRect.Right - 8,
      OutRect.Top + 20), 'OUTPUT', False, 1, [], TTextAlign.Leading,
      TTextAlign.Center);
    Canvas.Fill.Color := ThemePaintColor(UI_MUTED);
    for I := 0 to IoNames.Count - 1 do
      Canvas.FillText(RectF(OutRect.Left + 8, OutRect.Top + 22 + I * 15,
        OutRect.Right - 6, OutRect.Top + 37 + I * 15), IoNames[I], False, 1,
        [], TTextAlign.Leading, TTextAlign.Center);

    { dashed derived wires: INPUT -> roots, leaves -> OUTPUT }
    Canvas.Stroke.Color := ThemePaintStroke(UI_ACCENT_DIM);
    Canvas.Stroke.Thickness := 1;
    Canvas.Stroke.Dash := TStrokeDash.Dash;
    for I := 0 to FWorkflowNodesList.Count - 1 do
    begin
      if FWorkflowNodesList.ListItems[I] = nil then
        Continue;
      NodeId := WorkflowTextId(FWorkflowNodesList.ListItems[I].Text);
      RFrom := WorkflowCanvasNodeRect(I, Box.Width);
      if not WorkflowNodeHasEdge(NodeId, True) then
        WorkflowDrawWire(Canvas, PointF(IoRect.Right,
          (IoRect.Top + IoRect.Bottom) / 2),
          PointF(RFrom.Left, (RFrom.Top + RFrom.Bottom) / 2), 0.7);
      if not WorkflowNodeHasEdge(NodeId, False) then
        WorkflowDrawWire(Canvas,
          PointF(RFrom.Right, (RFrom.Top + RFrom.Bottom) / 2),
          PointF(OutRect.Left, (OutRect.Top + OutRect.Bottom) / 2), 0.7);
    end;
    Canvas.Stroke.Dash := TStrokeDash.Solid;
  finally
    IoNames.Free;
  end;

  if FWorkflowEdgesList <> nil then
    for I := 0 to FWorkflowEdgesList.Count - 1 do
    begin
      if FWorkflowEdgesList.ListItems[I] = nil then
        Continue;
      EdgeText := FWorkflowEdgesList.ListItems[I].Text;
      P := Pos(' -> ', EdgeText);
      if P <= 0 then
        Continue;
      FromId := Copy(EdgeText, 1, P - 1);
      ToId := Copy(EdgeText, P + 4, MaxInt);
      FromIndex := WorkflowNodeIndexById(FromId);
      ToIndex := WorkflowNodeIndexById(ToId);
      if (FromIndex < 0) or (ToIndex < 0) then
        Continue;
      RFrom := WorkflowCanvasNodeRect(FromIndex, Box.Width);
      RTo := WorkflowCanvasNodeRect(ToIndex, Box.Width);
      if SameText(FWorkflowSelectedEdge, EdgeText) then
      begin
        Canvas.Stroke.Color := ThemePaintStroke(UI_ACCENT);
        Canvas.Stroke.Thickness := 3;
      end
      else if SameText(FWorkflowHoverEdge, EdgeText) then
      begin
        Canvas.Stroke.Color := ThemePaintStroke(UI_ACCENT);
        Canvas.Stroke.Thickness := 2.4;
      end
      else
      begin
        Canvas.Stroke.Color := ThemePaintStroke(UI_ACCENT_DIM);
        Canvas.Stroke.Thickness := 2;
      end;
      EdgeStart := PointF(RFrom.Right, (RFrom.Top + RFrom.Bottom) / 2);
      EdgeEnd := PointF(RTo.Left, (RTo.Top + RTo.Bottom) / 2);
      WorkflowDrawWire(Canvas, EdgeStart, EdgeEnd, 0.95);
      { the bezier ends on a horizontal tangent, so the old arrowhead still
        points the right way }
      Canvas.DrawLine(EdgeEnd, PointF(EdgeEnd.X - 9, EdgeEnd.Y - 5), 0.95);
      Canvas.DrawLine(EdgeEnd, PointF(EdgeEnd.X - 9, EdgeEnd.Y + 5), 0.95);
      { hovered or selected wires light their endpoints too }
      if SameText(FWorkflowSelectedEdge, EdgeText) or
        SameText(FWorkflowHoverEdge, EdgeText) then
      begin
        Canvas.Fill.Color := ThemePaintColor(UI_ACCENT);
        Canvas.FillEllipse(RectF(EdgeStart.X - 4, EdgeStart.Y - 4,
          EdgeStart.X + 4, EdgeStart.Y + 4), 1);
        Canvas.FillEllipse(RectF(EdgeEnd.X - 4, EdgeEnd.Y - 4,
          EdgeEnd.X + 4, EdgeEnd.Y + 4), 1);
      end;
    end;

  if FWorkflowConnectFromId <> '' then
  begin
    FromIndex := WorkflowNodeIndexById(FWorkflowConnectFromId);
    if FromIndex >= 0 then
    begin
      RFrom := WorkflowCanvasNodeRect(FromIndex, Box.Width);
      Canvas.Stroke.Color := ThemePaintStroke(UI_ACCENT);
      Canvas.Stroke.Thickness := 2.5;
      Canvas.Stroke.Dash := TStrokeDash.Dash;
      WorkflowDrawWire(Canvas,
        PointF(RFrom.Right, (RFrom.Top + RFrom.Bottom) / 2),
        FWorkflowConnectPoint, 1);
      Canvas.Stroke.Dash := TStrokeDash.Solid;
    end;
  end;

  for I := 0 to FWorkflowNodesList.Count - 1 do
  begin
    NodeId := WorkflowTextId(FWorkflowNodesList.ListItems[I].Text);
    Selected := SameText(NodeId, SelectedId);
    R := WorkflowCanvasNodeRect(I, Box.Width);
    if Selected then
      Canvas.Fill.Color := ThemePaintColor(UI_ACCENT_DIM)
    else
      Canvas.Fill.Color := ThemePaintColor(UI_PANEL_ALT);
    Canvas.FillRect(R, 7, 7, [], 1);
    if Selected then
      Canvas.Stroke.Color := ThemePaintStroke(UI_ACCENT)
    else
      Canvas.Stroke.Color := ThemePaintStroke(UI_BORDER);
    Canvas.Stroke.Thickness := 1.4;
    Canvas.DrawRect(R, 7, 7, [], 1);

    NodeText := NodeId;
    if Length(NodeText) > 20 then
      NodeText := Copy(NodeText, 1, 17) + '...';
    NodeTool := WorkflowTextTool(FWorkflowNodesList.ListItems[I].Text);
    if NodeTool = '' then
      NodeTool := 'tool';
    TextR := RectF(R.Left + 10, R.Top + 5, R.Right - 10, R.Top + 24);
    Canvas.Fill.Color := ThemePaintColor(UI_TEXT);
    Canvas.Font.Size := TXT_BODY;
    Canvas.FillText(TextR, NodeText, False, 1, [], TTextAlign.Center,
      TTextAlign.Center);
    TextR := RectF(R.Left + 10, R.Top + 23, R.Right - 10, R.Bottom - 5);
    Canvas.Fill.Color := ThemePaintColor(UI_MUTED);
    Canvas.Font.Size := TXT_CAPTION;
    Canvas.FillText(TextR, NodeTool, False, 1, [], TTextAlign.Center,
      TTextAlign.Center);

    { last-run status: a small badge on the node plus the first line of its
      output under the box -- debugging without leaving the canvas }
    if (FWorkflowRunNodeOk <> nil) and
      FWorkflowRunNodeOk.TryGetValue(NodeId, RunOk) then
    begin
      if RunOk then
        Canvas.Fill.Color := WF_BADGE_OK
      else
        Canvas.Fill.Color := WF_BADGE_ERR;
      Canvas.FillEllipse(RectF(R.Right - 12, R.Top + 4, R.Right - 4,
        R.Top + 12), 1);
      Canvas.Stroke.Color := ThemePaintStroke(UI_BG);
      Canvas.Stroke.Thickness := 1;
      Canvas.DrawEllipse(RectF(R.Right - 12, R.Top + 4, R.Right - 4,
        R.Top + 12), 1);
      if (FWorkflowRunNodePreview <> nil) and
        FWorkflowRunNodePreview.TryGetValue(NodeId, RunPreview) and
        (RunPreview <> '') then
      begin
        Canvas.Fill.Color := ThemePaintColor(UI_MUTED);
        Canvas.Font.Size := TXT_CAPTION;
        Canvas.FillText(RectF(R.Left, R.Bottom + 2, R.Right + 40,
          R.Bottom + 16), RunPreview, False, 0.9, [], TTextAlign.Leading,
          TTextAlign.Center);
      end;
    end;

    if (FWorkflowConnectFromId <> '') and
      not SameText(NodeId, FWorkflowConnectFromId) then
      PortR := RectF(R.Left - 8, ((R.Top + R.Bottom) / 2) - 8,
        R.Left + 8, ((R.Top + R.Bottom) / 2) + 8)
    else
      PortR := RectF(R.Left - 6, ((R.Top + R.Bottom) / 2) - 6,
        R.Left + 6, ((R.Top + R.Bottom) / 2) + 6);
    if (FWorkflowConnectFromId <> '') and
      not SameText(NodeId, FWorkflowConnectFromId) then
      Canvas.Fill.Color := ThemePaintColor(UI_ACCENT_DIM)
    else
      Canvas.Fill.Color := ThemePaintColor(UI_MUTED);
    Canvas.FillEllipse(PortR, 1);
    Canvas.Stroke.Color := ThemePaintStroke(UI_BG);
    Canvas.Stroke.Thickness := 1;
    Canvas.DrawEllipse(PortR, 1);
    if SameText(NodeId, FWorkflowConnectFromId) then
      PortR := RectF(R.Right - 8, ((R.Top + R.Bottom) / 2) - 8,
        R.Right + 8, ((R.Top + R.Bottom) / 2) + 8)
    else
      PortR := RectF(R.Right - 6, ((R.Top + R.Bottom) / 2) - 6,
        R.Right + 6, ((R.Top + R.Bottom) / 2) + 6);
    Canvas.Fill.Color := ThemePaintColor(UI_ACCENT);
    Canvas.FillEllipse(PortR, 1);
    Canvas.DrawEllipse(PortR, 1);
  end;
end;

function TMasterDetailForm.WorkflowNodeHasEdge(const NodeId: string;
  Incoming: Boolean): Boolean;
{ True when some edge targets (Incoming) or leaves (not Incoming) NodeId.
  Roots/leaves are what the derived INPUT/OUTPUT wires attach to. }
var
  EdgeText: string;
  I: Integer;
  P: Integer;
begin
  Result := False;
  if (FWorkflowEdgesList = nil) or (NodeId = '') then
    Exit;
  for I := 0 to FWorkflowEdgesList.Count - 1 do
  begin
    if FWorkflowEdgesList.ListItems[I] = nil then
      Continue;
    EdgeText := FWorkflowEdgesList.ListItems[I].Text;
    P := Pos(' -> ', EdgeText);
    if P <= 0 then
      Continue;
    if Incoming then
    begin
      if SameText(Trim(Copy(EdgeText, P + 4, MaxInt)), NodeId) then
        Exit(True);
    end
    else if SameText(Trim(Copy(EdgeText, 1, P - 1)), NodeId) then
      Exit(True);
  end;
end;

function TMasterDetailForm.WfToScreen(const P: TPointF): TPointF;
begin
  Result := PointF(P.X + FWorkflowPan.X, P.Y + FWorkflowPan.Y);
end;

function TMasterDetailForm.WfToLogical(const P: TPointF): TPointF;
begin
  Result := PointF(P.X - FWorkflowPan.X, P.Y - FWorkflowPan.Y);
end;

{ The INPUT / OUTPUT boxes as movable citizens of the same space. Their
  logical positions live in the positions dictionary under reserved ids;
  the defaults reproduce the old fixed left/right placement, so an
  untouched workflow looks exactly as before. }
function TMasterDetailForm.WorkflowIORect(const Which: string;
  CanvasWidth, CanvasHeight: Single): TRectF;
var
  Pos: TPointF;
  P: TPointF;
begin
  if (FWorkflowNodePositions = nil) or
    (not FWorkflowNodePositions.TryGetValue(Which, Pos)) then
  begin
    if Which = WF_ID_INPUT then
      Pos := PointF(8, 12)
    else
      Pos := PointF(Max(120, CanvasWidth - WF_IO_W - 8), 12);
    if FWorkflowNodePositions <> nil then
      FWorkflowNodePositions.AddOrSetValue(Which, Pos);
  end;
  P := WfToScreen(Pos);
  Result := RectF(P.X, P.Y, P.X + WF_IO_W, P.Y + 46);
end;

procedure TMasterDetailForm.OpenFilesTabAt(const Path: string);
{ Jump to a workspace folder in the Files tab -- run outputs link here. }
begin
  SelectTabByText('Files');
  if FFilePathEdit <> nil then
    FFilePathEdit.Text := Path;
  FilesOpenPath(Path);
end;

procedure TMasterDetailForm.WorkflowFitViewClick(Sender: TObject);
begin
  WorkflowFitView;
end;

procedure TMasterDetailForm.WorkflowFitView;
{ Pan so the whole graph is visible from its top-left. The escape hatch for
  "I panned my graph off into space", and cheap: positions are logical, so
  fitting is just choosing a pan. }
var
  Pair: TPair<string, TPointF>;
  MinX, MinY: Single;
  Found: Boolean;
begin
  MinX := 0; MinY := 0; Found := False;
  if FWorkflowNodePositions <> nil then
    for Pair in FWorkflowNodePositions do
    begin
      if not Found then
      begin
        MinX := Pair.Value.X; MinY := Pair.Value.Y; Found := True;
      end
      else
      begin
        MinX := Min(MinX, Pair.Value.X);
        MinY := Min(MinY, Pair.Value.Y);
      end;
    end;
  if Found then
    FWorkflowPan := PointF(16 - MinX, 16 - MinY)
  else
    FWorkflowPan := PointF(0, 0);
  if FWorkflowCanvas <> nil then
    FWorkflowCanvas.Repaint;
end;

function TMasterDetailForm.WorkflowCanvasNodeRect(Index: Integer;
  CanvasWidth: Single): TRectF;
var
  NodeId: string;
  Pos: TPointF;
  P: TPointF;
begin
  Result := RectF(0, 0, 0, 0);
  if (FWorkflowNodesList = nil) or (Index < 0) or
    (Index >= FWorkflowNodesList.Count) then
    Exit;
  if FWorkflowNodesList.ListItems[Index] = nil then
    Exit;
  NodeId := WorkflowTextId(FWorkflowNodesList.ListItems[Index].Text);
  WorkflowEnsureNodePosition(NodeId, Index, CanvasWidth);
  if (FWorkflowNodePositions = nil) or
    (not FWorkflowNodePositions.TryGetValue(NodeId, Pos)) then
    Pos := PointF(10, 12);
  { SCREEN rect: every consumer is paint or hit-testing, both of which live
    in screen space. The stored position stays logical. }
  P := WfToScreen(Pos);
  Result := RectF(P.X, P.Y, P.X + 116, P.Y + 42);
end;

procedure TMasterDetailForm.WorkflowEnsureNodePosition(const NodeId: string;
  Index: Integer; CanvasWidth: Single);
var
  Col: Integer;
  Cols: Integer;
  Pos: TPointF;
  Row: Integer;
begin
  if (NodeId = '') or (FWorkflowNodePositions = nil) then
    Exit;
  if FWorkflowNodePositions.ContainsKey(NodeId) then
    Exit;
  { Lay out AFTER the INPUT gutter and before the OUTPUT box so auto-placed
    nodes never sit under either derived box. }
  Cols := Max(1, Trunc(Max(1, CanvasWidth - WF_GUTTER - WF_IO_W - 24) /
    (116 + 18)));
  Col := Index mod Cols;
  Row := Index div Cols;
  Pos := PointF(WF_GUTTER + Col * (116 + 18), 12 + Row * (42 + 22));
  FWorkflowNodePositions.AddOrSetValue(NodeId, Pos);
end;

procedure TMasterDetailForm.WorkflowDrawWire(Canvas: TCanvas;
  const A, B: TPointF; Opacity: Single);
{ Every wire on the canvas is a cubic bezier with horizontal tangents --
  the shape all the surveyed node-graph tools share, and most of why their
  graphs read as graphs instead of diagrams. Uses the CURRENT stroke, so
  callers keep owning color/thickness/dash. }
var
  DX: Single;
  Path: TPathData;
begin
  DX := Max(30, Abs(B.X - A.X) / 2);
  Path := TPathData.Create;
  try
    Path.MoveTo(A);
    Path.CurveTo(PointF(A.X + DX, A.Y), PointF(B.X - DX, B.Y), B);
    Canvas.DrawPath(Path, Opacity);
  finally
    Path.Free;
  end;
end;

function TMasterDetailForm.WorkflowWireHit(const A, B: TPointF;
  X, Y: Single): Boolean;
{ Curve-aware hit test: sample the SAME bezier WorkflowDrawWire paints and
  measure against the chords. A straight-line test against a curved wire
  misses exactly where the curve bows away -- the spot users aim for. }
const
  SAMPLES = 24;
var
  C1: TPointF;
  C2: TPointF;
  Dist: Single;
  DX: Single;
  I: Integer;
  LenSq: Single;
  P: TPointF;
  Q: TPointF;
  U: Single;

  function BezPoint(T: Single): TPointF;
  var
    MT: Single;
  begin
    MT := 1 - T;
    Result.X := MT * MT * MT * A.X + 3 * MT * MT * T * C1.X +
      3 * MT * T * T * C2.X + T * T * T * B.X;
    Result.Y := MT * MT * MT * A.Y + 3 * MT * MT * T * C1.Y +
      3 * MT * T * T * C2.Y + T * T * T * B.Y;
  end;

begin
  Result := False;
  DX := Max(30, Abs(B.X - A.X) / 2);
  C1 := PointF(A.X + DX, A.Y);
  C2 := PointF(B.X - DX, B.Y);
  P := A;
  for I := 1 to SAMPLES do
  begin
    Q := BezPoint(I / SAMPLES);
    LenSq := Sqr(Q.X - P.X) + Sqr(Q.Y - P.Y);
    if LenSq > 0 then
    begin
      U := Max(0, Min(1, ((X - P.X) * (Q.X - P.X) +
        (Y - P.Y) * (Q.Y - P.Y)) / LenSq));
      Dist := Sqrt(Sqr(X - (P.X + U * (Q.X - P.X))) +
        Sqr(Y - (P.Y + U * (Q.Y - P.Y))));
      if Dist <= 8 then
        Exit(True);
    end;
    P := Q;
  end;
end;

function TMasterDetailForm.WorkflowEdgeAtPoint(X, Y: Single;
  CanvasWidth: Single): Integer;
{ Index (in the edges list) of the wire under the point, or -1. The single
  owner for mouse-down selection AND hover, so the two can never disagree
  about what is hit. }
var
  EdgeText: string;
  FromIndex: Integer;
  I: Integer;
  P: Integer;
  RFrom: TRectF;
  RTo: TRectF;
  ToIndex: Integer;
begin
  Result := -1;
  if FWorkflowEdgesList = nil then
    Exit;
  for I := 0 to FWorkflowEdgesList.Count - 1 do
  begin
    if FWorkflowEdgesList.ListItems[I] = nil then
      Continue;
    EdgeText := FWorkflowEdgesList.ListItems[I].Text;
    P := Pos(' -> ', EdgeText);
    if P <= 0 then
      Continue;
    FromIndex := WorkflowNodeIndexById(Copy(EdgeText, 1, P - 1));
    ToIndex := WorkflowNodeIndexById(Copy(EdgeText, P + 4, MaxInt));
    if (FromIndex < 0) or (ToIndex < 0) then
      Continue;
    RFrom := WorkflowCanvasNodeRect(FromIndex, CanvasWidth);
    RTo := WorkflowCanvasNodeRect(ToIndex, CanvasWidth);
    if WorkflowWireHit(PointF(RFrom.Right, (RFrom.Top + RFrom.Bottom) / 2),
      PointF(RTo.Left, (RTo.Top + RTo.Bottom) / 2), X, Y) then
      Exit(I);
  end;
end;

function TMasterDetailForm.WfSnap(const P: TPointF): TPointF;
begin
  Result := PointF(Round(P.X / WF_GRID) * WF_GRID,
    Round(P.Y / WF_GRID) * WF_GRID);
end;

{ ---- the add-node palette: double-click empty canvas, type, Enter ---- }

procedure TMasterDetailForm.WorkflowShowPalette(const CanvasPt: TPointF);
var
  ParentCtl: TControl;
  PX: Single;
  PY: Single;
begin
  if (FWorkflowCanvas = nil) or (FWorkflowCanvas.ParentControl = nil) then
    Exit;
  ParentCtl := FWorkflowCanvas.ParentControl;
  { remember WHERE the palette was summoned: the node lands at that spot,
    not in the auto-layout column -- creating at the cursor is the point }
  FWorkflowPaletteDrop := WfSnap(WfToLogical(CanvasPt));
  if FWorkflowPalettePanel = nil then
  begin
    FWorkflowPalettePanel := TRectangle.Create(Self);
    FWorkflowPalettePanel.Width := 210;
    FWorkflowPalettePanel.Height := 232;
    StyleChromeRect(FWorkflowPalettePanel, UI_PANEL, UI_BORDER, 6, False);

    FWorkflowPaletteEdit := TEdit.Create(Self);
    FWorkflowPaletteEdit.Parent := FWorkflowPalettePanel;
    FWorkflowPaletteEdit.Align := TAlignLayout.Top;
    FWorkflowPaletteEdit.Height := H_INPUT;
    FWorkflowPaletteEdit.TextPrompt := 'search tools';
    FWorkflowPaletteEdit.OnChangeTracking := WorkflowPaletteFilterChange;
    FWorkflowPaletteEdit.OnKeyDown := WorkflowPaletteEditKeyDown;
    SetControlMargins(FWorkflowPaletteEdit, GAP_S, GAP_S, GAP_S, GAP_XS);

    FWorkflowPaletteList := TListBox.Create(Self);
    FWorkflowPaletteList.Parent := FWorkflowPalettePanel;
    FWorkflowPaletteList.Align := TAlignLayout.Client;
    FWorkflowPaletteList.OnItemClick := WorkflowPaletteItemClick;
    SetControlMargins(FWorkflowPaletteList, GAP_S, 0, GAP_S, GAP_S);
  end;
  FWorkflowPalettePanel.Parent := ParentCtl;
  PX := FWorkflowCanvas.Position.X + CanvasPt.X;
  PY := FWorkflowCanvas.Position.Y + CanvasPt.Y;
  PX := Max(0, Min(PX, ParentCtl.Width - FWorkflowPalettePanel.Width));
  PY := Max(0, Min(PY, ParentCtl.Height - FWorkflowPalettePanel.Height));
  FWorkflowPalettePanel.Position.X := PX;
  FWorkflowPalettePanel.Position.Y := PY;
  FWorkflowPalettePanel.Visible := True;
  FWorkflowPalettePanel.BringToFront;
  FWorkflowPaletteEdit.Text := '';
  WorkflowPaletteRefresh;
  FWorkflowPaletteEdit.SetFocus;
end;

procedure TMasterDetailForm.WorkflowHidePalette;
begin
  if FWorkflowPalettePanel <> nil then
    FWorkflowPalettePanel.Visible := False;
end;

procedure TMasterDetailForm.WorkflowPaletteFilterChange(Sender: TObject);
begin
  WorkflowPaletteRefresh;
end;

procedure TMasterDetailForm.WorkflowPaletteRefresh;
{ The palette lists exactly what the Tool combo offers (llm / replicate /
  every gateway tool once loaded) -- one source, so the two entry paths can
  never disagree about what exists. }
var
  Filter: string;
  I: Integer;
  Name: string;
begin
  if (FWorkflowPaletteList = nil) or (FWorkflowToolCombo = nil) then
    Exit;
  Filter := LowerCase(Trim(FWorkflowPaletteEdit.Text));
  FWorkflowPaletteList.BeginUpdate;
  try
    FWorkflowPaletteList.Clear;
    for I := 0 to FWorkflowToolCombo.Items.Count - 1 do
    begin
      Name := FWorkflowToolCombo.Items[I];
      if (Filter = '') or (Pos(Filter, LowerCase(Name)) > 0) then
        FWorkflowPaletteList.Items.Add(Name);
    end;
  finally
    FWorkflowPaletteList.EndUpdate;
  end;
  if FWorkflowPaletteList.Count > 0 then
    FWorkflowPaletteList.ItemIndex := 0;
end;

procedure TMasterDetailForm.WorkflowPaletteEditKeyDown(Sender: TObject;
  var Key: Word; var KeyChar: Char; Shift: TShiftState);
begin
  if Key = vkEscape then
  begin
    WorkflowHidePalette;
    Key := 0;
  end
  else if Key = vkReturn then
  begin
    if (FWorkflowPaletteList <> nil) and
      (FWorkflowPaletteList.Selected <> nil) then
      WorkflowPaletteAdd(FWorkflowPaletteList.Selected.Text);
    Key := 0;
  end
  else if (Key = vkDown) and (FWorkflowPaletteList <> nil) and
    (FWorkflowPaletteList.ItemIndex < FWorkflowPaletteList.Count - 1) then
  begin
    FWorkflowPaletteList.ItemIndex := FWorkflowPaletteList.ItemIndex + 1;
    Key := 0;
  end
  else if (Key = vkUp) and (FWorkflowPaletteList <> nil) and
    (FWorkflowPaletteList.ItemIndex > 0) then
  begin
    FWorkflowPaletteList.ItemIndex := FWorkflowPaletteList.ItemIndex - 1;
    Key := 0;
  end;
end;

procedure TMasterDetailForm.WorkflowPaletteItemClick(
  const Sender: TCustomListBox; const Item: TListBoxItem);
begin
  if Item <> nil then
    WorkflowPaletteAdd(Item.Text);
end;

procedure TMasterDetailForm.WorkflowPaletteAdd(const Tool: string);
var
  Drop: TPointF;
  Idx: Integer;
  NewId: string;
begin
  Drop := FWorkflowPaletteDrop;
  WorkflowHidePalette;
  if (Tool = '') or (FWorkflowToolCombo = nil) then
    Exit;
  Idx := FWorkflowToolCombo.Items.IndexOf(Tool);
  if Idx < 0 then
  begin
    FWorkflowToolCombo.Items.Add(Tool);
    Idx := FWorkflowToolCombo.Items.Count - 1;
  end;
  FWorkflowToolCombo.ItemIndex := Idx;
  { the palette always creates with FRESH default args -- WorkflowToolChange
    leaves the args memo alone while a node is selected, and inheriting the
    selected node's args here would be a surprise }
  if FWorkflowNodeIdEdit <> nil then
    FWorkflowNodeIdEdit.Text := '';
  if FWorkflowNodeArgsMemo <> nil then
    FWorkflowNodeArgsMemo.Lines.Text := WorkflowDefaultArgs(Tool);
  WorkflowAddNodeClick(nil);
  { AddNodeClick leaves the generated id in the id edit; drop that node at
    the summon point instead of the auto-layout slot }
  NewId := Trim(FWorkflowNodeIdEdit.Text);
  if (NewId <> '') and (FWorkflowNodePositions <> nil) then
    FWorkflowNodePositions.AddOrSetValue(NewId, Drop);
  if FWorkflowCanvas <> nil then
    FWorkflowCanvas.Repaint;
end;

procedure TMasterDetailForm.WorkflowDuplicateSelectedNode;
var
  Args: string;
  Item: TListBoxItem;
  N: Integer;
  NewId: string;
  NewItem: TListBoxItem;
  OldId: string;
  Pos: TPointF;
  Tool: string;
begin
  if (FWorkflowNodesList = nil) or (FWorkflowNodesList.Selected = nil) then
  begin
    SetStatus('select a node to duplicate');
    Exit;
  end;
  Item := FWorkflowNodesList.Selected;
  OldId := WorkflowTextId(Item.Text);
  Tool := WorkflowTextTool(Item.Text);
  if Tool = '' then
    Tool := 'tool';
  Args := Item.TagString;
  N := 2;
  NewId := OldId + '2';
  while WorkflowNodeIndexById(NewId) >= 0 do
  begin
    Inc(N);
    NewId := OldId + N.ToString;
  end;
  NewItem := AddCardListItem(FWorkflowNodesList, NewId, Tool + ' node', Args,
    58, True);
  NewItem.Text := NewId + ' | ' + Tool;
  { a fresh copy has never run }
  if FWorkflowRunNodeOk <> nil then
    FWorkflowRunNodeOk.Remove(NewId);
  if FWorkflowRunNodePreview <> nil then
    FWorkflowRunNodePreview.Remove(NewId);
  if (FWorkflowNodePositions <> nil) and
    FWorkflowNodePositions.TryGetValue(OldId, Pos) then
  begin
    { walk the diagonal until a slot is FREE -- duplicating the same source
      twice must not stack the copies into one apparent node }
    Pos := PointF(Pos.X + WF_GRID, Pos.Y + WF_GRID);
    while WorkflowPositionTaken(Pos) do
      Pos := PointF(Pos.X + WF_GRID, Pos.Y + WF_GRID);
    FWorkflowNodePositions.AddOrSetValue(NewId, Pos);
  end;
  FWorkflowNodesList.ItemIndex := FWorkflowNodesList.Count - 1;
  WorkflowRenderGraph;
  SetStatus('duplicated ' + OldId + ' as ' + NewId);
end;

function TMasterDetailForm.WorkflowPositionTaken(const P: TPointF): Boolean;
{ True when some node/IO box already sits (within half a grid step) at the
  logical point -- the free-slot probe for duplicate placement. }
var
  Pair: TPair<string, TPointF>;
begin
  Result := False;
  if FWorkflowNodePositions = nil then
    Exit;
  for Pair in FWorkflowNodePositions do
    if (Abs(Pair.Value.X - P.X) < WF_GRID / 2) and
      (Abs(Pair.Value.Y - P.Y) < WF_GRID / 2) then
      Exit(True);
end;

procedure TMasterDetailForm.WorkflowCanvasMouseDown(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  Box: TPaintBox;
  EdgeText: string;
  FromId: string;
  I: Integer;
  MidY: Single;
  NodeItem: TListBoxItem;
  P: Integer;
  PortR: TRectF;
  R: TRectF;
  ToId: string;
begin
  if not (Sender is TPaintBox) or (FWorkflowNodesList = nil) then
    Exit;
  Box := TPaintBox(Sender);
  WorkflowHidePalette;
  FWorkflowDraggingId := '';
  FWorkflowConnectFromId := '';
  { wires are beziers now, so the hit test follows the curve }
  I := WorkflowEdgeAtPoint(X, Y, Box.Width);
  if I >= 0 then
  begin
    EdgeText := FWorkflowEdgesList.ListItems[I].Text;
    P := Pos(' -> ', EdgeText);
    FromId := Copy(EdgeText, 1, P - 1);
    ToId := Copy(EdgeText, P + 4, MaxInt);
    FWorkflowSelectedEdge := EdgeText;
    FWorkflowEdgesList.ItemIndex := I;
    if FWorkflowEdgeFromEdit <> nil then
      FWorkflowEdgeFromEdit.Text := FromId;
    if FWorkflowEdgeToEdit <> nil then
      FWorkflowEdgeToEdit.Text := ToId;
    SetStatus('selected edge ' + EdgeText);
    Box.Repaint;
    Exit;
  end;
  FWorkflowSelectedEdge := '';
  { the INPUT/OUTPUT boxes drag like nodes -- they are citizens of the same
    space now, not chrome. They cannot be connect-sources, so only the
    body hit matters. }
  R := WorkflowIORect(WF_ID_INPUT, Box.Width, Box.Height);
  if (X >= R.Left) and (X <= R.Right) and (Y >= R.Top) and (Y <= R.Bottom) then
  begin
    FWorkflowDraggingId := WF_ID_INPUT;
    FWorkflowDragOffset := PointF(X - R.Left, Y - R.Top);
    Exit;
  end;
  R := WorkflowIORect(WF_ID_OUTPUT, Box.Width, Box.Height);
  if (X >= R.Left) and (X <= R.Right) and (Y >= R.Top) and (Y <= R.Bottom) then
  begin
    FWorkflowDraggingId := WF_ID_OUTPUT;
    FWorkflowDragOffset := PointF(X - R.Left, Y - R.Top);
    Exit;
  end;
  for I := 0 to FWorkflowNodesList.Count - 1 do
  begin
    NodeItem := FWorkflowNodesList.ListItems[I];
    if NodeItem = nil then
      Continue;
    R := WorkflowCanvasNodeRect(I, Box.Width);
    if (R.Width <= 0) or (R.Height <= 0) then
      Continue;
    MidY := (R.Top + R.Bottom) / 2;
    PortR := RectF(R.Right - 12, MidY - 12, R.Right + 12, MidY + 12);
    if ((X >= PortR.Left) and (X <= PortR.Right) and (Y >= PortR.Top) and
      (Y <= PortR.Bottom)) or ((ssShift in Shift) and (X >= R.Left) and
      (X <= R.Right) and (Y >= R.Top) and (Y <= R.Bottom)) then
    begin
      if FWorkflowNodesList.ItemIndex <> I then
        FWorkflowNodesList.ItemIndex := I
      else
        WorkflowNodeSelect(nil);
      FWorkflowConnectFromId := WorkflowTextId(NodeItem.Text);
      FWorkflowConnectPoint := PointF(X, Y);
      SetStatus('drag to a target node input port');
      Box.Repaint;
      Exit;
    end;
    if (X >= R.Left) and (X <= R.Right) and (Y >= R.Top) and
      (Y <= R.Bottom) then
    begin
      if FWorkflowNodesList.ItemIndex <> I then
        FWorkflowNodesList.ItemIndex := I
      else
        WorkflowNodeSelect(nil);
      FWorkflowDraggingId := WorkflowTextId(NodeItem.Text);
      FWorkflowDragOffset := PointF(X - R.Left, Y - R.Top);
      Box.Repaint;
      Exit;
    end;
  end;
  { nothing hit: a double-click opens the add-node palette AT that spot
    (n8n/ComfyUI's primary create gesture); a single click drags the SPACE.
    ssDouble rides on the second MouseDown, which is why no OnDblClick
    handler is needed -- and it carries the coordinates OnDblClick lacks. }
  if ssDouble in Shift then
  begin
    FWorkflowPanning := False;
    WorkflowShowPalette(PointF(X, Y));
    Exit;
  end;
  FWorkflowPanning := True;
  FWorkflowPanMouse := PointF(X, Y);
  FWorkflowPanOrigin := FWorkflowPan;
end;

procedure TMasterDetailForm.WorkflowCanvasMouseMove(Sender: TObject;
  Shift: TShiftState; X, Y: Single);
var
  Box: TPaintBox;
  HoverIdx: Integer;
  HoverText: string;
  Pos: TPointF;
begin
  if not (Sender is TPaintBox) then
    Exit;
  Box := TPaintBox(Sender);
  if FWorkflowConnectFromId <> '' then
  begin
    FWorkflowConnectPoint := PointF(Max(0, X), Max(0, Y));
    Box.Repaint;
    Exit;
  end;
  if FWorkflowPanning then
  begin
    FWorkflowPan := PointF(FWorkflowPanOrigin.X + (X - FWorkflowPanMouse.X),
      FWorkflowPanOrigin.Y + (Y - FWorkflowPanMouse.Y));
    Box.Repaint;
    Exit;
  end;
  if (FWorkflowDraggingId = '') or (FWorkflowNodePositions = nil) then
  begin
    { idle: track which wire is under the cursor so it can light up --
      repaint only on a state CHANGE, so plain mouse travel stays free }
    HoverText := '';
    HoverIdx := WorkflowEdgeAtPoint(X, Y, Box.Width);
    if (HoverIdx >= 0) and (FWorkflowEdgesList <> nil) then
      HoverText := FWorkflowEdgesList.ListItems[HoverIdx].Text;
    if not SameText(HoverText, FWorkflowHoverEdge) then
    begin
      FWorkflowHoverEdge := HoverText;
      Box.Repaint;
    end;
    Exit;
  end;
  { LOGICAL position, unclamped: the old Min(Box.Width - 116, ...) was the
    wall that made the canvas feel boxed in -- there IS no edge now, and
    fit-view is the way back if something is pushed far out }
  Pos := WfToLogical(PointF(X - FWorkflowDragOffset.X,
    Y - FWorkflowDragOffset.Y));
  FWorkflowNodePositions.AddOrSetValue(FWorkflowDraggingId, Pos);
  Box.Repaint;
end;

procedure TMasterDetailForm.WorkflowCanvasMouseUp(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  Box: TPaintBox;
  Pos: TPointF;
  TargetIndex: Integer;
  TargetId: string;
begin
  FWorkflowPanning := False;
  if (FWorkflowConnectFromId <> '') and (Sender is TPaintBox) then
  begin
    Box := TPaintBox(Sender);
    TargetIndex := WorkflowNodeIndexAtPoint(X, Y, Box.Width, True);
    if TargetIndex < 0 then
      TargetIndex := WorkflowNodeIndexAtPoint(X, Y, Box.Width, False);
    if (TargetIndex >= 0) and (FWorkflowNodesList <> nil) and
      (TargetIndex < FWorkflowNodesList.Count) and
      (FWorkflowNodesList.ListItems[TargetIndex] <> nil) then
    begin
      TargetId := WorkflowTextId(FWorkflowNodesList.ListItems[TargetIndex].Text);
      if WorkflowAddEdgeByIds(FWorkflowConnectFromId, TargetId) then
        SetStatus('workflow edge connected')
      else
        SetStatus('workflow edge not added');
    end
    else
      SetStatus('workflow connect canceled');
    FWorkflowConnectFromId := '';
    Box.Repaint;
    WorkflowRenderGraph;
    Exit;
  end;

  if FWorkflowDraggingId <> '' then
  begin
    { snap the DROP to the grid (drag itself stays free -- snapping mid-drag
      makes the node stutter under the cursor) }
    if (FWorkflowNodePositions <> nil) and
      FWorkflowNodePositions.TryGetValue(FWorkflowDraggingId, Pos) then
      FWorkflowNodePositions.AddOrSetValue(FWorkflowDraggingId, WfSnap(Pos));
    FWorkflowDraggingId := '';
    WorkflowRenderGraph;
  end;
end;

procedure TMasterDetailForm.WorkflowPickerChange(Sender: TObject);
var
  Name: string;
begin
  Name := ComboSelectedText(FWorkflowPickerCombo);
  if (Name <> '') and (FWorkflowNameEdit <> nil) then
    FWorkflowNameEdit.Text := Name;
end;

procedure TMasterDetailForm.WorkflowUpdateNodeClick(Sender: TObject);
var
  EdgeItem: TListBoxItem;
  FromId: string;
  I: Integer;
  Item: TListBoxItem;
  NewId: string;
  OldId: string;
  P: Integer;
  RunOk: Boolean;
  RunPreview: string;
  ToId: string;
  Tool: string;
begin
  if (FWorkflowNodesList = nil) or (FWorkflowNodesList.Selected = nil) then
  begin
    SetStatus('select a node first');
    Exit;
  end;
  Item := FWorkflowNodesList.Selected;
  OldId := WorkflowTextId(Item.Text);
  NewId := Trim(FWorkflowNodeIdEdit.Text);
  if NewId = '' then
  begin
    SetStatus('node id is required');
    Exit;
  end;
  for I := 0 to FWorkflowNodesList.Count - 1 do
    if (FWorkflowNodesList.ListItems[I] <> Item) and
      SameText(WorkflowTextId(FWorkflowNodesList.ListItems[I].Text), NewId) then
    begin
      SetStatus('node id already exists');
      Exit;
    end;

  Tool := ComboSelectedText(FWorkflowToolCombo);
  if Tool = '' then
    Tool := WorkflowTextTool(Item.Text);
  Item.Text := NewId + ' | ' + Tool;
  Item.TagString := FWorkflowNodeArgsMemo.Lines.Text;

  if not SameText(OldId, NewId) then
  begin
    if (FWorkflowNodePositions <> nil) and
      FWorkflowNodePositions.TryGetValue(OldId, FWorkflowDragOffset) then
    begin
      FWorkflowNodePositions.Remove(OldId);
      FWorkflowNodePositions.AddOrSetValue(NewId, FWorkflowDragOffset);
    end;
    { same node, new name: its run badge travels with it }
    if (FWorkflowRunNodeOk <> nil) and
      FWorkflowRunNodeOk.TryGetValue(OldId, RunOk) then
    begin
      FWorkflowRunNodeOk.Remove(OldId);
      FWorkflowRunNodeOk.AddOrSetValue(NewId, RunOk);
    end;
    if (FWorkflowRunNodePreview <> nil) and
      FWorkflowRunNodePreview.TryGetValue(OldId, RunPreview) then
    begin
      FWorkflowRunNodePreview.Remove(OldId);
      FWorkflowRunNodePreview.AddOrSetValue(NewId, RunPreview);
    end;
    for I := 0 to FWorkflowEdgesList.Count - 1 do
    begin
      EdgeItem := FWorkflowEdgesList.ListItems[I];
      P := Pos(' -> ', EdgeItem.Text);
      if P <= 0 then
        Continue;
      FromId := Copy(EdgeItem.Text, 1, P - 1);
      ToId := Copy(EdgeItem.Text, P + 4, MaxInt);
      if SameText(FromId, OldId) then
        FromId := NewId;
      if SameText(ToId, OldId) then
        ToId := NewId;
      EdgeItem.Text := FromId + ' -> ' + ToId;
    end;
  end;

  WorkflowRenderGraph;
end;

procedure TMasterDetailForm.WorkflowDeleteNodeClick(Sender: TObject);
var
  EdgeItem: TListBoxItem;
  FromId: string;
  Id: string;
  I: Integer;
  Item: TListBoxItem;
  P: Integer;
  ToId: string;
begin
  if (FWorkflowNodesList = nil) or (FWorkflowNodesList.Selected = nil) then
    Exit;
  Item := FWorkflowNodesList.Selected;
  Id := WorkflowTextId(Item.Text);
  Item.Free;
  if FWorkflowNodePositions <> nil then
    FWorkflowNodePositions.Remove(Id);
  { the run result dies with the node -- a later node that happens to get
    the same generated id must not inherit a badge it never earned }
  if FWorkflowRunNodeOk <> nil then
    FWorkflowRunNodeOk.Remove(Id);
  if FWorkflowRunNodePreview <> nil then
    FWorkflowRunNodePreview.Remove(Id);
  for I := FWorkflowEdgesList.Count - 1 downto 0 do
  begin
    EdgeItem := FWorkflowEdgesList.ListItems[I];
    P := Pos(' -> ', EdgeItem.Text);
    if P <= 0 then
      Continue;
    FromId := Copy(EdgeItem.Text, 1, P - 1);
    ToId := Copy(EdgeItem.Text, P + 4, MaxInt);
    if SameText(FromId, Id) or SameText(ToId, Id) then
      EdgeItem.Free;
  end;
  WorkflowRenderGraph;
end;

function TMasterDetailForm.WorkflowAddEdgeByIds(const FromId,
  ToId: string): Boolean;
var
  I: Integer;
  Item: TListBoxItem;
  Text: string;
begin
  Result := False;
  if (Trim(FromId) = '') or (Trim(ToId) = '') then
  begin
    SetStatus('edge needs from and to nodes');
    Exit;
  end;
  if SameText(FromId, ToId) then
  begin
    SetStatus('edge cannot target the same node');
    Exit;
  end;
  if (WorkflowNodeIndexById(FromId) < 0) or
    (WorkflowNodeIndexById(ToId) < 0) then
  begin
    SetStatus('edge endpoint node not found');
    Exit;
  end;
  Text := FromId + ' -> ' + ToId;
  for I := 0 to FWorkflowEdgesList.Count - 1 do
    if SameText(FWorkflowEdgesList.ListItems[I].Text, Text) then
      Exit(True);
  Item := TListBoxItem.Create(FWorkflowEdgesList);
  Item.Parent := FWorkflowEdgesList;
  Item.Text := Text;
  Item.Height := ROW_FORM;
  FWorkflowEdgesList.ItemIndex := FWorkflowEdgesList.Count - 1;
  FWorkflowSelectedEdge := Text;
  if FWorkflowEdgeFromEdit <> nil then
    FWorkflowEdgeFromEdit.Text := FromId;
  if FWorkflowEdgeToEdit <> nil then
    FWorkflowEdgeToEdit.Text := ToId;
  WorkflowRenderGraph;
  Result := True;
end;

procedure TMasterDetailForm.WorkflowAddEdgeClick(Sender: TObject);
begin
  WorkflowAddEdgeByIds(Trim(FWorkflowEdgeFromEdit.Text),
    Trim(FWorkflowEdgeToEdit.Text));
end;

procedure TMasterDetailForm.WorkflowDeleteEdgeClick(Sender: TObject);
begin
  if (FWorkflowEdgesList <> nil) and (FWorkflowEdgesList.Selected <> nil) then
  begin
    FWorkflowSelectedEdge := '';
    FWorkflowEdgesList.Selected.Free;
    WorkflowRenderGraph;
  end;
end;

procedure TMasterDetailForm.WorkflowEdgeSelect(Sender: TObject);
var
  EdgeText: string;
  P: Integer;
begin
  if (FWorkflowEdgesList = nil) or (FWorkflowEdgesList.Selected = nil) then
    Exit;
  EdgeText := FWorkflowEdgesList.Selected.Text;
  P := Pos(' -> ', EdgeText);
  if P <= 0 then
    Exit;
  FWorkflowSelectedEdge := EdgeText;
  if FWorkflowEdgeFromEdit <> nil then
    FWorkflowEdgeFromEdit.Text := Copy(EdgeText, 1, P - 1);
  if FWorkflowEdgeToEdit <> nil then
    FWorkflowEdgeToEdit.Text := Copy(EdgeText, P + 4, MaxInt);
  if FWorkflowCanvas <> nil then
    FWorkflowCanvas.Repaint;
end;

function TMasterDetailForm.WorkflowBuildSpec: string;
var
  ArgsRoot: TJSONValue;
  Edge: TJSONObject;
  Edges: TJSONArray;
  EdgeText: string;
  Feedback: TJSONObject;
  FeedbackArr: TJSONArray;
  FromId: string;
  HasLoop: Boolean;
  I: Integer;
  Input: TJSONObject;
  InputName: string;
  Inputs: TArray<string>;
  InputsArr: TJSONArray;
  Item: TListBoxItem;
  KeyName: string;
  LineText: string;
  UiObj: TJSONObject;
  Lines: TArray<string>;
  LoopObj: TJSONObject;
  Name: string;
  Node: TJSONObject;
  NodeId: string;
  Nodes: TJSONArray;
  NodePos: TPointF;
  Output: TJSONObject;
  OutputName: string;
  OutputsArr: TJSONArray;
  OutputValue: string;
  P: Integer;
  Spec: TJSONObject;
  ToId: string;
  ValueText: string;
begin
  Name := Trim(FWorkflowNameEdit.Text);
  if Name = '' then
    raise Exception.Create('workflow name is required');

  Spec := TJSONObject.Create;
  InputsArr := TJSONArray.Create;
  Nodes := TJSONArray.Create;
  Edges := TJSONArray.Create;
  OutputsArr := nil;
  LoopObj := nil;
  FeedbackArr := nil;
  try
    Spec.AddPair('name', Name);
    Spec.AddPair('description', FWorkflowDescEdit.Text);
    if (FWorkflowOutputDirEdit <> nil) and
       (Trim(FWorkflowOutputDirEdit.Text) <> '') then
      Spec.AddPair('output_dir', Trim(FWorkflowOutputDirEdit.Text));

    Inputs := FWorkflowInputsEdit.Text.Split([',']);
    for I := 0 to Length(Inputs) - 1 do
    begin
      InputName := Trim(Inputs[I]);
      if InputName = '' then
        Continue;
      Input := TJSONObject.Create;
      Input.AddPair('name', InputName);
      Input.AddPair('type', 'string');
      AddJsonBool(Input, 'required', True);
      InputsArr.AddElement(Input);
    end;

    OutputsArr := TJSONArray.Create;
    if FWorkflowOutputsMemo <> nil then
    begin
      Lines := FWorkflowOutputsMemo.Lines.Text.Replace(#13#10, #10).
        Replace(#13, #10).Split([#10]);
      for I := 0 to Length(Lines) - 1 do
      begin
        LineText := Trim(Lines[I]);
        if LineText = '' then
          Continue;
        P := Pos('=', LineText);
        if P > 0 then
        begin
          OutputName := Trim(Copy(LineText, 1, P - 1));
          OutputValue := Trim(Copy(LineText, P + 1, MaxInt));
        end
        else
        begin
          OutputName := LineText;
          OutputValue := '';
        end;
        if OutputName = '' then
          Continue;
        Output := TJSONObject.Create;
        Output.AddPair('name', OutputName);
        Output.AddPair('value', OutputValue);
        Output.AddPair('type', 'string');
        OutputsArr.AddElement(Output);
      end;
    end;

    LoopObj := TJSONObject.Create;
    LoopObj.AddPair('max', TJSONNumber.Create(1));
    FeedbackArr := TJSONArray.Create;
    HasLoop := False;
    if FWorkflowLoopMemo <> nil then
    begin
      Lines := FWorkflowLoopMemo.Lines.Text.Replace(#13#10, #10).
        Replace(#13, #10).Split([#10]);
      for I := 0 to Length(Lines) - 1 do
      begin
        LineText := Trim(Lines[I]);
        if LineText = '' then
          Continue;
        P := Pos('=', LineText);
        if P > 0 then
        begin
          KeyName := LowerCase(Trim(Copy(LineText, 1, P - 1)));
          ValueText := Trim(Copy(LineText, P + 1, MaxInt));
          if SameText(KeyName, 'max') then
          begin
            LoopObj.RemovePair('max').Free;
            LoopObj.AddPair('max', TJSONNumber.Create(Max(1,
              StrToIntDef(ValueText, 1))));
            HasLoop := True;
          end
          else if SameText(KeyName, 'until') and (ValueText <> '') then
          begin
            LoopObj.AddPair('until', ValueText);
            HasLoop := True;
          end;
          Continue;
        end;
        P := Pos('->', LineText);
        if P > 0 then
        begin
          OutputName := Trim(Copy(LineText, 1, P - 1));
          InputName := Trim(Copy(LineText, P + 2, MaxInt));
          if (OutputName <> '') and (InputName <> '') then
          begin
            Feedback := TJSONObject.Create;
            Feedback.AddPair('output', OutputName);
            Feedback.AddPair('input', InputName);
            FeedbackArr.AddElement(Feedback);
            HasLoop := True;
          end;
        end;
      end;
    end;

    for I := 0 to FWorkflowNodesList.Count - 1 do
    begin
      Item := FWorkflowNodesList.ListItems[I];
      NodeId := WorkflowTextId(Item.Text);
      Node := TJSONObject.Create;
      ArgsRoot := nil;
      try
        Node.AddPair('id', NodeId);
        Node.AddPair('tool', WorkflowTextTool(Item.Text));
        ArgsRoot := TJSONObject.ParseJSONValue(Item.TagString);
        if not (ArgsRoot is TJSONObject) then
          raise Exception.CreateFmt('node "%s" args must be a JSON object',
            [NodeId]);
        Node.AddPair('args', ArgsRoot);
        ArgsRoot := nil;
        WorkflowEnsureNodePosition(NodeId, I,
          IfThen(FWorkflowCanvas <> nil, FWorkflowCanvas.Width, 360));
        if not FWorkflowNodePositions.TryGetValue(NodeId, NodePos) then
          NodePos := PointF(20 + (I mod 4) * 150, 20 + (I div 4) * 78);
        Node.AddPair('x', TJSONNumber.Create(Round(NodePos.X)));
        Node.AddPair('y', TJSONNumber.Create(Round(NodePos.Y)));
        Nodes.AddElement(Node);
        { node x/y ride on the node itself -- the web client's existing
          convention; the ui block below carries what has no node to ride }
        Node := nil;
      finally
        ArgsRoot.Free;
        Node.Free;
      end;
    end;

    for I := 0 to FWorkflowEdgesList.Count - 1 do
    begin
      EdgeText := FWorkflowEdgesList.ListItems[I].Text;
      P := Pos(' -> ', EdgeText);
      if P <= 0 then
        Continue;
      FromId := Trim(Copy(EdgeText, 1, P - 1));
      ToId := Trim(Copy(EdgeText, P + 4, MaxInt));
      if (FromId = '') or (ToId = '') then
        Continue;
      Edge := TJSONObject.Create;
      Edge.AddPair('from', FromId);
      Edge.AddPair('to', ToId);
      Edges.AddElement(Edge);
    end;

    Spec.AddPair('inputs', InputsArr);
    InputsArr := nil;
    if (OutputsArr <> nil) and (OutputsArr.Count > 0) then
    begin
      Spec.AddPair('outputs', OutputsArr);
      OutputsArr := nil;
    end;
    Spec.AddPair('nodes', Nodes);
    { view state: pan + the movable INPUT/OUTPUT box positions. Nodes carry
      their own x/y (the web convention); these have no node to ride on. }
    UiObj := TJSONObject.Create;
    UiObj.AddPair('pan_x', TJSONNumber.Create(Round(FWorkflowPan.X)));
    UiObj.AddPair('pan_y', TJSONNumber.Create(Round(FWorkflowPan.Y)));
    if FWorkflowNodePositions.TryGetValue(WF_ID_INPUT, NodePos) then
    begin
      UiObj.AddPair('in_x', TJSONNumber.Create(Round(NodePos.X)));
      UiObj.AddPair('in_y', TJSONNumber.Create(Round(NodePos.Y)));
    end;
    if FWorkflowNodePositions.TryGetValue(WF_ID_OUTPUT, NodePos) then
    begin
      UiObj.AddPair('out_x', TJSONNumber.Create(Round(NodePos.X)));
      UiObj.AddPair('out_y', TJSONNumber.Create(Round(NodePos.Y)));
    end;
    Spec.AddPair('ui', UiObj);
    Nodes := nil;
    Spec.AddPair('edges', Edges);
    Edges := nil;
    if LoopObj <> nil then
    begin
      if FeedbackArr <> nil then
      begin
        LoopObj.AddPair('feedback', FeedbackArr);
        FeedbackArr := nil;
      end;
      if HasLoop then
      begin
        Spec.AddPair('loop', LoopObj);
        LoopObj := nil;
      end;
    end;
    Result := Spec.ToJSON;
  finally
    FeedbackArr.Free;
    LoopObj.Free;
    OutputsArr.Free;
    Edges.Free;
    Nodes.Free;
    InputsArr.Free;
    Spec.Free;
  end;
end;

procedure TMasterDetailForm.WorkflowSetSpecFromJson(const JsonText: string);
var
  Arr: TJSONArray;
  Builder: TStringBuilder;
  FeedbackObj: TJSONObject;
  I: Integer;
  InputName: string;
  Item: TListBoxItem;
  LineText: string;
  NodeId: string;
  NodeObj: TJSONObject;
  Obj: TJSONObject;
  OutputName: string;
  OutputValue: string;
  Root: TJSONValue;
  SpecObj: TJSONObject;
  Value: TJSONValue;
  XValue: TJSONValue;
  YValue: TJSONValue;
begin
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    SpecObj := TJSONObject(Root);
    Value := SpecObj.GetValue('workflow');
    if Value is TJSONObject then
      SpecObj := TJSONObject(Value);
    Value := SpecObj.GetValue('data');
    if Value is TJSONObject then
      SpecObj := TJSONObject(Value);

    FWorkflowNameEdit.Text := JsonAsString(SpecObj, 'name');
    if FWorkflowNameEdit.Text = '' then
      FWorkflowNameEdit.Text := JsonAsString(SpecObj, 'id');
    FWorkflowDescEdit.Text := JsonAsString(SpecObj, 'description');
    if FWorkflowOutputDirEdit <> nil then
      FWorkflowOutputDirEdit.Text := JsonAsString(SpecObj, 'output_dir');
    FWorkflowInputsEdit.Text := '';
    if FWorkflowOutputsMemo <> nil then
      FWorkflowOutputsMemo.Lines.Clear;
    if FWorkflowLoopMemo <> nil then
      FWorkflowLoopMemo.Lines.Clear;
    FWorkflowNodesList.Clear;
    FWorkflowEdgesList.Clear;
    if FWorkflowNodePositions <> nil then
      FWorkflowNodePositions.Clear;
    { run badges belong to a RUN, not the freshly loaded spec }
    if FWorkflowRunNodeOk <> nil then
      FWorkflowRunNodeOk.Clear;
    if FWorkflowRunNodePreview <> nil then
      FWorkflowRunNodePreview.Clear;
    FWorkflowHoverEdge := '';
    { restore the view AFTER the wipe -- an earlier draft restored first and
      the Clear silently discarded it. Missing ui (older files, web saves)
      keeps the defaults, which reproduce the old fixed layout. }
    FWorkflowPan := PointF(0, 0);
    Value := SpecObj.GetValue('ui');
    if Value is TJSONObject then
    begin
      FWorkflowPan := PointF(
        JsonAsInt64(TJSONObject(Value), 'pan_x'),
        JsonAsInt64(TJSONObject(Value), 'pan_y'));
      if TJSONObject(Value).GetValue('in_x') <> nil then
        FWorkflowNodePositions.AddOrSetValue(WF_ID_INPUT, PointF(
          JsonAsInt64(TJSONObject(Value), 'in_x'),
          JsonAsInt64(TJSONObject(Value), 'in_y')));
      if TJSONObject(Value).GetValue('out_x') <> nil then
        FWorkflowNodePositions.AddOrSetValue(WF_ID_OUTPUT, PointF(
          JsonAsInt64(TJSONObject(Value), 'out_x'),
          JsonAsInt64(TJSONObject(Value), 'out_y')));
    end;
    FWorkflowDraggingId := '';
    FWorkflowConnectFromId := '';

    Builder := TStringBuilder.Create;
    try
      Value := SpecObj.GetValue('inputs');
      if Value is TJSONArray then
      begin
        Arr := TJSONArray(Value);
        for I := 0 to Arr.Count - 1 do
        begin
          if Arr.Items[I] is TJSONObject then
            InputName := JsonAsString(TJSONObject(Arr.Items[I]), 'name')
          else
            InputName := Arr.Items[I].Value;
          if InputName = '' then
            Continue;
          if Builder.Length > 0 then
            Builder.Append(', ');
          Builder.Append(InputName);
        end;
      end;
      if Builder.Length = 0 then
        Builder.Append('prompt');
      FWorkflowInputsEdit.Text := Builder.ToString;

      Builder.Clear;
      Builder.Append('{');
      Value := SpecObj.GetValue('inputs');
      if Value is TJSONArray then
      begin
        Arr := TJSONArray(Value);
        for I := 0 to Arr.Count - 1 do
        begin
          if Arr.Items[I] is TJSONObject then
            InputName := JsonAsString(TJSONObject(Arr.Items[I]), 'name')
          else
            InputName := Arr.Items[I].Value;
          if InputName = '' then
            Continue;
          if Builder.Length > 1 then
            Builder.Append(',');
          Builder.Append(sLineBreak + '  "' + InputName + '": ""');
        end;
      end;
      if Builder.Length = 1 then
        Builder.Append(sLineBreak + '  "prompt": ""');
      Builder.Append(sLineBreak + '}');
      FWorkflowRunInputsMemo.Lines.Text := Builder.ToString;

      Builder.Clear;
      Value := SpecObj.GetValue('outputs');
      if (FWorkflowOutputsMemo <> nil) and (Value is TJSONArray) then
      begin
        Arr := TJSONArray(Value);
        for I := 0 to Arr.Count - 1 do
        begin
          OutputName := '';
          OutputValue := '';
          if Arr.Items[I] is TJSONObject then
          begin
            OutputName := JsonAsString(TJSONObject(Arr.Items[I]), 'name');
            OutputValue := JsonAsString(TJSONObject(Arr.Items[I]), 'value');
          end
          else
            OutputName := Arr.Items[I].Value;
          if OutputName = '' then
            Continue;
          if Builder.Length > 0 then
            Builder.AppendLine;
          if OutputValue <> '' then
            Builder.Append(OutputName + ' = ' + OutputValue)
          else
            Builder.Append(OutputName);
        end;
        FWorkflowOutputsMemo.Lines.Text := Builder.ToString;
      end;

      Builder.Clear;
      Value := SpecObj.GetValue('loop');
      if (FWorkflowLoopMemo <> nil) and (Value is TJSONObject) then
      begin
        Obj := TJSONObject(Value);
        Value := Obj.GetValue('max');
        if Value <> nil then
          Builder.AppendLine('max = ' + Value.Value);
        OutputValue := JsonAsString(Obj, 'until');
        if OutputValue <> '' then
          Builder.AppendLine('until = ' + OutputValue);
        Value := Obj.GetValue('feedback');
        if Value is TJSONArray then
        begin
          Arr := TJSONArray(Value);
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              FeedbackObj := TJSONObject(Arr.Items[I]);
              OutputName := JsonAsString(FeedbackObj, 'output');
              InputName := JsonAsString(FeedbackObj, 'input');
              if (OutputName <> '') and (InputName <> '') then
              begin
                LineText := OutputName + ' -> ' + InputName;
                if Builder.Length > 0 then
                  Builder.AppendLine;
                Builder.Append(LineText);
              end;
            end;
        end;
        FWorkflowLoopMemo.Lines.Text := Builder.ToString;
      end;
    finally
      Builder.Free;
    end;

    Value := SpecObj.GetValue('nodes');
    if Value is TJSONArray then
    begin
      Arr := TJSONArray(Value);
      for I := 0 to Arr.Count - 1 do
        if Arr.Items[I] is TJSONObject then
        begin
          NodeObj := TJSONObject(Arr.Items[I]);
          NodeId := JsonAsString(NodeObj, 'id');
          Value := NodeObj.GetValue('args');
          if Value <> nil then
            LineText := Value.ToJSON
          else
            LineText := '{}';
          Item := AddCardListItem(FWorkflowNodesList, NodeId,
            JsonAsString(NodeObj, 'tool') + ' node', LineText, 58, False);
          Item.Text := NodeId + ' | ' + JsonAsString(NodeObj, 'tool');
          XValue := NodeObj.GetValue('x');
          YValue := NodeObj.GetValue('y');
          if (NodeId <> '') and (XValue <> nil) and (YValue <> nil) then
            FWorkflowNodePositions.AddOrSetValue(NodeId, PointF(
              Max(0, StrToFloatDef(XValue.Value, 0)),
              Max(0, StrToFloatDef(YValue.Value, 0))))
          else
            WorkflowEnsureNodePosition(NodeId, I,
              IfThen(FWorkflowCanvas <> nil, FWorkflowCanvas.Width, 360));
        end;
    end;

    Value := SpecObj.GetValue('edges');
    if Value is TJSONArray then
    begin
      Arr := TJSONArray(Value);
      for I := 0 to Arr.Count - 1 do
        if Arr.Items[I] is TJSONObject then
        begin
          Obj := TJSONObject(Arr.Items[I]);
          Item := TListBoxItem.Create(FWorkflowEdgesList);
          Item.Parent := FWorkflowEdgesList;
          Item.Text := JsonAsString(Obj, 'from') + ' -> ' +
            JsonAsString(Obj, 'to');
          Item.Height := ROW_FORM;
        end;
    end;
  finally
    Root.Free;
  end;
  WorkflowRenderGraph;
end;

procedure TMasterDetailForm.WorkflowSaveClick(Sender: TObject);
var
  Body: string;
begin
  try
    Body := WorkflowBuildSpec;
  except
    on E: Exception do
    begin
      SetStatus('workflow save blocked: ' + E.Message);
      Exit;
    end;
  end;
  if FEndpointBodyMemos.ContainsKey('workflow') then
    FEndpointBodyMemos['workflow'].Lines.Text := Body;
  SetStatus('saving workflow...');
  FetchEndpoint('workflow', 'POST', '/v1/workflows', Body);
end;

procedure TMasterDetailForm.WorkflowLoadClick(Sender: TObject);
var
  Base: string;
  Name: string;
  Token: string;
  SessionId: string;
begin
  Name := Trim(FWorkflowNameEdit.Text);
  if Name = '' then
  begin
    Base := GatewayBaseUrl;
    Token := FTokenEdit.Text;
    SessionId := FActiveSessionId;
    SetStatus('loading workflow list...');
    TTask.Run(
      procedure
      var
        Arr: TJSONArray;
        ErrorText: string;
        I: Integer;
        Item: TJSONValue;
        ItemName: string;
        Names: TArray<string>;
        NamesList: TList<string>;
        Obj: TJSONObject;
        ResponseText: string;
        Root: TJSONValue;
        Status: Integer;
        Value: TJSONValue;
      begin
        NamesList := TList<string>.Create;
        try
          try
            ResponseText := HttpText(Base, Token, SessionId, 'GET',
              '/v1/workflows', '', '', 'application/json', Status);
            if not IsHttpOk(Status) then
              raise Exception.CreateFmt('workflow list HTTP %d: %s', [Status,
                ResponseText]);
            Root := TJSONObject.ParseJSONValue(ResponseText);
            try
              if Root is TJSONObject then
              begin
                Value := TJSONObject(Root).GetValue('workflows');
                if Value is TJSONArray then
                begin
                  Arr := TJSONArray(Value);
                  for I := 0 to Arr.Count - 1 do
                  begin
                    Item := Arr.Items[I];
                    if Item is TJSONObject then
                    begin
                      Obj := TJSONObject(Item);
                      ItemName := JsonAsString(Obj, 'id');
                      if ItemName = '' then
                        ItemName := JsonAsString(Obj, 'name');
                    end
                    else
                      ItemName := Item.Value;
                    if (ItemName <> '') and not NamesList.Contains(ItemName) then
                      NamesList.Add(ItemName);
                  end;
                end;
              end;
            finally
              Root.Free;
            end;
          except
            on E: Exception do
              ErrorText := E.Message;
          end;
          Names := NamesList.ToArray;
        finally
          NamesList.Free;
        end;

        TThread.Queue(nil,
          procedure
          var
            I: Integer;
            Memo: TMemo;
          begin
            if ErrorText <> '' then
            begin
              SetStatus('workflow list failed: ' + ErrorText);
              Exit;
            end;
            if FWorkflowPickerCombo <> nil then
            begin
              FWorkflowPickerCombo.OnChange := nil;
              FWorkflowPickerCombo.Items.BeginUpdate;
              try
                FWorkflowPickerCombo.Items.Clear;
                for I := 0 to Length(Names) - 1 do
                  FWorkflowPickerCombo.Items.Add(Names[I]);
                if FWorkflowPickerCombo.Items.Count > 0 then
                  FWorkflowPickerCombo.ItemIndex := 0;
              finally
                FWorkflowPickerCombo.Items.EndUpdate;
                FWorkflowPickerCombo.OnChange := WorkflowPickerChange;
              end;
              WorkflowPickerChange(nil);
            end;
            if FPaneMemos.TryGetValue('workflow', Memo) then
              Memo.Lines.Text := 'GET /v1/workflows' + sLineBreak +
                'HTTP ' + Status.ToString + sLineBreak + sLineBreak +
                ResponseText;
            SetStatus('workflow list loaded');
          end);
      end);
    Exit;
  end;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('loading workflow...');
  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET',
          '/v1/workflows/' + UrlEncode(Name), '', '', 'application/json',
          Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('workflow HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;
      TThread.Queue(nil,
        procedure
        var
          Memo: TMemo;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('workflow load failed: ' + ErrorText);
            Exit;
          end;
          WorkflowSetSpecFromJson(ResponseText);
          if FPaneMemos.TryGetValue('workflow', Memo) then
            Memo.Lines.Text := 'GET /v1/workflows/' + Name + sLineBreak +
              'HTTP ' + Status.ToString + sLineBreak + sLineBreak +
              ResponseText;
          SetStatus('workflow loaded');
        end);
    end);
end;

procedure TMasterDetailForm.WorkflowDeleteClick(Sender: TObject);
var
  Name: string;
begin
  Name := Trim(FWorkflowNameEdit.Text);
  if Name = '' then
  begin
    WorkflowNewClick(nil);
    Exit;
  end;
  SetStatus('deleting workflow...');
  FetchEndpoint('workflow', 'DELETE', '/v1/workflows/' + UrlEncode(Name), '');
end;

procedure TMasterDetailForm.WorkflowRunInputsClick(Sender: TObject);
var
  Added: Boolean;
  ExistingObj: TJSONObject;
  ExistingRoot: TJSONValue;
  ExistingValue: TJSONValue;
  I: Integer;
  InputName: string;
  Inputs: TArray<string>;
  NewValue: TJSONValue;
  Obj: TJSONObject;
begin
  if (FWorkflowInputsEdit = nil) or (FWorkflowRunInputsMemo = nil) then
    Exit;

  ExistingRoot := TJSONObject.ParseJSONValue(FWorkflowRunInputsMemo.Lines.Text);
  Obj := TJSONObject.Create;
  try
    ExistingObj := nil;
    if ExistingRoot is TJSONObject then
      ExistingObj := TJSONObject(ExistingRoot);
    Added := False;
    Inputs := FWorkflowInputsEdit.Text.Split([',']);
    for I := 0 to Length(Inputs) - 1 do
    begin
      InputName := Trim(Inputs[I]);
      if InputName = '' then
        Continue;
      ExistingValue := nil;
      if ExistingObj <> nil then
        ExistingValue := ExistingObj.GetValue(InputName);
      NewValue := CloneJsonValue(ExistingValue);
      if NewValue = nil then
        NewValue := TJSONString.Create('');
      Obj.AddPair(InputName, NewValue);
      Added := True;
    end;
    if not Added then
      Obj.AddPair('prompt', '');
    FWorkflowRunInputsMemo.Lines.Text := Obj.ToJSON;
    SetStatus('workflow run inputs refreshed');
  finally
    Obj.Free;
    ExistingRoot.Free;
  end;
end;

procedure TMasterDetailForm.WorkflowRunClick(Sender: TObject);
var
  Body: string;
  Name: string;
  Root: TJSONValue;
begin
  Name := Trim(FWorkflowNameEdit.Text);
  if Name = '' then
  begin
    SetStatus('save or name the workflow first');
    Exit;
  end;
  Body := Trim(FWorkflowRunInputsMemo.Lines.Text);
  if Body = '' then
    Body := '{}';
  Root := TJSONObject.ParseJSONValue(Body);
  try
    if not (Root is TJSONObject) then
    begin
      SetStatus('workflow inputs must be a JSON object');
      Exit;
    end;
  finally
    Root.Free;
  end;
  if FEndpointBodyMemos.ContainsKey('workflow') then
    FEndpointBodyMemos['workflow'].Lines.Text := Body;
  SetStatus('running workflow...');
  FetchEndpoint('workflow', 'POST', '/v1/workflows/' + UrlEncode(Name) + '/run',
    Body);
end;

procedure TMasterDetailForm.WorkflowLoadToolsClick(Sender: TObject);
var
  Base: string;
  Token: string;
  SessionId: string;
begin
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('loading workflow tools...');
  TTask.Run(
    procedure
    var
      Arr: TJSONArray;
      ErrorText: string;
      I: Integer;
      Item: TJSONValue;
      Name: string;
      Names: TArray<string>;
      NamesList: TList<string>;
      Obj: TJSONObject;
      ResponseText: string;
      Root: TJSONValue;
      Status: Integer;
      Value: TJSONValue;
    begin
      NamesList := TList<string>.Create;
      try
        NamesList.Add('llm');
        NamesList.Add('replicate');
        try
          ResponseText := HttpText(Base, Token, SessionId, 'GET',
            '/v1/mcp/tools', '', '', 'application/json', Status);
          if not IsHttpOk(Status) then
            raise Exception.CreateFmt('tools HTTP %d: %s', [Status,
              ResponseText]);
          Root := TJSONObject.ParseJSONValue(ResponseText);
          try
            Arr := nil;
            if Root is TJSONObject then
            begin
              Obj := TJSONObject(Root);
              Value := Obj.GetValue('tools');
              if Value is TJSONArray then
                Arr := TJSONArray(Value);
              if Arr = nil then
              begin
                Value := Obj.GetValue('data');
                if Value is TJSONArray then
                  Arr := TJSONArray(Value);
              end;
              if Arr = nil then
              begin
                Value := Obj.GetValue('result');
                if Value is TJSONObject then
                begin
                  Value := TJSONObject(Value).GetValue('tools');
                  if Value is TJSONArray then
                    Arr := TJSONArray(Value);
                end;
              end;
            end;
            if Arr <> nil then
              for I := 0 to Arr.Count - 1 do
              begin
                Item := Arr.Items[I];
                if Item is TJSONObject then
                  Name := JsonAsString(TJSONObject(Item), 'name')
                else
                  Name := Item.Value;
                if (Name <> '') and not NamesList.Contains(Name) then
                  NamesList.Add(Name);
              end;
          finally
            Root.Free;
          end;
        except
          on E: Exception do
            ErrorText := E.Message;
        end;
        Names := NamesList.ToArray;
      finally
        NamesList.Free;
      end;

      TThread.Queue(nil,
        procedure
        var
          Arr: TJSONArray;
          I: Integer;
          Item: TJSONValue;
          Memo: TMemo;
          Name: string;
          Obj: TJSONObject;
          Prior: string;
          Root: TJSONValue;
          Value: TJSONValue;
        begin
          if FWorkflowToolCombo = nil then
            Exit;
          if ErrorText = '' then
          begin
            if FWorkflowToolSchemas <> nil then
              FWorkflowToolSchemas.Clear;
            Root := TJSONObject.ParseJSONValue(ResponseText);
            try
              Arr := nil;
              if Root is TJSONObject then
              begin
                Value := TJSONObject(Root).GetValue('tools');
                if Value is TJSONArray then
                  Arr := TJSONArray(Value);
                if Arr = nil then
                begin
                  Value := TJSONObject(Root).GetValue('data');
                  if Value is TJSONArray then
                    Arr := TJSONArray(Value);
                end;
              end;
              if Arr <> nil then
                for I := 0 to Arr.Count - 1 do
                begin
                  Item := Arr.Items[I];
                  if Item is TJSONObject then
                  begin
                    Obj := TJSONObject(Item);
                    Name := JsonAsString(Obj, 'name');
                    Value := Obj.GetValue('schema');
                    if (Name <> '') and (Value <> nil) and
                      (FWorkflowToolSchemas <> nil) then
                      FWorkflowToolSchemas.AddOrSetValue(Name,
                        JsonPretty(Value));
                  end;
                end;
            finally
              Root.Free;
            end;
          end;
          Prior := ComboSelectedText(FWorkflowToolCombo);
          FWorkflowToolCombo.Items.BeginUpdate;
          try
            FWorkflowToolCombo.Items.Clear;
            for I := 0 to Length(Names) - 1 do
              FWorkflowToolCombo.Items.Add(Names[I]);
            FWorkflowToolCombo.ItemIndex := FWorkflowToolCombo.Items.IndexOf(Prior);
            if FWorkflowToolCombo.ItemIndex < 0 then
              FWorkflowToolCombo.ItemIndex := 0;
          finally
            FWorkflowToolCombo.Items.EndUpdate;
          end;
          if FPaneMemos.TryGetValue('workflow', Memo) then
          begin
            if ErrorText <> '' then
              Memo.Lines.Text := 'GET /v1/mcp/tools' + sLineBreak +
                'Error: ' + ErrorText
            else
              Memo.Lines.Text := 'GET /v1/mcp/tools' + sLineBreak +
                'HTTP ' + Status.ToString + sLineBreak + sLineBreak +
                ResponseText;
          end;
          if ErrorText <> '' then
            SetStatus('tools unavailable: ' + ErrorText)
          else
            SetStatus('workflow tools loaded');
        end);
    end);
end;

procedure TMasterDetailForm.ChatCodeCopyClick(Sender: TObject);
{ Copy button on a chat code block. The code rides in the button's TagString
  so each block needs no per-instance handler. }
var
  Clipboard: IFMXClipboardService;
  CodeText: string;
begin
  CodeText := '';
  if Sender is TButton then
    CodeText := TButton(Sender).TagString;
  if Trim(CodeText) = '' then
  begin
    SetStatus('nothing to copy');
    Exit;
  end;
  if TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService,
    IInterface(Clipboard)) then
  begin
    Clipboard.SetClipboard(TValue.From<string>(CodeText));
    SetStatus('code copied');
  end
  else
    SetStatus('clipboard service unavailable');
end;

procedure TMasterDetailForm.WorkflowRunResultCopyClick(Sender: TObject);
var
  Clipboard: IFMXClipboardService;
begin
  if (FWorkflowRunDetailMemo = nil) or
    (Trim(FWorkflowRunDetailMemo.Lines.Text) = '') then
  begin
    SetStatus('no workflow result detail to copy');
    Exit;
  end;
  if TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService,
    IInterface(Clipboard)) then
  begin
    Clipboard.SetClipboard(TValue.From<string>(FWorkflowRunDetailMemo.Lines.Text));
    SetStatus('workflow result copied');
  end
  else
    SetStatus('clipboard service unavailable');
end;

procedure TMasterDetailForm.WorkflowRunResultSelect(Sender: TObject);
var
  Detail: string;
  Root: TJSONValue;
begin
  if (FWorkflowRunResultsList = nil) or (FWorkflowRunResultsList.Selected = nil) or
    (FWorkflowRunDetailMemo = nil) then
    Exit;
  Detail := FWorkflowRunResultsList.Selected.TagString;
  { the Output-files card carries an action, not a payload: jump to the
    folder in the Files tab }
  if Detail.StartsWith('opendir' + #9) then
  begin
    OpenFilesTabAt(Copy(Detail, Length('opendir' + #9) + 1, MaxInt));
    Exit;
  end;
  if Trim(Detail) = '' then
    Detail := FWorkflowRunResultsList.Selected.Text;
  Root := TJSONObject.ParseJSONValue(Detail);
  try
    if Root <> nil then
      Detail := JsonPretty(Root);
  finally
    Root.Free;
  end;
  FWorkflowRunDetailMemo.Lines.Text := Detail;
  SetStatus('workflow result selected');
end;

procedure TMasterDetailForm.WorkflowRenderRunResult(const JsonText: string;
  Status: Integer);
var
  Arr: TJSONArray;
  Detail: string;
  I: Integer;
  Obj: TJSONObject;
  P: Integer;
  Root: TJSONValue;
  Row: TJSONObject;
  Title: string;
  Value: TJSONValue;
begin
  if FWorkflowRunResultsList = nil then
    Exit;
  FWorkflowRunResultsList.Clear;
  { per-node canvas badges reset with every run render -- stale ticks from
    the previous run would claim nodes this run never reached }
  if FWorkflowRunNodeOk <> nil then
    FWorkflowRunNodeOk.Clear;
  if FWorkflowRunNodePreview <> nil then
    FWorkflowRunNodePreview.Clear;
  if FWorkflowRunStatusLabel <> nil then
    FWorkflowRunStatusLabel.Text := 'Run results - HTTP ' + Status.ToString;

  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
    begin
      AddCardListItem(FWorkflowRunResultsList, 'Run response',
        Copy(Trim(JsonText), 1, 220), JsonText, 66, False);
      Exit;
    end;

    Obj := TJSONObject(Root);
    if JsonAsBool(Obj, 'ok') then
      Title := 'Workflow completed'
    else
      Title := 'Workflow failed';
    Detail := JsonAsString(Obj, 'error');
    if Detail = '' then
      Detail := JsonAsString(Obj, 'output');
    if Detail = '' then
      Detail := 'No top-level output returned.';
    AddCardListItem(FWorkflowRunResultsList, Title, Copy(Detail, 1, 220),
      JsonText, 64, JsonAsBool(Obj, 'ok'));

    { the engine reports where it wrote this run's outputs; make the folder
      one click away instead of a path to retype in the Files tab }
    if JsonAsString(Obj, 'output_dir') <> '' then
      AddCardListItem(FWorkflowRunResultsList, 'Output files',
        JsonAsString(Obj, 'output_dir'),
        'opendir' + #9 + JsonAsString(Obj, 'output_dir'), 54, True)
    else if JsonAsString(Obj, 'output_dir_error') <> '' then
      AddCardListItem(FWorkflowRunResultsList, 'Output files not written',
        JsonAsString(Obj, 'output_dir_error'), '', 54, False);

    Value := Obj.GetValue('nodes');
    if Value is TJSONArray then
    begin
      Arr := TJSONArray(Value);
      for I := 0 to Arr.Count - 1 do
        if Arr.Items[I] is TJSONObject then
        begin
          Row := TJSONObject(Arr.Items[I]);
          Title := JsonAsString(Row, 'node');
          if Title = '' then
            Title := 'node ' + (I + 1).ToString;
          if JsonAsString(Row, 'tool') <> '' then
            Title := Title + ' - ' + JsonAsString(Row, 'tool');
          Detail := JsonAsString(Row, 'error');
          if Detail = '' then
            Detail := JsonAsString(Row, 'text');
          if Detail = '' then
            Detail := IfThen(JsonAsBool(Row, 'ok'), 'OK', 'No result text');
          AddCardListItem(FWorkflowRunResultsList, Title, Copy(Detail, 1, 220),
            Row.ToJSON, 64, JsonAsBool(Row, 'ok'));
          { feed the canvas badges: status + the first line of output }
          if (JsonAsString(Row, 'node') <> '') and
            (FWorkflowRunNodeOk <> nil) then
          begin
            FWorkflowRunNodeOk.AddOrSetValue(JsonAsString(Row, 'node'),
              JsonAsBool(Row, 'ok'));
            Detail := Trim(Detail);
            P := Pos(#10, Detail);
            if P > 0 then
              Detail := Trim(Copy(Detail, 1, P - 1));
            if Length(Detail) > 34 then
              Detail := Copy(Detail, 1, 31) + '...';
            if FWorkflowRunNodePreview <> nil then
              FWorkflowRunNodePreview.AddOrSetValue(JsonAsString(Row, 'node'),
                Detail);
          end;
        end;
    end;
    if FWorkflowRunResultsList.Count > 0 then
    begin
      FWorkflowRunResultsList.ItemIndex := 0;
      WorkflowRunResultSelect(FWorkflowRunResultsList);
    end;
  finally
    Root.Free;
  end;
  if FWorkflowCanvas <> nil then
    FWorkflowCanvas.Repaint;
end;

procedure TMasterDetailForm.WorkflowRenderGraph;
var
  I: Integer;
  NodeId: string;
  Pos: TPointF;
  Text: TStringBuilder;
begin
  if FWorkflowGraphMemo = nil then
    Exit;
  Text := TStringBuilder.Create;
  try
    Text.AppendLine('Graph');
    Text.AppendLine;
    if FWorkflowInputsEdit <> nil then
      Text.AppendLine('Inputs: ' + FWorkflowInputsEdit.Text);
    Text.AppendLine;
    Text.AppendLine('Nodes:');
    if (FWorkflowNodesList = nil) or (FWorkflowNodesList.Count = 0) then
      Text.AppendLine('(none)')
    else
      for I := 0 to FWorkflowNodesList.Count - 1 do
      begin
        NodeId := WorkflowTextId(FWorkflowNodesList.ListItems[I].Text);
        WorkflowEnsureNodePosition(NodeId, I,
          IfThen(FWorkflowCanvas <> nil, FWorkflowCanvas.Width, 360));
        if FWorkflowNodePositions.TryGetValue(NodeId, Pos) then
          Text.AppendLine(Format('%s  @ %d,%d',
            [FWorkflowNodesList.ListItems[I].Text, Round(Pos.X), Round(Pos.Y)]))
        else
          Text.AppendLine(FWorkflowNodesList.ListItems[I].Text);
      end;
    Text.AppendLine;
    Text.AppendLine('Edges:');
    if (FWorkflowEdgesList = nil) or (FWorkflowEdgesList.Count = 0) then
      Text.AppendLine('(none)')
    else
      for I := 0 to FWorkflowEdgesList.Count - 1 do
        Text.AppendLine(FWorkflowEdgesList.ListItems[I].Text);
  finally
    FWorkflowGraphMemo.Lines.Text := Text.ToString;
    Text.Free;
  end;
  if FWorkflowCanvas <> nil then
    FWorkflowCanvas.Repaint;
end;

procedure TMasterDetailForm.LogsClearClick(Sender: TObject);
var
  Memo: TMemo;
begin
  if FPaneMemos.TryGetValue('logs', Memo) then
    Memo.Lines.Clear;
  if FLogsStatusLabel <> nil then
    FLogsStatusLabel.Text := 'cleared';
  SetStatus('logs cleared');
end;

procedure TMasterDetailForm.LogsClick(Sender: TObject);
var
  Action: string;
  Base: string;
  Memo: TMemo;
  SessionId: string;
  Token: string;
begin
  Action := '';
  if Sender is TButton then
    Action := TButton(Sender).TagString;

  if SameText(Action, 'stop') then
  begin
    FLogsAbort := True;
    if FLogsStatusLabel <> nil then
      FLogsStatusLabel.Text := 'stopping';
    SetStatus('stopping logs...');
    Exit;
  end;

  if FLogsRunning then
  begin
    if FLogsStatusLabel <> nil then
      FLogsStatusLabel.Text := 'tailing';
    SetStatus('logs already running');
    Exit;
  end;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  FLogsAbort := False;
  FLogsRunning := True;
  if FLogsStatusLabel <> nil then
    FLogsStatusLabel.Text := 'tailing';
  SetStatus('tailing logs...');
  if FPaneMemos.TryGetValue('logs', Memo) then
    Memo.Lines.Text := 'GET /v1/logs' + sLineBreak;

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpTextStreaming(Base, Token, SessionId, 'GET',
          '/v1/logs', '', '', 'text/event-stream',
          procedure(const ChunkText: string; var Abort: Boolean)
          begin
            Abort := FLogsAbort;
            if ChunkText <> '' then
              QueueLogAppend(ChunkText);
          end, Status);
        if (not FLogsAbort) and not IsHttpOk(Status) then
          ErrorText := Format('logs HTTP %d: %s', [Status, ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Memo: TMemo;
        begin
          FLogsRunning := False;
          FLogsAbort := False;
          if ErrorText <> '' then
          begin
            if FPaneMemos.TryGetValue('logs', Memo) then
              Memo.Lines.Add('Error: ' + ErrorText);
            if FLogsStatusLabel <> nil then
              FLogsStatusLabel.Text := 'error';
            SetStatus('logs failed');
          end
          else
          begin
            if FLogsStatusLabel <> nil then
              FLogsStatusLabel.Text := 'stopped';
            SetStatus('logs stopped');
          end;
        end);
    end);
end;

procedure TMasterDetailForm.ModeClick(Sender: TObject);
begin
  if SameText(FMode, 'plan') then
    FMode := 'build'
  else
    FMode := 'plan';
  RenderModeButton;
  SaveLocalSettings;
end;

procedure TMasterDetailForm.ModelComboChange(Sender: TObject);
begin
  if FModelCombo = nil then
    Exit;
  FSavedModel := CurrentModel;
  SaveLocalSettings;
  if FSavedModel = '' then
    SetStatus('model: server default')
  else
    SetStatus('model: ' + FSavedModel);
end;

procedure TMasterDetailForm.SetIconButton(Button: TButton;
  const Lookup, HintText, FallbackCaption: string);
{ For buttons whose GLYPH changes with state.

  ApplyButtonIcon cannot do these: it maps caption -> lookup and then exits
  early once the caption is blank, so a button that has already been
  iconified can never be re-mapped when its state flips. Their Render*
  procedures own them instead, and mark them 'noicon' so ApplyButtonIcon
  keeps its hands off.

  Same safety rule as everywhere else: only surrender the caption once the
  glyph is known to exist, so a style without it degrades to readable text. }
begin
  if Button = nil then
    Exit;
  Button.TagString := 'noicon';
  Button.Hint := HintText;
  Button.ShowHint := True;
  if FIconButtons and StyleLookupExists(Lookup) then
  begin
    Button.StyleLookup := Lookup;
    Button.Text := '';
    if Button.Width > ICON_BTN_W then
      Button.Width := ICON_BTN_W;
  end
  else
  begin
    Button.StyleLookup := '';
    Button.Text := FallbackCaption;
  end;
end;

function TMasterDetailForm.GatewayIdentity: string;
{ What "connected" is connected TO. Compared against the identity that last
  answered, so changing either field invalidates the state by itself. }
begin
  Result := GatewayBaseUrl + #1;
  if FTokenEdit <> nil then
    Result := Result + FTokenEdit.Text;
end;

procedure TMasterDetailForm.GatewaySettingsChange(Sender: TObject);
begin
  RenderConnectButton;
end;

class procedure TMasterDetailForm.SetChromeRoles(Rect: TRectangle;
  FillRole, StrokeRole: Integer);
{ The ONE encoder of the role tag. Call sites use it directly only when the
  colour value is ambiguous -- see ChromeRoleOf. }
begin
  if Rect <> nil then
    Rect.Tag := CHROME_TAG_MAGIC or (FillRole shl 4) or StrokeRole;
end;

procedure TMasterDetailForm.ReapplyChromeTheme(Obj: TFmxObject);
{ Re-run StyleChromeRect for every rect that recorded a role, using the
  palette that is current NOW. Walks a snapshot of the children for the same
  reason RestyleCoreControls does: re-styling can rebuild a control's applied
  style, and that mutates the very list being indexed. }
var
  i, Tag, FillRole, StrokeRole: Integer;
  Kids: TArray<TFmxObject>;
  R: TRectangle;
begin
  if Obj = nil then
    Exit;
  if Obj is TRectangle then
  begin
    R := TRectangle(Obj);
    Tag := R.Tag;
    if (Tag and $FF0000) = CHROME_TAG_MAGIC then
    begin
      FillRole := (Tag shr 4) and $F;
      StrokeRole := Tag and $F;
      if (FillRole > 0) or (StrokeRole > 0) then
        StyleChromeRect(R, ChromeColorOf(FillRole), ChromeColorOf(StrokeRole),
          R.XRadius, R.HitTest);
    end;
  end;
  SetLength(Kids, Obj.ChildrenCount);
  for i := 0 to Obj.ChildrenCount - 1 do
    Kids[i] := Obj.Children[i];
  for i := 0 to High(Kids) do
    if (Kids[i] <> nil) and (Kids[i].Parent = Obj) then
      ReapplyChromeTheme(Kids[i]);
end;

procedure TMasterDetailForm.ApplyOnboardingTheme;
{ The onboarding card floats over the dim shade, so unlike every other panel
  it has to paint an opaque ground -- and repaint it on theme change, which
  the role system cannot do for it because the panel role deliberately maps
  to an unpainted fill. }
begin
  if FOnboardingCard = nil then
    Exit;
  FOnboardingCard.Fill.Kind := TBrushKind.Solid;
  FOnboardingCard.Fill.Color := ThemePaintColor(UI_PANEL);
  FOnboardingCard.Stroke.Kind := TBrushKind.Solid;
  FOnboardingCard.Stroke.Color := ThemePaintStroke(UI_BORDER);
end;

procedure TMasterDetailForm.ApplyHeaderRuleTheme;
begin
  if FHeaderRule <> nil then
    FHeaderRule.Fill.Color := ThemePaintColor(UI_SEPARATOR);
end;

procedure TMasterDetailForm.RenderConnectButton;
{ The button reported an INTENT ("Connect") forever, including while
  connected, so it never answered the only question it is well placed to
  answer. It now reports the STATE and stays clickable as a reconnect. }
var
  Online: Boolean;
begin
  if FRefreshButton = nil then
    Exit;
  Online := (FOnlineIdentity <> '') and (FOnlineIdentity = GatewayIdentity);
  if Online then
    SetIconButton(FRefreshButton, 'linkedtoolbutton',
      'Connected to the gateway - click to reload sessions', 'Connected')
  else
    SetIconButton(FRefreshButton, 'unlinkedtoolbutton',
      'Connect to the gateway', 'Connect');
end;

procedure TMasterDetailForm.RenderSessionSearchBox;
begin
  if FSessionSearch = nil then
    Exit;
  FSessionSearch.Visible := FSessionSearchVisible;
  FSessionSearch.Height := IfThen(FSessionSearchVisible, 36, 0);
  SetControlMargins(FSessionSearch, 0, 0, 0,
    IfThen(FSessionSearchVisible, 8, 0));
end;

procedure TMasterDetailForm.SessionSearchToggleClick(Sender: TObject);
begin
  FSessionSearchVisible := not FSessionSearchVisible;
  RenderSessionSearchBox;
  if FSessionSearchVisible then
    FSessionSearch.SetFocus
  else if Trim(FSessionSearch.Text) <> '' then
  begin
    { closing the box must clear the filter too, or the list stays filtered
      by a term with nothing on screen to explain it }
    FSessionSearch.Text := '';
    RenderSessionList;
  end;
end;

procedure TMasterDetailForm.SessionSearchKeyDown(Sender: TObject;
  var Key: Word; var KeyChar: Char; Shift: TShiftState);
begin
  if Key = vkEscape then
  begin
    Key := 0;
    KeyChar := #0;
    SessionSearchToggleClick(nil);
  end;
end;

procedure TMasterDetailForm.UpdateFooterVisibility;
{ The turn counter footer describes the transcript, so it only belongs on
  the tab that shows one. }
begin
  if FChatStatsLabel = nil then
    Exit;
  FChatStatsLabel.Visible := ActiveTabIs('Chat');
  FChatStatsLabel.Height := IfThen(FChatStatsLabel.Visible, 20, 0);
end;

procedure TMasterDetailForm.RenderToolsButton;
{ Arrows out = expand, arrows in = collapse: the glyph shows what the click
  DOES, which is the only thing a caption-less control can say. }
begin
  if FChatToolsExpanded then
    SetIconButton(FToolsToggleButton, 'collapsetoolbutton',
      'Collapse the tool activity cards', 'Tools ' + #$25B4)
  else
    SetIconButton(FToolsToggleButton, 'expandtoolbutton',
      'Expand the tool activity cards', 'Tools ' + #$25BE);
end;

procedure TMasterDetailForm.RenderParamsButton;
{ The ONLY place the params button's caption is decided -- it was set from
  three (build, toggle, settings load), which is how a disclosure control
  ends up claiming it is open while its panel is shut. }
begin
  if FParamsToggleButton = nil then
    Exit;
  SetIconButton(FParamsToggleButton, 'sliderstoolbutton',
    IfThen(FChatParamsVisible, 'Hide sampling parameters',
    'Show sampling parameters'),
    IfThen(FChatParamsVisible, 'Params ' + #$25B4, 'Params ' + #$25BE));
end;

procedure TMasterDetailForm.ParamsToggleClick(Sender: TObject);
begin
  FChatParamsVisible := not FChatParamsVisible;
  if FChatParamsLayout <> nil then
    FChatParamsLayout.Visible := FChatParamsVisible;
  RenderParamsButton;
  ApplyResponsiveLayout;
  SaveLocalSettings;
  if FChatParamsVisible then
    SetStatus('chat params shown')
  else
    SetStatus('chat params hidden');
end;

procedure TMasterDetailForm.RenderModeButton;
begin
  if FModeButton = nil then
    Exit;
  { the caption is the STATE, not a label for it -- 'mode:' spent a third of
    the button's width explaining the other two thirds }
  if SameText(FMode, 'plan') then
    FModeButton.Text := 'Plan'
  else
  begin
    FMode := 'build';
    FModeButton.Text := 'Build';
  end;
  FModeButton.Hint := 'Build runs tools; Plan only proposes. Click to switch.';
  FModeButton.ShowHint := True;
end;

function TMasterDetailForm.CleanBaseUrl(const Value: string): string;
begin
  Result := Trim(Value);
  if Result = '' then
    Result := DEFAULT_GATEWAY;
  while (Result <> '') and (Result[Length(Result)] = '/') do
    Delete(Result, Length(Result), 1);
end;

function TMasterDetailForm.GatewayBaseUrl: string;
begin
  if FGatewayEdit = nil then
    Result := DEFAULT_GATEWAY
  else
    Result := CleanBaseUrl(FGatewayEdit.Text);
end;

function TMasterDetailForm.ComposeUrl(const BaseUrl, Endpoint: string): string;
var
  E: string;
begin
  E := Trim(Endpoint);
  if StartsText('http://', E) or StartsText('https://', E) then
    Exit(E);
  if (E = '') or (E[1] <> '/') then
    E := '/' + E;
  Result := CleanBaseUrl(BaseUrl) + E;
end;

function TMasterDetailForm.UrlEncode(const Value: string): string;
begin
  Result := TNetEncoding.URL.Encode(Value);
end;

procedure TMasterDetailForm.AddHeader(var Headers: TNetHeaders; const Name,
  Value: string);
var
  Index: Integer;
begin
  if Value = '' then
    Exit;
  Index := Length(Headers);
  SetLength(Headers, Index + 1);
  Headers[Index].Name := Name;
  Headers[Index].Value := Value;
end;

function TMasterDetailForm.HttpText(const BaseUrl, Token, SessionId, Method,
  Endpoint, Body, ContentType, Accept: string; out StatusCode: Integer): string;
var
  Client: THTTPClient;
  Headers: TNetHeaders;
  RequestStream: TStringStream;
  Response: IHTTPResponse;
  ResponseStream: TStringStream;
  Url: string;
begin
  Result := '';
  StatusCode := 0;
  Headers := nil;
  AddHeader(Headers, 'Accept', Accept);
  if Token <> '' then
    AddHeader(Headers, 'Authorization', 'Bearer ' + Token);
  if SessionId <> '' then
    AddHeader(Headers, 'X-PasClaw-Session', SessionId);
  if (Body <> '') and (ContentType <> '') then
    AddHeader(Headers, 'Content-Type', ContentType);

  Url := ComposeUrl(BaseUrl, Endpoint);
  Client := THTTPClient.Create;
  ResponseStream := TStringStream.Create('', TEncoding.UTF8);
  RequestStream := nil;
  try
    Client.ConnectionTimeout := 10000;
    Client.ResponseTimeout := 180000;
    if SameText(Method, 'GET') then
      Response := Client.Get(Url, ResponseStream, Headers)
    else if SameText(Method, 'DELETE') then
      Response := Client.Delete(Url, ResponseStream, Headers)
    else
    begin
      RequestStream := TStringStream.Create(Body, TEncoding.UTF8);
      if SameText(Method, 'PUT') then
        Response := Client.Put(Url, RequestStream, ResponseStream, Headers)
      else
        Response := Client.Post(Url, RequestStream, ResponseStream, Headers);
    end;
    StatusCode := Response.StatusCode;
    Result := ResponseStream.DataString;
  finally
    RequestStream.Free;
    ResponseStream.Free;
    Client.Free;
  end;
end;

function TMasterDetailForm.HttpTextStreaming(const BaseUrl, Token, SessionId,
  Method, Endpoint, Body, ContentType, Accept: string;
  const OnChunk: TStreamChunkProc; out StatusCode: Integer): string;
var
  Client: THTTPClient;
  Headers: TNetHeaders;
  RequestStream: TStringStream;
  Response: IHTTPResponse;
  ResponseStream: TStringStream;
  Url: string;
begin
  Result := '';
  StatusCode := 0;
  Headers := nil;
  AddHeader(Headers, 'Accept', Accept);
  if Token <> '' then
    AddHeader(Headers, 'Authorization', 'Bearer ' + Token);
  if SessionId <> '' then
    AddHeader(Headers, 'X-PasClaw-Session', SessionId);
  if (Body <> '') and (ContentType <> '') then
    AddHeader(Headers, 'Content-Type', ContentType);

  Url := ComposeUrl(BaseUrl, Endpoint);
  Client := THTTPClient.Create;
  ResponseStream := TStringStream.Create('', TEncoding.UTF8);
  RequestStream := nil;
  try
    Client.ConnectionTimeout := 10000;
    Client.ResponseTimeout := 180000;
    Client.ReceiveDataExCallback :=
      procedure(const Sender: TObject; AContentLength, AReadCount: Int64;
        AChunk: Pointer; AChunkLength: Cardinal; var AAbort: Boolean)
      var
        Bytes: TBytes;
        ChunkText: string;
      begin
        if (AChunk = nil) or (AChunkLength = 0) or not Assigned(OnChunk) then
          Exit;
        SetLength(Bytes, AChunkLength);
        Move(AChunk^, Bytes[0], AChunkLength);
        ChunkText := TEncoding.UTF8.GetString(Bytes);
        OnChunk(ChunkText, AAbort);
      end;

    if SameText(Method, 'GET') then
      Response := Client.Get(Url, ResponseStream, Headers)
    else if SameText(Method, 'DELETE') then
      Response := Client.Delete(Url, ResponseStream, Headers)
    else
    begin
      RequestStream := TStringStream.Create(Body, TEncoding.UTF8);
      if SameText(Method, 'PUT') then
        Response := Client.Put(Url, RequestStream, ResponseStream, Headers)
      else
        Response := Client.Post(Url, RequestStream, ResponseStream, Headers);
    end;
    StatusCode := Response.StatusCode;
    Result := ResponseStream.DataString;
  finally
    RequestStream.Free;
    ResponseStream.Free;
    Client.Free;
  end;
end;

function TMasterDetailForm.HttpPostFile(const BaseUrl, Token, SessionId,
  Endpoint, FilePath, ContentType, Accept: string;
  out StatusCode: Integer): string;
var
  Client: THTTPClient;
  Headers: TNetHeaders;
  Response: IHTTPResponse;
  ResponseStream: TStringStream;
  Url: string;
begin
  Result := '';
  StatusCode := 0;
  Headers := nil;
  AddHeader(Headers, 'Accept', Accept);
  if ContentType <> '' then
    AddHeader(Headers, 'Content-Type', ContentType);
  if Token <> '' then
    AddHeader(Headers, 'Authorization', 'Bearer ' + Token);
  if SessionId <> '' then
    AddHeader(Headers, 'X-PasClaw-Session', SessionId);

  Url := ComposeUrl(BaseUrl, Endpoint);
  Client := THTTPClient.Create;
  ResponseStream := TStringStream.Create('', TEncoding.UTF8);
  try
    Client.ConnectionTimeout := 10000;
    Client.ResponseTimeout := 180000;
    Response := Client.Post(Url, FilePath, ResponseStream, Headers);
    StatusCode := Response.StatusCode;
    Result := ResponseStream.DataString;
  finally
    ResponseStream.Free;
    Client.Free;
  end;
end;

function TMasterDetailForm.IsHttpOk(StatusCode: Integer): Boolean;
begin
  Result := (StatusCode >= 200) and (StatusCode < 300);
end;

function TMasterDetailForm.JsonAsBool(Obj: TJSONObject;
  const Name: string): Boolean;
var
  V: TJSONValue;
begin
  Result := False;
  if Obj = nil then
    Exit;
  V := Obj.GetValue(Name);
  if V <> nil then
    Result := SameText(V.Value, 'true') or (V.Value = '1');
end;

function TMasterDetailForm.JsonAsInt64(Obj: TJSONObject;
  const Name: string): Int64;
var
  V: TJSONValue;
begin
  Result := 0;
  if Obj = nil then
    Exit;
  V := Obj.GetValue(Name);
  if V <> nil then
    TryStrToInt64(V.Value, Result);
end;

function TMasterDetailForm.JsonAsString(Obj: TJSONObject;
  const Name: string): string;
var
  V: TJSONValue;
begin
  Result := '';
  if Obj = nil then
    Exit;
  V := Obj.GetValue(Name);
  if V <> nil then
    Result := V.Value;
end;

function TMasterDetailForm.CurrentModel: string;
begin
  Result := '';
  if (FModelCombo <> nil) and (FModelCombo.ItemIndex > 0) and
    (FModelCombo.ItemIndex < FModelCombo.Items.Count) then
    Result := FModelCombo.Items[FModelCombo.ItemIndex];
end;

function TMasterDetailForm.FormatBytes(Value: Int64): string;
begin
  if Value >= 1024 * 1024 * 1024 then
    Result := FormatFloat('0.## GB', Value / (1024 * 1024 * 1024))
  else if Value >= 1024 * 1024 then
    Result := FormatFloat('0.## MB', Value / (1024 * 1024))
  else if Value >= 1024 then
    Result := FormatFloat('0.## KB', Value / 1024)
  else
    Result := Value.ToString + ' B';
end;

function TMasterDetailForm.FormatSkillsText(const JsonText: string): string;
var
  Arr: TJSONArray;
  I: Integer;
  Obj: TJSONObject;
  Preview: string;
  Root: TJSONValue;
  Row: TJSONObject;
  Text: TStringBuilder;
  Value: TJSONValue;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Value := Obj.GetValue('skills');
      if Value is TJSONArray then
      begin
        Text.AppendLine('Installed Skills');
        Text.AppendLine;
        Arr := TJSONArray(Value);
        Text.AppendLine(Format('%d installed skill(s)', [Arr.Count]));
        Text.AppendLine;
        if Arr.Count = 0 then
          Text.AppendLine('(none)')
        else
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              Row := TJSONObject(Arr.Items[I]);
              Text.AppendLine(JsonAsString(Row, 'name'));
              Text.AppendLine('  id:          ' + JsonAsString(Row, 'id'));
              Text.AppendLine('  kind:        ' + JsonAsString(Row, 'kind'));
              Text.AppendLine('  path:        ' + JsonAsString(Row, 'path'));
              if JsonAsString(Row, 'dir') <> '' then
                Text.AppendLine('  dir:         ' + JsonAsString(Row, 'dir'));
              if JsonAsString(Row, 'description') <> '' then
                Text.AppendLine('  description: ' + JsonAsString(Row, 'description'));
              Text.AppendLine;
            end;
      end
      else
      begin
        Value := Obj.GetValue('pending');
        if Value is TJSONArray then
        begin
          Text.AppendLine('Pending Skills');
          Text.AppendLine;
          Arr := TJSONArray(Value);
          Text.AppendLine(Format('%d pending proposal(s)', [Arr.Count]));
          Text.AppendLine;
          if Arr.Count = 0 then
            Text.AppendLine('(none)')
          else
            for I := 0 to Arr.Count - 1 do
              if Arr.Items[I] is TJSONObject then
              begin
                Row := TJSONObject(Arr.Items[I]);
                Text.AppendLine(JsonAsString(Row, 'id'));
                Text.AppendLine('  action:  ' + JsonAsString(Row, 'action'));
                Text.AppendLine('  name:    ' + JsonAsString(Row, 'name'));
                Text.AppendLine('  created: ' + JsonAsString(Row, 'created'));
                Preview := Trim(JsonAsString(Row, 'content'));
                Preview := StringReplace(Preview, #13, ' ', [rfReplaceAll]);
                Preview := StringReplace(Preview, #10, ' ', [rfReplaceAll]);
                if Length(Preview) > 220 then
                  Preview := Copy(Preview, 1, 217) + '...';
                if Preview <> '' then
                  Text.AppendLine('  preview: ' + Preview);
                Text.AppendLine;
              end;
        end
        else
        begin
          Value := Obj.GetValue('results');
          if Value is TJSONArray then
          begin
            Text.AppendLine('Skill Catalog Results');
            Text.AppendLine;
            Arr := TJSONArray(Value);
            Text.AppendLine(Format('%d result(s)', [Arr.Count]));
            Text.AppendLine;
            if Arr.Count = 0 then
              Text.AppendLine('(none)')
            else
              for I := 0 to Arr.Count - 1 do
                if Arr.Items[I] is TJSONObject then
                begin
                  Row := TJSONObject(Arr.Items[I]);
                  Text.AppendLine(JsonAsString(Row, 'display_name'));
                  Text.AppendLine('  slug:    ' + JsonAsString(Row, 'slug'));
                  Text.AppendLine('  source:  ' + JsonAsString(Row, 'source'));
                  Text.AppendLine('  target:  ' + JsonAsString(Row, 'source') + ':' +
                    JsonAsString(Row, 'slug'));
                  Text.AppendLine('  version: ' + JsonAsString(Row, 'version'));
                  Text.AppendLine('  score:   ' + JsonAsString(Row, 'score'));
                  if JsonAsString(Row, 'summary') <> '' then
                    Text.AppendLine('  summary: ' + JsonAsString(Row, 'summary'));
                  Text.AppendLine;
                end;
          end
          else
            Text.AppendLine(JsonText);
        end;
      end;

      Text.AppendLine('Raw JSON:');
      Text.Append(JsonText);
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatRelayStatusText(const JsonText: string): string;
var
  Arr: TJSONArray;
  Caps: TJSONArray;
  CapsText: string;
  I: Integer;
  J: Integer;
  Obj: TJSONObject;
  Root: TJSONValue;
  Text: TStringBuilder;
  Value: TJSONValue;
  Worker: TJSONObject;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;

    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Text.AppendLine('Relay Status');
      Text.AppendLine;
      Text.AppendLine('Summary:');
      Text.AppendLine(Format('%-24s %s', ['Connected workers', JsonAsInt64(Obj, 'connected_workers').ToString]));
      Text.AppendLine(Format('%-24s %s', ['Pending', JsonAsInt64(Obj, 'pending_requests').ToString]));
      Text.AppendLine(Format('%-24s %s', ['In-flight', JsonAsInt64(Obj, 'inflight_requests').ToString]));
      Text.AppendLine(Format('%-24s %s', ['Total enqueued', JsonAsInt64(Obj, 'total_enqueued').ToString]));
      Text.AppendLine(Format('%-24s %s', ['Completed', JsonAsInt64(Obj, 'total_completed').ToString]));
      Text.AppendLine(Format('%-24s %s', ['Failed', JsonAsInt64(Obj, 'total_failed').ToString]));

      Text.AppendLine;
      Text.AppendLine('Connected workers:');
      Value := Obj.GetValue('workers');
      if Value is TJSONArray then
      begin
        Arr := TJSONArray(Value);
        if Arr.Count = 0 then
          Text.AppendLine('(none)')
        else
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              Worker := TJSONObject(Arr.Items[I]);
              CapsText := '';
              Value := Worker.GetValue('caps');
              if Value is TJSONArray then
              begin
                Caps := TJSONArray(Value);
                for J := 0 to Caps.Count - 1 do
                begin
                  if CapsText <> '' then
                    CapsText := CapsText + ', ';
                  CapsText := CapsText + Caps.Items[J].Value;
                end;
              end;
              if CapsText = '' then
                CapsText := '(none)';
              Text.AppendLine(JsonAsString(Worker, 'id'));
              Text.AppendLine('  capabilities: ' + CapsText);
              Text.AppendLine('  requests:     ' + JsonAsInt64(Worker, 'requests_seen').ToString);
              Text.AppendLine('  last seen:    ' + JsonAsString(Worker, 'last_seen'));
            end;
      end
      else
        Text.AppendLine('(none)');

      Text.AppendLine;
      Text.AppendLine('Worker connection:');
      Text.AppendLine('Workers connect outbound to ' + GatewayBaseUrl + '/v1/relay/poll and return results to /v1/relay/respond/<id>.');
      Text.AppendLine('Use the Token button to fetch the relay-scoped worker token.');

      Text.AppendLine;
      Text.AppendLine('Raw JSON:');
      Text.Append(JsonText);
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatRelayTokenText(const JsonText: string): string;
var
  Gateway: string;
  Obj: TJSONObject;
  Root: TJSONValue;
  SnippetToken: string;
  Text: TStringBuilder;
  Token: string;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;

    Obj := TJSONObject(Root);
    Gateway := GatewayBaseUrl;
    if (FRelayUrlEdit <> nil) and (Trim(FRelayUrlEdit.Text) <> '') then
      Gateway := Trim(FRelayUrlEdit.Text);
    Token := JsonAsString(Obj, 'token');
    SnippetToken := Token;
    if (FRelayTokenEdit <> nil) and FRelayTokenEdit.Password then
      SnippetToken := '<PASCLAW_RELAY_TOKEN>';

    Text := TStringBuilder.Create;
    try
      Text.AppendLine('Relay Worker Token');
      Text.AppendLine;
      Text.AppendLine('This token is scoped to /v1/relay/* and is intended for outbound workers.');
      Text.AppendLine;
      Text.AppendLine('Gateway: ' + Gateway);
      if SameText(SnippetToken, Token) then
        Text.AppendLine('Token:   ' + Token)
      else
        Text.AppendLine('Token:   ' + SnippetToken + ' (hidden)');
      Text.AppendLine;
      Text.AppendLine('Worker endpoints:');
      Text.AppendLine('GET  ' + Gateway + '/v1/relay/poll');
      Text.AppendLine('POST ' + Gateway + '/v1/relay/respond/<id>');
      Text.AppendLine;
      Text.AppendLine('Built-in FMX worker:');
      Text.AppendLine('Use the command, provider, model, and worker id fields above, then Connect.');
      Text.AppendLine('Model "*" advertises wildcard capability; blank uses the worker provider default.');
      Text.AppendLine;
      Text.AppendLine('PasClaw CLI:');
      Text.AppendLine('pasclaw relay --gateway-url ' + Gateway + ' --gateway-token ' + SnippetToken);
      Text.AppendLine;
      Text.AppendLine('Windows cmd:');
      Text.AppendLine('set PASCLAW_GATEWAY_URL=' + Gateway);
      Text.AppendLine('set PASCLAW_RELAY_TOKEN=' + SnippetToken);
      Text.AppendLine('pasclaw relay');
      Text.AppendLine;
      Text.AppendLine('PowerShell:');
      Text.AppendLine('$env:PASCLAW_GATEWAY_URL="' + Gateway + '"');
      Text.AppendLine('$env:PASCLAW_RELAY_TOKEN="' + SnippetToken + '"');
      Text.AppendLine('pasclaw relay');
      Text.AppendLine;
      Text.AppendLine('curl smoke test:');
      Text.AppendLine('curl -H "Authorization: Bearer ' + SnippetToken + '" "' + Gateway + '/v1/relay/poll?worker_id=fmx-smoke&caps=chat"');
      Text.AppendLine;
      Text.AppendLine('Python worker skeleton:');
      Text.AppendLine('import requests');
      Text.AppendLine('URL = "' + Gateway + '"');
      Text.AppendLine('headers = {"Authorization": "Bearer ' + SnippetToken + '", "X-Relay-Worker-Id": "py-worker-1", "X-Relay-Capabilities": "chat"}');
      Text.AppendLine('poll = requests.get(URL + "/v1/relay/poll", headers=headers, stream=True)');
      Text.AppendLine('for line in poll.iter_lines():');
      Text.AppendLine('    if not line:');
      Text.AppendLine('        continue');
      Text.AppendLine('    # parse the request, run local inference, then respond to /v1/relay/respond/<id>');
      Text.AppendLine;
      Text.AppendLine('Replicate cog-relay:');
      Text.AppendLine('replicate.run("your-handle/pasclaw-relay", input={"gateway_url": "' + Gateway + '", "gateway_token": "' + SnippetToken + '"})');
      Text.AppendLine;
      Text.AppendLine('Worker protocol:');
      Text.AppendLine('Workers poll outbound, run the requested local/provider task, then POST the result to /v1/relay/respond/<id>.');
      Text.AppendLine('Use worker_id and caps to distinguish local runtimes, GPU hosts, tools, and model families.');
      Text.AppendLine;
      Text.AppendLine('Raw JSON:');
      Text.Append(JsonText);
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatStatsText(const JsonText: string): string;
var
  Arr: TJSONArray;
  BytesSaved: Int64;
  I: Integer;
  Key: string;
  Obj: TJSONObject;
  Root: TJSONValue;
  Row: TJSONObject;
  Text: TStringBuilder;
  Tokens: Int64;
  Value: TJSONValue;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;

    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Text.AppendLine('Stats');
      Text.AppendLine;
      if not JsonAsBool(Obj, 'stats_collection_enabled') then
      begin
        Text.AppendLine('Stats collection is disabled. Enable stats_collection_enabled in config.json or onboarding to persist per-session counters.');
        Text.AppendLine;
      end;

      Text.AppendLine('Summary:');
      Text.AppendLine(Format('%-28s %s', ['Sessions', JsonAsInt64(Obj, 'sessions').ToString]));
      Text.AppendLine(Format('%-28s %s', ['Turns', JsonAsInt64(Obj, 'turns').ToString]));
      Text.AppendLine(Format('%-28s %s', ['Tool calls', JsonAsInt64(Obj, 'tool_calls').ToString]));
      Text.AppendLine(Format('%-28s %s', ['Input tokens', JsonAsInt64(Obj, 'input_tokens').ToString]));
      Text.AppendLine(Format('%-28s %s', ['Output tokens', JsonAsInt64(Obj, 'output_tokens').ToString]));
      Text.AppendLine(Format('%-28s %s', ['Cache read tokens', JsonAsInt64(Obj, 'cache_read_tokens').ToString]));
      Text.AppendLine(Format('%-28s %s', ['Cache created tokens', JsonAsInt64(Obj, 'cache_created_tokens').ToString]));
      BytesSaved := JsonAsInt64(Obj, 'truncation_bytes_saved');
      Text.AppendLine(Format('%-28s %s (%s)', ['Truncation bytes saved', BytesSaved.ToString, FormatBytes(BytesSaved)]));

      Text.AppendLine;
      Text.AppendLine('Tokens by provider:');
      Value := Obj.GetValue('by_provider');
      if Value is TJSONArray then
      begin
        Arr := TJSONArray(Value);
        if Arr.Count = 0 then
          Text.AppendLine('(none)')
        else
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              Row := TJSONObject(Arr.Items[I]);
              Key := JsonAsString(Row, 'provider');
              if Key = '' then
                Key := '(unknown)';
              Tokens := JsonAsInt64(Row, 'tokens');
              if Tokens = 0 then
                Tokens := JsonAsInt64(Row, 'input_tokens') +
                  JsonAsInt64(Row, 'output_tokens');
              Text.AppendLine(Format('%-32s %s', [Key, Tokens.ToString]));
            end;
      end
      else
        Text.AppendLine('(none)');

      Text.AppendLine;
      Text.AppendLine('Tokens by model:');
      Value := Obj.GetValue('by_model');
      if Value is TJSONArray then
      begin
        Arr := TJSONArray(Value);
        if Arr.Count = 0 then
          Text.AppendLine('(none)')
        else
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              Row := TJSONObject(Arr.Items[I]);
              Key := JsonAsString(Row, 'model');
              if Key = '' then
                Key := '(unknown)';
              Tokens := JsonAsInt64(Row, 'tokens');
              if Tokens = 0 then
                Tokens := JsonAsInt64(Row, 'input_tokens') +
                  JsonAsInt64(Row, 'output_tokens');
              Text.AppendLine(Format('%-32s %s', [Key, Tokens.ToString]));
            end;
      end
      else
        Text.AppendLine('(none)');

      Text.AppendLine;
      Text.AppendLine('Raw JSON:');
      Text.Append(JsonText);
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatWorkflowRunText(const JsonText: string): string;
var
  Arr: TJSONArray;
  I: Integer;
  Obj: TJSONObject;
  Root: TJSONValue;
  Row: TJSONObject;
  Text: TStringBuilder;
  Value: TJSONValue;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Text.AppendLine('Workflow Run');
      Text.AppendLine;
      if JsonAsBool(Obj, 'ok') then
        Text.AppendLine('Status: OK')
      else
        Text.AppendLine('Status: FAILED');
      if JsonAsString(Obj, 'error') <> '' then
        Text.AppendLine('Error:  ' + JsonAsString(Obj, 'error'));
      if JsonAsString(Obj, 'output') <> '' then
      begin
        Text.AppendLine;
        Text.AppendLine('Output:');
        Text.AppendLine(JsonAsString(Obj, 'output'));
      end;
      Text.AppendLine;
      Text.AppendLine('Nodes:');
      Value := Obj.GetValue('nodes');
      if Value is TJSONArray then
      begin
        Arr := TJSONArray(Value);
        if Arr.Count = 0 then
          Text.AppendLine('(none)')
        else
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              Row := TJSONObject(Arr.Items[I]);
              if JsonAsBool(Row, 'ok') then
                Text.Append('[ok] ')
              else
                Text.Append('[fail] ');
              Text.Append(JsonAsString(Row, 'node'));
              if JsonAsString(Row, 'tool') <> '' then
                Text.Append(' (' + JsonAsString(Row, 'tool') + ')');
              Text.AppendLine;
              if JsonAsString(Row, 'error') <> '' then
                Text.AppendLine('  error: ' + JsonAsString(Row, 'error'));
              if JsonAsString(Row, 'text') <> '' then
                Text.AppendLine('  text:  ' + JsonAsString(Row, 'text'));
            end;
      end
      else
        Text.AppendLine('(none)');
      Text.AppendLine;
      Text.AppendLine('Raw JSON:');
      Text.Append(JsonText);
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatFilesText(const JsonText: string): string;
var
  Arr: TJSONArray;
  I: Integer;
  Obj: TJSONObject;
  Root: TJSONValue;
  Row: TJSONObject;
  Text: TStringBuilder;
  Value: TJSONValue;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Text.AppendLine('Files');
      Text.AppendLine;
      Text.AppendLine('Path:      ' + JsonAsString(Obj, 'path'));
      Text.AppendLine('Workspace: ' + JsonAsString(Obj, 'workspace_root'));
      Text.AppendLine('Launch:    ' + JsonAsString(Obj, 'cwd_root'));
      Text.AppendLine;
      Text.AppendLine('Entries:');
      Value := Obj.GetValue('entries');
      if Value is TJSONArray then
      begin
        Arr := TJSONArray(Value);
        if Arr.Count = 0 then
          Text.AppendLine('(empty)')
        else
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              Row := TJSONObject(Arr.Items[I]);
              if JsonAsBool(Row, 'dir') then
                Text.AppendLine('[dir]  ' + JsonAsString(Row, 'name'))
              else
                Text.AppendLine(Format('[file] %-36s %s',
                  [JsonAsString(Row, 'name'),
                  FormatBytes(JsonAsInt64(Row, 'size'))]));
            end;
      end
      else
        Text.AppendLine('(none)');
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatFilesReadText(const JsonText: string): string;
var
  Obj: TJSONObject;
  Root: TJSONValue;
  Text: TStringBuilder;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Text.AppendLine('File Preview');
      Text.AppendLine;
      Text.AppendLine('Path: ' + JsonAsString(Obj, 'path'));
      if JsonAsBool(Obj, 'binary') then
      begin
        Text.AppendLine('Binary file: ' + FormatBytes(JsonAsInt64(Obj, 'size')));
        Text.AppendLine;
        Text.AppendLine('Use Peek or Download for raw bytes.');
      end
      else
      begin
        if JsonAsBool(Obj, 'truncated') then
          Text.AppendLine('(truncated at server preview cap)');
        Text.AppendLine;
        Text.Append(JsonAsString(Obj, 'content'));
      end;
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatCronText(const JsonText: string): string;
var
  Arr: TJSONArray;
  Channel: string;
  I: Integer;
  Root: TJSONValue;
  Row: TJSONObject;
  Text: TStringBuilder;
  Value: TJSONValue;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Text := TStringBuilder.Create;
    try
      Text.AppendLine('Cron Entries');
      Text.AppendLine;
      Value := TJSONObject(Root).GetValue('entries');
      if Value is TJSONArray then
      begin
        Arr := TJSONArray(Value);
        if Arr.Count = 0 then
          Text.AppendLine('(none)')
        else
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              Row := TJSONObject(Arr.Items[I]);
              Channel := '--';
              if JsonAsString(Row, 'channel_kind') <> '' then
                Channel := JsonAsString(Row, 'channel_kind') + ':' +
                  JsonAsString(Row, 'channel_target');
              Text.AppendLine(JsonAsString(Row, 'id'));
              Text.AppendLine('  spec:    ' + JsonAsString(Row, 'spec'));
              Text.AppendLine('  skill:   ' + JsonAsString(Row, 'skill'));
              Text.AppendLine('  args:    ' + JsonAsString(Row, 'args'));
              Text.AppendLine('  channel: ' + Channel);
              Text.AppendLine('  enabled: ' +
                BoolToStr(JsonAsBool(Row, 'enabled'), True));
              Text.AppendLine;
            end;
      end;
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatCheckpointText(const JsonText: string): string;
var
  Arr: TJSONArray;
  FileObj: TJSONObject;
  Files: TJSONArray;
  I: Integer;
  J: Integer;
  Obj: TJSONObject;
  Root: TJSONValue;
  Row: TJSONObject;
  Text: TStringBuilder;
  Value: TJSONValue;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Text.AppendLine('Checkpoints');
      Text.AppendLine;
      Text.AppendLine(Format('%-16s %s', ['Enabled',
        BoolToStr(JsonAsBool(Obj, 'enabled'), True)]));
      Text.AppendLine(Format('%-16s %s', ['Backend',
        JsonAsString(Obj, 'backend')]));
      Text.AppendLine(Format('%-16s %s', ['Current turn',
        JsonAsInt64(Obj, 'current_turn').ToString]));
      Text.AppendLine(Format('%-16s %s', ['Count',
        JsonAsInt64(Obj, 'count').ToString]));
      Text.AppendLine(Format('%-16s %s', ['Can redo',
        BoolToStr(JsonAsBool(Obj, 'can_redo'), True)]));
      Text.AppendLine;
      Value := Obj.GetValue('turns');
      if Value is TJSONArray then
      begin
        Arr := TJSONArray(Value);
        if Arr.Count = 0 then
          Text.AppendLine('(none)')
        else
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              Row := TJSONObject(Arr.Items[I]);
              Text.AppendLine('Turn ' + JsonAsInt64(Row, 'turn').ToString +
                '  ' + JsonAsString(Row, 'ts'));
              Value := Row.GetValue('files');
              if Value is TJSONArray then
              begin
                Files := TJSONArray(Value);
                for J := 0 to Files.Count - 1 do
                  if Files.Items[J] is TJSONObject then
                  begin
                    FileObj := TJSONObject(Files.Items[J]);
                    if JsonAsBool(FileObj, 'created') then
                      Text.AppendLine('  + ' + JsonAsString(FileObj, 'path'))
                    else
                      Text.AppendLine('  ~ ' + JsonAsString(FileObj, 'path'));
                  end;
              end;
            end;
      end;
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatMcpText(const JsonText: string): string;
var
  Arr: TJSONArray;
  I: Integer;
  Obj: TJSONObject;
  Root: TJSONValue;
  Row: TJSONObject;
  Text: TStringBuilder;
  Value: TJSONValue;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Value := Obj.GetValue('servers');
      if Value is TJSONArray then
      begin
        Text.AppendLine('MCP Servers');
        Text.AppendLine;
        Arr := TJSONArray(Value);
        if Arr.Count = 0 then
          Text.AppendLine('(none)')
        else
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              Row := TJSONObject(Arr.Items[I]);
              Text.AppendLine(JsonAsString(Row, 'name'));
              Text.AppendLine('  command: ' + JsonAsString(Row, 'cmd'));
              Text.AppendLine('  args:    ' + JsonAsString(Row, 'args'));
              if JsonAsBool(Row, 'enabled') then
                Text.AppendLine('  status:  enabled')
              else
                Text.AppendLine('  status:  disabled');
            end;
      end
      else
      begin
        Value := Obj.GetValue('tools');
        if not (Value is TJSONArray) then
          Value := Obj.GetValue('data');
        Text.AppendLine('MCP Tools');
        Text.AppendLine;
        if Value is TJSONArray then
        begin
          Arr := TJSONArray(Value);
          if Arr.Count = 0 then
            Text.AppendLine('(none)')
          else
            for I := 0 to Arr.Count - 1 do
              if Arr.Items[I] is TJSONObject then
              begin
                Row := TJSONObject(Arr.Items[I]);
                Text.AppendLine(JsonAsString(Row, 'name'));
                if JsonAsString(Row, 'description') <> '' then
                  Text.AppendLine('  ' + JsonAsString(Row, 'description'));
              end
              else
                Text.AppendLine(Arr.Items[I].Value);
        end
        else
          Text.AppendLine(JsonText);
      end;
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatMcpRpcText(const JsonText: string): string;
var
  Content: TJSONArray;
  ErrorObj: TJSONObject;
  I: Integer;
  Kind: string;
  Obj: TJSONObject;
  ResultObj: TJSONObject;
  Root: TJSONValue;
  Row: TJSONObject;
  Text: TStringBuilder;
  Value: TJSONValue;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Value := Obj.GetValue('error');
      if Value is TJSONObject then
      begin
        ErrorObj := TJSONObject(Value);
        Text.AppendLine('MCP Tool Error');
        Text.AppendLine;
        Text.AppendLine('Code:    ' + JsonAsString(ErrorObj, 'code'));
        Text.AppendLine('Message: ' + JsonAsString(ErrorObj, 'message'));
        Value := ErrorObj.GetValue('data');
        if Value <> nil then
        begin
          Text.AppendLine;
          Text.AppendLine('Data:');
          Text.AppendLine(JsonPretty(Value));
        end;
      end
      else
      begin
        Value := Obj.GetValue('result');
        if Value is TJSONObject then
          ResultObj := TJSONObject(Value)
        else
          ResultObj := Obj;

        Text.AppendLine('MCP Tool Result');
        Text.AppendLine;
        Text.AppendLine('isError: ' + BoolToStr(JsonAsBool(ResultObj, 'isError'), True));

        Value := ResultObj.GetValue('content');
        if Value is TJSONArray then
        begin
          Content := TJSONArray(Value);
          if Content.Count = 0 then
            Text.AppendLine('(no content)')
          else
            for I := 0 to Content.Count - 1 do
            begin
              Text.AppendLine;
              if Content.Items[I] is TJSONObject then
              begin
                Row := TJSONObject(Content.Items[I]);
                Kind := JsonAsString(Row, 'type');
                if Kind = '' then
                  Kind := 'item';
                Text.AppendLine('Content ' + IntToStr(I + 1) + ' (' + Kind + ')');
                Text.AppendLine(StringOfChar('-', 12 + Length(IntToStr(I + 1)) + Length(Kind)));
                if JsonAsString(Row, 'text') <> '' then
                  Text.AppendLine(JsonAsString(Row, 'text'))
                else if JsonAsString(Row, 'uri') <> '' then
                  Text.AppendLine('uri: ' + JsonAsString(Row, 'uri'))
                else if JsonAsString(Row, 'data') <> '' then
                begin
                  Text.AppendLine('mime: ' + JsonAsString(Row, 'mimeType'));
                  Text.AppendLine('data: ' + IntToStr(Length(JsonAsString(Row, 'data'))) + ' base64 chars');
                end
                else
                  Text.AppendLine(JsonPretty(Row));
              end
              else
                Text.AppendLine(Content.Items[I].Value);
            end;
        end
        else
          Text.AppendLine(JsonPretty(ResultObj));

        Value := ResultObj.GetValue('structuredContent');
        if Value <> nil then
        begin
          Text.AppendLine;
          Text.AppendLine('Structured content:');
          Text.AppendLine(JsonPretty(Value));
        end;
      end;

      Text.AppendLine;
      Text.AppendLine('Raw JSON:');
      Text.Append(JsonText);
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatVaultSearchText(const JsonText: string): string;
var
  Arr: TJSONArray;
  I: Integer;
  Root: TJSONValue;
  Row: TJSONObject;
  Text: TStringBuilder;
  Value: TJSONValue;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Text := TStringBuilder.Create;
    try
      Text.AppendLine('Code Vault Search');
      Text.AppendLine;
      Value := TJSONObject(Root).GetValue('results');
      if Value is TJSONArray then
      begin
        Arr := TJSONArray(Value);
        if Arr.Count = 0 then
          Text.AppendLine('(no matches)')
        else
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              Row := TJSONObject(Arr.Items[I]);
              Text.AppendLine(JsonAsString(Row, 'displayName'));
              if JsonAsString(Row, 'displayName') = '' then
                Text.AppendLine(JsonAsString(Row, 'slug'));
              if JsonAsString(Row, 'summary') <> '' then
                Text.AppendLine('  ' + JsonAsString(Row, 'summary'));
              Text.AppendLine('  slug: ' + JsonAsString(Row, 'slug'));
            end;
      end;
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.FormatVaultDetailText(const JsonText: string): string;
var
  Obj: TJSONObject;
  Root: TJSONValue;
  Text: TStringBuilder;
begin
  Result := JsonText;
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Text.AppendLine(JsonAsString(Obj, 'displayName'));
      if JsonAsString(Obj, 'displayName') = '' then
        Text.AppendLine(JsonAsString(Obj, 'slug'));
      Text.AppendLine(StringOfChar('=', 48));
      Text.AppendLine;
      if JsonAsString(Obj, 'summary') <> '' then
        Text.AppendLine(JsonAsString(Obj, 'summary'));
      Text.AppendLine;
      Text.AppendLine('Slug:     ' + JsonAsString(Obj, 'slug'));
      Text.AppendLine('Category: ' + JsonAsString(Obj, 'category'));
      Text.AppendLine('Version:  ' + JsonAsString(Obj, 'latestVersion'));
      Text.AppendLine('License:  ' + JsonAsString(Obj, 'license'));
      Text.AppendLine('Delphi:   ' + JsonAsString(Obj, 'delphiVersions'));
      Text.AppendLine('Repo:     ' + JsonAsString(Obj, 'repoUrl'));
      if JsonAsString(Obj, 'installSnippet') <> '' then
      begin
        Text.AppendLine;
        Text.AppendLine('Install:');
        Text.AppendLine(JsonAsString(Obj, 'installSnippet'));
      end;
      if JsonAsString(Obj, 'descriptionMarkdown') <> '' then
      begin
        Text.AppendLine;
        Text.AppendLine('Description:');
        Text.AppendLine(JsonAsString(Obj, 'descriptionMarkdown'));
      end;
      Result := Text.ToString;
    finally
      Text.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.EncodeIniText(const Value: string): string;
begin
  Result := TNetEncoding.Base64.EncodeBytesToString(TEncoding.UTF8.GetBytes(Value));
end;

function TMasterDetailForm.DecodeIniText(const Value: string): string;
begin
  Result := '';
  if Value = '' then
    Exit;
  try
    Result := TEncoding.UTF8.GetString(TNetEncoding.Base64.DecodeStringToBytes(Value));
  except
    Result := Value;
  end;
end;

procedure TMasterDetailForm.SetStatus(const Value: string);
begin
  if FStatusLabel <> nil then
    FStatusLabel.Text := Value;
end;

procedure TMasterDetailForm.UpdateParamsSummary;
var
  Bits: string;
  MaxTokens: string;
  SystemPrompt: string;
  Temperature: string;
begin
  if FParamsSummaryLabel = nil then
    Exit;
  SystemPrompt := '';
  if FSystemMemo <> nil then
    SystemPrompt := Trim(FSystemMemo.Lines.Text);
  Temperature := '';
  if FTemperatureEdit <> nil then
    Temperature := Trim(FTemperatureEdit.Text);
  MaxTokens := '';
  if FMaxTokensEdit <> nil then
    MaxTokens := Trim(FMaxTokensEdit.Text);

  Bits := '';
  if SystemPrompt <> '' then
    Bits := 'system';
  if Temperature <> '' then
  begin
    if Bits <> '' then
      Bits := Bits + ' / ';
    Bits := Bits + 'temp ' + Temperature;
  end;
  if MaxTokens <> '' then
  begin
    if Bits <> '' then
      Bits := Bits + ' / ';
    Bits := Bits + 'max ' + MaxTokens;
  end;
  if Bits = '' then
    Bits := 'defaults';
  FParamsSummaryLabel.Text := Bits;
  if FParamsResetButton <> nil then
    FParamsResetButton.Enabled := Bits <> 'defaults';
end;

procedure TMasterDetailForm.SaveChatParams(const SessionId: string);
var
  Ini: TIniFile;
  MaxTokens: string;
  Section: string;
  SystemPrompt: string;
  Temperature: string;
  procedure SaveSection(const Name: string);
  begin
    if (SystemPrompt = '') and (Temperature = '') and (MaxTokens = '') then
      Ini.EraseSection(Name)
    else
    begin
      Ini.WriteString(Name, 'system', EncodeIniText(SystemPrompt));
      Ini.WriteString(Name, 'temperature', Temperature);
      Ini.WriteString(Name, 'max_tokens', MaxTokens);
    end;
  end;
begin
  if FLoadingChatParams or (FSystemMemo = nil) or (FTemperatureEdit = nil) or
    (FMaxTokensEdit = nil) then
    Exit;

  SystemPrompt := FSystemMemo.Lines.Text;
  Temperature := Trim(FTemperatureEdit.Text);
  MaxTokens := Trim(FMaxTokensEdit.Text);
  Section := ChatParamsSection(SessionId);
  Ini := TIniFile.Create(FConfigFile);
  try
    SaveSection(Section);
    if Section <> ChatParamsSection('') then
      SaveSection(ChatParamsSection(''));
  finally
    Ini.Free;
  end;
  UpdateParamsSummary;
end;

procedure TMasterDetailForm.LoadChatParams(const SessionId: string);
var
  Ini: TIniFile;
  MaxTokens: string;
  Section: string;
  SystemPrompt: string;
  Temperature: string;
begin
  if (FSystemMemo = nil) or (FTemperatureEdit = nil) or (FMaxTokensEdit = nil) then
    Exit;
  Section := ChatParamsSection(SessionId);
  Ini := TIniFile.Create(FConfigFile);
  try
    if SessionId = '' then
    begin
      SystemPrompt := Ini.ReadString(Section, 'system',
        EncodeIniText(FSystemMemo.Lines.Text));
      Temperature := Ini.ReadString(Section, 'temperature',
        Trim(FTemperatureEdit.Text));
      MaxTokens := Ini.ReadString(Section, 'max_tokens',
        Trim(FMaxTokensEdit.Text));
    end
    else
    begin
      SystemPrompt := Ini.ReadString(Section, 'system', '');
      Temperature := Ini.ReadString(Section, 'temperature', '');
      MaxTokens := Ini.ReadString(Section, 'max_tokens', '');
    end;
  finally
    Ini.Free;
  end;

  FLoadingChatParams := True;
  try
    FSystemMemo.Lines.Text := DecodeIniText(SystemPrompt);
    FTemperatureEdit.Text := Temperature;
    FMaxTokensEdit.Text := MaxTokens;
    if FPromptPresetCombo <> nil then
      FPromptPresetCombo.ItemIndex := 0;
    if FPresetNameEdit <> nil then
      FPresetNameEdit.Text := '';
  finally
    FLoadingChatParams := False;
  end;
  SyncTemperatureTrackFromEdit;
  UpdateParamsSummary;
end;

procedure TMasterDetailForm.SyncTemperatureTrackFromEdit;
var
  D: Double;
  FS: TFormatSettings;
begin
  if (FTemperatureTrack = nil) or (FTemperatureEdit = nil) then
    Exit;
  FS := TFormatSettings.Create('en-US');
  if TryStrToFloat(Trim(FTemperatureEdit.Text), D, FS) then
    FTemperatureTrack.Value := Min(Max(D, FTemperatureTrack.Min),
      FTemperatureTrack.Max)
  else
    FTemperatureTrack.Value := 1;
end;

procedure TMasterDetailForm.TemperatureTrackChange(Sender: TObject);
var
  FS: TFormatSettings;
begin
  if FLoadingChatParams or (FTemperatureTrack = nil) or
    (FTemperatureEdit = nil) then
    Exit;
  FS := TFormatSettings.Create('en-US');
  FLoadingChatParams := True;
  try
    FTemperatureEdit.Text := FormatFloat('0.0#', FTemperatureTrack.Value, FS);
  finally
    FLoadingChatParams := False;
  end;
  SaveChatParams(FActiveSessionId);
  UpdateParamsSummary;
end;

procedure TMasterDetailForm.ChatParamsChanged(Sender: TObject);
begin
  if FLoadingChatParams then
    Exit;
  if Sender = FTemperatureEdit then
    SyncTemperatureTrackFromEdit;
  SaveChatParams(FActiveSessionId);
  UpdateParamsSummary;
end;

procedure TMasterDetailForm.ChatToolsToggleClick(Sender: TObject);
begin
  FChatToolsExpanded := not FChatToolsExpanded;
  UpdateToolsToggleCaption;
  SaveLocalSettings;   { the toggle is a persisted preference }
  RenderChat;
end;

procedure TMasterDetailForm.UpdateToolsToggleCaption;
{ Single place that derives the button's FACE from FChatToolsExpanded, so it
  can't drift from the state -- the toggle handler and the settings-restore
  path both call it. Nil-safe via SetIconButton. }
begin
  RenderToolsButton;
end;

procedure TMasterDetailForm.ResetParamsClick(Sender: TObject);
begin
  FLoadingChatParams := True;
  try
    if FSystemMemo <> nil then
      FSystemMemo.Lines.Clear;
    if FTemperatureEdit <> nil then
      FTemperatureEdit.Text := '';
    if FMaxTokensEdit <> nil then
      FMaxTokensEdit.Text := '';
    if FPromptPresetCombo <> nil then
      FPromptPresetCombo.ItemIndex := 0;
    if FPresetNameEdit <> nil then
      FPresetNameEdit.Text := '';
  finally
    FLoadingChatParams := False;
  end;
  SyncTemperatureTrackFromEdit;
  SaveChatParams(FActiveSessionId);
  UpdateParamsSummary;
  SetStatus('chat params reset');
end;

procedure TMasterDetailForm.LoadPromptPresets;
var
  I: Integer;
  Ini: TIniFile;
  Names: TStringList;
begin
  if FPromptPresetCombo = nil then
    Exit;

  FPromptPresetCombo.OnChange := nil;
  FPromptPresetCombo.Items.BeginUpdate;
  try
    FPromptPresetCombo.Items.Clear;
    FPromptPresetCombo.Items.Add('Preset -');
    Names := TStringList.Create;
    Ini := TIniFile.Create(FConfigFile);
    try
      Ini.ReadSection('prompt_presets', Names);
      Names.Sort;
      for I := 0 to Names.Count - 1 do
        FPromptPresetCombo.Items.Add(Names[I]);
    finally
      Ini.Free;
      Names.Free;
    end;
    FPromptPresetCombo.ItemIndex := 0;
  finally
    FPromptPresetCombo.Items.EndUpdate;
    FPromptPresetCombo.OnChange := PromptPresetChange;
  end;

  if FPresetDeleteButton <> nil then
    FPresetDeleteButton.Enabled := FPromptPresetCombo.Items.Count > 1;
end;

procedure TMasterDetailForm.PromptPresetChange(Sender: TObject);
var
  EncodedText: string;
  Ini: TIniFile;
  Name: string;
begin
  if (FPromptPresetCombo = nil) or (FPromptPresetCombo.ItemIndex <= 0) or
    (FPromptPresetCombo.ItemIndex >= FPromptPresetCombo.Items.Count) then
    Exit;

  Name := FPromptPresetCombo.Items[FPromptPresetCombo.ItemIndex];
  Ini := TIniFile.Create(FConfigFile);
  try
    EncodedText := Ini.ReadString('prompt_presets', Name, '');
  finally
    Ini.Free;
  end;

  FSystemMemo.Lines.Text := DecodeIniText(EncodedText);
  if FPresetNameEdit <> nil then
    FPresetNameEdit.Text := Name;
  SetStatus('loaded preset: ' + Name);
end;

procedure TMasterDetailForm.SavePresetClick(Sender: TObject);
var
  Ini: TIniFile;
  Name: string;
  Index: Integer;
begin
  Name := '';
  if FPresetNameEdit <> nil then
    Name := Trim(FPresetNameEdit.Text);
  if (Name = '') and (FPromptPresetCombo <> nil) and
    (FPromptPresetCombo.ItemIndex > 0) then
    Name := FPromptPresetCombo.Items[FPromptPresetCombo.ItemIndex];

  if Name = '' then
  begin
    SetStatus('preset name required');
    Exit;
  end;

  Ini := TIniFile.Create(FConfigFile);
  try
    Ini.WriteString('prompt_presets', Name,
      EncodeIniText(FSystemMemo.Lines.Text));
  finally
    Ini.Free;
  end;

  LoadPromptPresets;
  if FPromptPresetCombo <> nil then
  begin
    Index := FPromptPresetCombo.Items.IndexOf(Name);
    if Index >= 0 then
      FPromptPresetCombo.ItemIndex := Index;
  end;
  if FPresetNameEdit <> nil then
    FPresetNameEdit.Text := Name;
  SetStatus('saved preset: ' + Name);
end;

procedure TMasterDetailForm.DeletePresetClick(Sender: TObject);
var
  Ini: TIniFile;
  Name: string;
begin
  Name := '';
  if (FPromptPresetCombo <> nil) and (FPromptPresetCombo.ItemIndex > 0) then
    Name := FPromptPresetCombo.Items[FPromptPresetCombo.ItemIndex]
  else if FPresetNameEdit <> nil then
    Name := Trim(FPresetNameEdit.Text);

  if Name = '' then
  begin
    SetStatus('no preset selected');
    Exit;
  end;

  Ini := TIniFile.Create(FConfigFile);
  try
    Ini.DeleteKey('prompt_presets', Name);
  finally
    Ini.Free;
  end;

  LoadPromptPresets;
  if FPresetNameEdit <> nil then
    FPresetNameEdit.Text := '';
  SetStatus('deleted preset: ' + Name);
end;

procedure TMasterDetailForm.LoadLocalSettings;
var
  Ini: TIniFile;
begin
  FGatewayEdit.Text := DEFAULT_GATEWAY;
  FMode := 'build';
  Ini := TIniFile.Create(FConfigFile);
  try
    FGatewayEdit.Text := Ini.ReadString('gateway', 'url', DEFAULT_GATEWAY);
    FTokenEdit.Text := Ini.ReadString('gateway', 'token', '');
    FMode := Ini.ReadString('chat', 'mode', 'build');
    FSavedModel := Ini.ReadString('chat', 'model', '');
    FTemperatureEdit.Text := Ini.ReadString('chat', 'temperature', '');
    FMaxTokensEdit.Text := Ini.ReadString('chat', 'max_tokens', '');
    FSystemMemo.Lines.Text := Ini.ReadString('chat', 'system', '');
    FChatParamsVisible := False;
    FSidebarVisible := Ini.ReadBool('sidebar', 'visible', FSidebarVisible);
    FSessionDrawerWidth := Ini.ReadInteger('sidebar', 'width',
      Round(FSessionDrawerWidth));
    FDarkStyleEnabled := Ini.ReadBool('ui', 'dark_style', FDarkStyleEnabled);
    ApplyTheme;
    if FChatParamsLayout <> nil then
      FChatParamsLayout.Visible := FChatParamsVisible;
    RenderParamsButton;
    FChatToolsExpanded := Ini.ReadBool('chat', 'tool_details_expanded',
      FChatToolsExpanded);
    { Escape hatch: a style without the platform tool-button lookups renders
      icon-only buttons blank. icon_buttons=false restores text captions. }
    FIconButtons := Ini.ReadBool('ui', 'icon_buttons', FIconButtons);
    { BuildInterface has already created the button captioned "Tools +";
      restoring an expanded preference must move the label with it. }
    UpdateToolsToggleCaption;
    FOnboardingDismissed := Ini.ReadBool('onboarding', 'dismissed', False);
  finally
    Ini.Free;
  end;
  LoadChatParams('');
end;

procedure TMasterDetailForm.SaveLocalSettings;
var
  Ini: TIniFile;
begin
  if FGatewayEdit = nil then
    Exit;
  Ini := TIniFile.Create(FConfigFile);
  try
    Ini.WriteString('gateway', 'url', GatewayBaseUrl);
    Ini.WriteString('gateway', 'token', FTokenEdit.Text);
    Ini.WriteString('chat', 'mode', FMode);
    Ini.WriteString('chat', 'model', CurrentModel);
    Ini.WriteString('chat', 'temperature', Trim(FTemperatureEdit.Text));
    Ini.WriteString('chat', 'max_tokens', Trim(FMaxTokensEdit.Text));
    Ini.WriteString('chat', 'system', FSystemMemo.Lines.Text);
    Ini.WriteBool('chat', 'params_visible', False);
    Ini.WriteBool('sidebar', 'visible', FSidebarVisible);
    if (FSessionDrawer <> nil) and (FSessionDrawer.Mode = TMultiViewMode.Panel) and
      FSessionDrawer.Visible and (FSessionDrawer.Width > 0) then
      FSessionDrawerWidth := FSessionDrawer.Width;
    Ini.WriteInteger('sidebar', 'width', Round(FSessionDrawerWidth));
    Ini.WriteBool('ui', 'dark_style', FDarkStyleEnabled);
    { Web-UI parity (pasclaw.tooldetails.v1): the tool-card expand/collapse
      choice is a per-operator preference, not per-session -- it was toggled
      at runtime but reset to collapsed on every restart. }
    Ini.WriteBool('chat', 'tool_details_expanded', FChatToolsExpanded);
    Ini.WriteBool('ui', 'icon_buttons', FIconButtons);
    Ini.WriteBool('onboarding', 'dismissed', FOnboardingDismissed);
  finally
    Ini.Free;
  end;
end;

procedure TMasterDetailForm.UpdateSandboxLabelFromConfig(const JsonText: string);
var
  Backend: string;
  DockerObj: TJSONObject;
  Image: string;
  Obj: TJSONObject;
  RestrictText: string;
  Root: TJSONValue;
  SandboxObj: TJSONObject;
  ShellText: string;
  Value: TJSONValue;
  Workspace: string;
begin
  if FSandboxLabel = nil then
    Exit;

  Backend := 'local';
  Image := '';
  Workspace := '(startup working dir)';
  RestrictText := 'filesystem unrestricted';
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if Root is TJSONObject then
    begin
      Obj := TJSONObject(Root);
      Backend := Trim(JsonAsString(Obj, 'shell_backend'));
      if Backend = '' then
        Backend := 'local';

      Value := Obj.GetValue('sandbox');
      if Value is TJSONObject then
      begin
        SandboxObj := TJSONObject(Value);
        if JsonAsString(SandboxObj, 'workspace') <> '' then
          Workspace := JsonAsString(SandboxObj, 'workspace');
        if JsonAsBool(SandboxObj, 'restrict_to_workspace') then
          RestrictText := 'restricted to workspace';
      end;

      Value := Obj.GetValue('shell_backend_docker');
      if Value is TJSONObject then
      begin
        DockerObj := TJSONObject(Value);
        Image := JsonAsString(DockerObj, 'image');
      end;
    end;
  finally
    Root.Free;
  end;

  if SameText(Backend, 'docker') then
  begin
    ShellText := 'shell: docker';
    if Image <> '' then
      ShellText := ShellText + ' (' + Image + ')';
  end
  else
    ShellText := 'shell: local';

  FSandboxLabel.Text := ShellText + ' | workspace: ' + Workspace +
    ' | ' + RestrictText;
  FSandboxLabel.Hint := FSandboxLabel.Text;
end;

procedure TMasterDetailForm.LoadSandboxStatus;
var
  Base: string;
  SessionId: string;
  Token: string;
begin
  if FSandboxLabel <> nil then
    FSandboxLabel.Text := 'shell: loading...';
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET', '/v1/config',
          '', '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('config HTTP %d', [Status]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        begin
          if ErrorText <> '' then
          begin
            if FSandboxLabel <> nil then
            begin
              FSandboxLabel.Text := 'shell: local | config unavailable';
              FSandboxLabel.Hint := ErrorText;
            end;
            Exit;
          end;
          UpdateSandboxLabelFromConfig(ResponseText);
        end);
    end);
end;

procedure TMasterDetailForm.RefreshClick(Sender: TObject);
begin
  SaveLocalSettings;
  SetStatus('connecting...');
  LoadSessions;
  LoadModels;
  LoadSandboxStatus;
  FetchEndpoint('settings', 'GET', '/v1/status', '');
  CheckFirstBootOnboarding;
end;

procedure TMasterDetailForm.CronClearClick(Sender: TObject);
var
  Memo: TMemo;
begin
  if FCronIdEdit <> nil then
    FCronIdEdit.Text := '';
  if FCronSpecEdit <> nil then
    FCronSpecEdit.Text := '';
  if FCronSkillEdit <> nil then
    FCronSkillEdit.Text := '';
  if FCronArgsEdit <> nil then
    FCronArgsEdit.Text := '';
  if FCronChannelKindEdit <> nil then
    FCronChannelKindEdit.Text := '';
  if FCronChannelTargetEdit <> nil then
    FCronChannelTargetEdit.Text := '';
  if FCronEnabledCheck <> nil then
    FCronEnabledCheck.IsChecked := True;
  if FCronList <> nil then
    FCronList.ItemIndex := -1;
  if FCronDetailTitleLabel <> nil then
    FCronDetailTitleLabel.Text := 'New Cron Job';
  if FCronDetailMetaLabel <> nil then
    FCronDetailMetaLabel.Text := 'Draft schedule';
  if FCronDetailMemo <> nil then
    FCronDetailMemo.Lines.Text := 'Enter an id, cron spec, skill, args, and optional channel.';
  if FPaneMemos.TryGetValue('cron', Memo) then
    { the title label above this memo already says "New Cron Job" -- an
      ASCII-underlined repeat of it inside the memo is terminal dressing }
    Memo.Lines.Text := 'Enter an id, cron spec, skill, args, and optional channel.';
  SetStatus('new cron job');
end;

procedure TMasterDetailForm.CronLoadFromJson(const JsonText: string);
var
  Obj: TJSONObject;
  Root: TJSONValue;
begin
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    if FCronIdEdit <> nil then
      FCronIdEdit.Text := JsonAsString(Obj, 'id');
    if FCronSpecEdit <> nil then
      FCronSpecEdit.Text := JsonAsString(Obj, 'spec');
    if FCronSkillEdit <> nil then
      FCronSkillEdit.Text := JsonAsString(Obj, 'skill');
    if FCronArgsEdit <> nil then
      FCronArgsEdit.Text := JsonAsString(Obj, 'args');
    if FCronChannelKindEdit <> nil then
      FCronChannelKindEdit.Text := JsonAsString(Obj, 'channel_kind');
    if FCronChannelTargetEdit <> nil then
      FCronChannelTargetEdit.Text := JsonAsString(Obj, 'channel_target');
    if FCronEnabledCheck <> nil then
      FCronEnabledCheck.IsChecked := (Obj.GetValue('enabled') = nil) or
        JsonAsBool(Obj, 'enabled');
  finally
    Root.Free;
  end;
end;

procedure TMasterDetailForm.CronListChange(Sender: TObject);
var
  Args: string;
  Channel: string;
  Memo: TMemo;
  Obj: TJSONObject;
  Root: TJSONValue;
  Text: TStringBuilder;
begin
  if (FCronList = nil) or (FCronList.Selected = nil) then
    Exit;
  CronLoadFromJson(FCronList.Selected.TagString);
  if not FPaneMemos.TryGetValue('cron', Memo) then
    Exit;

  Root := TJSONObject.ParseJSONValue(FCronList.Selected.TagString);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Channel := '--';
    if JsonAsString(Obj, 'channel_kind') <> '' then
      Channel := JsonAsString(Obj, 'channel_kind') + ':' +
        JsonAsString(Obj, 'channel_target');
    Args := JsonAsString(Obj, 'args');
    if Args = '' then
      Args := '(none)';
    if FCronDetailTitleLabel <> nil then
      FCronDetailTitleLabel.Text := JsonAsString(Obj, 'id');
    if FCronDetailMetaLabel <> nil then
      FCronDetailMetaLabel.Text := JsonAsString(Obj, 'spec') + '  |  ' +
        JsonAsString(Obj, 'skill') + '  |  ' + Channel;
    if FCronDetailMemo <> nil then
      FCronDetailMemo.Lines.Text := 'Enabled: ' +
        BoolToStr(JsonAsBool(Obj, 'enabled'), True) + sLineBreak +
        'Args: ' + Args;

    Text := TStringBuilder.Create;
    try
      Text.AppendLine('Cron Job');
      Text.AppendLine;
      Text.AppendLine(Format('%-12s %s', ['Id', JsonAsString(Obj, 'id')]));
      Text.AppendLine(Format('%-12s %s', ['Spec', JsonAsString(Obj, 'spec')]));
      Text.AppendLine(Format('%-12s %s', ['Skill', JsonAsString(Obj, 'skill')]));
      Text.AppendLine(Format('%-12s %s', ['Channel', Channel]));
      Text.AppendLine(Format('%-12s %s', ['Enabled',
        BoolToStr(JsonAsBool(Obj, 'enabled'), True)]));
      Text.AppendLine;
      Text.AppendLine('Args:');
      Text.AppendLine(Args);
      Text.AppendLine;
      Text.AppendLine('Raw JSON:');
      Text.Append(Obj.ToJSON);
      Memo.Lines.Text := Text.ToString;
    finally
      Text.Free;
    end;
    SetStatus('cron job selected');
  finally
    Root.Free;
  end;
end;

procedure TMasterDetailForm.CronRefreshClick(Sender: TObject);
var
  Base: string;
  SessionId: string;
  Token: string;
begin
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('loading cron...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET', '/v1/cron',
          '', '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('cron HTTP %d: %s', [Status, ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Arr: TJSONArray;
          Channel: string;
          I: Integer;
          DetailText: string;
          Memo: TMemo;
          Root: TJSONValue;
          Row: TJSONObject;
          Value: TJSONValue;
        begin
          if FCronList <> nil then
            FCronList.Clear;
          if ErrorText <> '' then
          begin
            if FCronStatusLabel <> nil then
              FCronStatusLabel.Text := 'Cron failed: ' + ErrorText;
            SetStatus('cron failed');
            Exit;
          end;
          Root := TJSONObject.ParseJSONValue(ResponseText);
          try
            if Root is TJSONObject then
            begin
              Value := TJSONObject(Root).GetValue('entries');
              if (Value is TJSONArray) and (FCronList <> nil) then
              begin
                Arr := TJSONArray(Value);
                for I := 0 to Arr.Count - 1 do
                  if Arr.Items[I] is TJSONObject then
                  begin
                    Row := TJSONObject(Arr.Items[I]);
                    Channel := '--';
                    if JsonAsString(Row, 'channel_kind') <> '' then
                      Channel := JsonAsString(Row, 'channel_kind') + ':' +
                        JsonAsString(Row, 'channel_target');
                    DetailText := JsonAsString(Row, 'spec') + '  |  ' +
                      JsonAsString(Row, 'skill') + '  |  ' + Channel;
                    if JsonAsString(Row, 'args') <> '' then
                      DetailText := DetailText + '  |  args: ' +
                        JsonAsString(Row, 'args');
                    AddCardListItem(FCronList, JsonAsString(Row, 'id'),
                      DetailText, Row.ToJSON, 62, JsonAsBool(Row, 'enabled'));
                  end;
              end;
            end;
          finally
            Root.Free;
          end;
          if (FCronList <> nil) and (FCronList.Count > 0) then
            FCronList.ItemIndex := 0;
          if FCronStatusLabel <> nil then
            FCronStatusLabel.Text := Format('%d cron entrie(s)',
              [IfThen(FCronList <> nil, FCronList.Count, 0)]);
          if FPaneMemos.TryGetValue('cron', Memo) then
            Memo.Lines.Text := 'GET /v1/cron' + sLineBreak + 'HTTP ' +
              Status.ToString + sLineBreak + sLineBreak +
              FormatCronText(ResponseText);
          AddListEmptyState(FCronList,
            'No cron jobs yet. Fill in the editor and press Save to schedule one.');
          SetStatus('cron loaded');
        end);
    end);
end;

procedure TMasterDetailForm.CronSaveClick(Sender: TObject);
var
  ArgsText: string;
  Base: string;
  BodyText: string;
  ChannelKindText: string;
  ChannelTargetText: string;
  CronObj: TJSONObject;
  IdText: string;
  SessionId: string;
  SkillText: string;
  SpecText: string;
  Token: string;
begin
  IdText := Trim(FCronIdEdit.Text);
  SpecText := Trim(FCronSpecEdit.Text);
  SkillText := Trim(FCronSkillEdit.Text);
  ArgsText := Trim(FCronArgsEdit.Text);
  ChannelKindText := Trim(FCronChannelKindEdit.Text);
  ChannelTargetText := Trim(FCronChannelTargetEdit.Text);
  if IdText = '' then
  begin
    SetStatus('cron id is required');
    Exit;
  end;
  if SpecText = '' then
  begin
    SetStatus('cron spec is required');
    Exit;
  end;
  if SkillText = '' then
  begin
    SetStatus('cron skill is required');
    Exit;
  end;

  CronObj := TJSONObject.Create;
  try
    CronObj.AddPair('id', IdText);
    CronObj.AddPair('spec', SpecText);
    CronObj.AddPair('skill', SkillText);
    CronObj.AddPair('args', ArgsText);
    AddJsonBool(CronObj, 'enabled',
      (FCronEnabledCheck = nil) or FCronEnabledCheck.IsChecked);
    CronObj.AddPair('channel_kind', ChannelKindText);
    CronObj.AddPair('channel_target', ChannelTargetText);
    BodyText := CronObj.ToJSON;
  finally
    CronObj.Free;
  end;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('saving cron job...');

  TTask.Run(
    procedure
    var
      Config: TJSONObject;
      ConfigText: string;
      CronValue: TJSONValue;
      ErrorText: string;
      I: Integer;
      Item: TJSONValue;
      NewCrons: TJSONArray;
      Pair: TJSONPair;
      Replaced: Boolean;
      ResponseText: string;
      Root: TJSONValue;
      Row: TJSONObject;
      SavedConfigText: string;
      Status: Integer;
      Value: TJSONValue;
    begin
      Root := nil;
      NewCrons := nil;
      try
        try
          ConfigText := HttpText(Base, Token, SessionId, 'GET', '/v1/config',
            '', '', 'application/json', Status);
          if not IsHttpOk(Status) then
            raise Exception.CreateFmt('config HTTP %d: %s', [Status,
              ConfigText]);

          Root := TJSONObject.ParseJSONValue(ConfigText);
          if Root is TJSONObject then
            Config := TJSONObject(Root)
          else
          begin
            Root.Free;
            Config := TJSONObject.Create;
            Root := Config;
          end;

          NewCrons := TJSONArray.Create;
          Replaced := False;
          Value := Config.GetValue('crons');
          if Value is TJSONArray then
            for I := 0 to TJSONArray(Value).Count - 1 do
            begin
              Item := TJSONArray(Value).Items[I];
              if Item is TJSONObject then
              begin
                Row := TJSONObject(Item);
                if SameText(JsonAsString(Row, 'id'), IdText) then
                begin
                  CronValue := TJSONObject.ParseJSONValue(BodyText);
                  if CronValue <> nil then
                    NewCrons.AddElement(CronValue);
                  Replaced := True;
                end
                else
                begin
                  CronValue := CloneJsonValue(Item);
                  if CronValue <> nil then
                    NewCrons.AddElement(CronValue);
                end;
              end
              else
              begin
                CronValue := CloneJsonValue(Item);
                if CronValue <> nil then
                  NewCrons.AddElement(CronValue);
              end;
            end;
          if not Replaced then
          begin
            CronValue := TJSONObject.ParseJSONValue(BodyText);
            if CronValue <> nil then
              NewCrons.AddElement(CronValue);
          end;

          Pair := Config.RemovePair('crons');
          Pair.Free;
          Config.AddPair('crons', NewCrons);
          NewCrons := nil;
          SavedConfigText := Config.ToJSON;

          ResponseText := HttpText(Base, Token, SessionId, 'PUT', '/v1/config',
            SavedConfigText, 'application/json', 'application/json', Status);
          if not IsHttpOk(Status) then
            raise Exception.CreateFmt('config save HTTP %d: %s', [Status,
              ResponseText]);
        except
          on E: Exception do
            ErrorText := E.Message;
        end;

        TThread.Queue(nil,
          procedure
          var
            BodyMemo: TMemo;
            Memo: TMemo;
          begin
            if ErrorText <> '' then
            begin
              SetStatus('cron save failed: ' + ErrorText);
              Exit;
            end;
            if FEndpointBodyMemos.TryGetValue('settings', BodyMemo) then
              BodyMemo.Lines.Text := SavedConfigText;
            if FPaneMemos.TryGetValue('cron', Memo) then
              Memo.Lines.Text := 'PUT /v1/config' + sLineBreak + 'HTTP ' +
                Status.ToString + sLineBreak + sLineBreak +
                'Saved cron job: ' + IdText;
            ConfigRenderEditor;
            CronRefreshClick(nil);
            SetStatus('cron job saved');
          end);
      finally
        NewCrons.Free;
        Root.Free;
      end;
    end);
end;

procedure TMasterDetailForm.CronRemoveClick(Sender: TObject);
var
  Base: string;
  IdText: string;
  SessionId: string;
  Token: string;
begin
  IdText := Trim(FCronIdEdit.Text);
  if IdText = '' then
  begin
    SetStatus('select or enter a cron id');
    Exit;
  end;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('removing cron job...');

  TTask.Run(
    procedure
    var
      Config: TJSONObject;
      ConfigText: string;
      CronValue: TJSONValue;
      ErrorText: string;
      I: Integer;
      Item: TJSONValue;
      NewCrons: TJSONArray;
      Pair: TJSONPair;
      Removed: Boolean;
      ResponseText: string;
      Root: TJSONValue;
      Row: TJSONObject;
      SavedConfigText: string;
      Status: Integer;
      Value: TJSONValue;
    begin
      Root := nil;
      NewCrons := nil;
      try
        try
          ConfigText := HttpText(Base, Token, SessionId, 'GET', '/v1/config',
            '', '', 'application/json', Status);
          if not IsHttpOk(Status) then
            raise Exception.CreateFmt('config HTTP %d: %s', [Status,
              ConfigText]);

          Root := TJSONObject.ParseJSONValue(ConfigText);
          if Root is TJSONObject then
            Config := TJSONObject(Root)
          else
            raise Exception.Create('config JSON root is not an object');

          NewCrons := TJSONArray.Create;
          Removed := False;
          Value := Config.GetValue('crons');
          if Value is TJSONArray then
            for I := 0 to TJSONArray(Value).Count - 1 do
            begin
              Item := TJSONArray(Value).Items[I];
              if Item is TJSONObject then
              begin
                Row := TJSONObject(Item);
                if SameText(JsonAsString(Row, 'id'), IdText) then
                  Removed := True
                else
                begin
                  CronValue := CloneJsonValue(Item);
                  if CronValue <> nil then
                    NewCrons.AddElement(CronValue);
                end;
              end
              else
              begin
                CronValue := CloneJsonValue(Item);
                if CronValue <> nil then
                  NewCrons.AddElement(CronValue);
              end;
            end;
          if not Removed then
            raise Exception.Create('cron job not found: ' + IdText);

          Pair := Config.RemovePair('crons');
          Pair.Free;
          Config.AddPair('crons', NewCrons);
          NewCrons := nil;
          SavedConfigText := Config.ToJSON;

          ResponseText := HttpText(Base, Token, SessionId, 'PUT', '/v1/config',
            SavedConfigText, 'application/json', 'application/json', Status);
          if not IsHttpOk(Status) then
            raise Exception.CreateFmt('config save HTTP %d: %s', [Status,
              ResponseText]);
        except
          on E: Exception do
            ErrorText := E.Message;
        end;

        TThread.Queue(nil,
          procedure
          var
            BodyMemo: TMemo;
            Memo: TMemo;
          begin
            if ErrorText <> '' then
            begin
              SetStatus('cron remove failed: ' + ErrorText);
              Exit;
            end;
            if FEndpointBodyMemos.TryGetValue('settings', BodyMemo) then
              BodyMemo.Lines.Text := SavedConfigText;
            if FPaneMemos.TryGetValue('cron', Memo) then
              Memo.Lines.Text := 'PUT /v1/config' + sLineBreak + 'HTTP ' +
                Status.ToString + sLineBreak + sLineBreak +
                'Removed cron job: ' + IdText;
            CronClearClick(nil);
            ConfigRenderEditor;
            CronRefreshClick(nil);
            SetStatus('cron job removed');
          end);
      finally
        NewCrons.Free;
        Root.Free;
      end;
    end);
end;

procedure TMasterDetailForm.StatsRefreshClick(Sender: TObject);
var
  Base: string;
  SessionId: string;
  Token: string;
begin
  if FStatsTimer <> nil then
    FStatsTimer.Enabled := (FStatsAutoRefreshCheck <> nil) and
      FStatsAutoRefreshCheck.IsChecked;
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('loading stats...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET', '/v1/stats',
          '', '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('stats HTTP %d: %s', [Status, ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Memo: TMemo;
          Obj: TJSONObject;
          Root: TJSONValue;
          Value: TJSONValue;
          procedure AddSummary(const Name, ValueText: string);
          var
            Card: TRectangle;
            It: TListBoxItem;
            NameLabel: TLabel;
            ValueLabel: TLabel;
          begin
            It := TListBoxItem.Create(FStatsSummaryList);
            It.Parent := FStatsSummaryList;
            It.Text := '';
            It.Height := ROW_CARD;
            It.HitTest := False;

            Card := TRectangle.Create(It);
            Card.Parent := It;
            Card.Align := TAlignLayout.Client;
            StyleChromeRect(Card, UI_PANEL_ALT, UI_BORDER, 4, False);
            SetControlMargins(Card, 0, 3, 0, 3);
            SetControlPadding(Card, 10, 5, 10, 5);

            NameLabel := TLabel.Create(Card);
            NameLabel.Parent := Card;
            NameLabel.Align := TAlignLayout.Top;
            NameLabel.Height := 18;
            NameLabel.Text := Name;
            NameLabel.StyledSettings := NameLabel.StyledSettings - [TStyledSetting.Size];
            UseStyledLabelColor(NameLabel);
            NameLabel.TextSettings.Font.Size := TXT_BODY;

            ValueLabel := TLabel.Create(Card);
            ValueLabel.Parent := Card;
            ValueLabel.Align := TAlignLayout.Client;
            ValueLabel.Text := ValueText;
            ValueLabel.StyledSettings := ValueLabel.StyledSettings -
              [TStyledSetting.FontColor, TStyledSetting.Size,
              TStyledSetting.Style];
            UseStyledLabelColor(ValueLabel);
            ValueLabel.TextSettings.Font.Size := TXT_DISPLAY;
            ValueLabel.TextSettings.Font.Style := [TFontStyle.fsBold];
            ValueLabel.TextSettings.VertAlign := TTextAlign.Center;
          end;
          procedure AddTokenRows(Target: TListBox; Items: TJSONArray;
            const NameKey: string);
          var
            Count: Integer;
            I: Integer;
            DetailText: string;
            J: Integer;
            NameValue: string;
            Names: TArray<string>;
            RowObj: TJSONObject;
            TempName: string;
            TempToken: Int64;
            Tokens: TArray<Int64>;
            TotalTokens: Int64;
          begin
            if (Target = nil) or (Items = nil) then
              Exit;
            SetLength(Names, Items.Count);
            SetLength(Tokens, Items.Count);
            Count := 0;
            TotalTokens := 0;
            for I := 0 to Items.Count - 1 do
              if Items.Items[I] is TJSONObject then
              begin
                RowObj := TJSONObject(Items.Items[I]);
                NameValue := JsonAsString(RowObj, NameKey);
                if NameValue = '' then
                  NameValue := '(unknown)';
                Names[Count] := NameValue;
                Tokens[Count] := JsonAsInt64(RowObj, 'tokens');
                Inc(TotalTokens, Tokens[Count]);
                Inc(Count);
              end;

            for I := 0 to Count - 2 do
              for J := I + 1 to Count - 1 do
                if Tokens[J] > Tokens[I] then
                begin
                  TempToken := Tokens[I];
                  Tokens[I] := Tokens[J];
                  Tokens[J] := TempToken;
                  TempName := Names[I];
                  Names[I] := Names[J];
                  Names[J] := TempName;
                end;

            if Count = 0 then
            begin
              AddCardListItem(Target, 'No data', 'No token rows returned', '',
                48, False);
              Exit;
            end;

            for I := 0 to Count - 1 do
            begin
              DetailText := Tokens[I].ToString + ' tokens';
              if TotalTokens > 0 then
                DetailText := DetailText + Format('  -  %.1f%% of total',
                  [Tokens[I] * 100.0 / TotalTokens]);
              AddCardListItem(Target, Names[I], DetailText, Names[I], 48,
                I = 0);
            end;
          end;
        begin
          { unchanged payload -> unchanged UI. Skipping the rebuild is what
            keeps an idle auto-refresh from freeing rows under the pointer
            every tick (see StatsTimerTick). }
          if ErrorText + '|' + ResponseText = FLastStatsPayload then
          begin
            SetStatus('stats unchanged');
            Exit;
          end;
          FLastStatsPayload := ErrorText + '|' + ResponseText;
          if FStatsSummaryList <> nil then
            FStatsSummaryList.Clear;
          if FStatsProviderList <> nil then
            FStatsProviderList.Clear;
          if FStatsModelList <> nil then
            FStatsModelList.Clear;
          if ErrorText <> '' then
          begin
            if FStatsStatusLabel <> nil then
              FStatsStatusLabel.Text := 'Stats failed: ' + ErrorText;
            SetStatus('stats failed');
            Exit;
          end;
          Root := TJSONObject.ParseJSONValue(ResponseText);
          try
            if Root is TJSONObject then
            begin
              Obj := TJSONObject(Root);
              if FStatsStatusLabel <> nil then
                if JsonAsBool(Obj, 'stats_collection_enabled') then
                  FStatsStatusLabel.Text := 'Aggregating ' +
                    JsonAsInt64(Obj, 'sessions').ToString + ' session(s)'
                else
                  FStatsStatusLabel.Text := 'Stats collection is disabled';
              if FStatsSummaryList <> nil then
              begin
                AddSummary('Sessions', JsonAsInt64(Obj, 'sessions').ToString);
                AddSummary('Turns', JsonAsInt64(Obj, 'turns').ToString);
                AddSummary('Tool calls', JsonAsInt64(Obj, 'tool_calls').ToString);
                AddSummary('Input tokens', JsonAsInt64(Obj, 'input_tokens').ToString);
                AddSummary('Output tokens', JsonAsInt64(Obj, 'output_tokens').ToString);
                AddSummary('Cache read', JsonAsInt64(Obj, 'cache_read_tokens').ToString);
                AddSummary('Cache created', JsonAsInt64(Obj, 'cache_created_tokens').ToString);
                AddSummary('Bytes saved',
                  FormatBytes(JsonAsInt64(Obj, 'truncation_bytes_saved')));
              end;
              Value := Obj.GetValue('by_provider');
              if Value is TJSONArray then
                AddTokenRows(FStatsProviderList, TJSONArray(Value), 'provider');
              Value := Obj.GetValue('by_model');
              if Value is TJSONArray then
                AddTokenRows(FStatsModelList, TJSONArray(Value), 'model');
            end;
          finally
            Root.Free;
          end;
          if FPaneMemos.TryGetValue('stats', Memo) then
            Memo.Lines.Text := 'GET /v1/stats' + sLineBreak + 'HTTP ' +
              Status.ToString + sLineBreak + sLineBreak +
              FormatStatsText(ResponseText);
          SetStatus('stats loaded');
        end);
    end);
end;

procedure TMasterDetailForm.StatsTimerTick(Sender: TObject);
{ Auto-refresh discipline, here and in RelayTimerTick. The naive tick did a
  full clear-and-rebuild of the tab's list boxes every interval, forever,
  even with the app idle on another tab. Freeing rows the pointer is resting
  on (FMX keeps a hovered-control reference) or that hold the selection is
  the classic intermittent access violation -- the app "AVs just sitting
  there". Three rules:
    1. only refresh the tab you can see (the web UI does the same);
    2. an unchanged payload repaints nothing (checked in the render closure);
    3. rebuilds detach OnChange while the old rows die. }
begin
  if (FStatsAutoRefreshCheck = nil) or not FStatsAutoRefreshCheck.IsChecked then
  begin
    if FStatsTimer <> nil then
      FStatsTimer.Enabled := False;
    Exit;
  end;
  if ActiveTabIs('Stats') then
    StatsRefreshClick(nil);
end;

function TMasterDetailForm.ActiveTabIs(const Caption: string): Boolean;
begin
  Result := (FTabControl <> nil) and (FTabControl.TabIndex >= 0) and
    (FTabControl.TabIndex < FTabControl.TabCount) and
    SameText(FTabControl.Tabs[FTabControl.TabIndex].Text, Caption);
end;

procedure TMasterDetailForm.SetButtonWidth(Button: TButton; W: Single);
{ The ONE place a responsive width is applied to a button.

  An iconified button's width belongs to the icon system (ICON_BTN_W), and
  the layout pass runs on construction, on every resize, and right after a
  toggle -- so any width it writes wins. Guarding each call site was tried
  and failed the way per-site rules always do here: two of them were added
  with the icons and the two that already existed were missed, leaving
  Params and Tools as wide, mostly empty pills. The rule lives here now, so
  a new call site cannot forget it. }
begin
  if (Button = nil) or IsIconified(Button) then
    Exit;
  Button.Width := W;
end;

class function TMasterDetailForm.IsIconified(Button: TButton): Boolean;
{ Blank caption + hint showing is ApplyButtonIcon's signature. While it
  holds, that system owns the button's face and width -- responsive layout
  re-captioning or re-widening it would grow a 34px icon into a wide blank
  pill on every resize. }
begin
  Result := (Button <> nil) and (Button.Text = '') and Button.ShowHint;
end;

function TMasterDetailForm.FriendlyAge(const StampText: string): string;
{ '2h ago' beats a raw timestamp in a sidebar. The gateway sends unix epoch
  seconds for session updated_at; ISO 8601 is accepted too since import paths
  produce it. Anything unparseable comes back verbatim -- never worse than
  before. }
var
  Epoch: Int64;
  Mins: Int64;
  Stamp: TDateTime;
begin
  Result := StampText;
  if TryStrToInt64(Trim(StampText), Epoch) and (Epoch > 100000000) then
    Stamp := TTimeZone.Local.ToLocalTime(UnixToDateTime(Epoch))
  else if not TryISO8601ToDate(StampText, Stamp, False) then
    Exit;
  Mins := MinutesBetween(Now, Stamp);
  if Mins < 1 then
    Result := 'just now'
  else if Mins < 60 then
    Result := Format('%dm ago', [Mins])
  else if Mins < 60 * 24 then
    Result := Format('%dh ago', [Mins div 60])
  else
    Result := Format('%dd ago', [Mins div (60 * 24)]);
end;

procedure TMasterDetailForm.CheckpointListChange(Sender: TObject);
var
  FileArr: TJSONArray;
  FileObj: TJSONObject;
  I: Integer;
  Lines: TStringBuilder;
  Obj: TJSONObject;
  Root: TJSONValue;
  Value: TJSONValue;
begin
  if (FCheckpointDetailMemo = nil) or (FCheckpointList = nil) or
    (FCheckpointList.Selected = nil) then
    Exit;
  Root := TJSONObject.ParseJSONValue(FCheckpointList.Selected.TagString);
  try
    if not (Root is TJSONObject) then
    begin
      FCheckpointDetailMemo.Lines.Text := FCheckpointList.Selected.TagString;
      Exit;
    end;
    Obj := TJSONObject(Root);
    Lines := TStringBuilder.Create;
    try
      Lines.AppendLine('Turn: ' + JsonAsInt64(Obj, 'turn').ToString);
      Lines.AppendLine('Timestamp: ' + JsonAsString(Obj, 'ts'));
      Lines.AppendLine;
      Lines.AppendLine('Files:');
      Value := Obj.GetValue('files');
      if Value is TJSONArray then
      begin
        FileArr := TJSONArray(Value);
        if FileArr.Count = 0 then
          Lines.AppendLine('(none)')
        else
          for I := 0 to FileArr.Count - 1 do
            if FileArr.Items[I] is TJSONObject then
            begin
              FileObj := TJSONObject(FileArr.Items[I]);
              if JsonAsBool(FileObj, 'created') then
                Lines.Append('+ ')
              else
                Lines.Append('~ ');
              Lines.AppendLine(JsonAsString(FileObj, 'path'));
            end;
      end
      else
        Lines.AppendLine('(no files listed)');
      FCheckpointDetailMemo.Lines.Text := Lines.ToString;
    finally
      Lines.Free;
    end;
  finally
    Root.Free;
  end;
end;

procedure TMasterDetailForm.CheckpointRefreshClick(Sender: TObject);
var
  Base: string;
  SessionId: string;
  Token: string;
begin
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('loading checkpoints...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET',
          '/v1/checkpoints', '', '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('checkpoints HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Arr: TJSONArray;
          FileArr: TJSONArray;
          FileCount: Integer;
          Card: TRectangle;
          FileLabel: TLabel;
          FileObj: TJSONObject;
          FileText: string;
          I: Integer;
          Item: TListBoxItem;
          J: Integer;
          Memo: TMemo;
          MetaLabel: TLabel;
          TurnLabel: TLabel;
          Obj: TJSONObject;
          Root: TJSONValue;
          Row: TJSONObject;
          Value: TJSONValue;
        begin
          if FCheckpointList <> nil then
            FCheckpointList.Clear;
          if ErrorText <> '' then
          begin
            if FCheckpointStatusLabel <> nil then
              FCheckpointStatusLabel.Text := 'Checkpoints failed: ' +
                ErrorText;
            SetStatus('checkpoints failed');
            Exit;
          end;
          Root := TJSONObject.ParseJSONValue(ResponseText);
          try
            if Root is TJSONObject then
            begin
              Obj := TJSONObject(Root);
              FCheckpointCurrentTurn := JsonAsInt64(Obj, 'current_turn');
              if FCheckpointStatusLabel <> nil then
                if JsonAsBool(Obj, 'enabled') then
                  FCheckpointStatusLabel.Text := Format('backend %s, current turn %d, %d checkpoint(s)%s',
                    [JsonAsString(Obj, 'backend'),
                    JsonAsInt64(Obj, 'current_turn'),
                    JsonAsInt64(Obj, 'count'),
                    IfThen(JsonAsBool(Obj, 'can_redo'), ', redo available',
                      '')])
                else
                  FCheckpointStatusLabel.Text := 'Checkpoints disabled';
              Value := Obj.GetValue('turns');
              if (Value is TJSONArray) and (FCheckpointList <> nil) then
              begin
                Arr := TJSONArray(Value);
                for I := Arr.Count - 1 downto 0 do
                  if Arr.Items[I] is TJSONObject then
                  begin
                    Row := TJSONObject(Arr.Items[I]);
                    FileCount := 0;
                    FileText := '';
                    Value := Row.GetValue('files');
                    if Value is TJSONArray then
                    begin
                      FileArr := TJSONArray(Value);
                      FileCount := FileArr.Count;
                      for J := 0 to Min(FileArr.Count - 1, 3) do
                        if FileArr.Items[J] is TJSONObject then
                        begin
                          FileObj := TJSONObject(FileArr.Items[J]);
                          if FileText <> '' then
                            FileText := FileText + sLineBreak;
                          if JsonAsBool(FileObj, 'created') then
                            FileText := FileText + '+ '
                          else
                            FileText := FileText + '~ ';
                          FileText := FileText + JsonAsString(FileObj, 'path');
                        end;
                      if FileArr.Count > 4 then
                        FileText := FileText + sLineBreak + Format('... %d more',
                          [FileArr.Count - 4]);
                    end;
                    if FileText = '' then
                      FileText := '(no files listed)';
                    Item := TListBoxItem.Create(FCheckpointList);
                    Item.Parent := FCheckpointList;
                    Item.Text := '';
                    Item.TagString := Row.ToJSON;
                    Item.Height := 104;
                    Item.HitTest := True;
                    Item.OnClick := CardListItemClick;

                    Card := TRectangle.Create(Item);
                    Card.Parent := Item;
                    Card.Align := TAlignLayout.Client;
                    StyleChromeRect(Card, UI_PANEL_ALT, UI_BORDER, 4, True);
                    Card.OnClick := CardListItemClick;
                    SetControlMargins(Card, 0, 3, 0, 3);
                    SetControlPadding(Card, 10, GAP_S, 10, GAP_S);

                    TurnLabel := TLabel.Create(Card);
                    TurnLabel.Parent := Card;
                    TurnLabel.Align := TAlignLayout.Top;
                    TurnLabel.HitTest := False;
                    TurnLabel.Height := ROW_TEXT;
                    TurnLabel.Text := Format('Turn %d',
                      [JsonAsInt64(Row, 'turn')]);
                    TurnLabel.StyledSettings := TurnLabel.StyledSettings -
                      [TStyledSetting.FontColor, TStyledSetting.Style];
                    UseStyledLabelColor(TurnLabel);
                    TurnLabel.TextSettings.Font.Style := [TFontStyle.fsBold];

                    MetaLabel := TLabel.Create(Card);
                    MetaLabel.Parent := Card;
                    MetaLabel.Align := TAlignLayout.Top;
                    MetaLabel.HitTest := False;
                    MetaLabel.Height := 18;
                    MetaLabel.Text := Format('%s  |  %d file(s)',
                      [JsonAsString(Row, 'ts'), FileCount]);
                    MetaLabel.StyledSettings := MetaLabel.StyledSettings -
                      [TStyledSetting.Size];
                    UseStyledLabelColor(MetaLabel);
                    MetaLabel.TextSettings.Font.Size := TXT_BODY;

                    FileLabel := TLabel.Create(Card);
                    FileLabel.Parent := Card;
                    FileLabel.Align := TAlignLayout.Client;
                    FileLabel.HitTest := False;
                    FileLabel.Text := FileText;
                    FileLabel.WordWrap := True;
                    FileLabel.StyledSettings := FileLabel.StyledSettings -
                      [TStyledSetting.Size];
                    UseStyledLabelColor(FileLabel);
                    FileLabel.TextSettings.Font.Size := TXT_BODY;
                  end;
              end;
              if (FCheckpointList <> nil) and (FCheckpointList.Count > 0) then
              begin
                FCheckpointList.ItemIndex := 0;
                CheckpointListChange(FCheckpointList);
              end
              else if FCheckpointDetailMemo <> nil then
                FCheckpointDetailMemo.Lines.Text := 'No checkpoints returned for this chat.';
            end;
          finally
            Root.Free;
          end;
          if FPaneMemos.TryGetValue('checkpoints', Memo) then
            Memo.Lines.Text := 'GET /v1/checkpoints' + sLineBreak +
              'HTTP ' + Status.ToString + sLineBreak + sLineBreak +
              FormatCheckpointText(ResponseText);
          AddListEmptyState(FCheckpointList,
            'No checkpoints yet. They appear as the agent edits workspace files.');
          SetStatus('checkpoints loaded');
        end);
    end);
end;

procedure TMasterDetailForm.CheckpointActionClick(Sender: TObject);
var
  Endpoint: string;
  Kind: string;
  N: Int64;
  Root: TJSONValue;
  Turn: Int64;
begin
  if Sender is TButton then
    Kind := TButton(Sender).TagString
  else
    Kind := '';

  if Kind = 'revert' then
  begin
    if (FCheckpointList = nil) or (FCheckpointList.Selected = nil) then
    begin
      SetStatus('select a checkpoint turn first');
      Exit;
    end;
    Turn := 0;
    Root := TJSONObject.ParseJSONValue(FCheckpointList.Selected.TagString);
    try
      if Root is TJSONObject then
        Turn := JsonAsInt64(TJSONObject(Root), 'turn');
    finally
      Root.Free;
    end;
    if Turn <= 0 then
    begin
      SetStatus('selected checkpoint has no turn');
      Exit;
    end;
    N := FCheckpointCurrentTurn - Turn + 1;
    if N < 1 then
    begin
      SetStatus('checkpoint is not before current turn');
      Exit;
    end;
    Endpoint := '/v1/checkpoints/undo?n=' + N.ToString;
  end
  else if (Kind = 'undo') or (Kind = 'redo') then
    Endpoint := '/v1/checkpoints/' + Kind + '?n=1'
  else
    Exit;

  FetchEndpoint('checkpoints', 'POST', Endpoint, '');
end;

procedure TMasterDetailForm.RelaySnippetCopyClick(Sender: TObject);
var
  Clipboard: IFMXClipboardService;
begin
  if (FRelaySnippetsMemo = nil) or (Trim(FRelaySnippetsMemo.Lines.Text) = '') then
  begin
    SetStatus('no relay snippets to copy');
    Exit;
  end;

  if TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService,
    IInterface(Clipboard)) then
  begin
    Clipboard.SetClipboard(TValue.From<string>(FRelaySnippetsMemo.Lines.Text));
    SetStatus('relay snippets copied');
  end
  else
    SetStatus('clipboard service unavailable');
end;

procedure TMasterDetailForm.RelayWorkerProfileChange(Sender: TObject);
var
  Profile: string;
begin
  Profile := ComboSelectedText(FRelayWorkerProfileCombo);
  if SameText(Profile, 'LocalPal') then
  begin
    if FRelayWorkerCommandEdit <> nil then
      FRelayWorkerCommandEdit.Text := 'pasclaw';
    if FRelayWorkerProviderEdit <> nil then
      FRelayWorkerProviderEdit.Text := 'localpal';
    if FRelayWorkerModelEdit <> nil then
      FRelayWorkerModelEdit.Text := 'localpal';
    if FRelayWorkerIdEdit <> nil then
      FRelayWorkerIdEdit.Text := 'localpal-' + IntToStr(WinGetCurrentProcessId);
    SetStatus('LocalPal relay profile selected');
  end
  else
    SetStatus('custom relay profile selected');
  RelayRenderSnippets(nil);
end;

procedure TMasterDetailForm.RelayRenderSnippets(Sender: TObject);
var
  Base: string;
  Cmd: string;
  LocalPalHint: string;
  ModelText: string;
  Profile: string;
  ProviderText: string;
  TokenText: string;
  WorkerId: string;
begin
  if FRelaySnippetsMemo = nil then
    Exit;

  if FRelayUrlEdit <> nil then
    Base := Trim(FRelayUrlEdit.Text)
  else
    Base := '';
  if Base = '' then
    Base := GatewayBaseUrl;
  if Base = '' then
    Base := 'http://127.0.0.1:7077';

  if (FRelayTokenEdit <> nil) and (FRelayTokenEdit.Text <> '') and
    not FRelayTokenEdit.Password then
    TokenText := FRelayTokenEdit.Text
  else
    TokenText := '<PASCLAW_RELAY_TOKEN>';

  if FRelayWorkerCommandEdit <> nil then
    Cmd := Trim(FRelayWorkerCommandEdit.Text)
  else
    Cmd := '';
  if Cmd = '' then
    Cmd := 'pasclaw';
  if FRelayWorkerIdEdit <> nil then
    WorkerId := Trim(FRelayWorkerIdEdit.Text)
  else
    WorkerId := '';
  if WorkerId = '' then
    WorkerId := 'fmx-worker';
  if FRelayWorkerModelEdit <> nil then
    ModelText := Trim(FRelayWorkerModelEdit.Text)
  else
    ModelText := '';
  if ModelText = '' then
    ModelText := '*';
  if FRelayWorkerProviderEdit <> nil then
    ProviderText := Trim(FRelayWorkerProviderEdit.Text)
  else
    ProviderText := '';
  Profile := ComboSelectedText(FRelayWorkerProfileCombo);
  LocalPalHint := '';
  if SameText(Profile, 'LocalPal') or SameText(ProviderText, 'localpal') then
    LocalPalHint := 'LocalPal prep' + sLineBreak +
      'localpal model catalog' + sLineBreak +
      'localpal model download smollm' + sLineBreak +
      'localpal chat "ready"' + sLineBreak + sLineBreak;

  FRelaySnippetsMemo.Lines.Text := LocalPalHint +
    'CLI flags' + sLineBreak +
    Cmd + ' relay --gateway-url "' + Base + '" --gateway-token "' + TokenText +
      '" --worker-id "' + WorkerId + '" --model "' + ModelText + '"' +
      IfThen(ProviderText <> '', ' --provider "' + ProviderText + '"', '') +
      sLineBreak + sLineBreak +
    'PowerShell env' + sLineBreak +
    '$env:PASCLAW_GATEWAY_URL="' + Base + '"' + sLineBreak +
    '$env:PASCLAW_RELAY_TOKEN="' + TokenText + '"' + sLineBreak +
    '$env:PASCLAW_RELAY_WORKER_ID="' + WorkerId + '"' + sLineBreak +
    '$env:PASCLAW_RELAY_CAPABILITIES="' + ModelText + '"' + sLineBreak +
    IfThen(ProviderText <> '', '$env:PASCLAW_PROVIDER="' + ProviderText + '"' + sLineBreak, '') +
    Cmd + ' relay';
end;

procedure TMasterDetailForm.RelayTimerTick(Sender: TObject);
{ same discipline as StatsTimerTick -- see the comment there }
begin
  if (FRelayAutoRefreshCheck = nil) or not FRelayAutoRefreshCheck.IsChecked then
  begin
    if FRelayTimer <> nil then
      FRelayTimer.Enabled := False;
    Exit;
  end;
  if ActiveTabIs('Relay') then
    RelayRefreshClick(nil);
end;

procedure TMasterDetailForm.RelayWorkerListChange(Sender: TObject);
var
  Caps: string;
  CapsArr: TJSONArray;
  I: Integer;
  Obj: TJSONObject;
  Root: TJSONValue;
  Value: TJSONValue;
begin
  if (FRelayWorkersList = nil) or (FRelayWorkersList.Selected = nil) or
    (FRelayWorkersList.Selected.TagString = '') then
    Exit;

  Root := TJSONObject.ParseJSONValue(FRelayWorkersList.Selected.TagString);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Caps := '';
    Value := Obj.GetValue('caps');
    if Value is TJSONArray then
    begin
      CapsArr := TJSONArray(Value);
      for I := 0 to CapsArr.Count - 1 do
      begin
        if Caps <> '' then
          Caps := Caps + ', ';
        Caps := Caps + CapsArr.Items[I].Value;
      end;
    end;
    if Caps = '' then
      Caps := '(wildcard)';

    if FRelayWorkerDetailTitleLabel <> nil then
      FRelayWorkerDetailTitleLabel.Text := JsonAsString(Obj, 'id');
    if FRelayWorkerDetailMetaLabel <> nil then
      FRelayWorkerDetailMetaLabel.Text := Caps;
    if FRelayWorkerDetailMemo <> nil then
      FRelayWorkerDetailMemo.Lines.Text := Format('Requests seen: %d%sLast seen: %s',
        [JsonAsInt64(Obj, 'requests_seen'), sLineBreak,
        JsonAsString(Obj, 'last_seen')]);
    SetStatus('relay worker selected');
  finally
    Root.Free;
  end;
end;

procedure TMasterDetailForm.RelayRefreshClick(Sender: TObject);
var
  Base: string;
  SessionId: string;
  Token: string;
begin
  if FRelayTimer <> nil then
    FRelayTimer.Enabled := (FRelayAutoRefreshCheck <> nil) and
      FRelayAutoRefreshCheck.IsChecked;
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  if FRelayUrlEdit <> nil then
    FRelayUrlEdit.Text := Base;
  SetStatus('loading relay status...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET',
          '/v1/relay/status', '', '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('relay HTTP %d: %s', [Status, ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Arr: TJSONArray;
          Caps: string;
          CapsArr: TJSONArray;
          I: Integer;
          J: Integer;
          Memo: TMemo;
          Obj: TJSONObject;
          Root: TJSONValue;
          Row: TJSONObject;
          Value: TJSONValue;
          procedure AddMetric(const Name, ValueText: string);
          var
            Card: TRectangle;
            It: TListBoxItem;
            NameLabel: TLabel;
            ValueLabel: TLabel;
          begin
            It := TListBoxItem.Create(FRelayStatsList);
            It.Parent := FRelayStatsList;
            It.Text := '';
            It.Height := ROW_CARD;

            Card := TRectangle.Create(It);
            Card.Parent := It;
            Card.Align := TAlignLayout.Client;
            StyleChromeRect(Card, UI_PANEL_ALT, UI_BORDER, 4, False);
            SetControlMargins(Card, 0, 3, 0, 3);
            SetControlPadding(Card, 10, GAP_S, 10, GAP_S);

            NameLabel := TLabel.Create(Card);
            NameLabel.Parent := Card;
            NameLabel.Align := TAlignLayout.Top;
            NameLabel.Height := 18;
            NameLabel.Text := Name;
            NameLabel.StyledSettings := NameLabel.StyledSettings - [TStyledSetting.Size];
            UseStyledLabelColor(NameLabel);
            NameLabel.TextSettings.Font.Size := TXT_BODY;

            ValueLabel := TLabel.Create(Card);
            ValueLabel.Parent := Card;
            ValueLabel.Align := TAlignLayout.Client;
            ValueLabel.Text := ValueText;
            ValueLabel.StyledSettings := ValueLabel.StyledSettings -
              [TStyledSetting.FontColor, TStyledSetting.Size,
              TStyledSetting.Style];
            UseStyledLabelColor(ValueLabel);
            ValueLabel.TextSettings.Font.Size := TXT_DISPLAY;
            ValueLabel.TextSettings.Font.Style := [TFontStyle.fsBold];
            ValueLabel.TextSettings.VertAlign := TTextAlign.Center;
          end;
        begin
          { see StatsRefreshClick: identical payload means identical UI, so
            do not tear down and rebuild rows every 5-second tick }
          if ErrorText + '|' + ResponseText = FLastRelayPayload then
          begin
            SetStatus('relay unchanged');
            Exit;
          end;
          FLastRelayPayload := ErrorText + '|' + ResponseText;
          if FRelayStatsList <> nil then
            FRelayStatsList.Clear;
          if FRelayWorkersList <> nil then
          begin
            { the rebuild below reselects row 0 and calls the change handler
              itself; change events from a list mid-teardown act on dying
              rows }
            FRelayWorkersList.OnChange := nil;
            FRelayWorkersList.Clear;
          end;
          if ErrorText <> '' then
          begin
            if FRelayStatusLabel <> nil then
              FRelayStatusLabel.Text := 'Relay failed: ' + ErrorText;
            SetStatus('relay failed');
            if FRelayWorkersList <> nil then
              FRelayWorkersList.OnChange := RelayWorkerListChange;
            Exit;
          end;
          Root := TJSONObject.ParseJSONValue(ResponseText);
          try
            if Root is TJSONObject then
            begin
              Obj := TJSONObject(Root);
              if FRelayStatsList <> nil then
              begin
                AddMetric('Workers', JsonAsInt64(Obj, 'connected_workers').ToString);
                AddMetric('Pending', JsonAsInt64(Obj, 'pending_requests').ToString);
                AddMetric('Inflight', JsonAsInt64(Obj, 'inflight_requests').ToString);
                AddMetric('Completed', JsonAsInt64(Obj, 'total_completed').ToString);
                AddMetric('Failed', JsonAsInt64(Obj, 'total_failed').ToString);
              end;
              if FRelayStatusLabel <> nil then
                FRelayStatusLabel.Text := Format('%d worker(s), %d pending, %d inflight',
                  [JsonAsInt64(Obj, 'connected_workers'),
                  JsonAsInt64(Obj, 'pending_requests'),
                  JsonAsInt64(Obj, 'inflight_requests')]);
              Value := Obj.GetValue('workers');
              if (Value is TJSONArray) and (FRelayWorkersList <> nil) then
              begin
                Arr := TJSONArray(Value);
                for I := 0 to Arr.Count - 1 do
                  if Arr.Items[I] is TJSONObject then
                  begin
                    Row := TJSONObject(Arr.Items[I]);
                    Caps := '';
                    Value := Row.GetValue('caps');
                    if Value is TJSONArray then
                    begin
                      CapsArr := TJSONArray(Value);
                      for J := 0 to CapsArr.Count - 1 do
                      begin
                        if Caps <> '' then
                          Caps := Caps + ', ';
                        Caps := Caps + CapsArr.Items[J].Value;
                      end;
                    end;
                    if Caps = '' then
                      Caps := '(wildcard)';
                    AddCardListItem(FRelayWorkersList, JsonAsString(Row, 'id'),
                      Format('%s  |  seen %d  |  last %s', [Caps,
                      JsonAsInt64(Row, 'requests_seen'),
                      JsonAsString(Row, 'last_seen')]), Row.ToJSON, 62,
                      I = 0);
                  end;
              end;
              if FRelayWorkersList <> nil then
                if FRelayWorkersList.Count > 0 then
                begin
                  FRelayWorkersList.ItemIndex := 0;
                  RelayWorkerListChange(FRelayWorkersList);
                end
                else
                begin
                  AddCardListItem(FRelayWorkersList, 'No workers connected',
                    'Start or connect a relay worker to serve local requests.',
                    '', 58, False);
                  if FRelayWorkerDetailTitleLabel <> nil then
                    FRelayWorkerDetailTitleLabel.Text := 'No workers connected';
                  if FRelayWorkerDetailMetaLabel <> nil then
                    FRelayWorkerDetailMetaLabel.Text := 'Relay idle';
                  if FRelayWorkerDetailMemo <> nil then
                    FRelayWorkerDetailMemo.Lines.Text :=
                      'Start or connect a relay worker to serve local requests.';
                end;
            end;
          finally
            Root.Free;
            if FRelayWorkersList <> nil then
              FRelayWorkersList.OnChange := RelayWorkerListChange;
          end;
          if FPaneMemos.TryGetValue('relay', Memo) then
            Memo.Lines.Text := 'GET /v1/relay/status' + sLineBreak +
              'HTTP ' + Status.ToString + sLineBreak + sLineBreak +
              FormatRelayStatusText(ResponseText);
          SetStatus('relay loaded');
        end);
    end);
end;

procedure TMasterDetailForm.RelayTokenToggleClick(Sender: TObject);
var
  Memo: TMemo;
begin
  if FRelayTokenEdit = nil then
    Exit;

  FRelayTokenEdit.Password := not FRelayTokenEdit.Password;
  if FRelayShowTokenButton <> nil then
    if FRelayTokenEdit.Password then
      FRelayShowTokenButton.Text := 'Show'
    else
      FRelayShowTokenButton.Text := 'Hide';

  if (FRelayTokenJson <> '') and FPaneMemos.TryGetValue('relay', Memo) then
    Memo.Lines.Text := FormatRelayTokenText(FRelayTokenJson);
  RelayRenderSnippets(nil);
end;

procedure TMasterDetailForm.RelayTokenClick(Sender: TObject);
var
  Base: string;
  SessionId: string;
  Token: string;
begin
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('loading relay token...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET',
          '/v1/relay/worker-token', '', '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('relay token HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Memo: TMemo;
          RelayToken: string;
          Root: TJSONValue;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('relay token failed: ' + ErrorText);
            Exit;
          end;
          RelayToken := '';
          Root := TJSONObject.ParseJSONValue(ResponseText);
          try
            if Root is TJSONObject then
              RelayToken := JsonAsString(TJSONObject(Root), 'token');
          finally
            Root.Free;
          end;
          FRelayTokenJson := ResponseText;
          if FRelayUrlEdit <> nil then
            FRelayUrlEdit.Text := Base;
          if FRelayTokenEdit <> nil then
            FRelayTokenEdit.Text := RelayToken;
          RelayRenderSnippets(nil);
          if FPaneMemos.TryGetValue('relay', Memo) then
            Memo.Lines.Text := FormatRelayTokenText(FRelayTokenJson);
          SetStatus('relay token loaded');
        end);
    end);
end;

function TMasterDetailForm.RelayWorkerRunning: Boolean;
var
  ExitCode: Cardinal;
begin
  Result := False;
  if FRelayWorkerProcessHandle = 0 then
    Exit;
  if WinGetExitCodeProcess(FRelayWorkerProcessHandle, ExitCode) then
    Result := ExitCode = WIN_STILL_ACTIVE;
end;

procedure TMasterDetailForm.RelayWorkerUpdateControls(const StateText: string);
var
  Running: Boolean;
begin
  Running := RelayWorkerRunning;
  if FRelayWorkerConnectButton <> nil then
    FRelayWorkerConnectButton.Enabled := not Running;
  if FRelayWorkerDisconnectButton <> nil then
    FRelayWorkerDisconnectButton.Enabled := Running;
  if FRelayWorkerCommandEdit <> nil then
    FRelayWorkerCommandEdit.Enabled := not Running;
  if FRelayWorkerProviderEdit <> nil then
    FRelayWorkerProviderEdit.Enabled := not Running;
  if FRelayWorkerModelEdit <> nil then
    FRelayWorkerModelEdit.Enabled := not Running;
  if FRelayWorkerProfileCombo <> nil then
    FRelayWorkerProfileCombo.Enabled := not Running;
  if FRelayWorkerIdEdit <> nil then
    FRelayWorkerIdEdit.Enabled := not Running;
  if (StateText <> '') and (FRelayStatusLabel <> nil) then
    FRelayStatusLabel.Text := StateText;
end;

procedure TMasterDetailForm.RelayWorkerRefreshLog;
var
  Text: string;
begin
  if (FRelayWorkerLogMemo = nil) or (FRelayWorkerLogPath = '') or
    not TFile.Exists(FRelayWorkerLogPath) then
    Exit;
  try
    Text := TFile.ReadAllText(FRelayWorkerLogPath, TEncoding.UTF8);
    if Length(Text) > 24000 then
      Text := Copy(Text, Length(Text) - 23999, 24000);
    if Trim(Text) = '' then
      Text := 'worker started; waiting for output...';
    FRelayWorkerLogMemo.Lines.Text := Text;
  except
    on E: Exception do
      FRelayWorkerLogMemo.Lines.Text := 'worker log read failed: ' + E.Message;
  end;
end;

procedure TMasterDetailForm.RelayWorkerConnectClick(Sender: TObject);
var
  Base: string;
  CmdLine: string;
  CommandText: string;
  Created: Boolean;
  DisplayCommand: string;
  LogHandle: NativeUInt;
  ModelText: string;
  PI: TWinProcessInformation;
  ProviderText: string;
  SA: TWinSecurityAttributes;
  SI: TWinStartupInfo;
  Token: string;
  WorkerId: string;
begin
  if RelayWorkerRunning then
  begin
    SetStatus('local relay worker already running');
    Exit;
  end;
  if FRelayWorkerProcessHandle <> 0 then
  begin
    WinCloseHandle(FRelayWorkerProcessHandle);
    FRelayWorkerProcessHandle := 0;
    FRelayWorkerProcessId := 0;
  end;

  CommandText := 'pasclaw';
  if FRelayWorkerCommandEdit <> nil then
    CommandText := Trim(FRelayWorkerCommandEdit.Text);
  if CommandText = '' then
  begin
    SetStatus('relay worker command required');
    Exit;
  end;

  Base := GatewayBaseUrl;
  if (FRelayUrlEdit <> nil) and (Trim(FRelayUrlEdit.Text) <> '') then
    Base := CleanBaseUrl(FRelayUrlEdit.Text);
  if FRelayUrlEdit <> nil then
    FRelayUrlEdit.Text := Base;

  Token := '';
  if FRelayTokenEdit <> nil then
    Token := Trim(FRelayTokenEdit.Text);
  if Token = '' then
    Token := Trim(FTokenEdit.Text);

  ProviderText := '';
  if FRelayWorkerProviderEdit <> nil then
    ProviderText := Trim(FRelayWorkerProviderEdit.Text);
  ModelText := '';
  if FRelayWorkerModelEdit <> nil then
    ModelText := Trim(FRelayWorkerModelEdit.Text);
  WorkerId := '';
  if FRelayWorkerIdEdit <> nil then
    WorkerId := Trim(FRelayWorkerIdEdit.Text);

  CmdLine := QuoteProcessArg(CommandText) + ' relay --gateway-url ' +
    QuoteProcessArg(Base);
  if Token <> '' then
    CmdLine := CmdLine + ' --gateway-token ' + QuoteProcessArg(Token);
  if ProviderText <> '' then
    CmdLine := CmdLine + ' --provider ' + QuoteProcessArg(ProviderText);
  if SameText(ModelText, '*') then
    CmdLine := CmdLine + ' --model ""'
  else if ModelText <> '' then
    CmdLine := CmdLine + ' --model ' + QuoteProcessArg(ModelText);
  if WorkerId <> '' then
    CmdLine := CmdLine + ' --worker-id ' + QuoteProcessArg(WorkerId);

  FRelayWorkerLogPath := System.IOUtils.TPath.Combine(
    System.IOUtils.TPath.GetTempPath, 'pasclaw-studio-relay-' +
    IntToStr(WinGetCurrentProcessId) + '-' +
    IntToStr(Int64(WinGetTickCount64)) + '.log');

  FillChar(SA, SizeOf(SA), 0);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;
  LogHandle := WinCreateFile(PChar(FRelayWorkerLogPath), WIN_GENERIC_WRITE,
    WIN_FILE_SHARE_READ, @SA, WIN_CREATE_ALWAYS, WIN_FILE_ATTRIBUTE_NORMAL, 0);
  if LogHandle = NativeUInt(-1) then
  begin
    SetStatus('relay worker log failed: ' + SysErrorMessage(WinGetLastError));
    Exit;
  end;

  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := WIN_STARTF_USESHOWWINDOW or WIN_STARTF_USESTDHANDLES;
  SI.wShowWindow := WIN_SW_HIDE;
  SI.hStdOutput := LogHandle;
  SI.hStdError := LogHandle;
  SI.hStdInput := 0;
  FillChar(PI, SizeOf(PI), 0);

  UniqueString(CmdLine);
  Created := WinCreateProcess(nil, PChar(CmdLine), nil, nil, True,
    WIN_CREATE_NO_WINDOW, nil, nil, SI, PI);
  WinCloseHandle(LogHandle);

  if not Created then
  begin
    if FRelayWorkerLogMemo <> nil then
      FRelayWorkerLogMemo.Lines.Text := 'start failed: ' +
        SysErrorMessage(WinGetLastError) + sLineBreak + CmdLine;
    SetStatus('relay worker start failed');
    Exit;
  end;

  FRelayWorkerProcessHandle := PI.hProcess;
  FRelayWorkerProcessId := PI.dwProcessId;
  WinCloseHandle(PI.hThread);

  DisplayCommand := CmdLine;
  if Token <> '' then
    DisplayCommand := StringReplace(DisplayCommand, Token, '<token>',
      [rfReplaceAll]);
  if FRelayWorkerLogMemo <> nil then
    FRelayWorkerLogMemo.Lines.Text := Format('started pid %d%s%s%slog: %s',
      [FRelayWorkerProcessId, sLineBreak, DisplayCommand, sLineBreak,
      FRelayWorkerLogPath]);
  if FRelayWorkerTimer <> nil then
    FRelayWorkerTimer.Enabled := True;
  RelayWorkerUpdateControls(Format('local relay worker running (pid %d)',
    [FRelayWorkerProcessId]));
  SetStatus('relay worker connected');
  RelayRefreshClick(nil);
end;

procedure TMasterDetailForm.RelayWorkerDisconnectClick(Sender: TObject);
begin
  if FRelayWorkerTimer <> nil then
    FRelayWorkerTimer.Enabled := False;
  if FRelayWorkerProcessHandle <> 0 then
  begin
    if RelayWorkerRunning then
    begin
      WinTerminateProcess(FRelayWorkerProcessHandle, 0);
      WinWaitForSingleObject(FRelayWorkerProcessHandle, 1500);
    end;
    WinCloseHandle(FRelayWorkerProcessHandle);
    FRelayWorkerProcessHandle := 0;
    FRelayWorkerProcessId := 0;
  end;
  RelayWorkerRefreshLog;
  if FRelayWorkerLogMemo <> nil then
    FRelayWorkerLogMemo.Lines.Add('worker stopped by user');
  RelayWorkerUpdateControls('local relay worker stopped');
  SetStatus('relay worker disconnected');
  RelayRefreshClick(nil);
end;

procedure TMasterDetailForm.RelayWorkerTimerTick(Sender: TObject);
var
  ExitCode: Cardinal;
begin
  RelayWorkerRefreshLog;
  if FRelayWorkerProcessHandle = 0 then
  begin
    if FRelayWorkerTimer <> nil then
      FRelayWorkerTimer.Enabled := False;
    RelayWorkerUpdateControls;
    Exit;
  end;

  ExitCode := 0;
  if not RelayWorkerRunning then
  begin
    WinGetExitCodeProcess(FRelayWorkerProcessHandle, ExitCode);
    WinCloseHandle(FRelayWorkerProcessHandle);
    FRelayWorkerProcessHandle := 0;
    FRelayWorkerProcessId := 0;
    if FRelayWorkerTimer <> nil then
      FRelayWorkerTimer.Enabled := False;
    RelayWorkerUpdateControls(Format('local relay worker exited (%d)',
      [ExitCode]));
    SetStatus('relay worker exited');
    RelayRefreshClick(nil);
  end
  else
    RelayWorkerUpdateControls;
end;

procedure TMasterDetailForm.ShowOnboarding;
{ The card's copy belongs to RenderOnboardingStep alone. The old StatusText
  parameter was a second writer of the same label, and the two disagreed the
  moment the step machinery landed. }
begin
  if FOnboardingOverlay = nil then
    Exit;
  RenderOnboardingStep;
  FOnboardingOverlay.Visible := True;
  FOnboardingOverlay.BringToFront;
end;

procedure TMasterDetailForm.OnboardingShowClick(Sender: TObject);
begin
  FOnboardingDismissed := False;
  FOnboardingStep := 0;      { reopening starts the wizard over }
  ShowOnboarding;
end;

procedure TMasterDetailForm.OnboardingProviderClick(Sender: TObject);
begin
  if FOnboardingOverlay <> nil then
    FOnboardingOverlay.Visible := False;
  SelectTabByText('Settings');
  if FSettingsTabs <> nil then
    FSettingsTabs.TabIndex := 1;
  if FProviderCatalogJson = '' then
    ProviderCatalogClick(nil);
  SetStatus('onboarding: configure provider');
end;

procedure TMasterDetailForm.OnboardingMemoryClick(Sender: TObject);
begin
  if FOnboardingOverlay <> nil then
    FOnboardingOverlay.Visible := False;
  SelectTabByText('Memory');
  if FMemoryTabs <> nil then
    FMemoryTabs.TabIndex := 2;
  MemorySetupLoadClick(nil);
  SetStatus('onboarding: memory setup');
end;

procedure TMasterDetailForm.OnboardingFinishClick(Sender: TObject);
begin
  FOnboardingDismissed := True;
  if FOnboardingOverlay <> nil then
    FOnboardingOverlay.Visible := False;
  SaveLocalSettings;
  SetStatus('onboarding complete');
end;

procedure TMasterDetailForm.CheckFirstBootOnboarding;
var
  Base: string;
  SessionId: string;
  Token: string;
begin
  if FOnboardingDismissed then
    Exit;
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;

  TTask.Run(
    procedure
    var
      Arr: TJSONArray;
      DefaultModel: string;
      DefaultProvider: string;
      ErrorText: string;
      I: Integer;
      NeedsOnboarding: Boolean;
      Obj: TJSONObject;
      ProviderCount: Integer;
      ResponseText: string;
      Root: TJSONValue;
      Row: TJSONObject;
      Status: Integer;
      Value: TJSONValue;
    begin
      NeedsOnboarding := False;
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET', '/v1/config',
          '', '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('config HTTP %d', [Status]);

        Root := TJSONObject.ParseJSONValue(ResponseText);
        try
          if Root is TJSONObject then
          begin
            Obj := TJSONObject(Root);
            DefaultProvider := Trim(JsonAsString(Obj, 'default_provider'));
            DefaultModel := Trim(JsonAsString(Obj, 'default_model'));
            ProviderCount := 0;
            Value := Obj.GetValue('providers');
            if Value is TJSONArray then
            begin
              Arr := TJSONArray(Value);
              for I := 0 to Arr.Count - 1 do
                if Arr.Items[I] is TJSONObject then
                begin
                  Row := TJSONObject(Arr.Items[I]);
                  if (not JsonAsBool(Row, 'placeholder')) and
                    ((JsonAsString(Row, 'name') <> '') or
                    (JsonAsString(Row, 'kind') <> '')) then
                    Inc(ProviderCount);
                end;
            end;
            NeedsOnboarding := (ProviderCount = 0) or
              (DefaultProvider = '') or (DefaultModel = '');
          end;
        finally
          Root.Free;
        end;
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        begin
          if ErrorText <> '' then
            Exit;
          if NeedsOnboarding and (not FOnboardingDismissed) then
            ShowOnboarding;
        end);
    end);
end;

procedure TMasterDetailForm.FileDetailCopyClick(Sender: TObject);
var
  Clipboard: IFMXClipboardService;
begin
  if (FFileDetailMemo = nil) or (Trim(FFileDetailMemo.Lines.Text) = '') then
  begin
    SetStatus('no file detail to copy');
    Exit;
  end;
  if TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService,
    IInterface(Clipboard)) then
  begin
    Clipboard.SetClipboard(TValue.From<string>(FFileDetailMemo.Lines.Text));
    SetStatus('file detail copied');
  end
  else
    SetStatus('clipboard service unavailable');
end;

procedure TMasterDetailForm.FilesOpenPath(const Path: string);
var
  Base: string;
  Endpoint: string;
  Token: string;
  SessionId: string;
begin
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  Endpoint := '/v1/fs';
  if Trim(Path) <> '' then
    Endpoint := Endpoint + '?path=' + UrlEncode(Trim(Path));
  if FEndpointEdits.ContainsKey('files') then
    FEndpointEdits['files'].Text := Endpoint;
  if FFilePreviewImage <> nil then
    FFilePreviewImage.Visible := False;
  SetStatus('loading files...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET', Endpoint, '',
          '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('files HTTP %d: %s', [Status, ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Arr: TJSONArray;
          CurrentPath: string;
          CwdRoot: string;
          FullPath: string;
          I: Integer;
          Item: TListBoxItem;
          Memo: TMemo;
          Obj: TJSONObject;
          Root: TJSONValue;
          Row: TJSONObject;
          Value: TJSONValue;
          WorkspaceRoot: string;
          procedure AddFileRow(const DisplayName, TargetPath, KindText,
            SizeDisplay, SizeRaw: string);
          var
            Card: TRectangle;
            MetaLabel: TLabel;
            MetaText: string;
            NameLabel: TLabel;
            RowItem: TListBoxItem;
          begin
            if FFileList = nil then
              Exit;
            RowItem := TListBoxItem.Create(FFileList);
            RowItem.Parent := FFileList;
            RowItem.Text := '';
            RowItem.TagString := TargetPath + #9 + KindText + #9 + SizeRaw;
            RowItem.Height := 68;
            RowItem.HitTest := True;
            RowItem.OnClick := CardListItemClick;

            Card := TRectangle.Create(RowItem);
            Card.Parent := RowItem;
            Card.Align := TAlignLayout.Client;
            StyleChromeRect(Card, UI_PANEL_ALT, UI_BORDER, 4, True);
            Card.OnClick := CardListItemClick;
            SetControlMargins(Card, 0, 3, 0, 3);
            SetControlPadding(Card, 10, GAP_S, 10, GAP_S);

            NameLabel := TLabel.Create(Card);
            NameLabel.Parent := Card;
            NameLabel.Align := TAlignLayout.Top;
            NameLabel.HitTest := False;
            NameLabel.Height := ROW_TEXT;
            NameLabel.Text := DisplayName;
            NameLabel.StyledSettings := NameLabel.StyledSettings -
              [TStyledSetting.FontColor, TStyledSetting.Style];
            UseStyledLabelColor(NameLabel);
            NameLabel.TextSettings.Font.Style := [TFontStyle.fsBold];

            MetaText := KindText;
            if SameText(KindText, 'dir') then
              MetaText := 'directory'
            else if SizeDisplay <> '' then
              MetaText := 'file | ' + SizeDisplay;
            if TargetPath <> '' then
              MetaText := MetaText + ' | ' + TargetPath;

            MetaLabel := TLabel.Create(Card);
            MetaLabel.Parent := Card;
            MetaLabel.Align := TAlignLayout.Client;
            MetaLabel.HitTest := False;
            MetaLabel.Text := MetaText;
            MetaLabel.WordWrap := True;
            MetaLabel.StyledSettings := MetaLabel.StyledSettings -
              [TStyledSetting.Size];
            UseStyledLabelColor(MetaLabel);
            MetaLabel.TextSettings.Font.Size := TXT_BODY;
          end;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('files failed: ' + ErrorText);
            Exit;
          end;
          Root := TJSONObject.ParseJSONValue(ResponseText);
          try
            if Root is TJSONObject then
            begin
              Obj := TJSONObject(Root);
              CurrentPath := JsonAsString(Obj, 'path');
              if FFilePathEdit <> nil then
                FFilePathEdit.Text := CurrentPath;
              if FFileRootsList <> nil then
              begin
                FFileRootsList.Clear;
                WorkspaceRoot := JsonAsString(Obj, 'workspace_root');
                CwdRoot := JsonAsString(Obj, 'cwd_root');
                if WorkspaceRoot <> '' then
                begin
                  Item := TListBoxItem.Create(FFileRootsList);
                  Item.Parent := FFileRootsList;
                  if SameText(CurrentPath, WorkspaceRoot) then
                    Item.Text := '[Workspace]  ' + WorkspaceRoot
                  else
                    Item.Text := 'Workspace  ' + WorkspaceRoot;
                  Item.TagString := WorkspaceRoot;
                  Item.Height := ROW_FORM;
                  Item.HitTest := True;
                  Item.OnClick := CardListItemClick;
                end;
                if (CwdRoot <> '') and (not SameText(CwdRoot,
                  WorkspaceRoot)) then
                begin
                  Item := TListBoxItem.Create(FFileRootsList);
                  Item.Parent := FFileRootsList;
                  if SameText(CurrentPath, CwdRoot) then
                    Item.Text := '[Launch]  ' + CwdRoot
                  else
                    Item.Text := 'Launch  ' + CwdRoot;
                  Item.TagString := CwdRoot;
                  Item.Height := ROW_FORM;
                  Item.HitTest := True;
                  Item.OnClick := CardListItemClick;
                end;
              end;
              if FFileList <> nil then
              begin
                FFileList.Clear;
                if CurrentPath <> '' then
                begin
                  AddFileRow('../', FsParentPath(CurrentPath), 'dir', '', '0');
                end;
                Value := Obj.GetValue('entries');
                if Value is TJSONArray then
                begin
                  Arr := TJSONArray(Value);
                  for I := 0 to Arr.Count - 1 do
                    if Arr.Items[I] is TJSONObject then
                    begin
                      Row := TJSONObject(Arr.Items[I]);
                      FullPath := FsJoinPath(CurrentPath,
                        JsonAsString(Row, 'name'));
                      if JsonAsBool(Row, 'dir') then
                        AddFileRow('[dir]  ' + JsonAsString(Row, 'name'),
                          FullPath, 'dir', '', '0')
                      else
                        AddFileRow(JsonAsString(Row, 'name'), FullPath, 'file',
                          FormatBytes(JsonAsInt64(Row, 'size')),
                          JsonAsInt64(Row, 'size').ToString);
                    end;
                end;
              end;
            end;
          finally
            Root.Free;
          end;
          if FPaneMemos.TryGetValue('files', Memo) then
            Memo.Lines.Text := 'GET ' + Endpoint + sLineBreak + 'HTTP ' +
              Status.ToString + sLineBreak + sLineBreak +
              FormatFilesText(ResponseText);
          if FFilePreviewImage <> nil then
            FFilePreviewImage.Visible := False;
          if FFileHexToolbar <> nil then
            FFileHexToolbar.Visible := False;
          if FFileDetailMemo <> nil then
          begin
            FFileDetailMemo.Visible := True;
            FFileDetailMemo.Lines.Text := 'Select a file from the browser to preview text, images, or binary hex pages here.';
          end;
          if FFileHexLabel <> nil then
          begin
            if CurrentPath <> '' then
              FFileHexLabel.Text := CurrentPath
            else
              FFileHexLabel.Text := 'Files';
          end;
          if FFileViewerStatusLabel <> nil then
          begin
            if CurrentPath <> '' then
              FFileViewerStatusLabel.Text := CurrentPath
            else
              FFileViewerStatusLabel.Text := '(home)';
          end;
          SetStatus('files loaded');
        end);
    end);
end;

procedure TMasterDetailForm.FilesReadPath(const Path: string);
var
  Base: string;
  Endpoint: string;
  Token: string;
  SessionId: string;
begin
  if Trim(Path) = '' then
    Exit;
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  Endpoint := '/v1/fs/read?path=' + UrlEncode(Path);
  if FEndpointEdits.ContainsKey('files') then
    FEndpointEdits['files'].Text := Endpoint;
  if FFilePreviewImage <> nil then
    FFilePreviewImage.Visible := False;
  if FFileHexToolbar <> nil then
    FFileHexToolbar.Visible := False;
  if FFileDetailMemo <> nil then
  begin
    FFileDetailMemo.Visible := True;
    FFileDetailMemo.Lines.Text := 'Loading ' + Path + '...';
  end;
  if FFileHexLabel <> nil then
    FFileHexLabel.Text := 'Reading: ' + Path;
  SetStatus('reading file...');
  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET', Endpoint, '',
          '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('read HTTP %d: %s', [Status, ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;
      TThread.Queue(nil,
        procedure
        var
          ContentText: string;
          Memo: TMemo;
          Obj: TJSONObject;
          Root: TJSONValue;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('file read failed: ' + ErrorText);
            Exit;
          end;
          if FPaneMemos.TryGetValue('files', Memo) then
            Memo.Lines.Text := 'GET ' + Endpoint + sLineBreak + 'HTTP ' +
              Status.ToString + sLineBreak + sLineBreak +
              FormatFilesReadText(ResponseText);
          if FFilePreviewImage <> nil then
            FFilePreviewImage.Visible := False;
          if FFileHexToolbar <> nil then
            FFileHexToolbar.Visible := False;
          if FFileDetailMemo <> nil then
          begin
            FFileDetailMemo.Visible := True;
            FFileDetailMemo.Lines.Text := FormatFilesReadText(ResponseText);
          end;
          if FFileHexLabel <> nil then
            FFileHexLabel.Text := Path;
          Root := TJSONObject.ParseJSONValue(ResponseText);
          try
            if Root is TJSONObject then
            begin
              Obj := TJSONObject(Root);
              ContentText := JsonAsString(Obj, 'content');
              if JsonAsBool(Obj, 'binary') or LooksBinaryText(ContentText) then
              begin
                FFileHexPath := Path;
                FFileHexOffset := 0;
                FFileHexTotal := JsonAsInt64(Obj, 'size');
                if FEndpointEdits.ContainsKey('files') then
                  FEndpointEdits['files'].Text := '/v1/fs/peek?path=' +
                    UrlEncode(Path) + '&offset=0&len=' + FFileHexPageSize.ToString;
                FilesPeekPath(Path, 0);
              end;
            end;
          finally
            Root.Free;
          end;
          SetStatus('file preview loaded');
        end);
    end);
end;

procedure TMasterDetailForm.FilesPreviewImagePath(const Path: string);
var
  Base: string;
  Endpoint: string;
  SessionId: string;
  Token: string;
begin
  if Trim(Path) = '' then
    Exit;
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  Endpoint := '/v1/fs/download?path=' + UrlEncode(Path);
  if FEndpointEdits.ContainsKey('files') then
    FEndpointEdits['files'].Text := Endpoint;
  if FFilePreviewImage <> nil then
    FFilePreviewImage.Visible := False;
  if FFileHexToolbar <> nil then
    FFileHexToolbar.Visible := False;
  if FFileDetailMemo <> nil then
  begin
    FFileDetailMemo.Visible := True;
    FFileDetailMemo.Lines.Text := 'Loading image preview for ' + Path + '...';
  end;
  if FFileHexLabel <> nil then
    FFileHexLabel.Text := 'Image: loading ' + Path;
  SetStatus('loading image preview...');

  TTask.Run(
    procedure
    var
      Bytes: TBytes;
      Client: THTTPClient;
      ErrorText: string;
      Headers: TNetHeaders;
      Mem: TMemoryStream;
      Response: IHTTPResponse;
      Status: Integer;
    begin
      Status := 0;
      try
        Headers := nil;
        AddHeader(Headers, 'Accept', 'image/*, application/octet-stream');
        if Token <> '' then
          AddHeader(Headers, 'Authorization', 'Bearer ' + Token);
        if SessionId <> '' then
          AddHeader(Headers, 'X-PasClaw-Session', SessionId);
        Client := THTTPClient.Create;
        Mem := TMemoryStream.Create;
        try
          Client.ConnectionTimeout := 10000;
          Client.ResponseTimeout := 180000;
          Response := Client.Get(ComposeUrl(Base, Endpoint), Mem, Headers);
          Status := Response.StatusCode;
          if not IsHttpOk(Status) then
            raise Exception.CreateFmt('image HTTP %d', [Status]);
          SetLength(Bytes, Mem.Size);
          if Mem.Size > 0 then
          begin
            Mem.Position := 0;
            Mem.ReadBuffer(Bytes[0], Mem.Size);
          end;
        finally
          Mem.Free;
          Client.Free;
        end;
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Memo: TMemo;
          Stream: TBytesStream;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('image preview failed: ' + ErrorText);
            Exit;
          end;
          if FFilePreviewImage <> nil then
          begin
            Stream := TBytesStream.Create(Bytes);
            try
              FFilePreviewImage.Bitmap.LoadFromStream(Stream);
            finally
              Stream.Free;
            end;
            FFilePreviewImage.Visible := True;
          end;
          if FFileHexToolbar <> nil then
            FFileHexToolbar.Visible := False;
          if FFileHexLabel <> nil then
            FFileHexLabel.Text := 'Image preview: ' + Path;
          if FPaneMemos.TryGetValue('files', Memo) then
            Memo.Lines.Text := 'GET ' + Endpoint + sLineBreak + 'HTTP ' +
              Status.ToString + sLineBreak + sLineBreak + 'Image preview' +
              sLineBreak + sLineBreak +
              'Path: ' + Path + sLineBreak + 'Size: ' +
              FormatBytes(Length(Bytes));
          if FFileDetailMemo <> nil then
          begin
            FFileDetailMemo.Lines.Text := 'Image preview' + sLineBreak + sLineBreak + 'Path: ' + Path +
              sLineBreak + 'Size: ' + FormatBytes(Length(Bytes));
            FFileDetailMemo.Visible := False;
          end;
          SetStatus('image preview loaded');
        end);
    end);
end;

procedure TMasterDetailForm.FilesPeekPath(const Path: string; Offset: Int64);
var
  Base: string;
  Endpoint: string;
  SessionId: string;
  Token: string;
begin
  if Trim(Path) = '' then
    Exit;
  if Offset < 0 then
    Offset := 0;
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  FFileHexPath := Path;
  FFileHexOffset := Offset;
  Endpoint := '/v1/fs/peek?path=' + UrlEncode(Path) + '&offset=' +
    Offset.ToString + '&len=' + FFileHexPageSize.ToString;
  if FEndpointEdits.ContainsKey('files') then
    FEndpointEdits['files'].Text := Endpoint;
  if FFilePreviewImage <> nil then
    FFilePreviewImage.Visible := False;
  if FFileHexToolbar <> nil then
    FFileHexToolbar.Visible := True;
  if FFileDetailMemo <> nil then
  begin
    FFileDetailMemo.Visible := True;
    FFileDetailMemo.Lines.Text := 'Loading hex page for ' + Path + '...';
  end;
  if FFileHexLabel <> nil then
    FFileHexLabel.Text := 'Hex: loading ' + Path;
  SetStatus('loading hex page...');

  TTask.Run(
    procedure
    var
      Bytes: TBytes;
      Client: THTTPClient;
      ErrorText: string;
      Headers: TNetHeaders;
      Mem: TMemoryStream;
      Response: IHTTPResponse;
      ResponseOffset: Int64;
      Status: Integer;
      Total: Int64;
    begin
      ResponseOffset := Offset;
      Total := FFileHexTotal;
      try
        Headers := nil;
        AddHeader(Headers, 'Accept', 'application/octet-stream, application/json');
        if Token <> '' then
          AddHeader(Headers, 'Authorization', 'Bearer ' + Token);
        if SessionId <> '' then
          AddHeader(Headers, 'X-PasClaw-Session', SessionId);
        Client := THTTPClient.Create;
        Mem := TMemoryStream.Create;
        try
          Client.ConnectionTimeout := 10000;
          Client.ResponseTimeout := 180000;
          Response := Client.Get(ComposeUrl(Base, Endpoint), Mem, Headers);
          Status := Response.StatusCode;
          if not IsHttpOk(Status) then
            raise Exception.CreateFmt('peek HTTP %d', [Status]);
          Total := StrToInt64Def(Response.HeaderValue['X-File-Total'], Total);
          ResponseOffset := StrToInt64Def(Response.HeaderValue['X-File-Offset'],
            ResponseOffset);
          SetLength(Bytes, Mem.Size);
          if Mem.Size > 0 then
          begin
            Mem.Position := 0;
            Mem.ReadBuffer(Bytes[0], Mem.Size);
          end;
        finally
          Mem.Free;
          Client.Free;
        end;
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          DetailText: string;
          EndOffset: Int64;
          Memo: TMemo;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('hex load failed: ' + ErrorText);
            if FFileHexLabel <> nil then
              FFileHexLabel.Text := 'Hex: error';
            Exit;
          end;
          FFileHexOffset := ResponseOffset;
          FFileHexTotal := Total;
          EndOffset := ResponseOffset + Length(Bytes);
          if EndOffset > 0 then
            Dec(EndOffset);
          if FFilePreviewImage <> nil then
            FFilePreviewImage.Visible := False;
          if FFileHexToolbar <> nil then
            FFileHexToolbar.Visible := True;
          if FFileHexLabel <> nil then
            FFileHexLabel.Text := Format('Hex: bytes %d-%d of %d',
              [ResponseOffset, EndOffset, Total]);
          DetailText := 'Hex Viewer' +
            sLineBreak + sLineBreak + 'Path: ' + Path + sLineBreak +
            Format('Bytes %d-%d of %d', [ResponseOffset, EndOffset, Total]) +
            sLineBreak + sLineBreak + HexDumpText(Bytes, ResponseOffset);
          if FPaneMemos.TryGetValue('files', Memo) then
            Memo.Lines.Text := 'GET ' + Endpoint + sLineBreak + 'HTTP ' +
              Status.ToString + sLineBreak + sLineBreak + DetailText;
          if FFileDetailMemo <> nil then
          begin
            FFileDetailMemo.Visible := True;
            FFileDetailMemo.Lines.Text := DetailText;
          end;
          SetStatus('hex page loaded');
        end);
    end);
end;

procedure TMasterDetailForm.FilesBrowseClick(Sender: TObject);
var
  Action: string;
  Path: string;
begin
  Action := 'browse';
  if Sender is TButton then
    Action := TButton(Sender).TagString;
  Path := '';
  if FFilePathEdit <> nil then
    Path := Trim(FFilePathEdit.Text);
  if Action = 'up' then
    FilesOpenPath(FsParentPath(Path))
  else if Action = 'peek' then
    FilesPeekPath(Path, 0)
  else if Action = 'read' then
  begin
    if IsPreviewImagePath(Path) then
      FilesPreviewImagePath(Path)
    else
      FilesReadPath(Path);
  end
  else
    FilesOpenPath(Path);
end;

procedure TMasterDetailForm.FilesHexFirstClick(Sender: TObject);
begin
  if FFileHexPath = '' then
  begin
    if FFilePathEdit <> nil then
      FFileHexPath := Trim(FFilePathEdit.Text);
  end;
  if FFileHexPath <> '' then
    FilesPeekPath(FFileHexPath, 0);
end;

procedure TMasterDetailForm.FilesHexLastClick(Sender: TObject);
var
  LastOffset: Int64;
begin
  if FFileHexPath = '' then
  begin
    if FFilePathEdit <> nil then
      FFileHexPath := Trim(FFilePathEdit.Text);
  end;
  if FFileHexPath = '' then
    Exit;
  if FFileHexTotal > 0 then
    LastOffset := (FFileHexTotal - 1) div FFileHexPageSize * FFileHexPageSize
  else
    LastOffset := 0;
  FilesPeekPath(FFileHexPath, LastOffset);
end;

procedure TMasterDetailForm.FilesHexPrevClick(Sender: TObject);
begin
  if FFileHexPath = '' then
  begin
    if FFilePathEdit <> nil then
      FFileHexPath := Trim(FFilePathEdit.Text);
  end;
  if FFileHexPath <> '' then
    FilesPeekPath(FFileHexPath, Max(0, FFileHexOffset - FFileHexPageSize));
end;

procedure TMasterDetailForm.FilesHexNextClick(Sender: TObject);
var
  NextOffset: Int64;
begin
  if FFileHexPath = '' then
  begin
    if FFilePathEdit <> nil then
      FFileHexPath := Trim(FFilePathEdit.Text);
  end;
  if FFileHexPath = '' then
    Exit;
  NextOffset := FFileHexOffset + FFileHexPageSize;
  if (FFileHexTotal > 0) and (NextOffset >= FFileHexTotal) then
    NextOffset := Max(0, FFileHexTotal - FFileHexPageSize);
  FilesPeekPath(FFileHexPath, NextOffset);
end;

procedure TMasterDetailForm.FilesListChange(Sender: TObject);
var
  Item: TListBoxItem;
  Parts: TArray<string>;
  SizeRaw: Int64;
begin
  if (FFileList = nil) or (FFileList.Selected = nil) then
    Exit;
  Item := FFileList.Selected;
  Parts := Item.TagString.Split([#9]);
  if Length(Parts) < 2 then
    Exit;
  if FFilePathEdit <> nil then
    FFilePathEdit.Text := Parts[0];
  if SameText(Parts[1], 'dir') then
    FilesOpenPath(Parts[0])
  else if IsPreviewImagePath(Parts[0]) then
  begin
    SizeRaw := 0;
    if Length(Parts) >= 3 then
      SizeRaw := StrToInt64Def(Parts[2], 0);
    if SizeRaw > 25 * 1024 * 1024 then
    begin
      if FFilePreviewImage <> nil then
        FFilePreviewImage.Visible := False;
      if FFileHexToolbar <> nil then
        FFileHexToolbar.Visible := False;
      if FFileDetailMemo <> nil then
      begin
        FFileDetailMemo.Visible := True;
        FFileDetailMemo.Lines.Text := FormatBytes(SizeRaw) +
          ' image - too large to preview inline.' + sLineBreak +
          'Use Download to save the file.' + sLineBreak + sLineBreak +
          'Path: ' + Parts[0];
      end;
      if FFileHexLabel <> nil then
        FFileHexLabel.Text := 'Image too large: ' + Parts[0];
      SetStatus('image too large to preview; use Download');
    end
    else
      FilesPreviewImagePath(Parts[0]);
  end
  else
    FilesReadPath(Parts[0]);
end;

procedure TMasterDetailForm.FilesRootClick(Sender: TObject);
var
  Path: string;
begin
  if (FFileRootsList = nil) or (FFileRootsList.Selected = nil) then
    Exit;
  Path := FFileRootsList.Selected.TagString;
  if Path = '' then
    Exit;
  if FFilePathEdit <> nil then
    FFilePathEdit.Text := Path;
  FilesOpenPath(Path);
end;

procedure TMasterDetailForm.FilesDownloadSelectedClick(Sender: TObject);
var
  Path: string;
  Parts: TArray<string>;
begin
  Path := '';
  if (FFileList <> nil) and (FFileList.Selected <> nil) then
  begin
    Parts := FFileList.Selected.TagString.Split([#9]);
    if Length(Parts) >= 2 then
      Path := Parts[0];
    if (Length(Parts) >= 2) and SameText(Parts[1], 'dir') then
    begin
      SetStatus('select a file to download');
      Exit;
    end;
  end;
  if (Path = '') and (FFilePathEdit <> nil) then
    Path := Trim(FFilePathEdit.Text);
  if Path = '' then
  begin
    SetStatus('no file selected');
    Exit;
  end;
  if FEndpointEdits.ContainsKey('files') then
    FEndpointEdits['files'].Text := '/v1/fs/download?path=' + UrlEncode(Path);
  FileDownloadClick(Sender);
end;

procedure TMasterDetailForm.McpRefreshClick(Sender: TObject);
var
  Base: string;
  Token: string;
  SessionId: string;
begin
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('loading MCP servers...');
  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET', '/v1/mcp', '',
          '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('mcp HTTP %d: %s', [Status, ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;
      TThread.Queue(nil,
        procedure
        var
          Arr: TJSONArray;
          DetailText: string;
          I: Integer;
          Memo: TMemo;
          Root: TJSONValue;
          Row: TJSONObject;
          Value: TJSONValue;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('MCP failed: ' + ErrorText);
            Exit;
          end;
          if FMcpList <> nil then
          begin
            FMcpList.Clear;
            Root := TJSONObject.ParseJSONValue(ResponseText);
            try
              if Root is TJSONObject then
              begin
                Value := TJSONObject(Root).GetValue('servers');
                if Value is TJSONArray then
                begin
                  Arr := TJSONArray(Value);
                  for I := 0 to Arr.Count - 1 do
                    if Arr.Items[I] is TJSONObject then
                    begin
                      Row := TJSONObject(Arr.Items[I]);
                      if JsonAsString(Row, 'cmd') <> '' then
                        DetailText := JsonAsString(Row, 'cmd') + ' ' +
                          JsonAsString(Row, 'args')
                      else
                        DetailText := 'MCP server';
                      if JsonAsBool(Row, 'enabled') then
                        AddCardListItem(FMcpList,
                          JsonAsString(Row, 'name') + '  enabled', DetailText,
                          'server' + #9 + JsonPretty(Row), 60, True)
                      else
                        AddCardListItem(FMcpList,
                          JsonAsString(Row, 'name') + '  disabled', DetailText,
                          'server' + #9 + JsonPretty(Row), 60, False);
                    end;
                end;
              end;
            finally
              Root.Free;
            end;
          end;
          if FPaneMemos.TryGetValue('mcp', Memo) then
            Memo.Lines.Text := 'GET /v1/mcp' + sLineBreak + 'HTTP ' +
              Status.ToString + sLineBreak + sLineBreak +
              FormatMcpText(ResponseText);
          SetStatus('MCP servers loaded');
        end);
    end);
end;

procedure TMasterDetailForm.McpToolsClick(Sender: TObject);
var
  Base: string;
  Token: string;
  SessionId: string;
begin
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('loading MCP tools...');
  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET',
          '/v1/mcp/tools', '', '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('mcp tools HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;
      TThread.Queue(nil,
        procedure
        var
          Arr: TJSONArray;
          Description: string;
          I: Integer;
          Memo: TMemo;
          Name: string;
          Root: TJSONValue;
          Row: TJSONObject;
          Schema: TJSONValue;
          SchemaText: string;
          Value: TJSONValue;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('MCP tools failed: ' + ErrorText);
            Exit;
          end;
          if FMcpList <> nil then
            FMcpList.Clear;
          if FMcpToolCombo <> nil then
          begin
            FMcpToolCombo.OnChange := nil;
            FMcpToolCombo.Items.Clear;
          end;
          Root := TJSONObject.ParseJSONValue(ResponseText);
          try
            if Root is TJSONObject then
            begin
              Value := TJSONObject(Root).GetValue('tools');
              if Value is TJSONArray then
              begin
                Arr := TJSONArray(Value);
                for I := 0 to Arr.Count - 1 do
                  if Arr.Items[I] is TJSONObject then
                  begin
                    Row := TJSONObject(Arr.Items[I]);
                    Name := JsonAsString(Row, 'name');
                    if Name = '' then
                      Continue;
                    if FMcpToolCombo <> nil then
                      FMcpToolCombo.Items.Add(Name);
                    if FMcpList <> nil then
                    begin
                      Description := JsonAsString(Row, 'description');
                      if Description = '' then
                        Description := 'Schema-driven MCP tool';
                      Schema := Row.GetValue('schema');
                      if Schema = nil then
                        Schema := Row.GetValue('input_schema');
                      if Schema = nil then
                        Schema := Row.GetValue('parameters');
                      if Schema = nil then
                        SchemaText := '{}'
                      else
                        SchemaText := JsonPretty(Schema);
                      AddCardListItem(FMcpList, Name, Description,
                        Name + #9 + JsonAsString(Row, 'description') + #9 +
                        SchemaText, 66, False);
                    end;
                  end;
              end;
            end;
          finally
            Root.Free;
          end;
          if FMcpToolCombo <> nil then
          begin
            if FMcpToolCombo.Items.Count > 0 then
              FMcpToolCombo.ItemIndex := 0
            else
              FMcpToolCombo.ItemIndex := -1;
            FMcpToolCombo.OnChange := McpToolChange;
          end;
          if (FMcpToolCombo <> nil) and (FMcpToolCombo.ItemIndex >= 0) then
            McpToolChange(FMcpToolCombo);
          if FPaneMemos.TryGetValue('mcp', Memo) then
            Memo.Lines.Text := 'GET /v1/mcp/tools' + sLineBreak + 'HTTP ' +
              Status.ToString + sLineBreak + sLineBreak +
              FormatMcpText(ResponseText);
          SetStatus('MCP tools loaded');
        end);
    end);
end;

procedure TMasterDetailForm.McpServerClearClick(Sender: TObject);
begin
  if FMcpServerNameEdit <> nil then
    FMcpServerNameEdit.Text := '';
  if FMcpServerCmdEdit <> nil then
    FMcpServerCmdEdit.Text := '';
  if FMcpServerArgsEdit <> nil then
    FMcpServerArgsEdit.Text := '';
  if FMcpServerEnvMemo <> nil then
    FMcpServerEnvMemo.Lines.Clear;
  if FMcpServerEnabledCheck <> nil then
    FMcpServerEnabledCheck.IsChecked := True;
  if FMcpList <> nil then
    FMcpList.ItemIndex := -1;
  SetStatus('new MCP server');
end;

procedure TMasterDetailForm.McpServerLoadFromJson(const JsonText: string);
var
  Memo: TMemo;
  Obj: TJSONObject;
  Root: TJSONValue;
begin
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    if FMcpServerNameEdit <> nil then
      FMcpServerNameEdit.Text := JsonAsString(Obj, 'name');
    if FMcpServerCmdEdit <> nil then
      FMcpServerCmdEdit.Text := JsonAsString(Obj, 'cmd');
    if FMcpServerArgsEdit <> nil then
      FMcpServerArgsEdit.Text := JsonAsString(Obj, 'args');
    if FMcpServerEnvMemo <> nil then
      FMcpServerEnvMemo.Lines.Text := JsonAsString(Obj, 'env');
    if FMcpServerEnabledCheck <> nil then
      FMcpServerEnabledCheck.IsChecked := JsonAsBool(Obj, 'enabled');

    if FPaneMemos.TryGetValue('mcp', Memo) then
      Memo.Lines.Text := 'MCP Server' + sLineBreak + sLineBreak +
        Format('%-10s %s', ['Name', JsonAsString(Obj, 'name')]) +
        sLineBreak + Format('%-10s %s', ['Enabled',
        BoolToStr(JsonAsBool(Obj, 'enabled'), True)]) + sLineBreak +
        Format('%-10s %s', ['Command', JsonAsString(Obj, 'cmd')]) +
        sLineBreak + Format('%-10s %s', ['Args', JsonAsString(Obj, 'args')]) +
        sLineBreak + sLineBreak + 'Env:' + sLineBreak +
        JsonAsString(Obj, 'env');
  finally
    Root.Free;
  end;
end;

procedure TMasterDetailForm.McpServerSaveClick(Sender: TObject);
var
  ArgsText: string;
  Base: string;
  BodyText: string;
  CmdText: string;
  EnvText: string;
  NameText: string;
  ServerObj: TJSONObject;
  SessionId: string;
  Token: string;
begin
  NameText := Trim(FMcpServerNameEdit.Text);
  CmdText := Trim(FMcpServerCmdEdit.Text);
  ArgsText := Trim(FMcpServerArgsEdit.Text);
  EnvText := '';
  if FMcpServerEnvMemo <> nil then
    EnvText := FMcpServerEnvMemo.Lines.Text;
  if NameText = '' then
  begin
    SetStatus('MCP server name is required');
    Exit;
  end;
  if CmdText = '' then
  begin
    SetStatus('MCP server command is required');
    Exit;
  end;

  ServerObj := TJSONObject.Create;
  try
    ServerObj.AddPair('name', NameText);
    ServerObj.AddPair('cmd', CmdText);
    ServerObj.AddPair('args', ArgsText);
    ServerObj.AddPair('env', EnvText);
    AddJsonBool(ServerObj, 'enabled',
      (FMcpServerEnabledCheck = nil) or FMcpServerEnabledCheck.IsChecked);
    BodyText := ServerObj.ToJSON;
  finally
    ServerObj.Free;
  end;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('saving MCP server...');

  TTask.Run(
    procedure
    var
      Config: TJSONObject;
      ConfigText: string;
      ErrorText: string;
      I: Integer;
      Item: TJSONValue;
      NewServers: TJSONArray;
      Pair: TJSONPair;
      ResponseText: string;
      Root: TJSONValue;
      Row: TJSONObject;
      SavedConfigText: string;
      ServerValue: TJSONValue;
      Status: Integer;
      Value: TJSONValue;
      Replaced: Boolean;
    begin
      Root := nil;
      NewServers := nil;
      try
        try
          ConfigText := HttpText(Base, Token, SessionId, 'GET', '/v1/config',
          '', '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('config HTTP %d: %s', [Status, ConfigText]);

        Root := TJSONObject.ParseJSONValue(ConfigText);
        if Root is TJSONObject then
          Config := TJSONObject(Root)
        else
        begin
          Root.Free;
          Config := TJSONObject.Create;
          Root := Config;
        end;

        NewServers := TJSONArray.Create;
        Replaced := False;
        Value := Config.GetValue('mcp_servers');
        if Value is TJSONArray then
          for I := 0 to TJSONArray(Value).Count - 1 do
          begin
            Item := TJSONArray(Value).Items[I];
            if Item is TJSONObject then
            begin
              Row := TJSONObject(Item);
              if SameText(JsonAsString(Row, 'name'), NameText) then
              begin
                ServerValue := TJSONObject.ParseJSONValue(BodyText);
                if ServerValue <> nil then
                  NewServers.AddElement(ServerValue);
                Replaced := True;
              end
              else
                NewServers.AddElement(CloneJsonValue(Item));
            end;
          end;
        if not Replaced then
        begin
          ServerValue := TJSONObject.ParseJSONValue(BodyText);
          if ServerValue <> nil then
            NewServers.AddElement(ServerValue);
        end;

        Pair := Config.RemovePair('mcp_servers');
        Pair.Free;
        Config.AddPair('mcp_servers', NewServers);
        NewServers := nil;
        SavedConfigText := Config.ToJSON;

        ResponseText := HttpText(Base, Token, SessionId, 'PUT', '/v1/config',
          SavedConfigText, 'application/json', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('config save HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          BodyMemo: TMemo;
          Memo: TMemo;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('MCP server save failed: ' + ErrorText);
            Exit;
          end;
          if FEndpointBodyMemos.TryGetValue('settings', BodyMemo) then
            BodyMemo.Lines.Text := SavedConfigText;
          if FPaneMemos.TryGetValue('mcp', Memo) then
            Memo.Lines.Text := 'PUT /v1/config' + sLineBreak + 'HTTP ' +
              Status.ToString + sLineBreak + sLineBreak +
              'Saved MCP server: ' + NameText;
          ConfigRenderEditor;
          McpRefreshClick(nil);
          SetStatus('MCP server saved');
        end);
    finally
      NewServers.Free;
      Root.Free;
    end;
    end);
end;

procedure TMasterDetailForm.McpServerRemoveClick(Sender: TObject);
var
  Base: string;
  NameText: string;
  SessionId: string;
  Token: string;
begin
  NameText := Trim(FMcpServerNameEdit.Text);
  if NameText = '' then
  begin
    SetStatus('select or enter an MCP server name');
    Exit;
  end;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('removing MCP server...');

  TTask.Run(
    procedure
    var
      Config: TJSONObject;
      ConfigText: string;
      ErrorText: string;
      I: Integer;
      Item: TJSONValue;
      NewServers: TJSONArray;
      Pair: TJSONPair;
      ResponseText: string;
      Root: TJSONValue;
      Row: TJSONObject;
      SavedConfigText: string;
      Status: Integer;
      Value: TJSONValue;
      Removed: Boolean;
    begin
      Root := nil;
      NewServers := nil;
      try
        try
          ConfigText := HttpText(Base, Token, SessionId, 'GET', '/v1/config',
            '', '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('config HTTP %d: %s', [Status, ConfigText]);

        Root := TJSONObject.ParseJSONValue(ConfigText);
        if Root is TJSONObject then
          Config := TJSONObject(Root)
        else
          raise Exception.Create('config JSON root is not an object');

        NewServers := TJSONArray.Create;
        Removed := False;
        Value := Config.GetValue('mcp_servers');
        if Value is TJSONArray then
          for I := 0 to TJSONArray(Value).Count - 1 do
          begin
            Item := TJSONArray(Value).Items[I];
            if Item is TJSONObject then
            begin
              Row := TJSONObject(Item);
              if SameText(JsonAsString(Row, 'name'), NameText) then
                Removed := True
              else
                NewServers.AddElement(CloneJsonValue(Item));
            end;
          end;
        if not Removed then
          raise Exception.Create('MCP server not found: ' + NameText);

        Pair := Config.RemovePair('mcp_servers');
        Pair.Free;
        Config.AddPair('mcp_servers', NewServers);
        NewServers := nil;
        SavedConfigText := Config.ToJSON;

        ResponseText := HttpText(Base, Token, SessionId, 'PUT', '/v1/config',
          SavedConfigText, 'application/json', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('config save HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          BodyMemo: TMemo;
          Memo: TMemo;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('MCP server remove failed: ' + ErrorText);
            Exit;
          end;
          if FEndpointBodyMemos.TryGetValue('settings', BodyMemo) then
            BodyMemo.Lines.Text := SavedConfigText;
          if FPaneMemos.TryGetValue('mcp', Memo) then
            Memo.Lines.Text := 'PUT /v1/config' + sLineBreak + 'HTTP ' +
              Status.ToString + sLineBreak + sLineBreak +
              'Removed MCP server: ' + NameText;
          McpServerClearClick(nil);
          ConfigRenderEditor;
          McpRefreshClick(nil);
          SetStatus('MCP server removed');
        end);
    finally
      NewServers.Free;
      Root.Free;
    end;
    end);
end;

procedure TMasterDetailForm.McpToolChange(Sender: TObject);
var
  I: Integer;
  Memo: TMemo;
  Name: string;
  Parts: TArray<string>;
begin
  Name := '';
  if Sender = FMcpList then
  begin
    if (FMcpList <> nil) and (FMcpList.Selected <> nil) then
    begin
      Parts := FMcpList.Selected.TagString.Split([#9]);
      if (Length(Parts) > 0) and SameText(Parts[0], 'server') then
      begin
        if FMcpTabs <> nil then
          FMcpTabs.TabIndex := 0;
        if Length(Parts) > 1 then
          McpServerLoadFromJson(Parts[1]);
        Exit;
      end;
      if Length(Parts) > 0 then
        Name := Parts[0];
      if (FMcpToolCombo <> nil) and (Name <> '') then
        FMcpToolCombo.ItemIndex := FMcpToolCombo.Items.IndexOf(Name);
    end;
  end
  else
    Name := ComboSelectedText(FMcpToolCombo);

  if (Name = '') or (FMcpList = nil) then
    Exit;
  for I := 0 to FMcpList.Count - 1 do
  begin
    Parts := FMcpList.ListItems[I].TagString.Split([#9]);
    if (Length(Parts) > 0) and SameText(Parts[0], Name) then
    begin
      if FMcpTabs <> nil then
        FMcpTabs.TabIndex := 1;
      if FMcpToolArgsMemo <> nil then
        FMcpToolArgsMemo.Lines.Text := '{}';
      if (FMcpSchemaForm <> nil) and (Length(Parts) > 2) then
        BuildSchemaForm(FMcpSchemaForm, Parts[2], '{}', False);
      if FPaneMemos.TryGetValue('mcp', Memo) then
      begin
        Memo.Lines.Text := 'MCP Tool' + sLineBreak + sLineBreak +
          'Name: ' + Parts[0] + sLineBreak;
        if Length(Parts) > 1 then
          Memo.Lines.Add('Description: ' + Parts[1]);
        if Length(Parts) > 2 then
        begin
          Memo.Lines.Add('');
          Memo.Lines.Add('Schema:');
          Memo.Lines.Add(Parts[2]);
        end;
      end;
      Break;
    end;
  end;
end;

procedure TMasterDetailForm.McpSchemaApplyClick(Sender: TObject);
var
  Obj: TJSONObject;
begin
  if FMcpSchemaForm = nil then
    Exit;
  Obj := CollectSchemaForm(FMcpSchemaForm, False);
  try
    if FMcpToolArgsMemo <> nil then
      FMcpToolArgsMemo.Lines.Text := Obj.ToJSON;
    SetStatus('MCP args updated from form');
  finally
    Obj.Free;
  end;
end;

procedure TMasterDetailForm.McpResultCopyClick(Sender: TObject);
var
  Clipboard: IFMXClipboardService;
begin
  if (FMcpResultDetailMemo = nil) or (Trim(FMcpResultDetailMemo.Lines.Text) = '') then
  begin
    SetStatus('no MCP result detail to copy');
    Exit;
  end;
  if TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService,
    IInterface(Clipboard)) then
  begin
    Clipboard.SetClipboard(TValue.From<string>(FMcpResultDetailMemo.Lines.Text));
    SetStatus('MCP result copied');
  end
  else
    SetStatus('clipboard service unavailable');
end;

procedure TMasterDetailForm.McpResultSelect(Sender: TObject);
var
  Detail: string;
  Root: TJSONValue;
  TextValue: string;
begin
  if (FMcpResultList = nil) or (FMcpResultList.Selected = nil) or
    (FMcpResultDetailMemo = nil) then
    Exit;
  Detail := FMcpResultList.Selected.TagString;
  if Trim(Detail) = '' then
    Detail := FMcpResultList.Selected.Text;
  Root := TJSONObject.ParseJSONValue(Detail);
  try
    if Root is TJSONObject then
    begin
      (* An MCP text content block is the payload the operator actually wants
         to read. Pretty-printing the whole block buries it in escapes --
         render the text itself, with the raw block underneath for anything a
         caller still needs (annotations, mime types). Paren-star delimiters:
         a JSON example inside a curly-brace comment ends it at the first
         '}', which is what broke the dcc64 build. *)
      TextValue := JsonAsString(TJSONObject(Root), 'text');
      if (TextValue <> '') and
        SameText(JsonAsString(TJSONObject(Root), 'type'), 'text') then
        Detail := TextValue + sLineBreak + sLineBreak +
          '--- raw block ---' + sLineBreak + JsonPretty(Root)
      else
        Detail := JsonPretty(Root);
    end
    else if Root <> nil then
      Detail := JsonPretty(Root);
  finally
    Root.Free;
  end;
  FMcpResultDetailMemo.Lines.Text := Detail;
  SetStatus('MCP result selected');
end;

procedure TMasterDetailForm.McpRenderInvokeResult(const JsonText: string;
  Status: Integer);
var
  Arr: TJSONArray;
  Detail: string;
  I: Integer;
  Obj: TJSONObject;
  ResultObj: TJSONObject;
  Root: TJSONValue;
  Row: TJSONObject;
  Title: string;
  Value: TJSONValue;
begin
  if FMcpResultList = nil then
    Exit;
  if FMcpTabs <> nil then
    FMcpTabs.TabIndex := 2;
  FMcpResultList.Clear;
  if FMcpResultStatusLabel <> nil then
    FMcpResultStatusLabel.Text := 'MCP invoke result - HTTP ' + Status.ToString;

  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if not (Root is TJSONObject) then
    begin
      AddCardListItem(FMcpResultList, 'MCP response', Copy(Trim(JsonText), 1, 220),
        JsonText, 52, False);
      Exit;
    end;

    Obj := TJSONObject(Root);
    Value := Obj.GetValue('error');
    if Value is TJSONObject then
    begin
      Row := TJSONObject(Value);
      Detail := JsonAsString(Row, 'message');
      if Detail = '' then
        Detail := JsonPretty(Row);
      AddCardListItem(FMcpResultList, 'Tool error', Copy(Detail, 1, 220),
        JsonPretty(Row), 58, False);
    end
    else
    begin
      Value := Obj.GetValue('result');
      if Value is TJSONObject then
      begin
        ResultObj := TJSONObject(Value);
        AddCardListItem(FMcpResultList, 'Tool completed',
          IfThen(JsonAsBool(ResultObj, 'isError'), 'Result flagged as error',
          'Result returned successfully'), JsonPretty(ResultObj), 54,
          not JsonAsBool(ResultObj, 'isError'));
        Value := ResultObj.GetValue('content');
        if Value is TJSONArray then
        begin
          Arr := TJSONArray(Value);
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              Row := TJSONObject(Arr.Items[I]);
              Title := JsonAsString(Row, 'type');
              if Title = '' then
                Title := 'content ' + (I + 1).ToString;
              Detail := JsonAsString(Row, 'text');
              if Detail = '' then
                Detail := JsonPretty(Row);
              AddCardListItem(FMcpResultList, Title, Copy(Detail, 1, 220),
                JsonPretty(Row), 58, not JsonAsBool(ResultObj, 'isError'));
            end;
        end;
      end
      else
        AddCardListItem(FMcpResultList, 'Tool response', Copy(JsonText, 1, 220),
          JsonText, 58, True);
    end;

    if FMcpResultList.Count > 0 then
    begin
      FMcpResultList.ItemIndex := 0;
      McpResultSelect(FMcpResultList);
    end;
  finally
    Root.Free;
  end;
end;

procedure TMasterDetailForm.McpToolInvokeClick(Sender: TObject);
var
  Args: TJSONValue;
  Body: string;
  FormArgs: TJSONObject;
  Name: string;
  Obj: TJSONObject;
  Params: TJSONObject;
  RawArgsText: string;
begin
  Name := ComboSelectedText(FMcpToolCombo);
  if Name = '' then
  begin
    SetStatus('select an MCP tool');
    Exit;
  end;

  if SchemaFormHasFields(FMcpSchemaForm) then
  begin
    FormArgs := CollectSchemaForm(FMcpSchemaForm, False);
    try
      RawArgsText := FormArgs.ToJSON;
      if FMcpToolArgsMemo <> nil then
        FMcpToolArgsMemo.Lines.Text := RawArgsText;
    finally
      FormArgs.Free;
    end;
  end
  else
    RawArgsText := Trim(FMcpToolArgsMemo.Lines.Text);

  Args := TJSONObject.ParseJSONValue(RawArgsText);
  if not (Args is TJSONObject) then
  begin
    Args.Free;
    SetStatus('tool arguments must be a JSON object');
    Exit;
  end;

  Obj := TJSONObject.Create;
  Params := TJSONObject.Create;
  try
    Params.AddPair('name', Name);
    Params.AddPair('arguments', Args);
    Args := nil;
    Obj.AddPair('jsonrpc', '2.0');
    Obj.AddPair('id', TJSONNumber.Create(1));
    Obj.AddPair('method', 'tools/call');
    Obj.AddPair('params', Params);
    Params := nil;
    Body := Obj.ToJSON;
    if FEndpointBodyMemos.ContainsKey('mcp') then
      FEndpointBodyMemos['mcp'].Lines.Text := Body;
    if FMcpTabs <> nil then
      FMcpTabs.TabIndex := 2;
    FetchEndpoint('mcp', 'POST', '/v1/mcp/rpc', Body);
  finally
    Args.Free;
    Params.Free;
    Obj.Free;
  end;
end;

procedure TMasterDetailForm.SkillsRefreshClick(Sender: TObject);
var
  Base: string;
  Token: string;
  SessionId: string;
begin
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('loading skills...');
  TTask.Run(
    procedure
    var
      ErrorText: string;
      PendingText: string;
      SkillsText: string;
      Status: Integer;
      StatusPending: Integer;
    begin
      try
        SkillsText := HttpText(Base, Token, SessionId, 'GET', '/v1/skills',
          '', '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('skills HTTP %d: %s', [Status, SkillsText]);
        PendingText := HttpText(Base, Token, SessionId, 'GET',
          '/v1/skills/pending', '', '', 'application/json', StatusPending);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;
      TThread.Queue(nil,
        procedure
        var
          Arr: TJSONArray;
          I: Integer;
          Memo: TMemo;
          Root: TJSONValue;
          Row: TJSONObject;
          Value: TJSONValue;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('skills failed: ' + ErrorText);
            Exit;
          end;
          if FSkillList <> nil then
          begin
            FSkillList.Clear;
            Root := TJSONObject.ParseJSONValue(SkillsText);
            try
              if Root is TJSONObject then
              begin
                Value := TJSONObject(Root).GetValue('skills');
                if Value is TJSONArray then
                begin
                  Arr := TJSONArray(Value);
                  for I := 0 to Arr.Count - 1 do
                    if Arr.Items[I] is TJSONObject then
                    begin
                      Row := TJSONObject(Arr.Items[I]);
                      AddCardListItem(FSkillList, JsonAsString(Row, 'name'),
                        'Installed ' + JsonAsString(Row, 'kind'),
                        JsonAsString(Row, 'id') + #9 + JsonPretty(Row), 58,
                        False);
                    end;
                end;
              end;
            finally
              Root.Free;
            end;
          end;
          if FSkillPendingList <> nil then
          begin
            FSkillPendingList.Clear;
            Root := TJSONObject.ParseJSONValue(PendingText);
            try
              if Root is TJSONObject then
              begin
                Value := TJSONObject(Root).GetValue('pending');
                if Value is TJSONArray then
                begin
                  Arr := TJSONArray(Value);
                  for I := 0 to Arr.Count - 1 do
                    if Arr.Items[I] is TJSONObject then
                    begin
                      Row := TJSONObject(Arr.Items[I]);
                      AddCardListItem(FSkillPendingList,
                        JsonAsString(Row, 'name'),
                        'Pending ' + JsonAsString(Row, 'action'),
                        JsonAsString(Row, 'id') + #9 + JsonPretty(Row), 58,
                        True);
                    end;
                end;
              end;
            finally
              Root.Free;
            end;
          end;
          if FPaneMemos.TryGetValue('skills', Memo) then
            Memo.Lines.Text := 'Installed skills:' + sLineBreak +
              SkillsText + sLineBreak + sLineBreak +
              'Pending approval:' + sLineBreak + PendingText;
          AddListEmptyState(FSkillList,
            'No skills installed. Open the catalog below and install one.');
          SetStatus('skills loaded');
        end);
    end);
end;

procedure TMasterDetailForm.SkillsSearchClick(Sender: TObject);
var
  Base: string;
  Query: string;
  Token: string;
  SessionId: string;
begin
  Query := '';
  if FSkillSearchEdit <> nil then
    Query := Trim(FSkillSearchEdit.Text);
  if Query = '' then
  begin
    SetStatus('enter a skill search');
    Exit;
  end;
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('searching skills...');
  TTask.Run(
    procedure
    var
      Endpoint: string;
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      Endpoint := '/v1/skills/search?q=' + UrlEncode(Query);
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET', Endpoint, '',
          '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('skill search HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;
      TThread.Queue(nil,
        procedure
        var
          Arr: TJSONArray;
          I: Integer;
          DisplayName: string;
          Memo: TMemo;
          Root: TJSONValue;
          Row: TJSONObject;
          Source: string;
          Target: string;
          Value: TJSONValue;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('skill search failed: ' + ErrorText);
            Exit;
          end;
          if FSkillCatalogList <> nil then
          begin
            FSkillCatalogList.Clear;
            Root := TJSONObject.ParseJSONValue(ResponseText);
            try
              if Root is TJSONObject then
              begin
                Value := TJSONObject(Root).GetValue('results');
                if Value is TJSONArray then
                begin
                  Arr := TJSONArray(Value);
                  for I := 0 to Arr.Count - 1 do
                    if Arr.Items[I] is TJSONObject then
                    begin
                      Row := TJSONObject(Arr.Items[I]);
                      Source := JsonAsString(Row, 'source');
                      if SameText(Source, 'clawhub') then
                        Target := 'clawhub:' + JsonAsString(Row, 'slug')
                      else
                        Target := 'hub:' + JsonAsString(Row, 'slug');
                      DisplayName := JsonAsString(Row, 'display_name');
                      if DisplayName = '' then
                        DisplayName := JsonAsString(Row, 'slug');
                      AddCardListItem(FSkillCatalogList, DisplayName,
                        'Catalog source: ' + Source, Target + #9 +
                        JsonPretty(Row), 58, False);
                    end;
                end;
              end;
            finally
              Root.Free;
            end;
          end;
          if FPaneMemos.TryGetValue('skills', Memo) then
            Memo.Lines.Text := 'GET ' + Endpoint + sLineBreak + 'HTTP ' +
              Status.ToString + sLineBreak + sLineBreak +
              FormatSkillsText(ResponseText);
          SetStatus('skill search loaded');
        end);
    end);
end;

procedure TMasterDetailForm.SkillsInstallClick(Sender: TObject);
var
  Obj: TJSONObject;
  Parts: TArray<string>;
  Target: string;
begin
  Target := '';
  if (Sender is TButton) and SameText(TButton(Sender).TagString, 'catalog') and
    (FSkillCatalogList <> nil) and (FSkillCatalogList.Selected <> nil) then
  begin
    Parts := FSkillCatalogList.Selected.TagString.Split([#9]);
    if Length(Parts) > 0 then
      Target := Parts[0];
  end;
  if (Target = '') and (FSkillInstallEdit <> nil) then
    Target := Trim(FSkillInstallEdit.Text);
  if Target = '' then
  begin
    SetStatus('enter or select a skill target');
    Exit;
  end;
  Obj := TJSONObject.Create;
  try
    Obj.AddPair('target', Target);
    if FEndpointBodyMemos.ContainsKey('skills') then
      FEndpointBodyMemos['skills'].Lines.Text := Obj.ToJSON;
    FetchEndpoint('skills', 'POST', '/v1/skills', Obj.ToJSON);
  finally
    Obj.Free;
  end;
end;

procedure TMasterDetailForm.SkillsRemoveClick(Sender: TObject);
var
  Id: string;
  Parts: TArray<string>;
begin
  if (FSkillList = nil) or (FSkillList.Selected = nil) then
  begin
    SetStatus('select an installed skill');
    Exit;
  end;
  Parts := FSkillList.Selected.TagString.Split([#9]);
  if Length(Parts) = 0 then
    Exit;
  Id := Parts[0];
  if Id = '' then
    Exit;
  FetchEndpoint('skills', 'DELETE', '/v1/skills/' + UrlEncode(Id), '');
end;

procedure TMasterDetailForm.SkillsApproveClick(Sender: TObject);
var
  Id: string;
  Obj: TJSONObject;
  Parts: TArray<string>;
begin
  if (FSkillPendingList = nil) or (FSkillPendingList.Selected = nil) then
  begin
    SetStatus('select a pending skill');
    Exit;
  end;
  Parts := FSkillPendingList.Selected.TagString.Split([#9]);
  if Length(Parts) = 0 then
    Exit;
  Id := Parts[0];
  Obj := TJSONObject.Create;
  try
    Obj.AddPair('id', Id);
    if FEndpointBodyMemos.ContainsKey('skills') then
      FEndpointBodyMemos['skills'].Lines.Text := Obj.ToJSON;
    FetchEndpoint('skills', 'POST', '/v1/skills/pending/approve', Obj.ToJSON);
  finally
    Obj.Free;
  end;
end;

procedure TMasterDetailForm.SkillsRejectClick(Sender: TObject);
var
  Id: string;
  Obj: TJSONObject;
  Parts: TArray<string>;
begin
  if (FSkillPendingList = nil) or (FSkillPendingList.Selected = nil) then
  begin
    SetStatus('select a pending skill');
    Exit;
  end;
  Parts := FSkillPendingList.Selected.TagString.Split([#9]);
  if Length(Parts) = 0 then
    Exit;
  Id := Parts[0];
  Obj := TJSONObject.Create;
  try
    Obj.AddPair('id', Id);
    if FEndpointBodyMemos.ContainsKey('skills') then
      FEndpointBodyMemos['skills'].Lines.Text := Obj.ToJSON;
    FetchEndpoint('skills', 'POST', '/v1/skills/pending/reject', Obj.ToJSON);
  finally
    Obj.Free;
  end;
end;

procedure TMasterDetailForm.SkillsListChange(Sender: TObject);
var
  Context: string;
  Memo: TMemo;
  Parts: TArray<string>;

  function FormatSkillSelection(const Target, JsonText, SelectionContext: string): string;
  var
    Obj: TJSONObject;
    Root: TJSONValue;
    Text: TStringBuilder;
    Value: TJSONValue;

    procedure AddField(const LabelText, JsonName: string);
    var
      FieldValue: string;
    begin
      FieldValue := JsonAsString(Obj, JsonName);
      if FieldValue <> '' then
        Text.AppendLine(Format('%-14s %s', [LabelText, FieldValue]));
    end;

    procedure AddJsonSection(const TitleText, JsonName: string);
    begin
      Value := Obj.GetValue(JsonName);
      if Value <> nil then
      begin
        Text.AppendLine;
        Text.AppendLine(TitleText);
        Text.AppendLine(StringOfChar('-', Length(TitleText)));
        Text.AppendLine(JsonPretty(Value));
      end;
    end;

  begin
    Result := JsonText;
    Root := TJSONObject.ParseJSONValue(JsonText);
    try
      if not (Root is TJSONObject) then
        Exit;
      Obj := TJSONObject(Root);
      Text := TStringBuilder.Create;
      try
        Text.AppendLine(SelectionContext);
        Text.AppendLine(StringOfChar('=', Length(SelectionContext)));
        Text.AppendLine;
        if Target <> '' then
          Text.AppendLine(Format('%-14s %s', ['Target', Target]));
        AddField('ID', 'id');
        AddField('Name', 'name');
        AddField('Display', 'display_name');
        AddField('Display', 'displayName');
        AddField('Slug', 'slug');
        AddField('Kind', 'kind');
        AddField('Source', 'source');
        AddField('Action', 'action');
        AddField('Status', 'status');
        AddField('Version', 'version');
        AddField('Repo', 'repo');
        AddField('URL', 'url');
        AddField('Path', 'path');
        if JsonAsString(Obj, 'summary') <> '' then
        begin
          Text.AppendLine;
          Text.AppendLine('Summary:');
          Text.AppendLine(JsonAsString(Obj, 'summary'));
        end;
        if JsonAsString(Obj, 'description') <> '' then
        begin
          Text.AppendLine;
          Text.AppendLine('Description:');
          Text.AppendLine(JsonAsString(Obj, 'description'));
        end;
        AddJsonSection('Permissions', 'permissions');
        AddJsonSection('Tools', 'tools');
        AddJsonSection('Files', 'files');
        AddJsonSection('Manifest', 'manifest');
        Text.AppendLine;
        Text.AppendLine('Raw JSON:');
        Text.Append(JsonText);
        Result := Text.ToString;
      finally
        Text.Free;
      end;
    finally
      Root.Free;
    end;
  end;

  procedure UpdateNativeSkillDetail(const Target, JsonText,
    SelectionContext: string);
  var
    BodyText: string;
    DisplayText: string;
    MetaText: string;
    Obj: TJSONObject;
    Root: TJSONValue;
  begin
    Root := TJSONObject.ParseJSONValue(JsonText);
    try
      if not (Root is TJSONObject) then
        Exit;
      Obj := TJSONObject(Root);
      DisplayText := JsonAsString(Obj, 'display_name');
      if DisplayText = '' then
        DisplayText := JsonAsString(Obj, 'displayName');
      if DisplayText = '' then
        DisplayText := JsonAsString(Obj, 'name');
      if DisplayText = '' then
        DisplayText := Target;
      MetaText := SelectionContext;
      if JsonAsString(Obj, 'kind') <> '' then
        MetaText := MetaText + '  |  ' + JsonAsString(Obj, 'kind');
      if JsonAsString(Obj, 'source') <> '' then
        MetaText := MetaText + '  |  ' + JsonAsString(Obj, 'source');
      if JsonAsString(Obj, 'action') <> '' then
        MetaText := MetaText + '  |  ' + JsonAsString(Obj, 'action');
      BodyText := JsonAsString(Obj, 'summary');
      if BodyText = '' then
        BodyText := JsonAsString(Obj, 'description');
      if BodyText = '' then
        BodyText := JsonAsString(Obj, 'repo');
      if BodyText = '' then
        BodyText := JsonAsString(Obj, 'url');
      if FSkillDetailTitleLabel <> nil then
        FSkillDetailTitleLabel.Text := DisplayText;
      if FSkillDetailMetaLabel <> nil then
        FSkillDetailMetaLabel.Text := MetaText;
      if FSkillDetailMemo <> nil then
        FSkillDetailMemo.Lines.Text := BodyText;
    finally
      Root.Free;
    end;
  end;

begin
  if not FPaneMemos.TryGetValue('skills', Memo) then
    Exit;
  Context := 'Skill';
  if (Sender = FSkillList) and (FSkillList.Selected <> nil) then
  begin
    Parts := FSkillList.Selected.TagString.Split([#9]);
    Context := 'Installed Skill';
  end
  else if (Sender = FSkillCatalogList) and (FSkillCatalogList.Selected <> nil) then
  begin
    Parts := FSkillCatalogList.Selected.TagString.Split([#9]);
    Context := 'Catalog Skill';
  end
  else if (Sender = FSkillPendingList) and (FSkillPendingList.Selected <> nil) then
  begin
    Parts := FSkillPendingList.Selected.TagString.Split([#9]);
    Context := 'Pending Skill';
  end
  else
    Exit;
  if Length(Parts) > 1 then
  begin
    Memo.Lines.Text := FormatSkillSelection(Parts[0], Parts[1], Context);
    UpdateNativeSkillDetail(Parts[0], Parts[1], Context);
  end;
  if (Sender = FSkillCatalogList) and (Length(Parts) > 0) and
    (FSkillInstallEdit <> nil) then
    FSkillInstallEdit.Text := Parts[0];
  if Length(Parts) > 0 then
    SetStatus(Context + ': ' + Parts[0]);
end;

procedure TMasterDetailForm.VaultSearchClick(Sender: TObject);
var
  Base: string;
  Query: string;
  Token: string;
  SessionId: string;
begin
  Query := '';
  if FVaultSearchEdit <> nil then
    Query := Trim(FVaultSearchEdit.Text);
  if Query = '' then
  begin
    SetStatus('enter a vault search');
    Exit;
  end;
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('searching vault...');
  TTask.Run(
    procedure
    var
      Endpoint: string;
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      Endpoint := '/v1/vault?q=' + UrlEncode(Query);
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET', Endpoint, '',
          '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('vault HTTP %d: %s', [Status, ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;
      TThread.Queue(nil,
        procedure
        var
          Arr: TJSONArray;
          DetailText: string;
          I: Integer;
          Memo: TMemo;
          Root: TJSONValue;
          Row: TJSONObject;
          Title: string;
          Value: TJSONValue;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('vault search failed: ' + ErrorText);
            Exit;
          end;
          FVaultCurrentSlug := '';
          if FVaultList <> nil then
          begin
            FVaultList.Clear;
            Root := TJSONObject.ParseJSONValue(ResponseText);
            try
              if Root is TJSONObject then
              begin
                Value := TJSONObject(Root).GetValue('results');
                if Value is TJSONArray then
                begin
                  Arr := TJSONArray(Value);
                  for I := 0 to Arr.Count - 1 do
                    if Arr.Items[I] is TJSONObject then
                    begin
                      Row := TJSONObject(Arr.Items[I]);
                      Title := JsonAsString(Row, 'displayName');
                      if Title = '' then
                        Title := JsonAsString(Row, 'slug');
                      DetailText := JsonAsString(Row, 'summary');
                      if DetailText = '' then
                        DetailText := JsonAsString(Row, 'repoUrl');
                      AddCardListItem(FVaultList, Title, DetailText,
                        JsonAsString(Row, 'slug') + #9 + JsonPretty(Row), 62,
                        False);
                    end;
                end;
              end;
            finally
              Root.Free;
            end;
            if FVaultList.Count > 0 then
              FVaultList.ItemIndex := 0;
          end;
          if FPaneMemos.TryGetValue('vault', Memo) then
            Memo.Lines.Text := 'GET ' + Endpoint + sLineBreak + 'HTTP ' +
              Status.ToString + sLineBreak + sLineBreak +
              FormatVaultSearchText(ResponseText);
          AddListEmptyState(FVaultList,
            'No vault matches. Try a broader search term.');
          SetStatus('vault search loaded');
        end);
    end);
end;

procedure TMasterDetailForm.VaultDetailCopyClick(Sender: TObject);
var
  Clipboard: IFMXClipboardService;
begin
  if (FVaultDetailMemo = nil) or (Trim(FVaultDetailMemo.Lines.Text) = '') then
  begin
    SetStatus('no vault detail to copy');
    Exit;
  end;
  if TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService,
    IInterface(Clipboard)) then
  begin
    Clipboard.SetClipboard(TValue.From<string>(FVaultDetailMemo.Lines.Text));
    SetStatus('vault detail copied');
  end
  else
    SetStatus('clipboard service unavailable');
end;

procedure TMasterDetailForm.VaultListChange(Sender: TObject);
var
  Base: string;
  Parts: TArray<string>;
  Slug: string;
  Token: string;
  SessionId: string;
begin
  if (FVaultList = nil) or (FVaultList.Selected = nil) then
    Exit;
  Parts := FVaultList.Selected.TagString.Split([#9]);
  if Length(Parts) = 0 then
    Exit;
  Slug := Parts[0];
  if Slug = '' then
    Exit;
  FVaultCurrentSlug := Slug;
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('loading vault detail...');
  TTask.Run(
    procedure
    var
      Endpoint: string;
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      Endpoint := '/v1/vault/' + UrlEncode(Slug);
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET', Endpoint, '',
          '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('vault detail HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;
      TThread.Queue(nil,
        procedure
        var
          DetailText: string;
          DisplayName: string;
          Memo: TMemo;
          Obj: TJSONObject;
          RepoUrl: string;
          Root: TJSONValue;
        begin
          if ErrorText <> '' then
          begin
            if FVaultTitleLabel <> nil then
              FVaultTitleLabel.Text := Slug;
            if FVaultMetaLabel <> nil then
              FVaultMetaLabel.Text := 'Detail failed: ' + ErrorText;
            SetStatus('vault detail failed: ' + ErrorText);
            Exit;
          end;
          Root := TJSONObject.ParseJSONValue(ResponseText);
          try
            if Root is TJSONObject then
            begin
              Obj := TJSONObject(Root);
              DisplayName := JsonAsString(Obj, 'displayName');
              if DisplayName = '' then
                DisplayName := Slug;
              RepoUrl := JsonAsString(Obj, 'repoUrl');
              if FVaultTitleLabel <> nil then
                FVaultTitleLabel.Text := DisplayName;
              if FVaultMetaLabel <> nil then
                FVaultMetaLabel.Text := Slug + IfThen(RepoUrl <> '',
                  '  |  ' + RepoUrl, '');
              DetailText := '';
              if JsonAsString(Obj, 'summary') <> '' then
                DetailText := DetailText + JsonAsString(Obj, 'summary') +
                  sLineBreak + sLineBreak;
              if JsonAsString(Obj, 'installSnippet') <> '' then
                DetailText := DetailText + 'Install' + sLineBreak +
                  JsonAsString(Obj, 'installSnippet') + sLineBreak +
                  sLineBreak;
              if JsonAsString(Obj, 'descriptionMarkdown') <> '' then
                DetailText := DetailText + JsonAsString(Obj,
                  'descriptionMarkdown')
              else if JsonAsString(Obj, 'description') <> '' then
                DetailText := DetailText + JsonAsString(Obj, 'description');
              if FVaultDetailMemo <> nil then
                FVaultDetailMemo.Lines.Text := Trim(DetailText);
            end;
          finally
            Root.Free;
          end;
          if FPaneMemos.TryGetValue('vault', Memo) then
            Memo.Lines.Text := 'GET ' + Endpoint + sLineBreak + 'HTTP ' +
              Status.ToString + sLineBreak + sLineBreak +
              FormatVaultDetailText(ResponseText);
          SetStatus('vault detail loaded');
        end);
    end);
end;

procedure TMasterDetailForm.VaultBuildWithClick(Sender: TObject);
var
  Base: string;
  Slug: string;
  Token: string;
  SessionId: string;
begin
  Slug := FVaultCurrentSlug;
  if Slug = '' then
  begin
    SetStatus('select a vault entry');
    Exit;
  end;
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('preparing vault attachment...');
  TTask.Run(
    procedure
    var
      ContextText: string;
      DisplayName: string;
      Endpoint: string;
      ErrorText: string;
      Obj: TJSONObject;
      ResponseText: string;
      Root: TJSONValue;
      Status: Integer;
    begin
      Endpoint := '/v1/vault/' + UrlEncode(Slug);
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET', Endpoint, '',
          '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('vault detail HTTP %d: %s', [Status,
            ResponseText]);
        Root := TJSONObject.ParseJSONValue(ResponseText);
        try
          if Root is TJSONObject then
          begin
            Obj := TJSONObject(Root);
            DisplayName := JsonAsString(Obj, 'displayName');
            if DisplayName = '' then
              DisplayName := Slug;
            ContextText := '# ' + DisplayName + sLineBreak + sLineBreak +
              'Repo: ' + JsonAsString(Obj, 'repoUrl') + sLineBreak +
              'Install:' + sLineBreak + JsonAsString(Obj, 'installSnippet') +
              sLineBreak + sLineBreak +
              JsonAsString(Obj, 'descriptionMarkdown');
          end
          else
            ContextText := ResponseText;
        finally
          Root.Free;
        end;
      except
        on E: Exception do
          ErrorText := E.Message;
      end;
      TThread.Queue(nil,
        procedure
        begin
          if ErrorText <> '' then
          begin
            SetStatus('vault build-with failed: ' + ErrorText);
            Exit;
          end;
          AddAttachment(Slug + '.md', ContextText);
          if FPromptMemo <> nil then
            FPromptMemo.Lines.Text := 'Help me build a small Object Pascal example using ' +
              DisplayName + '. Use the attached library reference for install/setup.';
          RenderAttachments;
          SelectTabByText('Chat');
          SetStatus('vault reference attached');
        end);
    end);
end;

procedure TMasterDetailForm.FileDownloadClick(Sender: TObject);
var
  Base: string;
  Dialog: TSaveDialog;
  Edit: TEdit;
  Endpoint: string;
  FilePath: string;
  SessionId: string;
  Token: string;
begin
  Endpoint := '/v1/fs/download?path=';
  if FEndpointEdits.TryGetValue('files', Edit) and
    (Trim(Edit.Text) <> '') then
    Endpoint := Edit.Text;
  if Pos('/v1/fs/download', Endpoint) = 0 then
    Endpoint := '/v1/fs/download?path=';

  Dialog := TSaveDialog.Create(Self);
  try
    Dialog.Filter := 'All files|*.*';
    Dialog.FileName := 'pasclaw-file.bin';
    if (FFilePathEdit <> nil) and (Trim(FFilePathEdit.Text) <> '') then
      Dialog.FileName := FsFileName(Trim(FFilePathEdit.Text));
    if not Dialog.Execute then
      Exit;
    FilePath := Dialog.FileName;
  finally
    Dialog.Free;
  end;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('downloading file...');
  TTask.Run(
    procedure
    var
      Client: THTTPClient;
      ErrorText: string;
      Headers: TNetHeaders;
      Response: IHTTPResponse;
      Status: Integer;
      Stream: TFileStream;
    begin
      try
        Headers := nil;
        AddHeader(Headers, 'Accept', 'application/octet-stream, text/plain, application/json');
        if Token <> '' then
          AddHeader(Headers, 'Authorization', 'Bearer ' + Token);
        if SessionId <> '' then
          AddHeader(Headers, 'X-PasClaw-Session', SessionId);
        Client := THTTPClient.Create;
        Stream := TFileStream.Create(FilePath, fmCreate);
        try
          Client.ConnectionTimeout := 10000;
          Client.ResponseTimeout := 180000;
          Response := Client.Get(ComposeUrl(Base, Endpoint), Stream, Headers);
          Status := Response.StatusCode;
          if not IsHttpOk(Status) then
            raise Exception.CreateFmt('file download HTTP %d', [Status]);
        finally
          Stream.Free;
          Client.Free;
        end;
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Memo: TMemo;
        begin
          if FPaneMemos.TryGetValue('files', Memo) then
            if ErrorText <> '' then
              Memo.Lines.Text := 'GET ' + Endpoint + sLineBreak +
                'Error: ' + ErrorText
            else
              Memo.Lines.Text := 'GET ' + Endpoint + sLineBreak +
                'saved to ' + FilePath;
          if ErrorText <> '' then
            SetStatus('file download failed')
          else
            SetStatus('file downloaded');
        end);
    end);
end;

procedure TMasterDetailForm.KbSourcesLoadClick(Sender: TObject);
var
  Base: string;
  SessionId: string;
  Token: string;
begin
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  if FEndpointEdits.ContainsKey('kb') then
    FEndpointEdits['kb'].Text := '/v1/kb';
  SetStatus('loading KB sources...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET', '/v1/kb',
          '', '', 'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('KB HTTP %d: %s', [Status, ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Arr: TJSONArray;
          I: Integer;
          Memo: TMemo;
          Root: TJSONValue;
          Row: TJSONObject;
          Stats: TJSONObject;
          Value: TJSONValue;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('KB sources failed: ' + ErrorText);
            Exit;
          end;

          if FKBSourceList <> nil then
            FKBSourceList.Clear;
          Root := TJSONObject.ParseJSONValue(ResponseText);
          try
            if Root is TJSONObject then
            begin
              Value := TJSONObject(Root).GetValue('stats');
              if Value is TJSONObject then
              begin
                Stats := TJSONObject(Value);
                if FKBStatusLabel <> nil then
                  FKBStatusLabel.Text := Format('%d source(s), %d file(s), %d chunk(s)%s',
                    [JsonAsInt64(Stats, 'sources'),
                    JsonAsInt64(Stats, 'files'),
                    JsonAsInt64(Stats, 'chunks'),
                    IfThen(JsonAsBool(Stats, 'vector_ready'), ' with vector index', '')]);
              end;
              Value := TJSONObject(Root).GetValue('sources');
              if (Value is TJSONArray) and (FKBSourceList <> nil) then
              begin
                Arr := TJSONArray(Value);
                for I := 0 to Arr.Count - 1 do
                  if Arr.Items[I] is TJSONObject then
                  begin
                    Row := TJSONObject(Arr.Items[I]);
                    AddCardListItem(FKBSourceList, JsonAsString(Row, 'root'),
                      Format('%d file(s), %d chunk(s)',
                      [JsonAsInt64(Row, 'files'), JsonAsInt64(Row, 'chunks')]),
                      JsonPretty(Row), 58, False);
                  end;
              end;
            end;
          finally
            Root.Free;
          end;
          if FPaneMemos.TryGetValue('kb', Memo) then
            Memo.Lines.Text := 'GET /v1/kb' + sLineBreak + 'HTTP ' +
              Status.ToString + sLineBreak + sLineBreak +
              FormatKbSourcesText(ResponseText);
          SetStatus('KB sources loaded');
        end);
    end);
end;

procedure TMasterDetailForm.KbSearchClick(Sender: TObject);
var
  Base: string;
  Query: string;
  SessionId: string;
  Token: string;
begin
  Query := '';
  if FKBSearchEdit <> nil then
    Query := Trim(FKBSearchEdit.Text);
  if Query = '' then
  begin
    SetStatus('KB query is required');
    Exit;
  end;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  if FEndpointEdits.ContainsKey('kb') then
    FEndpointEdits['kb'].Text := '/v1/kb/search?q=' + UrlEncode(Query);
  SetStatus('searching KB...');

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'GET',
          '/v1/kb/search?q=' + UrlEncode(Query), '', '', 'application/json',
          Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('KB search HTTP %d: %s', [Status,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Arr: TJSONArray;
          I: Integer;
          Memo: TMemo;
          Root: TJSONValue;
          Row: TJSONObject;
          Snippet: string;
          Value: TJSONValue;
        begin
          if ErrorText <> '' then
          begin
            SetStatus('KB search failed: ' + ErrorText);
            Exit;
          end;
          if FKBResultsList <> nil then
            FKBResultsList.Clear;
          Root := TJSONObject.ParseJSONValue(ResponseText);
          try
            if Root is TJSONObject then
            begin
              Value := TJSONObject(Root).GetValue('hits');
              if (Value is TJSONArray) and (FKBResultsList <> nil) then
              begin
                Arr := TJSONArray(Value);
                for I := 0 to Arr.Count - 1 do
                  if Arr.Items[I] is TJSONObject then
                  begin
                    Row := TJSONObject(Arr.Items[I]);
                    Snippet := JsonAsString(Row, 'snippet');
                    AddCardListItem(FKBResultsList, JsonAsString(Row, 'path'),
                      Format('chunk %d, score %s%s%s',
                      [JsonAsInt64(Row, 'chunk'), JsonAsString(Row, 'score'),
                      sLineBreak, Copy(Snippet, 1, 180)]),
                      JsonAsString(Row, 'path') + #9 + JsonAsString(Row,
                      'chunk') + #9 + Snippet, 76, False);
                  end;
              end;
            end;
          finally
            Root.Free;
          end;
          if FKBStatusLabel <> nil then
            FKBStatusLabel.Text := Format('%d KB hit(s)',
              [IfThen(FKBResultsList <> nil, FKBResultsList.Count, 0)]);
          if FPaneMemos.TryGetValue('kb', Memo) then
            Memo.Lines.Text := 'GET /v1/kb/search?q=' + Query +
              sLineBreak + 'HTTP ' + Status.ToString + sLineBreak +
              sLineBreak + FormatKbSearchText(ResponseText);
          AddListEmptyState(FKBResultsList,
            'No results. Index sources on this tab, then search again.');
          SetStatus('KB search complete');
        end);
    end);
end;

procedure TMasterDetailForm.KbResultsChange(Sender: TObject);
var
  Memo: TMemo;
  Parts: TArray<string>;
begin
  if (FKBResultsList = nil) or (FKBResultsList.Selected = nil) then
    Exit;
  Parts := FKBResultsList.Selected.TagString.Split([#9]);
  if Length(Parts) < 3 then
    Exit;
  if FPaneMemos.TryGetValue('kb', Memo) then
    Memo.Lines.Text := 'KB Result' + sLineBreak +
      sLineBreak + 'Path:  ' + Parts[0] + sLineBreak + 'Chunk: ' + Parts[1] +
      sLineBreak + sLineBreak + Parts[2];
end;

procedure TMasterDetailForm.KbResultOpenFileClick(Sender: TObject);
{ Jump from a KB search hit to the file it came from -- the web UI's
  result-card click-through. TagString is path<TAB>chunk<TAB>text. }
var
  Parts: TArray<string>;
  PathText: string;
begin
  if (FKBResultsList = nil) or (FKBResultsList.Selected = nil) then
  begin
    SetStatus('select a KB result first');
    Exit;
  end;
  Parts := FKBResultsList.Selected.TagString.Split([#9]);
  if Length(Parts) < 1 then
    Exit;
  PathText := Trim(Parts[0]);
  if PathText = '' then
  begin
    SetStatus('this result has no source path');
    Exit;
  end;
  SelectTabByText('Files');
  { A KB hit is a FILE path. FilesOpenPath drives /v1/fs, the directory
    listing, which the gateway 404s for a non-directory -- so the button
    switched tabs and then failed. Use the same read/preview dispatch the
    Files tab's own 'read' action uses. }
  if IsPreviewImagePath(PathText) then
    FilesPreviewImagePath(PathText)
  else
    FilesReadPath(PathText);
end;

procedure TMasterDetailForm.KbSourcesChange(Sender: TObject);
var
  Memo: TMemo;
  Obj: TJSONObject;
  Root: TJSONValue;
  Text: TStringBuilder;
begin
  if (FKBSourceList = nil) or (FKBSourceList.Selected = nil) then
    Exit;
  if not FPaneMemos.TryGetValue('kb', Memo) then
    Exit;

  Root := TJSONObject.ParseJSONValue(FKBSourceList.Selected.TagString);
  try
    if not (Root is TJSONObject) then
      Exit;
    Obj := TJSONObject(Root);
    Text := TStringBuilder.Create;
    try
      Text.AppendLine('KB Source');
      Text.AppendLine;
      Text.AppendLine(Format('%-10s %s', ['Root', JsonAsString(Obj, 'root')]));
      Text.AppendLine(Format('%-10s %d', ['Files', JsonAsInt64(Obj, 'files')]));
      Text.AppendLine(Format('%-10s %d', ['Chunks', JsonAsInt64(Obj, 'chunks')]));
      if JsonAsString(Obj, 'updated_at') <> '' then
        Text.AppendLine(Format('%-10s %s', ['Updated', JsonAsString(Obj, 'updated_at')]));
      Text.AppendLine;
      Text.AppendLine('Raw JSON:');
      Text.Append(Obj.ToJSON);
      Memo.Lines.Text := Text.ToString;
    finally
      Text.Free;
    end;
    SetStatus('KB source selected');
  finally
    Root.Free;
  end;
end;

procedure TMasterDetailForm.KbUploadClick(Sender: TObject);
var
  Base: string;
  Dialog: TOpenDialog;
  FilePath: string;
  SessionId: string;
  Token: string;
begin
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Filter := 'Knowledge files|*.md;*.markdown;*.txt;*.rst;*.adoc;*.org;*.pas;*.pp;*.inc;*.dpr;*.lpr;*.c;*.h;*.cc;*.cpp;*.hpp;*.cs;*.java;*.go;*.rs;*.js;*.ts;*.py;*.rb;*.php;*.swift;*.kt;*.sql;*.sh;*.bat;*.ps1;*.json;*.yaml;*.yml;*.toml;*.ini;*.csv;*.html;*.htm;*.pdf|All files|*.*';
    if not Dialog.Execute then
      Exit;
    FilePath := Dialog.FileName;
  finally
    Dialog.Free;
  end;

  if TFile.GetSize(FilePath) > 30 * 1024 * 1024 then
  begin
    SetStatus('KB file too large: max 30 MB');
    Exit;
  end;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('uploading KB file...');
  TTask.Run(
    procedure
    var
      Body: string;
      Bytes: TBytes;
      ErrorText: string;
      Obj: TJSONObject;
      ResponseText: string;
      Status: Integer;
    begin
      try
        Obj := TJSONObject.Create;
        try
          Obj.AddPair('name', ExtractFileName(FilePath));
          if SameText(ExtractFileExt(FilePath), '.pdf') then
          begin
            Bytes := TFile.ReadAllBytes(FilePath);
            Obj.AddPair('content_b64', TNetEncoding.Base64.EncodeBytesToString(Bytes));
          end
          else
            Obj.AddPair('content', TFile.ReadAllText(FilePath, TEncoding.UTF8));
          Body := Obj.ToJSON;
        finally
          Obj.Free;
        end;
        ResponseText := HttpText(Base, Token, SessionId, 'POST',
          '/v1/kb/upload', Body, 'application/json', 'application/json',
          Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('KB upload HTTP %d: %s',
            [Status, ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Chunks: Int64;
          Files: Int64;
          Memo: TMemo;
          Root: TJSONValue;
          Summary: string;
          Uploaded: string;
        begin
          Summary := ResponseText;
          if ErrorText = '' then
          begin
            Root := TJSONObject.ParseJSONValue(ResponseText);
            try
              if Root is TJSONObject then
              begin
                Uploaded := JsonAsString(TJSONObject(Root), 'uploaded');
                Files := JsonAsInt64(TJSONObject(Root), 'indexed_files');
                Chunks := JsonAsInt64(TJSONObject(Root), 'indexed_chunks');
                Summary := 'KB Upload' +
                  sLineBreak + sLineBreak + 'Uploaded: ' + Uploaded +
                  sLineBreak + 'Indexed files: ' + Files.ToString +
                  sLineBreak + 'Indexed chunks: ' + Chunks.ToString +
                  sLineBreak + sLineBreak + 'Raw JSON:' + sLineBreak + ResponseText;
                if FKBStatusLabel <> nil then
                  FKBStatusLabel.Text := Format('indexed %s: %d file(s), %d chunk(s)',
                    [Uploaded, Files, Chunks]);
              end;
            finally
              Root.Free;
            end;
          end;
          if FPaneMemos.TryGetValue('kb', Memo) then
          begin
            if ErrorText <> '' then
              Memo.Lines.Text := 'POST /v1/kb/upload' + sLineBreak +
                'Error: ' + ErrorText
            else
              Memo.Lines.Text := 'POST /v1/kb/upload' + sLineBreak +
                'HTTP ' + Status.ToString + sLineBreak + sLineBreak + Summary;
          end;
          if ErrorText <> '' then
            SetStatus('KB upload failed')
          else
          begin
            SetStatus('KB upload complete');
            KbSourcesLoadClick(nil);
          end;
        end);
    end);
end;

procedure TMasterDetailForm.WorkspaceExportClick(Sender: TObject);
var
  Base: string;
  Dialog: TSaveDialog;
  FilePath: string;
  SessionId: string;
  Token: string;
begin
  Dialog := TSaveDialog.Create(Self);
  try
    Dialog.Filter := 'ZIP archive|*.zip|All files|*.*';
    Dialog.FileName := 'pasclaw-workspace.zip';
    if not Dialog.Execute then
      Exit;
    FilePath := Dialog.FileName;
  finally
    Dialog.Free;
  end;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('exporting workspace...');
  TTask.Run(
    procedure
    var
      Client: THTTPClient;
      ErrorText: string;
      Headers: TNetHeaders;
      Response: IHTTPResponse;
      Stream: TFileStream;
      Status: Integer;
    begin
      try
        Headers := nil;
        AddHeader(Headers, 'Accept', 'application/zip, application/octet-stream');
        if Token <> '' then
          AddHeader(Headers, 'Authorization', 'Bearer ' + Token);
        if SessionId <> '' then
          AddHeader(Headers, 'X-PasClaw-Session', SessionId);
        Client := THTTPClient.Create;
        Stream := TFileStream.Create(FilePath, fmCreate);
        try
          Client.ConnectionTimeout := 10000;
          Client.ResponseTimeout := 180000;
          Response := Client.Get(ComposeUrl(Base, '/v1/workspace/export'),
            Stream, Headers);
          Status := Response.StatusCode;
          if not IsHttpOk(Status) then
            raise Exception.CreateFmt('workspace export HTTP %d', [Status]);
        finally
          Stream.Free;
          Client.Free;
        end;
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Memo: TMemo;
        begin
          if FPaneMemos.TryGetValue('settings', Memo) then
            if ErrorText <> '' then
              Memo.Lines.Text := 'GET /v1/workspace/export' + sLineBreak +
                'Error: ' + ErrorText
            else
              Memo.Lines.Text := 'GET /v1/workspace/export' + sLineBreak +
                'saved to ' + FilePath;
          if ErrorText <> '' then
            SetStatus('workspace export failed')
          else
            SetStatus('workspace exported');
        end);
    end);
end;

procedure TMasterDetailForm.WorkspaceImportClick(Sender: TObject);
var
  Base: string;
  Dialog: TOpenDialog;
  FilePath: string;
  SessionId: string;
  Token: string;
begin
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Filter := 'ZIP archive|*.zip|All files|*.*';
    if not Dialog.Execute then
      Exit;
    FilePath := Dialog.FileName;
  finally
    Dialog.Free;
  end;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus('importing workspace...');
  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpPostFile(Base, Token, SessionId,
          '/v1/workspace/import', FilePath, 'application/zip',
          'application/json', Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('workspace import HTTP %d: %s',
            [Status, ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          Memo: TMemo;
        begin
          if FPaneMemos.TryGetValue('settings', Memo) then
          begin
            if ErrorText <> '' then
              Memo.Lines.Text := 'POST /v1/workspace/import' + sLineBreak +
                'Error: ' + ErrorText
            else
              Memo.Lines.Text := 'POST /v1/workspace/import' + sLineBreak +
                'HTTP ' + Status.ToString + sLineBreak + sLineBreak +
                ResponseText;
          end;
          if ErrorText <> '' then
            SetStatus('workspace import failed')
          else
            SetStatus('workspace imported');
        end);
    end);
end;

procedure TMasterDetailForm.LoadModels;
var
  Base: string;
  Token: string;
  SessionId: string;
begin
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  TTask.Run(
    procedure
    var
      Arr: TJSONArray;
      I: Integer;
      Id: string;
      Item: TJSONValue;
      Obj: TJSONObject;
      Root: TJSONValue;
      Status: Integer;
      Text: string;
      Value: TJSONValue;
      Models: TArray<string>;
      ModelList: TList<string>;
    begin
      ModelList := TList<string>.Create;
      try
        try
          Text := HttpText(Base, Token, SessionId, 'GET', '/v1/models', '',
            '', 'application/json', Status);
          if IsHttpOk(Status) then
          begin
            Root := TJSONObject.ParseJSONValue(Text);
            try
              if Root is TJSONObject then
              begin
                Obj := TJSONObject(Root);
                Arr := nil;
                Value := Obj.GetValue('data');
                if Value is TJSONArray then
                  Arr := TJSONArray(Value);
                if Arr = nil then
                begin
                  Value := Obj.GetValue('models');
                  if Value is TJSONArray then
                    Arr := TJSONArray(Value);
                end;
                if Arr <> nil then
                  for I := 0 to Arr.Count - 1 do
                  begin
                    Item := Arr.Items[I];
                    if Item is TJSONObject then
                      Id := JsonAsString(TJSONObject(Item), 'id')
                    else
                      Id := Item.Value;
                    if (Id <> '') and not ModelList.Contains(Id) then
                      ModelList.Add(Id);
                  end;
              end;
            finally
              Root.Free;
            end;
          end;
        except
          { Keep the default-model entry only. }
        end;
        Models := ModelList.ToArray;
      finally
        ModelList.Free;
      end;
      TThread.Queue(nil,
        procedure
        var
          I: Integer;
        begin
          FModelCombo.OnChange := nil;
          FModelCombo.Items.BeginUpdate;
          try
            FModelCombo.Items.Clear;
            FModelCombo.Items.Add('default model');
            for I := 0 to Length(Models) - 1 do
              FModelCombo.Items.Add(Models[I]);
            FModelCombo.ItemIndex := 0;
            if FSavedModel <> '' then
              FModelCombo.ItemIndex := FModelCombo.Items.IndexOf(FSavedModel);
            if FModelCombo.ItemIndex < 0 then
              FModelCombo.ItemIndex := 0;
          finally
            FModelCombo.Items.EndUpdate;
            FModelCombo.OnChange := ModelComboChange;
          end;
        end);
    end);
end;

procedure TMasterDetailForm.LoadSessions;
var
  Base: string;
  Token: string;
  SessionId: string;
begin
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  TTask.Run(
    procedure
    var
      Arr: TJSONArray;
      ErrorText: string;
      I: Integer;
      ItemObj: TJSONObject;
      Root: TJSONValue;
      Session: TPasClawSession;
      Sessions: TArray<TPasClawSession>;
      SessionList: TList<TPasClawSession>;
      Status: Integer;
      Text: string;
      Value: TJSONValue;
    begin
      SessionList := TList<TPasClawSession>.Create;
      try
        try
          Text := HttpText(Base, Token, SessionId, 'GET', '/v1/sessions', '',
            '', 'application/json', Status);
          if not IsHttpOk(Status) then
            raise Exception.CreateFmt('sessions HTTP %d: %s', [Status, Text]);
          Root := TJSONObject.ParseJSONValue(Text);
          try
            if Root is TJSONObject then
            begin
              Arr := nil;
              Value := TJSONObject(Root).GetValue('sessions');
              if Value is TJSONArray then
                Arr := TJSONArray(Value);
              if Arr <> nil then
                for I := 0 to Arr.Count - 1 do
                  if Arr.Items[I] is TJSONObject then
                  begin
                    ItemObj := TJSONObject(Arr.Items[I]);
                    Session.Id := JsonAsString(ItemObj, 'id');
                    Session.Title := JsonAsString(ItemObj, 'title');
                    Session.UpdatedAt := JsonAsString(ItemObj, 'updated_at');
                    if Session.Title = '' then
                      Session.Title := '(untitled)';
                    if Session.Id <> '' then
                      SessionList.Add(Session);
                  end;
            end;
          finally
            Root.Free;
          end;
        except
          on E: Exception do
            ErrorText := E.Message;
        end;
        Sessions := SessionList.ToArray;
      finally
        SessionList.Free;
      end;
      TThread.Queue(nil,
        procedure
        var
          I: Integer;
        begin
          if ErrorText <> '' then
          begin
            FOnlineIdentity := '';
            RenderConnectButton;
            SetStatus('offline: ' + ErrorText);
            Exit;
          end;
          { the endpoint that ACTUALLY answered, captured for this request --
            not whatever the fields happen to hold now }
          FOnlineIdentity := Base + #1 + Token;
          RenderConnectButton;
          FSessionCache.Clear;
          for I := 0 to Length(Sessions) - 1 do
            FSessionCache.Add(Sessions[I]);
          RenderSessionList;
          SetStatus('connected');
          { land in the newest conversation, not the empty placeholder card
            -- connecting should drop you into your chat like the web UI }
          if (FActiveSessionId = '') and (FSessionCache.Count > 0) then
            LoadSession(FSessionCache[0].Id);
        end);
    end);
end;

procedure TMasterDetailForm.RenderSessionList;
var
  Card: TRectangle;
  Filter: string;
  Glyph: TPath;
  I: Integer;
  Item: TListBoxItem;
  MetaText: string;
  SelectedIndex: Integer;
  Session: TPasClawSession;
  Title: string;
  TitleLabel: TLabel;
begin
  FLoadingSessions := True;
  FSessionList.BeginUpdate;
  try
    FSessionList.Clear;
    Filter := Trim(LowerCase(FSessionSearch.Text));
    SelectedIndex := -1;
    for I := 0 to FSessionCache.Count - 1 do
    begin
      Session := FSessionCache[I];
      Title := Session.Title;
      if (Filter <> '') and (Pos(Filter, LowerCase(Title)) = 0) then
        Continue;
      Item := TListBoxItem.Create(FSessionList);
      Item.Parent := FSessionList;
      Item.Text := '';
      Item.TagString := Session.Id;
      Item.Height := ROW_LIST;
      Item.HitTest := True;
      Item.OnClick := CardListItemClick;

      Card := TRectangle.Create(Item);
      Card.Parent := Item;
      Card.Align := TAlignLayout.Client;
      StyleChromeRect(Card, UI_PANEL_ALT, UI_BORDER, 6, True);
      { A rule around every row turns a list into a grid -- ten sessions drew
        ten boxes competing with the ten titles inside them. Only the active
        session is outlined, because there only one line means something. }
      Card.Stroke.Kind := TBrushKind.None;
      Card.OnClick := CardListItemClick;
      SetControlMargins(Card, 0, 1, 0, 1);
      SetControlPadding(Card, GAP_S, GAP_XS, GAP_S, GAP_XS);

      { A leading rail. Titles are ragged by nature -- they are whatever the
        first message said -- so a fixed mark at the start of every row gives
        the eye a column to run down instead of a jagged left edge.

        It carries the ACTIVE state as well: the selected session's bubble
        takes the accent while the rest stay muted, so selection reads from
        the rail even where the card's outline is clipped or scrolled. A mark
        that also answers a question earns its place; pure decoration on
        every row would just be noise with extra steps. }
      Glyph := TPath.Create(Card);
      Glyph.Parent := Card;
      Glyph.Align := TAlignLayout.Left;
      Glyph.Width := SESSION_GLYPH_W;
      Glyph.HitTest := False;
      Glyph.Data.Data := GLYPH_SESSION;
      Glyph.WrapMode := TPathWrapMode.Fit;
      Glyph.Stroke.Kind := TBrushKind.None;
      Glyph.Fill.Kind := TBrushKind.Solid;
      { A raw TPath brush does NOT inherit the style book's foreground the
        way a styled label does, so it has to be mapped explicitly -- this is
        precisely what ThemePaintColor is for. }
      Glyph.Fill.Color := ThemePaintColor(UI_MUTED);
      { the bubble is wider than tall; inset vertically so it sits on the
        text's optical centre rather than filling the row }
      SetControlMargins(Glyph, 0, GAP_XS + 1, GAP_S, GAP_XS + 1);

      TitleLabel := TLabel.Create(Card);
      TitleLabel.Parent := Card;
      TitleLabel.Align := TAlignLayout.Client;
      TitleLabel.HitTest := False;
      TitleLabel.Text := Title;
      TitleLabel.WordWrap := False;
      { tier 4 -- the sidebar is navigation chrome; only the transcript gets
        full-strength ink. Regular weight: a column of bold titles reads as a
        wall of emphasis, which is no emphasis at all. }
      StyleLabel(TitleLabel, UI_CHROME_TEXT, TXT_TITLE, False);

      { The age and the raw id were a second line of text per row, louder
        than the titles and answering a question nobody asked mid-scan. They
        move to the hover hint, where they cost nothing until wanted. }
      MetaText := Session.Id;
      if Session.UpdatedAt <> '' then
        MetaText := FriendlyAge(Session.UpdatedAt) + '  |  ' + Session.Id;
      Card.Hint := Title + sLineBreak + MetaText;
      Card.ShowHint := True;

      if Session.Id = FActiveSessionId then
      begin
        Glyph.Fill.Color := ThemePaintColor(UI_ACCENT);
        Card.Stroke.Kind := TBrushKind.Solid;
        { These overwrite what StyleChromeRect just theme-mapped, so they
          have to map too. Unmapped, the ACTIVE card took the dark theme's
          UI_ACCENT_DIM -- a near-black navy -- as its fill on light paper. }
        Card.Stroke.Color := ThemePaintStroke(UI_ACCENT);
        Card.Fill.Color := ThemePaintColor(UI_ACCENT_DIM);
        SelectedIndex := FSessionList.Count - 1;
      end;
    end;
    if FSessionList.Count = 0 then
    begin
      { empty state: say what belongs here and how to get one, instead of
        presenting a silent blank column }
      Item := TListBoxItem.Create(FSessionList);
      Item.Parent := FSessionList;
      Item.Text := '';
      Item.Height := ROW_CARD;
      Item.HitTest := False;
      TitleLabel := TLabel.Create(Item);
      TitleLabel.Parent := Item;
      TitleLabel.Align := TAlignLayout.Client;
      TitleLabel.HitTest := False;
      TitleLabel.WordWrap := True;
      if Filter <> '' then
        TitleLabel.Text := 'No sessions match the filter.'
      else
        TitleLabel.Text :=
          'No sessions yet. Connect to a gateway, then press + to start one.';
      SetControlMargins(TitleLabel, 10, GAP_S, 10, GAP_S);
      StyleLabel(TitleLabel, UI_MUTED, TXT_BODY, False);
    end;
    FSessionList.ItemIndex := SelectedIndex;
  finally
    FSessionList.EndUpdate;
    FLoadingSessions := False;
  end;
end;

procedure TMasterDetailForm.SessionSearchChange(Sender: TObject);
begin
  RenderSessionList;
end;

procedure TMasterDetailForm.SessionListChange(Sender: TObject);
begin
  if FLoadingSessions then
    Exit;
  if FSessionList.Selected <> nil then
  begin
    LoadSession(FSessionList.Selected.TagString);
    { closing over the picked session must re-measure too -- LoadSession is
      async, so waiting for its render left the transcript capped while the
      composer had already gone full width (and stayed that way if the load
      failed) }
    if (FSessionDrawer <> nil) and
      (FSessionDrawer.Mode = TMultiViewMode.Drawer) then
      SetSidebarVisible(False, False);
  end;
end;

procedure TMasterDetailForm.NewSessionClick(Sender: TObject);
begin
  SaveChatParams(FActiveSessionId);
  FActiveSessionId := '';
  LoadChatParams('');
  FTurns.Clear;
  FPromptMemo.Lines.Clear;
  if FAttachments <> nil then
    FAttachments.Clear;
  if FQueuedPrompts <> nil then
    FQueuedPrompts.Clear;
  RenderAttachments;
  RenderQueue;
  RenderSessionList;
  RenderChat;
  SetStatus('new chat');
  SelectTabByText('Chat');
end;

procedure TMasterDetailForm.DeleteSessionClick(Sender: TObject);
var
  Base: string;
  Ini: TIniFile;
  SessionId: string;
  Token: string;
begin
  SessionId := FActiveSessionId;
  if SessionId = '' then
  begin
    SetStatus('no session selected');
    Exit;
  end;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SetStatus('deleting session...');
  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'DELETE',
          '/v1/sessions/' + UrlEncode(SessionId), '', '', 'application/json',
          Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('delete HTTP %d: %s', [Status, ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        begin
          if ErrorText <> '' then
          begin
            SetStatus('delete failed: ' + ErrorText);
            Exit;
          end;
          Ini := TIniFile.Create(FConfigFile);
          try
            Ini.EraseSection(ChatParamsSection(SessionId));
          finally
            Ini.Free;
          end;
          if FActiveSessionId = SessionId then
          begin
            FActiveSessionId := '';
            LoadChatParams('');
            FTurns.Clear;
            RenderChat;
          end;
          SetStatus('session deleted');
          LoadSessions;
        end);
    end);
end;

procedure TMasterDetailForm.ChatTranscriptChange(Sender: TObject);
var
  TurnIndex: Integer;
begin
  if (FChatList = nil) or (FChatList.Selected = nil) then
    Exit;
  TurnIndex := StrToIntDef(FChatList.Selected.TagString, -1);
  if (TurnIndex < 0) or (TurnIndex >= FTurns.Count) then
    Exit;
  if FChatTurnEdit <> nil then
    FChatTurnEdit.Text := (TurnIndex + 1).ToString;
  if (FChatTurnList <> nil) and (FChatTurnList.ItemIndex <> TurnIndex) then
    FChatTurnList.ItemIndex := TurnIndex;
  SetStatus('selected turn ' + (TurnIndex + 1).ToString);
end;

procedure TMasterDetailForm.ChatTurnListChange(Sender: TObject);
var
  TurnIndex: Integer;
begin
  if (FChatTurnList = nil) or (FChatTurnList.Selected = nil) then
    Exit;
  TurnIndex := StrToIntDef(FChatTurnList.Selected.TagString, -1);
  if (TurnIndex < 0) or (TurnIndex >= FTurns.Count) then
    Exit;
  if FChatTurnEdit <> nil then
    FChatTurnEdit.Text := (TurnIndex + 1).ToString;
  if (FChatList <> nil) and (FChatList.ItemIndex <> TurnIndex) then
    FChatList.ItemIndex := TurnIndex;
  SetStatus('selected turn ' + (TurnIndex + 1).ToString);
end;

procedure TMasterDetailForm.ChatTurnActionClick(Sender: TObject);
var
  Action: string;
  Clipboard: IFMXClipboardService;
  I: Integer;
  Parts: TArray<string>;
  Turn: TChatTurn;
  TurnIndex: Integer;
begin
  if Sender is TButton then
    Action := TButton(Sender).TagString
  else
    Action := '';
  TurnIndex := -1;
  Parts := Action.Split([#9]);
  if Length(Parts) > 0 then
    Action := Parts[0];
  if Length(Parts) > 1 then
    TurnIndex := StrToIntDef(Parts[1], -1);
  if (TurnIndex < 0) and (FChatTurnEdit <> nil) and
    (Trim(FChatTurnEdit.Text) <> '') then
    TurnIndex := StrToIntDef(Trim(FChatTurnEdit.Text), 0) - 1;

  if Action = 'copy' then
  begin
    if TurnIndex < 0 then
      TurnIndex := FTurns.Count - 1;
    if (TurnIndex < 0) or (TurnIndex >= FTurns.Count) then
    begin
      SetStatus('select a turn to copy');
      Exit;
    end;
    Turn := FTurns[TurnIndex];
    if TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService,
      IInterface(Clipboard)) then
    begin
      Clipboard.SetClipboard(TValue.From<string>(Turn.Text));
      SetStatus('turn copied');
    end
    else
      SetStatus('clipboard unavailable');
    Exit;
  end;

  if Action = 'edit' then
  begin
    if TurnIndex < 0 then
      for I := FTurns.Count - 1 downto 0 do
        if SameText(FTurns[I].Role, 'user') then
        begin
          TurnIndex := I;
          Break;
        end;
    if (TurnIndex < 0) or (TurnIndex >= FTurns.Count) then
    begin
      SetStatus('enter a user turn number');
      Exit;
    end;
    Turn := FTurns[TurnIndex];
    if not SameText(Turn.Role, 'user') then
    begin
      SetStatus('only user turns can be edited');
      Exit;
    end;
    if FPromptMemo <> nil then
      FPromptMemo.Lines.Text := Turn.Text;
    while FTurns.Count > TurnIndex do
      FTurns.Delete(FTurns.Count - 1);
    if FChatTurnEdit <> nil then
      FChatTurnEdit.Text := (TurnIndex + 1).ToString;
    RenderChat;
    SetStatus('turn loaded for editing');
    Exit;
  end;

  if Action = 'regen' then
  begin
    if TurnIndex < 0 then
      TurnIndex := FTurns.Count - 1;
    if (TurnIndex < 0) or (TurnIndex >= FTurns.Count) then
    begin
      SetStatus('enter a turn number to regenerate');
      Exit;
    end;
    while (TurnIndex > 0) and (not SameText(FTurns[TurnIndex].Role, 'user')) do
      Dec(TurnIndex);
    if not SameText(FTurns[TurnIndex].Role, 'user') then
    begin
      SetStatus('no user turn found for regenerate');
      Exit;
    end;
    Turn := FTurns[TurnIndex];
    while FTurns.Count > TurnIndex do
      FTurns.Delete(FTurns.Count - 1);
    if FPromptMemo <> nil then
      FPromptMemo.Lines.Text := Turn.Text;
    if FChatTurnEdit <> nil then
      FChatTurnEdit.Text := (TurnIndex + 1).ToString;
    RenderChat;
    SendClick(FSendButton);
  end;
end;

function TMasterDetailForm.CollectChatFilePaths: TArray<string>;
var
  Files: TStringList;
  I: Integer;
  Lines: TArray<string>;
  Turn: TChatTurn;

  function CleanPath(const Candidate: string): string;
  var
    P: Integer;
    Q: Integer;
    R: Integer;
    S: string;
  begin
    S := Trim(Candidate);
    P := Pos('"path"', S);
    if P > 0 then
    begin
      Q := PosEx(':', S, P);
      if Q > 0 then
      begin
        Q := PosEx('"', S, Q + 1);
        R := PosEx('"', S, Q + 1);
        if (Q > 0) and (R > Q) then
          S := Copy(S, Q + 1, R - Q - 1);
      end;
    end;
    if StartsText('path=', S) then
      Delete(S, 1, 5)
    else if StartsText('path:', S) then
      Delete(S, 1, 5);
    S := Trim(S);
    while (S <> '') and CharInSet(S[1], ['"', '''', ' ']) do
      Delete(S, 1, 1);
    while (S <> '') and CharInSet(S[Length(S)], ['"', '''', ',', ';', ' ']) do
      Delete(S, Length(S), 1);
    if (S <> '') and (Pos('...', S) = 0) then
      Result := S
    else
      Result := '';
  end;

  procedure AddCandidate(const Candidate: string);
  var
    Path: string;
  begin
    Path := CleanPath(Candidate);
    if (Path <> '') and (Files.IndexOf(Path) < 0) then
      Files.Add(Path);
  end;

  procedure TryToolLine(const Line, ToolName: string);
  var
    P: Integer;
    Q: Integer;
    Raw: string;
  begin
    P := Pos(ToolName + '(', Line);
    if P = 0 then
      Exit;
    Raw := Copy(Line, P + Length(ToolName) + 1, MaxInt);
    Q := Pos(')', Raw);
    if Q > 0 then
      Raw := Copy(Raw, 1, Q - 1);
    AddCandidate(Raw);
  end;

  procedure ScanLine(const Line: string);
  var
    S: string;
  begin
    S := Trim(Line);
    if StartsText('*** Add File:', S) then
      AddCandidate(Copy(S, Length('*** Add File:') + 1, MaxInt))
    else if StartsText('*** Update File:', S) then
      AddCandidate(Copy(S, Length('*** Update File:') + 1, MaxInt))
    else if StartsText('*** Move to:', S) then
      AddCandidate(Copy(S, Length('*** Move to:') + 1, MaxInt));
    TryToolLine(S, 'write_file');
    TryToolLine(S, 'append_file');
    TryToolLine(S, 'edit_file');
    TryToolLine(S, 'fs_write');
    TryToolLine(S, 'fs_edit_hashline');
    TryToolLine(S, 'apply_patch');
  end;

begin
  Files := TStringList.Create;
  try
    for I := 0 to FTurns.Count - 1 do
    begin
      Turn := FTurns[I];
      if not SameText(Turn.Role, 'assistant') then
        Continue;
      Lines := Turn.Text.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
      for var Line in Lines do
        ScanLine(Line);
    end;
    SetLength(Result, Files.Count);
    for I := 0 to Files.Count - 1 do
      Result[I] := Files[I];
  finally
    Files.Free;
  end;
end;

procedure TMasterDetailForm.ChatFileActionClick(Sender: TObject);
var
  Action: string;
  Parts: TArray<string>;
  Path: string;
  TagText: string;
begin
  if Sender is TListBoxItem then
    TagText := TListBoxItem(Sender).TagString
  else if Sender is TControl then
    TagText := TControl(Sender).TagString
  else
    Exit;
  Parts := TagText.Split([#9]);
  if Length(Parts) = 0 then
    Exit;
  Action := Parts[0];
  Path := '';
  if Length(Parts) > 1 then
    Path := Parts[1];

  if FChatFilesPopup <> nil then
    FChatFilesPopup.IsOpen := False;

  if SameText(Action, 'all') then
  begin
    ChatFilesClick(nil);
    Exit;
  end;

  if Path = '' then
    Exit;
  if FFilePathEdit <> nil then
    FFilePathEdit.Text := Path;

  if SameText(Action, 'save') then
  begin
    if FEndpointEdits.ContainsKey('files') then
      FEndpointEdits['files'].Text := '/v1/fs/download?path=' +
        UrlEncode(Path);
    FileDownloadClick(nil);
    Exit;
  end;

  SelectTabByText('Files');
  if SameText(Action, 'hex') then
    FilesPeekPath(Path, 0)
  else if SameText(Action, 'folder') then
    FilesOpenPath(FsParentPath(Path))
  else if IsPreviewImagePath(Path) then
    FilesPreviewImagePath(Path)
  else
    FilesReadPath(Path);
end;

procedure TMasterDetailForm.ChatFilesClick(Sender: TObject);
var
  I: Integer;
  Item: TListBoxItem;
  Memo: TMemo;
  Path: string;
  Paths: TArray<string>;
  Text: TStringBuilder;

  procedure AddMenuAction(const Caption, Action, ActionPath: string);
  var
    MenuItem: TListBoxItem;
  begin
    if FChatFilesList = nil then
      Exit;
    MenuItem := TListBoxItem.Create(FChatFilesList);
    MenuItem.Parent := FChatFilesList;
    MenuItem.Text := Caption;
    MenuItem.TagString := Action + #9 + ActionPath;
    MenuItem.Height := ROW_BAR;
    MenuItem.OnClick := ChatFileActionClick;
  end;

  procedure AddActionButton(AParent: TFmxObject; const Caption, Action,
    ActionPath: string; Width: Single);
  var
    Btn: TButton;
  begin
    Btn := TButton.Create(FChatFilesList);
    Btn.Parent := AParent;
    Btn.Align := TAlignLayout.Left;
    Btn.Width := Width;
    Btn.Text := Caption;
    Btn.TagString := Action + #9 + ActionPath;
    Btn.OnClick := ChatFileActionClick;
    SetControlMargins(Btn, 0, 0, GAP_S, 0);
  end;

  procedure AddMenuFile(const ActionPath: string);
  var
    Actions: TLayout;
    Card: TRectangle;
    FileName: string;
    MenuItem: TListBoxItem;
    NameLabel: TLabel;
    PathLabel: TLabel;
  begin
    if FChatFilesList = nil then
      Exit;
    FileName := ExtractFileName(ActionPath);
    if FileName = '' then
      FileName := ActionPath;

    MenuItem := TListBoxItem.Create(FChatFilesList);
    MenuItem.Parent := FChatFilesList;
    MenuItem.Text := '';
    MenuItem.TagString := 'preview' + #9 + ActionPath;
    MenuItem.Height := 102;

    Card := TRectangle.Create(MenuItem);
    Card.Parent := MenuItem;
    Card.Align := TAlignLayout.Client;
    StyleChromeRect(Card, UI_PANEL_ALT, UI_BORDER, 4, False);
    SetControlMargins(Card, 0, 3, 0, 3);
    SetControlPadding(Card, 10, GAP_S, 10, GAP_S);

    NameLabel := TLabel.Create(Card);
    NameLabel.Parent := Card;
    NameLabel.Align := TAlignLayout.Top;
    NameLabel.Height := ROW_TEXT;
    NameLabel.Text := FileName;
    NameLabel.StyledSettings := NameLabel.StyledSettings - [TStyledSetting.Style];
    UseStyledLabelColor(NameLabel);
    NameLabel.TextSettings.Font.Style := [TFontStyle.fsBold];

    PathLabel := TLabel.Create(Card);
    PathLabel.Parent := Card;
    PathLabel.Align := TAlignLayout.Top;
    PathLabel.Height := ROW_TEXT;
    PathLabel.Text := ActionPath;
    PathLabel.WordWrap := False;
    PathLabel.StyledSettings := PathLabel.StyledSettings -
      [TStyledSetting.FontColor, TStyledSetting.Size];
    PathLabel.TextSettings.FontColor := $FF9AA4BF;
    PathLabel.TextSettings.Font.Size := TXT_CAPTION;

    Actions := TLayout.Create(Card);
    Actions.Parent := Card;
    Actions.Align := TAlignLayout.Client;
    SetControlMargins(Actions, 0, GAP_S, 0, 0);

    AddActionButton(Actions, 'Preview', 'preview', ActionPath, 68);
    AddActionButton(Actions, 'Save', 'save', ActionPath, 56);
    AddActionButton(Actions, 'Hex', 'hex', ActionPath, 48);
    AddActionButton(Actions, 'Folder', 'folder', ActionPath, 64);
  end;

begin
  Paths := CollectChatFilePaths;

  if (Sender is TControl) and (FChatFilesPopup <> nil) and
    (FChatFilesList <> nil) then
  begin
    FChatFilesList.Clear;
    FChatFilesPopup.PlacementTarget := TControl(Sender);
    if Length(Paths) = 0 then
    begin
      Item := TListBoxItem.Create(FChatFilesList);
      Item.Parent := FChatFilesList;
      Item.Text := 'No file write/edit paths detected in this chat.';
      Item.Height := ROW_BAR;
    end
    else
    begin
      AddMenuAction('Show all in Files tab', 'all', '');
      for I := 0 to Length(Paths) - 1 do
      begin
        Path := Paths[I];
        AddMenuFile(Path);
      end;
    end;
    if Length(Paths) = 0 then
      FChatFilesPopup.Height := 70
    else
      FChatFilesPopup.Height := Min(360, Max(96, 44 + Length(Paths) * 104));
    FChatFilesPopup.IsOpen := True;
    if Length(Paths) = 0 then
      SetStatus('no chat files found')
    else
      SetStatus(Format('%d chat file action(s)', [Length(Paths)]));
    Exit;
  end;

  SelectTabByText('Files');
  if FFilePreviewImage <> nil then
    FFilePreviewImage.Visible := False;
  if FFileList <> nil then
    FFileList.Clear;
  Text := TStringBuilder.Create;
  try
    Text.AppendLine('Chat Files');
    Text.AppendLine;
    if Length(Paths) = 0 then
      Text.AppendLine('No file write/edit paths were detected in this chat yet.')
    else
    begin
      for I := 0 to Length(Paths) - 1 do
      begin
        Path := Paths[I];
        Text.AppendLine(Path);
        if FFileList <> nil then
        begin
          Item := TListBoxItem.Create(FFileList);
          Item.Parent := FFileList;
          if ExtractFileName(Path) <> '' then
            Item.Text := ExtractFileName(Path) + '  ' + Path
          else
            Item.Text := Path;
          Item.TagString := Path + #9 + 'file' + #9 + '0';
          Item.Height := ROW_FORM;
        end;
      end;
    end;
    if FPaneMemos.TryGetValue('files', Memo) then
      Memo.Lines.Text := Text.ToString;
  finally
    Text.Free;
  end;

  if Length(Paths) = 0 then
    SetStatus('no chat files found')
  else if Length(Paths) = 1 then
  begin
    if FFilePathEdit <> nil then
      FFilePathEdit.Text := Paths[0];
    if IsPreviewImagePath(Paths[0]) then
      FilesPreviewImagePath(Paths[0])
    else
      FilesReadPath(Paths[0]);
  end
  else
    SetStatus(Format('%d chat file(s)', [Length(Paths)]));
end;

procedure TMasterDetailForm.ChatCheckpointClick(Sender: TObject);
var
  Base: string;
  Kind: string;
  SessionId: string;
  Token: string;
begin
  if not (Sender is TButton) then
    Exit;
  Kind := TButton(Sender).TagString;
  if (Kind <> 'undo') and (Kind <> 'redo') then
    Exit;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  SetStatus(Kind + ' checkpoint...');
  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, 'POST',
          '/v1/checkpoints/' + Kind + '?n=1', '', '', 'application/json',
          Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('%s HTTP %d: %s', [Kind, Status, ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        begin
          if ErrorText <> '' then
          begin
            AddTurn('assistant', 'Checkpoint ' + Kind + ' failed: ' + ErrorText);
            SetStatus('checkpoint failed');
          end
          else
          begin
            AddTurn('assistant', 'Checkpoint ' + Kind + ':' + sLineBreak +
              ResponseText);
            SetStatus('checkpoint ' + Kind + ' complete');
          end;
          RenderChat;
          if ErrorText = '' then
            CheckpointRefreshClick(nil);
        end);
    end);
end;

procedure TMasterDetailForm.LoadSession(const SessionId: string);
var
  Base: string;
  Token: string;
begin
  if SessionId = '' then
    Exit;
  if SessionId <> FActiveSessionId then
    SaveChatParams(FActiveSessionId);
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  FActiveSessionId := SessionId;
  SetStatus('loading session...');
  TTask.Run(
    procedure
    var
      ErrorText: string;
      Status: Integer;
      Text: string;
      Turns: TArray<TChatTurn>;
    begin
      try
        Text := HttpText(Base, Token, SessionId, 'GET',
          '/v1/sessions/' + UrlEncode(SessionId), '', '', 'application/json',
          Status);
        if not IsHttpOk(Status) then
          raise Exception.CreateFmt('session HTTP %d: %s', [Status, Text]);
        Turns := ParseSessionTurns(Text);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;
      TThread.Queue(nil,
        procedure
        var
          I: Integer;
        begin
          if SessionId <> FActiveSessionId then
            Exit;
          if ErrorText <> '' then
          begin
            SetStatus('session load failed: ' + ErrorText);
            Exit;
          end;
          FTurns.Clear;
          for I := 0 to Length(Turns) - 1 do
            FTurns.Add(Turns[I]);
          RenderChat;
          LoadChatParams(SessionId);
          SetStatus('session loaded');
        end);
    end);
end;

function TMasterDetailForm.ParseSessionTurns(
  const JsonText: string): TArray<TChatTurn>;
var
  Arr: TJSONArray;
  I: Integer;
  Msg: TJSONObject;
  Root: TJSONValue;
  Turn: TChatTurn;
  Turns: TList<TChatTurn>;
  Value: TJSONValue;
  VisibleIndex: Integer;
begin
  Turns := TList<TChatTurn>.Create;
  try
    Root := TJSONObject.ParseJSONValue(JsonText);
    try
      if Root is TJSONObject then
      begin
        Arr := nil;
        Value := TJSONObject(Root).GetValue('messages');
        if Value is TJSONArray then
          Arr := TJSONArray(Value);
        if Arr <> nil then
          for I := 0 to Arr.Count - 1 do
            if Arr.Items[I] is TJSONObject then
            begin
              Msg := TJSONObject(Arr.Items[I]);
              Turn.Role := JsonAsString(Msg, 'role');
              if SameText(Turn.Role, 'user') or SameText(Turn.Role, 'assistant') then
              begin
                Turn.Text := JsonAsString(Msg, 'content');
                Turn.ToolDetails := '';
                Turns.Add(Turn);
              end;
            end;
        Value := TJSONObject(Root).GetValue('tool_details');
        if Value is TJSONArray then
        begin
          Arr := TJSONArray(Value);
          VisibleIndex := 0;
          for I := 0 to Arr.Count - 1 do
          begin
            if VisibleIndex >= Turns.Count then
              Break;
            if not (Arr.Items[I] is TJSONNull) then
            begin
              Turn := Turns[VisibleIndex];
              Turn.ToolDetails := Arr.Items[I].ToJSON;
              Turns[VisibleIndex] := Turn;
            end;
            Inc(VisibleIndex);
          end;
        end;
      end;
    finally
      Root.Free;
    end;
    Result := Turns.ToArray;
  finally
    Turns.Free;
  end;
end;

procedure TMasterDetailForm.AddTurn(const Role, Text: string);
var
  Turn: TChatTurn;
begin
  Turn.Role := Role;
  Turn.Text := Text;
  Turn.ToolDetails := '';
  FTurns.Add(Turn);
end;

procedure TMasterDetailForm.AddAttachment(const Name, Content: string);
const
  ATTACH_MAX_CHARS = 256 * 1024;
var
  Attachment: TChatAttachment;
begin
  if Content = '' then
    Exit;
  if Name <> '' then
    Attachment.Name := Name
  else
    Attachment.Name := 'attachment-' + (FAttachments.Count + 1).ToString + '.txt';
  Attachment.Content := Content;
  if Length(Attachment.Content) > ATTACH_MAX_CHARS then
    Attachment.Content := Copy(Attachment.Content, 1, ATTACH_MAX_CHARS) +
      sLineBreak + '...(truncated)';
  FAttachments.Add(Attachment);
  RenderAttachments;
end;

function TMasterDetailForm.AttachmentSummary: string;
var
  I: Integer;
  Names: TStringBuilder;
begin
  if FAttachments.Count = 0 then
    Exit('');
  Names := TStringBuilder.Create;
  try
    for I := 0 to FAttachments.Count - 1 do
    begin
      if I > 0 then
        Names.Append(', ');
      if I >= 3 then
      begin
        Names.Append('+').Append((FAttachments.Count - I).ToString).Append(' more');
        Break;
      end;
      Names.Append(FAttachments[I].Name);
    end;
    Result := FAttachments.Count.ToString + ' attachment';
    if FAttachments.Count <> 1 then
      Result := Result + 's';
    Result := Result + ': ' + Names.ToString;
  finally
    Names.Free;
  end;
end;

procedure TMasterDetailForm.RenderAttachments;
var
  Attachment: TChatAttachment;
  Chip: TRectangle;
  DetailLabel: TLabel;
  HasAttachments: Boolean;
  I: Integer;
  NameText: string;
  RemoveButton: TButton;
  TitleLabel: TLabel;
begin
  HasAttachments := (FAttachments <> nil) and (FAttachments.Count > 0);
  if FAttachmentLabel <> nil then
  begin
    FAttachmentLabel.Visible := HasAttachments;
    if HasAttachments then
    begin
      FAttachmentLabel.Height := ROW_TEXT;
      FAttachmentLabel.Text := AttachmentSummary;
    end
    else
    begin
      FAttachmentLabel.Height := 0;
      FAttachmentLabel.Text := '';
    end;
  end;

  if FAttachmentStrip <> nil then
  begin
    while FAttachmentStrip.ChildrenCount > 0 do
      FAttachmentStrip.Children[0].Free;
    FAttachmentStrip.Visible := HasAttachments;
    if HasAttachments then
    begin
      FAttachmentStrip.Height := IfThen(ClientWidth < 560, 36, 40);
      for I := 0 to FAttachments.Count - 1 do
      begin
        Attachment := FAttachments[I];
        NameText := Attachment.Name;
        if Length(NameText) > 28 then
          NameText := Copy(NameText, 1, 25) + '...';

        Chip := TRectangle.Create(FAttachmentStrip);
        Chip.Parent := FAttachmentStrip;
        Chip.Align := TAlignLayout.Left;
        Chip.Width := Min(260, Max(152, Length(NameText) * 7 + 96));
        SetControlMargins(Chip, 0, 3, GAP_S, 3);
        SetControlPadding(Chip, 10, 5, GAP_S, 5);
        StyleChromeRect(Chip, UI_ACCENT_DIM, UI_ACCENT, 6, False);

        RemoveButton := TButton.Create(Chip);
        RemoveButton.Parent := Chip;
        RemoveButton.Align := TAlignLayout.Right;
        RemoveButton.Width := 26;
        RemoveButton.Text := 'X';
        RemoveButton.TagString := I.ToString;
        RemoveButton.OnClick := AttachmentRemoveClick;
        SetControlMargins(RemoveButton, GAP_S, 1, 0, 1);
        StyleButton(RemoveButton, False);

        TitleLabel := TLabel.Create(Chip);
        TitleLabel.Parent := Chip;
        TitleLabel.Align := TAlignLayout.Top;
        TitleLabel.Height := 16;
        TitleLabel.HitTest := False;
        TitleLabel.Text := Format('%d  %s', [I + 1, NameText]);
        StyleLabel(TitleLabel, UI_TEXT, TXT_BODY, True);

        DetailLabel := TLabel.Create(Chip);
        DetailLabel.Parent := Chip;
        DetailLabel.Align := TAlignLayout.Client;
        DetailLabel.HitTest := False;
        DetailLabel.Text := FormatBytes(Length(Attachment.Content));
        StyleLabel(DetailLabel, UI_MUTED, TXT_CAPTION, False);
      end;
    end
    else
      FAttachmentStrip.Height := 0;
  end;

  if FClearAttachmentsButton <> nil then
    FClearAttachmentsButton.Enabled := HasAttachments;
  UpdateClearAttachmentsButton;
  UpdateComposerState;
end;

procedure TMasterDetailForm.RenderQueue;
var
  Count: Integer;
  Preview: string;
begin
  if FQueueLabel = nil then
    Exit;

  Count := 0;
  if FQueuedPrompts <> nil then
    Count := FQueuedPrompts.Count;

  FQueueLabel.Visible := Count > 0;
  if Count > 0 then
  begin
    Preview := Trim(FQueuedPrompts.Peek);
    Preview := StringReplace(Preview, #13, ' ', [rfReplaceAll]);
    Preview := StringReplace(Preview, #10, ' ', [rfReplaceAll]);
    if Length(Preview) > 96 then
      Preview := Copy(Preview, 1, 93) + '...';
    FQueueLabel.Height := ROW_TEXT;
    FQueueLabel.Text := Format('Queued: %d - next: %s', [Count, Preview]);
  end
  else
  begin
    FQueueLabel.Height := 0;
    FQueueLabel.Text := '';
  end;
  UpdateComposerState;
end;

procedure TMasterDetailForm.UpdateComposerState;
var
  AttachmentCount: Integer;
  HasAttachments: Boolean;
  HasDraft: Boolean;
  ComposerHeight: Single;
  Narrow: Boolean;
  PromptChars: Integer;
  PromptText: string;
  QueueCount: Integer;
  StatusColor: TAlphaColor;
  StatusText: string;
begin
  PromptText := '';
  if FPromptMemo <> nil then
    PromptText := Trim(FPromptMemo.Lines.Text);
  PromptChars := Length(PromptText);

  AttachmentCount := 0;
  if FAttachments <> nil then
    AttachmentCount := FAttachments.Count;
  HasAttachments := AttachmentCount > 0;
  HasDraft := (PromptChars > 0) or HasAttachments;

  QueueCount := 0;
  if FQueuedPrompts <> nil then
    QueueCount := FQueuedPrompts.Count;

  Narrow := ClientWidth < 560;
  if FAttachmentStrip <> nil then
  begin
    FAttachmentStrip.Visible := HasAttachments;
    if HasAttachments then
      FAttachmentStrip.Height := IfThen(Narrow, 34, 38)
    else
      FAttachmentStrip.Height := 0;
  end;

  if FComposerLayout <> nil then
  begin
    ComposerHeight := IfThen(Narrow, 156, 176);
    if HasAttachments then
      ComposerHeight := ComposerHeight + IfThen(Narrow, 54, 60);
    if QueueCount > 0 then
      ComposerHeight := ComposerHeight + 22;
    FComposerLayout.Height := Min(260, ComposerHeight);
  end;

  if FSendButton <> nil then
  begin
    if FSending then
    begin
      FSendButton.Enabled := True;
      if FChatAbort then
        FSendButton.Text := 'Stopping'
      else
        FSendButton.Text := 'Stop';
    end
    else
    begin
      FSendButton.Enabled := HasDraft;
      FSendButton.Text := 'Send';
    end;
    StyleButton(FSendButton, FSending or HasDraft);
  end;

  if FAttachButton <> nil then
    FAttachButton.Enabled := not FChatAbort;
  if FClearAttachmentsButton <> nil then
    FClearAttachmentsButton.Enabled := HasAttachments and not FChatAbort;
  UpdateClearAttachmentsButton;

  if FComposerStatusLabel <> nil then
  begin
    StatusColor := UI_MUTED;
    if FSending then
    begin
      StatusColor := UI_ACCENT;
      if FChatAbort then
      begin
        StatusColor := UI_WARN;
        StatusText := 'Stopping current run';
      end
      else if QueueCount > 0 then
        StatusText := Format('Working - %d queued', [QueueCount])
      else
        StatusText := 'Working';
    end
    else if QueueCount > 0 then
    begin
      StatusColor := UI_WARN;
      StatusText := Format('%d queued', [QueueCount]);
    end
    else if HasAttachments then
    begin
      StatusColor := UI_ACCENT;
      StatusText := Format('%d attachment(s) ready', [AttachmentCount]);
    end
    else if PromptChars > 0 then
    begin
      StatusColor := UI_TEXT;
      StatusText := Format('Draft: %d char(s)', [PromptChars]);
    end
    else
      StatusText := 'Ready';

    FComposerStatusLabel.Text := StatusText;
    StyleLabel(FComposerStatusLabel, StatusColor, TXT_BODY, False);
  end;
end;

procedure TMasterDetailForm.EnqueuePrompt;
var
  Prompt: string;
begin
  if FQueuedPrompts = nil then
    Exit;

  Prompt := Trim(FPromptMemo.Lines.Text);
  if (Prompt = '') and ((FAttachments = nil) or (FAttachments.Count = 0)) then
  begin
    UpdateComposerState;
    Exit;
  end;

  Prompt := ComposePrompt(Prompt);
  FPromptMemo.Lines.Clear;
  if FAttachments <> nil then
    FAttachments.Clear;
  RenderAttachments;

  FQueuedPrompts.Enqueue(Prompt);
  RenderQueue;
  SetStatus(Format('queued %d message(s)', [FQueuedPrompts.Count]));
end;

function TMasterDetailForm.ComposePrompt(const TypedPrompt: string): string;
var
  Attachment: TChatAttachment;
  Text: TStringBuilder;
begin
  if (FAttachments = nil) or (FAttachments.Count = 0) then
    Exit(TypedPrompt);

  Text := TStringBuilder.Create;
  try
    for Attachment in FAttachments do
    begin
      Text.AppendLine('Attached file: ' + Attachment.Name);
      Text.AppendLine('```');
      Text.AppendLine(Attachment.Content);
      Text.AppendLine('```');
      Text.AppendLine;
    end;
    if TypedPrompt <> '' then
      Text.Append(TypedPrompt);
    Result := Text.ToString;
  finally
    Text.Free;
  end;
end;

procedure TMasterDetailForm.AttachFilesClick(Sender: TObject);
const
  ATTACH_MAX_BYTES = 4 * 1024 * 1024;
var
  Added: Integer;
  Dialog: TOpenDialog;
  FilePath: string;
  Skipped: Integer;
begin
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Filter := 'Text and code files|*.txt;*.md;*.markdown;*.pas;*.pp;*.inc;*.dpr;*.lpr;*.json;*.yaml;*.yml;*.toml;*.ini;*.csv;*.html;*.htm;*.css;*.js;*.ts;*.py;*.rb;*.php;*.sql;*.sh;*.bat;*.ps1|All files|*.*';
    Dialog.Options := Dialog.Options + [TOpenOption.ofAllowMultiSelect,
      TOpenOption.ofFileMustExist];
    if not Dialog.Execute then
      Exit;

    Added := 0;
    Skipped := 0;
    for FilePath in Dialog.Files do
    begin
      if TFile.GetSize(FilePath) > ATTACH_MAX_BYTES then
      begin
        Inc(Skipped);
        Continue;
      end;
      try
        AddAttachment(ExtractFileName(FilePath),
          TFile.ReadAllText(FilePath, TEncoding.UTF8));
        Inc(Added);
      except
        Inc(Skipped);
      end;
    end;
  finally
    Dialog.Free;
  end;

  if Skipped > 0 then
    SetStatus(Format('attached %d file(s), skipped %d', [Added, Skipped]))
  else
    SetStatus(Format('attached %d file(s)', [Added]));
end;

procedure TMasterDetailForm.AttachmentRemoveClick(Sender: TObject);
var
  Index: Integer;
begin
  if not (Sender is TButton) then
    Exit;
  Index := StrToIntDef(TButton(Sender).TagString, -1);
  if (Index < 0) or (Index >= FAttachments.Count) then
    Exit;
  FAttachments.Delete(Index);
  RenderAttachments;
  SetStatus('attachment removed');
end;

procedure TMasterDetailForm.ClearAttachmentsClick(Sender: TObject);
begin
  FAttachments.Clear;
  RenderAttachments;
  SetStatus('attachments cleared');
end;

function TMasterDetailForm.SnapshotTurns: TArray<TChatTurn>;
var
  I: Integer;
begin
  SetLength(Result, FTurns.Count);
  for I := 0 to FTurns.Count - 1 do
    Result[I] := FTurns[I];
end;

function TMasterDetailForm.AppendTurnArray(const Turns: TArray<TChatTurn>;
  const Role, Text: string): TArray<TChatTurn>;
var
  I: Integer;
begin
  SetLength(Result, Length(Turns) + 1);
  for I := 0 to Length(Turns) - 1 do
    Result[I] := Turns[I];
  Result[High(Result)].Role := Role;
  Result[High(Result)].Text := Text;
  Result[High(Result)].ToolDetails := '';
end;

procedure TMasterDetailForm.RenderChat;
var
  AssistantCount: Integer;
  ChatFlowHeight: Single;
  I: Integer;
  OtherCount: Integer;
  Prefix: string;
  Preview: string;
  SelectedTurn: Integer;
  SessionText: string;
  Turn: TChatTurn;
  UserCount: Integer;

  function CompactUserBody(const Value: string): string;
  var
    AttachCount: Integer;
    Body: TStringBuilder;
    FileName: string;
    I: Integer;
    LineText: string;
    Lines: TArray<string>;
  begin
    if Pos('Attached file:', Value) = 0 then
      Exit(Value);

    Body := TStringBuilder.Create;
    try
      Lines := Value.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
      I := 0;
      AttachCount := 0;
      while I < Length(Lines) do
      begin
        LineText := Trim(Lines[I]);
        if StartsText('Attached file:', LineText) then
        begin
          Inc(AttachCount);
          FileName := Trim(Copy(LineText, Length('Attached file:') + 1,
            MaxInt));
          if Body.Length > 0 then
            Body.AppendLine;
          if FileName = '' then
            Body.Append('[attached] file')
          else
            Body.Append('[attached] ' + FileName);
          Inc(I);
          if (I < Length(Lines)) and (Trim(Lines[I]) = '```') then
          begin
            Inc(I);
            while (I < Length(Lines)) and (Trim(Lines[I]) <> '```') do
              Inc(I);
            if I < Length(Lines) then
              Inc(I);
          end;
          Continue;
        end;

        if (LineText <> '') or (Body.Length > 0) then
        begin
          if Body.Length > 0 then
            Body.AppendLine;
          Body.Append(Lines[I]);
        end;
        Inc(I);
      end;

      Result := Trim(Body.ToString);
      if (Result = '') and (AttachCount > 0) then
        Result := Format('%d attached file(s)', [AttachCount]);
    finally
      Body.Free;
    end;
  end;

  procedure AddTranscriptCard(Index, Total: Integer; const RoleValue,
    BodyValue, ToolDetailsValue: string);
  var
    ActionButton: TButton;
    ActionRow: TLayout;
    BodyHost: TLayout;
    BodyLabel: TLabel;
    BodyText: string;
    BorderColor: TAlphaColor;
    Card: TRectangle;
    ContentHeight: Single;
    EstLines: Integer;
    FillColor: TAlphaColor;
    Header: TLayout;
    HeaderCopyButton: TButton;
    MaxBubbleWidth: Single;
    AvailableWidth: Single;
    MetaLabel: TLabel;
    MetaText: string;
    CharsPerLine: Integer;
    HasRichText: Boolean;
    HasToolCards: Boolean;
    HasToolDetails: Boolean;
    RawBodyText: string;
    ToolCardCount: Integer;
    TranscriptItem: TListBoxItem;
    TranscriptRow: TLayout;
    RowHeight: Single;

    function EstimateTextLines(const Text: string; CharsPerLine: Integer): Integer;
    var
      I: Integer;
      LineText: string;
      Lines: TArray<string>;
    begin
      Result := 0;
      Lines := Text.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
      for I := 0 to Length(Lines) - 1 do
      begin
        LineText := Lines[I];
        Result := Result + Max(1, (Length(LineText) div Max(24, CharsPerLine)) + 1);
      end;
      Result := Max(1, Result);
    end;

    function CountToolCards(const Text: string): Integer;
    var
      P: Integer;
      Start: Integer;
    begin
      Result := 0;
      Start := 1;
      while True do
      begin
        P := PosEx('<details class="tool-card', Text, Start);
        if P = 0 then
          Break;
        Inc(Result);
        Start := P + Length('<details class="tool-card');
      end;
    end;

    procedure AddTurnButton(const Caption, Action: string; Width: Single);
    begin
      ActionButton := TButton.Create(ActionRow);
      ActionButton.Parent := ActionRow;
      ActionButton.Align := TAlignLayout.Left;
      ActionButton.Width := Width;
      ActionButton.Text := Caption;
      ActionButton.TagString := Action + #9 + Index.ToString;
      ActionButton.OnClick := ChatTurnActionClick;
      SetControlMargins(ActionButton, 0, 0, GAP_S, 0);
      StyleButton(ActionButton, False);
    end;

    function CleanInlineMarkdown(const Value: string): string;
    var
      Close: Integer;
      LinkEnd: Integer;
      Rest: string;
      Start: Integer;
      Url: string;
    begin
      { Markdown links: FMX TLabel has no rich text, so render "text (url)"
        rather than dropping the destination the way a bare strip would.
        Image links keep the same shape minus the leading '!'. }
      Result := Value;
      Start := Pos('[', Result);
      while Start > 0 do
      begin
        Close := PosEx(']', Result, Start + 1);
        if (Close = 0) or (Close + 1 > Length(Result)) or
          (Result[Close + 1] <> '(') then
        begin
          Start := PosEx('[', Result, Start + 1);
          Continue;
        end;
        LinkEnd := PosEx(')', Result, Close + 2);
        if LinkEnd = 0 then
          Break;
        Url := Trim(Copy(Result, Close + 2, LinkEnd - Close - 2));
        Rest := Copy(Result, Start + 1, Close - Start - 1);
        if (Start > 1) and (Result[Start - 1] = '!') then
          Dec(Start);
        if (Url = '') or SameText(Url, Rest) then
          Result := Copy(Result, 1, Start - 1) + Rest +
            Copy(Result, LinkEnd + 1, MaxInt)
        else
          Result := Copy(Result, 1, Start - 1) + Rest + ' (' + Url + ')' +
            Copy(Result, LinkEnd + 1, MaxInt);
        Start := PosEx('[', Result, Start + Length(Rest));
      end;
      Result := StringReplace(Result, '~~', '', [rfReplaceAll]);
      Result := StringReplace(Result, '`', '', [rfReplaceAll]);
      Result := StringReplace(Result, '**', '', [rfReplaceAll]);
      Result := StringReplace(Result, '__', '', [rfReplaceAll]);
    end;

    procedure AddTextLabel(const Text: string; Size: Single; Bold: Boolean;
      Accent: Boolean = False; Indent: Single = 0);
    var
      Lines: Integer;
      SegmentHeight: Single;
      SegmentLabel: TLabel;
      SegmentText: string;
    begin
      SegmentText := Trim(Text);
      if SegmentText = '' then
        Exit;
      Lines := EstimateTextLines(SegmentText, CharsPerLine);
      { A TLabel clips to its bounds, so a cap that bites SILENTLY DROPS the
        tail of a long paragraph. Keep only a pathological-content ceiling. }
      SegmentHeight := Min(CHAT_ROW_MAX, Max(Size + 20,
        Lines * (Size + 8) + 12));
      SegmentLabel := TLabel.Create(BodyHost);
      SegmentLabel.Parent := BodyHost;
      SegmentLabel.Align := TAlignLayout.Top;
      SegmentLabel.Height := SegmentHeight;
      SegmentLabel.HitTest := False;
      SegmentLabel.Text := CleanInlineMarkdown(SegmentText);
      SegmentLabel.WordWrap := True;
      SegmentLabel.TextSettings.VertAlign := TTextAlign.Leading;
      SetControlMargins(SegmentLabel, Indent, 4, 0, 4);
      ContentHeight := ContentHeight + SegmentHeight + 8;
      if Accent then
        StyleLabel(SegmentLabel, UI_ACCENT, Size, Bold)
      else
        StyleLabel(SegmentLabel, UI_CHAT_TEXT, Size, Bold);   { tier 1 }
    end;

    { A horizontal rule (--- / *** / ___). }
    procedure AddRuleBlock;
    var
      Rule: TRectangle;
    begin
      Rule := TRectangle.Create(BodyHost);
      Rule.Parent := BodyHost;
      Rule.Align := TAlignLayout.Top;
      Rule.Height := 1;
      Rule.HitTest := False;
      StyleChromeRect(Rule, UI_BORDER, UI_BORDER, 0, False);
      SetControlMargins(Rule, 0, GAP_S, 0, GAP_S);
      ContentHeight := ContentHeight + 17;
    end;

    { A blockquote: accent bar on the left, muted text beside it. }
    procedure AddQuoteBlock(const Text: string);
    var
      Bar: TRectangle;
      Host: TLayout;
      Lines: Integer;
      QuoteLabel: TLabel;
      QuoteHeight: Single;
    begin
      if Trim(Text) = '' then
        Exit;
      Lines := EstimateTextLines(Text, Max(20, CharsPerLine - 4));
      QuoteHeight := Max(28, Lines * 20 + 12);
      Host := TLayout.Create(BodyHost);
      Host.Parent := BodyHost;
      Host.Align := TAlignLayout.Top;
      Host.Height := QuoteHeight;
      SetControlMargins(Host, 0, GAP_S, 0, GAP_S);

      Bar := TRectangle.Create(Host);
      Bar.Parent := Host;
      Bar.Align := TAlignLayout.Left;
      Bar.Width := 3;
      Bar.HitTest := False;
      StyleChromeRect(Bar, UI_ACCENT_DIM, UI_ACCENT_DIM, 0, False);

      QuoteLabel := TLabel.Create(Host);
      QuoteLabel.Parent := Host;
      QuoteLabel.Align := TAlignLayout.Client;
      QuoteLabel.HitTest := False;
      QuoteLabel.Text := CleanInlineMarkdown(Trim(Text));
      QuoteLabel.WordWrap := True;
      QuoteLabel.TextSettings.VertAlign := TTextAlign.Leading;
      SetControlMargins(QuoteLabel, 10, 0, 0, 0);
      StyleLabel(QuoteLabel, UI_MUTED, TXT_TITLE, False);
      ContentHeight := ContentHeight + QuoteHeight + 12;
    end;

    { A markdown table: one row layout per line, equal-width cells, bold
      accent header. Cells are laid out left-to-right so columns line up
      without relying on a monospace font. }
    procedure AddTableBlock(Rows: TStrings);
    var
      CellLabel: TLabel;
      CellText: string;
      Cells: TArray<string>;
      ColCount: Integer;
      ColWidth: Single;
      CharsPerCell: Integer;
      C: Integer;
      IsHeader: Boolean;
      Panel: TRectangle;
      R: Integer;
      RowHeights: TArray<Single>;
      RowHost: TLayout;
      RowLines: Integer;
      RowText: string;
      TableHeight: Single;

      function SplitRow(const Line: string): TArray<string>;
      var
        Body: string;
      begin
        Body := Trim(Line);
        if StartsText('|', Body) then
          Body := Copy(Body, 2, MaxInt);
        if EndsText('|', Body) then
          Body := Copy(Body, 1, Length(Body) - 1);
        Result := Body.Split(['|']);
      end;

    begin
      if (Rows = nil) or (Rows.Count = 0) then
        Exit;
      ColCount := 1;
      for R := 0 to Rows.Count - 1 do
        ColCount := Max(ColCount, Length(SplitRow(Rows[R])));

      { Row heights are computed from the WIDEST cell in each row so long
        values (URLs, paths, commands, prose) wrap instead of being silently
        clipped to one line. }
      ColWidth := Max(60, (Max(240, MaxBubbleWidth - 60)) / ColCount);
      CharsPerCell := Max(8, Trunc(ColWidth / 7.2));
      SetLength(RowHeights, Rows.Count);
      TableHeight := 12;
      for R := 0 to Rows.Count - 1 do
      begin
        Cells := SplitRow(Rows[R]);
        RowLines := 1;
        for C := 0 to Length(Cells) - 1 do
          RowLines := Max(RowLines,
            EstimateTextLines(Trim(Cells[C]), CharsPerCell));
        RowHeights[R] := Max(24, RowLines * 18 + 6);
        TableHeight := TableHeight + RowHeights[R];
      end;

      Panel := TRectangle.Create(BodyHost);
      Panel.Parent := BodyHost;
      Panel.Align := TAlignLayout.Top;
      Panel.Height := TableHeight;
      StyleChromeRect(Panel, UI_PANEL, UI_BORDER, 6, False);
      SetControlMargins(Panel, 0, GAP_S, 0, GAP_S);
      SetControlPadding(Panel, GAP_S, GAP_S, GAP_S, GAP_S);
      ContentHeight := ContentHeight + TableHeight + 12;

      for R := 0 to Rows.Count - 1 do
      begin
        RowText := Rows[R];
        IsHeader := R = 0;
        Cells := SplitRow(RowText);
        RowHost := TLayout.Create(Panel);
        RowHost.Parent := Panel;
        RowHost.Align := TAlignLayout.Top;
        RowHost.Height := RowHeights[R];
        for C := 0 to ColCount - 1 do
        begin
          if C < Length(Cells) then
            CellText := Trim(Cells[C])
          else
            CellText := '';
          CellLabel := TLabel.Create(RowHost);
          CellLabel.Parent := RowHost;
          CellLabel.Align := TAlignLayout.Left;
          CellLabel.Width := ColWidth;
          CellLabel.HitTest := False;
          CellLabel.Text := CleanInlineMarkdown(CellText);
          CellLabel.WordWrap := True;
          CellLabel.TextSettings.VertAlign := TTextAlign.Leading;
          if IsHeader then
            StyleLabel(CellLabel, UI_ACCENT, TXT_TITLE, True)
          else
            StyleLabel(CellLabel, UI_TEXT, TXT_TITLE, False);
        end;
      end;
    end;

    procedure AddBodyTextBlock(const Text: string);
    var
      I: Integer;
      LineText: string;
      Lines: TArray<string>;
      Paragraph: TStringBuilder;

      procedure FlushParagraph;
      begin
        AddTextLabel(Paragraph.ToString, 12, False);
        Paragraph.Clear;
      end;

      { Leading-space depth of a raw line, in list levels (2 spaces or a tab
        per level) -- markdown nests sub-lists by indentation. }
      function IndentDepth(const Raw: string): Integer;
      var
        K: Integer;
        Spaces: Integer;
      begin
        Spaces := 0;
        for K := 1 to Length(Raw) do
        begin
          if Raw[K] = ' ' then
            Inc(Spaces)
          else if Raw[K] = #9 then
            Inc(Spaces, 2)
          else
            Break;
        end;
        Result := Spaces div 2;
        if Result > 4 then
          Result := 4;
      end;

      { "12. text" / "3) text" -> ordered-list item. The old code only matched
        a literal "1. ", so every item after the first fell through to the
        paragraph accumulator and lost its line break. }
      function OrderedMarkerLen(const Line: string): Integer;
      var
        K: Integer;
      begin
        Result := 0;
        K := 1;
        while (K <= Length(Line)) and CharInSet(Line[K], ['0'..'9']) do
          Inc(K);
        if (K = 1) or (K > Length(Line)) then
          Exit;
        if not CharInSet(Line[K], ['.', ')']) then
          Exit;
        Inc(K);
        if (K > Length(Line)) or (Line[K] <> ' ') then
          Exit;
        Result := K;
      end;

      function IsRule(const Line: string): Boolean;
      var
        Body: string;
      begin
        Body := StringReplace(Line, ' ', '', [rfReplaceAll]);
        Result := (Length(Body) >= 3) and
          ((StringReplace(Body, '-', '', [rfReplaceAll]) = '') or
           (StringReplace(Body, '*', '', [rfReplaceAll]) = '') or
           (StringReplace(Body, '_', '', [rfReplaceAll]) = ''));
      end;

      { A table separator row: |---|:--:|---| }
      function IsTableSeparator(const Line: string): Boolean;
      var
        Body: string;
      begin
        Body := StringReplace(Trim(Line), ' ', '', [rfReplaceAll]);
        if (Body = '') or (Pos('|', Body) = 0) then
          Exit(False);
        Body := StringReplace(Body, '|', '', [rfReplaceAll]);
        Body := StringReplace(Body, ':', '', [rfReplaceAll]);
        Result := (Body <> '') and (StringReplace(Body, '-', '',
          [rfReplaceAll]) = '');
      end;

    var
      Depth: Integer;
      MarkerLen: Integer;
      Quote: TStringBuilder;
      RawLine: string;
      TableRows: TStringList;

      procedure FlushQuote;
      begin
        if Quote.Length > 0 then
        begin
          AddQuoteBlock(Quote.ToString);
          Quote.Clear;
        end;
      end;

      procedure FlushTable;
      begin
        if TableRows.Count > 0 then
        begin
          AddTableBlock(TableRows);
          TableRows.Clear;
        end;
      end;

      procedure FlushAll;
      begin
        FlushParagraph;
        FlushQuote;
        FlushTable;
      end;

    begin
      if Trim(Text) = '' then
        Exit;
      Paragraph := TStringBuilder.Create;
      Quote := TStringBuilder.Create;
      TableRows := TStringList.Create;
      try
        Lines := Text.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
        for I := 0 to Length(Lines) - 1 do
        begin
          RawLine := Lines[I];
          LineText := Trim(RawLine);
          if LineText = '' then
          begin
            FlushAll;
            Continue;
          end;

          { Tables: accumulate consecutive pipe rows, drop the separator.
            A table is recognised either by a leading '|' or by the NEXT line
            being a separator row -- "Name | Value" over "--- | ---" is valid
            markdown and the outer pipes are optional. }
          if (Pos('|', LineText) > 0) and
            (StartsText('|', LineText) or (TableRows.Count > 0) or
             ((I + 1 < Length(Lines)) and IsTableSeparator(Lines[I + 1]))) then
          begin
            if IsTableSeparator(LineText) then
              Continue;
            FlushParagraph;
            FlushQuote;
            TableRows.Add(LineText);
            Continue;
          end;
          FlushTable;

          if StartsText('>', LineText) then
          begin
            FlushParagraph;
            if Quote.Length > 0 then
              Quote.Append(' ');
            Quote.Append(Trim(Copy(LineText, 2, MaxInt)));
            Continue;
          end;
          FlushQuote;

          if IsRule(LineText) then
          begin
            FlushParagraph;
            AddRuleBlock;
            Continue;
          end;

          if StartsText('#### ', LineText) then
          begin
            FlushParagraph;
            AddTextLabel(Copy(LineText, 6, MaxInt), 12, True, True);
          end
          else if StartsText('### ', LineText) then
          begin
            FlushParagraph;
            AddTextLabel(Copy(LineText, 5, MaxInt), 12, True, True);
          end
          else if StartsText('## ', LineText) then
          begin
            FlushParagraph;
            AddTextLabel(Copy(LineText, 4, MaxInt), 13, True, True);
          end
          else if StartsText('# ', LineText) then
          begin
            FlushParagraph;
            AddTextLabel(Copy(LineText, 3, MaxInt), 14, True, True);
          end
          else if StartsText('- ', LineText) or StartsText('* ', LineText) or
            StartsText('+ ', LineText) then
          begin
            FlushParagraph;
            Depth := IndentDepth(RawLine);
            AddTextLabel(BULLET_GLYPHS[Min(Depth, 2)] + ' ' +
              Copy(LineText, 3, MaxInt), 12, False, False, 12 + Depth * 16);
          end
          else
          begin
            MarkerLen := OrderedMarkerLen(LineText);
            if MarkerLen > 0 then
            begin
              FlushParagraph;
              Depth := IndentDepth(RawLine);
              AddTextLabel(LineText, 12, False, False, 12 + Depth * 16);
            end
            else
            begin
              if Paragraph.Length > 0 then
                Paragraph.Append(' ');
              Paragraph.Append(LineText);
            end;
          end;
        end;
        FlushAll;
      finally
        TableRows.Free;
        Quote.Free;
        Paragraph.Free;
      end;
    end;

    procedure AddCodeBlock(const Text: string; const Language: string = '');
    var
      Bar: TLayout;
      CodeMemo: TMemo;
      CopyButton: TButton;
      LangLabel: TLabel;
      Lines: Integer;
    begin
      if Trim(Text) = '' then
        Exit;
      Lines := Length(Text.Replace(#13#10, #10).Split([#10]));

      { Header bar: language tag on the left, Copy on the right -- the web UI
        affordance. The button carries the code in TagString so the shared
        form-level handler can copy it without a closure. }
      Bar := TLayout.Create(BodyHost);
      Bar.Parent := BodyHost;
      Bar.Align := TAlignLayout.Top;
      Bar.Height := ROW_TEXT;
      SetControlMargins(Bar, 0, GAP_S, 0, 0);

      LangLabel := TLabel.Create(Bar);
      LangLabel.Parent := Bar;
      LangLabel.Align := TAlignLayout.Left;
      LangLabel.Width := 160;
      LangLabel.HitTest := False;
      if Trim(Language) <> '' then
        LangLabel.Text := LowerCase(Trim(Language))
      else
        LangLabel.Text := 'code';
      LangLabel.TextSettings.VertAlign := TTextAlign.Center;
      StyleLabel(LangLabel, UI_MUTED, TXT_BODY, False);

      CopyButton := TButton.Create(Bar);
      CopyButton.Parent := Bar;
      CopyButton.Align := TAlignLayout.Right;
      CopyButton.Width := 62;
      CopyButton.Height := ROW_TEXT;
      CopyButton.Text := 'Copy';
      CopyButton.TagString := Text;
      CopyButton.OnClick := ChatCodeCopyClick;
      StyleButton(CopyButton, False);

      CodeMemo := TMemo.Create(BodyHost);
      CodeMemo.Parent := BodyHost;
      CodeMemo.Align := TAlignLayout.Top;
      CodeMemo.Height := Min(360, Max(72, Lines * 18 + 30));
      CodeMemo.ReadOnly := True;
      CodeMemo.WordWrap := False;
      CodeMemo.Lines.Text := Text;
      SetControlMargins(CodeMemo, 0, 0, 0, GAP_S);
      ContentHeight := ContentHeight + CodeMemo.Height + 12 + 22;
      StyleTextControl(CodeMemo, UI_TEXT, TXT_TITLE);
    end;

    procedure RenderBodyBlocks;
    var
      Code: TStringBuilder;
      CodeLang: string;
      I: Integer;
      InCode: Boolean;
      LineText: string;
      Lines: TArray<string>;
      Text: TStringBuilder;
    begin
      Lines := BodyText.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
      Text := TStringBuilder.Create;
      Code := TStringBuilder.Create;
      try
        InCode := False;
        CodeLang := '';
        for I := 0 to Length(Lines) - 1 do
        begin
          LineText := Lines[I];
          if StartsText('```', Trim(LineText)) then
          begin
            if InCode then
            begin
              AddCodeBlock(Code.ToString.TrimRight, CodeLang);
              Code.Clear;
              CodeLang := '';
              InCode := False;
            end
            else
            begin
              AddBodyTextBlock(Text.ToString);
              Text.Clear;
              { ```pascal -> the language tag shown on the block header }
              CodeLang := Trim(Copy(Trim(LineText), 4, MaxInt));
              InCode := True;
            end;
            Continue;
          end;
          if InCode then
            Code.AppendLine(LineText)
          else
            Text.AppendLine(LineText);
        end;
        if InCode then
          AddCodeBlock(Code.ToString.TrimRight, CodeLang);
        AddBodyTextBlock(Text.ToString);
      finally
        Code.Free;
        Text.Free;
      end;
    end;

    procedure AddToolCardBlock(const CardHtml: string);
    var
      DetailMemo: TMemo;
      DetailText: string;
      HeaderClose: Integer;
      HeaderLabel: TLabel;
      HeaderStart: Integer;
      P: Integer;
      Panel: TRectangle;
      TitleText: string;
    begin
      TitleText := '';
      P := Pos('class="tc-call"', CardHtml);
      if P > 0 then
      begin
        P := PosEx('>', CardHtml, P);
        HeaderClose := PosEx('</span>', CardHtml, P + 1);
        if (P > 0) and (HeaderClose > P) then
          TitleText := HtmlFragmentToText(Copy(CardHtml, P + 1,
            HeaderClose - P - 1));
      end;
      if TitleText = '' then
        TitleText := 'tool call';
      if Pos('tool-card err', CardHtml) > 0 then
        TitleText := TitleText + '  failed';

      DetailText := ToolCardText(CardHtml, FChatToolsExpanded);
      HeaderStart := Pos(sLineBreak, DetailText);
      if HeaderStart > 0 then
        DetailText := Trim(Copy(DetailText, HeaderStart + Length(sLineBreak), MaxInt));

      Panel := TRectangle.Create(BodyHost);
      Panel.Parent := BodyHost;
      Panel.Align := TAlignLayout.Top;
      if FChatToolsExpanded then
        Panel.Height := Min(420, Max(112, EstimateTextLines(DetailText, CharsPerLine) * 20 + 76))
      else
        Panel.Height := ROW_LIST;
      StyleChromeRect(Panel, UI_PANEL, UI_ACCENT_DIM, 6, False);
      SetControlMargins(Panel, 0, GAP_S, 0, GAP_S);
      SetControlPadding(Panel, 10, GAP_S, 10, GAP_S);
      ContentHeight := ContentHeight + Panel.Height + 12;

      HeaderLabel := TLabel.Create(Panel);
      HeaderLabel.Parent := Panel;
      HeaderLabel.Align := TAlignLayout.Top;
      HeaderLabel.Height := ROW_TEXT;
      HeaderLabel.HitTest := False;
      HeaderLabel.Text := TitleText;
      HeaderLabel.TextSettings.VertAlign := TTextAlign.Center;
      StyleLabel(HeaderLabel, UI_ACCENT, TXT_TITLE, True);

      if FChatToolsExpanded and (DetailText <> '') then
      begin
        DetailMemo := TMemo.Create(Panel);
        DetailMemo.Parent := Panel;
        DetailMemo.Align := TAlignLayout.Client;
        DetailMemo.ReadOnly := True;
        DetailMemo.WordWrap := True;
        DetailMemo.Lines.Text := DetailText;
        SetControlMargins(DetailMemo, 0, GAP_XS, 0, 0);
        StyleTextControl(DetailMemo, UI_TEXT, TXT_BODY);
      end;
    end;

    procedure RenderToolCardBlocks;
    var
      CardHtml: string;
      P: Integer;
      Q: Integer;
      Start: Integer;
    begin
      Start := 1;
      while True do
      begin
        P := PosEx('<details class="tool-card', RawBodyText, Start);
        if P = 0 then
          Break;
        if P > Start then
          AddBodyTextBlock(HtmlFragmentToText(Copy(RawBodyText, Start,
            P - Start)));
        Q := PosEx('</details>', RawBodyText, P);
        if Q = 0 then
          Break;
        CardHtml := Copy(RawBodyText, P, Q + Length('</details>') - P);
        AddToolCardBlock(CardHtml);
        Start := Q + Length('</details>');
      end;
      if Start <= Length(RawBodyText) then
        AddBodyTextBlock(HtmlFragmentToText(Copy(RawBodyText, Start,
          MaxInt)));
    end;

    function DetailFieldText(Obj: TJSONObject; const Names: array of string): string;
    var
      I: Integer;
      Value: TJSONValue;
    begin
      Result := '';
      if Obj = nil then
        Exit;
      for I := Low(Names) to High(Names) do
      begin
        Value := Obj.GetValue(Names[I]);
        if Value = nil then
          Continue;
        if Value is TJSONString then
          Result := Value.Value
        else
          Result := Value.ToJSON;
        if Trim(Result) <> '' then
          Exit;
      end;
    end;

    { Returns the vertical space this section actually consumes, so the
      caller can size the panel to its children instead of guessing. }
    function IsPlainAscii(const Text: string): Boolean;
    { Character count only models width for single-column ASCII. A tab has
      no fixed width either, so it is refused with the rest. }
    var
      I: Integer;
    begin
      for I := 1 to Length(Text) do
        if (Text[I] > #126) or (Text[I] = #9) then
          Exit(False);
      Result := True;
    end;

    function AddToolDetailSection(Host: TFmxObject; const TitleText,
      DetailText: string): Single;
    { A TMemo is by far the most expensive control the transcript builds --
      model, presentation layer, two scroll bars and a caret each -- and an
      expanded transcript wants three per tool call. Output short enough to
      fit without scrolling gets a TLabel instead, which is most of them and
      costs a fraction; anything long keeps the memo so it stays scrollable
      and selectable. }
    const
      SECTION_LINE_H = 18;
      NO_SCROLL_LINES = 9;      { fits inside the 190px memo cap }
    var
      Body: TControl;
      BodyHeight: Single;
      Lines: Integer;
      Memo: TMemo;
      SectionLabel: TLabel;
      TextLabel: TLabel;
    begin
      Result := 0;
      if Trim(DetailText) = '' then
        Exit;
      SectionLabel := TLabel.Create(Host);
      SectionLabel.Parent := Host;
      SectionLabel.Align := TAlignLayout.Top;
      SectionLabel.Height := ROW_TEXT;
      SectionLabel.HitTest := False;
      SectionLabel.Text := TitleText;
      StyleLabel(SectionLabel, UI_MUTED, TXT_CAPTION, True);

      { Decide against a DELIBERATELY narrow budget, and size from the same
        pessimistic count. EstimateTextLines divides by an average character
        width, so a line of wide glyphs wraps sooner than it predicts -- and
        a label cannot scroll, so an optimistic guess hides output for good.
        Three-quarters of the budget covers that spread, and non-ASCII text
        is refused outright because one character can be two columns wide
        (or more) and no character count models it.

        Half the budget, not three quarters: modelled against a line of all
        'W' -- about 1.6x the average glyph -- three quarters still came out
        one line short, and one line short is one line lost. }
      Lines := EstimateTextLines(DetailText, Max(18, CharsPerLine div 2));
      BodyHeight := Min(190, Max(58, Lines * SECTION_LINE_H + 24));
      if (Lines <= NO_SCROLL_LINES) and IsPlainAscii(DetailText) then
      begin
        TextLabel := TLabel.Create(Host);
        TextLabel.Parent := Host;
        TextLabel.Align := TAlignLayout.Top;
        TextLabel.Height := BodyHeight;
        TextLabel.HitTest := False;
        TextLabel.WordWrap := True;
        TextLabel.Text := DetailText;
        TextLabel.TextSettings.VertAlign := TTextAlign.Leading;
        StyleLabel(TextLabel, UI_TEXT, TXT_BODY, False);
        Body := TextLabel;
      end
      else
      begin
        Memo := TMemo.Create(Host);
        Memo.Parent := Host;
        Memo.Align := TAlignLayout.Top;
        Memo.Height := BodyHeight;
        Memo.ReadOnly := True;
        Memo.WordWrap := True;
        Memo.Lines.Text := DetailText;
        StyleTextControl(Memo, UI_TEXT, TXT_BODY);
        Body := Memo;
      end;
      SetControlMargins(Body, 0, 2, 0, GAP_S);
      { label + body + the 2/8 margins above and below the body }
      Result := SectionLabel.Height + BodyHeight + 10;
    end;

    procedure RenderToolDetailBlocks;
    var
      ArgsText: string;
      DetailObj: TJSONObject;
      ErrorText: string;
      HeaderLabel: TLabel;
      I: Integer;
      Panel: TRectangle;
      ResultText: string;
      SectionHost: TLayout;
      Root: TJSONValue;
      SectionsHeight: Single;
      TitleText: string;
    begin
      Root := TJSONObject.ParseJSONValue(ToolDetailsValue);
      try
        if not (Root is TJSONArray) then
          Exit;
        for I := 0 to TJSONArray(Root).Count - 1 do
        begin
          if not (TJSONArray(Root).Items[I] is TJSONObject) then
            Continue;
          DetailObj := TJSONObject(TJSONArray(Root).Items[I]);
          TitleText := DetailFieldText(DetailObj, ['name', 'tool', 'call']);
          if TitleText = '' then
            TitleText := 'tool detail';
          ArgsText := DetailFieldText(DetailObj, ['args', 'arguments', 'input']);
          ResultText := DetailFieldText(DetailObj, ['result', 'output', 'content']);
          ErrorText := DetailFieldText(DetailObj, ['err', 'error']);

          Panel := TRectangle.Create(BodyHost);
          Panel.Parent := BodyHost;
          Panel.Align := TAlignLayout.Top;
          Panel.Height := ROW_LIST;   { header-only; grown below when expanded }
          { Muted chrome, not accent: the screenshots showed expanded tool
            cards -- accent borders, accent bold headers -- shouting over the
            conversation. The hierarchy rule is that CHAT TEXT pulls the eye;
            tool plumbing is chrome and dresses like it. }
          StyleChromeRect(Panel, UI_PANEL_ALT, UI_BORDER, 6, False);
          SetControlMargins(Panel, 0, GAP_S, 0, GAP_S);
          SetControlPadding(Panel, 10, GAP_S, 10, GAP_S);

          { The header is a Top sibling and the sections live in a CLIENT
            host, so the header's position no longer depends on how FMX
            orders Align.Top siblings -- Client takes whatever is left after
            the Top children, whichever way that iteration runs. Relying on
            sibling order is what put the tool name underneath its own
            output. }
          HeaderLabel := TLabel.Create(Panel);
          HeaderLabel.Parent := Panel;
          HeaderLabel.Align := TAlignLayout.Top;
          HeaderLabel.Height := ROW_TEXT;
          HeaderLabel.HitTest := False;
          if FChatToolsExpanded then
            HeaderLabel.Text := 'tool detail - ' + TitleText
          else
            HeaderLabel.Text := 'tool detail + ' + TitleText;
          StyleLabel(HeaderLabel, UI_CHROME_TEXT, TXT_BODY, True);

          if FChatToolsExpanded then
          begin
            { Sum what the sections REALLY occupy and size the panel to it.
              The old code guessed the height with a capped estimate that did
              not match how the sections lay themselves out, so an expanded
              panel was routinely shorter than its own children -- and since
              the children are Align.Top with fixed heights, the overflow
              painted straight over the following chat bubbles. }
            SectionHost := TLayout.Create(Panel);
            SectionHost.Parent := Panel;
            SectionHost.Align := TAlignLayout.Client;
            SectionsHeight := 0;
            SectionsHeight := SectionsHeight +
              AddToolDetailSection(SectionHost, 'ARGS', ArgsText);
            SectionsHeight := SectionsHeight +
              AddToolDetailSection(SectionHost, 'RESULT', ResultText);
            SectionsHeight := SectionsHeight +
              AddToolDetailSection(SectionHost, 'ERROR', ErrorText);
            { header + sections + the panel's own 8/8 vertical padding }
            Panel.Height := Max(44, HeaderLabel.Height + SectionsHeight + 16);
          end;
          ContentHeight := ContentHeight + Panel.Height + 12;
        end;
      finally
        Root.Free;
      end;
    end;
  begin
    if (FChatFlow = nil) and (FChatList = nil) then
      Exit;

    RawBodyText := BodyValue;
    HasToolCards := SameText(RoleValue, 'assistant') and
      (Pos('<details class="tool-card', RawBodyText) > 0);
    HasToolDetails := SameText(RoleValue, 'assistant') and
      (Trim(ToolDetailsValue) <> '');
    BodyText := BodyValue;
    if BodyText = '' then
      BodyText := '(empty)';
    { No role captions, no avatar medallions: alignment and ground already
      say who is speaking (user right + tinted bubble, assistant left on open
      canvas), the way every chat app does. Labels were chrome shouting the
      obvious. }
    FillColor := UI_PANEL_ALT;
    BorderColor := UI_BORDER;
    if SameText(RoleValue, 'user') then
    begin
      BodyText := CompactUserBody(BodyText);
      { tier 2 -- a distinct ground + border so the user's turn reads as a
        bubble in a dialogue rather than another row in a log. }
      FillColor := UI_USER_FILL;
      BorderColor := UI_USER_BORDER;
    end
    else if SameText(RoleValue, 'assistant') then
    begin
      BodyText := FormatChatDisplayText(BodyText, FChatToolsExpanded);
      FillColor := UI_PANEL;
      BorderColor := UI_BORDER;
    end
    else if SameText(RoleValue, 'system') then
      BorderColor := UI_WARN;
    { One predicate, shared rules -- see MarkdownNeedsBlockRenderer. }
    HasRichText := HasToolCards or HasToolDetails or
      (Pos('```', BodyText) > 0) or MarkdownNeedsBlockRenderer(BodyText);

    AvailableWidth := 640;
    if (FChatFlow <> nil) and (FChatFlow.Width > 0) then
      { INNER width. The flow's own padding is not usable row space, so a row
        sized to the OUTER width does not fit its content area -- the flow
        then lays it out oversized and the right-aligned user card runs past
        the measured column into the scroll box's clipped edge. }
      AvailableWidth := FChatFlow.Width - CHAT_FLOW_PAD * 2
    else if (FChatScroll <> nil) and (FChatScroll.Width > 0) then
      AvailableWidth := FChatScroll.Width
    else if (FChatList <> nil) and (FChatList.Width > 0) then
      AvailableWidth := FChatList.Width;

    MaxBubbleWidth := 640;
    if AvailableWidth > 0 then
    begin
      if SameText(RoleValue, 'assistant') then
        MaxBubbleWidth := Max(320, AvailableWidth - 28)
      else
      begin
        MaxBubbleWidth := Max(260, AvailableWidth - 18);
        if AvailableWidth > 720 then
          MaxBubbleWidth := Min(720, AvailableWidth * 0.68);
      end;
    end;

    if Index = SelectedTurn then
      BorderColor := UI_ACCENT;
    CharsPerLine := Max(34, Trunc(MaxBubbleWidth / 7.2));
    if not SameText(RoleValue, 'assistant') then
      CharsPerLine := Max(30, Trunc(MaxBubbleWidth / 7.8));
    ToolCardCount := CountToolCards(RawBodyText);
    EstLines := EstimateTextLines(BodyText, CharsPerLine);
    { Sanity ceiling only -- must stay well above any real turn. A cap that
      bites clips the row while its children keep their full height, which
      is what makes bubbles overlap. }
    RowHeight := Min(CHAT_ROW_MAX, Max(84, 74 + EstLines * 20));
    if HasRichText then
      RowHeight := Min(2200, Max(112, RowHeight + 24));
    if HasToolCards then
    begin
      if FChatToolsExpanded then
        RowHeight := Min(2200, RowHeight + Max(90, ToolCardCount * 110))
      else
        RowHeight := Min(2200, RowHeight + Max(28, ToolCardCount * 48));
    end;
    ContentHeight := 0;
    BodyHost := nil;
    TranscriptItem := nil;
    TranscriptRow := nil;
    if FChatFlow <> nil then
    begin
      TranscriptRow := TLayout.Create(FChatFlow);
      TranscriptRow.Parent := FChatFlow;
      TranscriptRow.Align := TAlignLayout.None;
      { AvailableWidth is already the flow's inner width, so the row fills
        the measured column exactly -- no arbitrary allowance either way }
      TranscriptRow.Width := Max(CHAT_MIN_W, AvailableWidth);
      TranscriptRow.Height := RowHeight;
      TranscriptRow.TagString := Index.ToString;
      TranscriptRow.HitTest := False;
      Card := TRectangle.Create(TranscriptRow);
      Card.Parent := TranscriptRow;
    end
    else
    begin
      TranscriptItem := TListBoxItem.Create(FChatList);
      TranscriptItem.Parent := FChatList;
      TranscriptItem.Text := '';
      TranscriptItem.TagString := Index.ToString;
      TranscriptItem.Height := RowHeight;
      TranscriptItem.HitTest := True;
      TranscriptItem.OnClick := CardListItemClick;
      Card := TRectangle.Create(TranscriptItem);
      Card.Parent := TranscriptItem;
    end;
    if SameText(RoleValue, 'user') then
      Card.Align := TAlignLayout.Right
    else
      Card.Align := TAlignLayout.Left;
    Card.Width := MaxBubbleWidth;
    StyleChromeRect(Card, FillColor, BorderColor, 8, True);
    { the assistant speaks on open canvas -- no box line around its text.
      The user bubble and the system warning border stay; a selected turn
      still shows the accent outline so selection is visible. }
    if SameText(RoleValue, 'assistant') and (Index <> SelectedTurn) then
      Card.Stroke.Kind := TBrushKind.None;
    Card.HitTest := True;
    if SameText(RoleValue, 'assistant') then
      SetControlMargins(Card, 0, GAP_XS, 18, GAP_XS)
    else
      SetControlMargins(Card, 48, GAP_S, 0, GAP_S);
    SetControlPadding(Card, GAP_M, 10, GAP_M, GAP_M);

    { Slim header: just the turn meta and the copy icon, right-aligned. }
    Header := TLayout.Create(Card);
    Header.Parent := Card;
    Header.Align := TAlignLayout.Top;
    Header.Height := H_INPUT;

    { Copy is created FIRST so it takes the outermost right slot; the turn
      meta then sits to its left, reading "turn 3/8  [copy]" left to right. }
    HeaderCopyButton := TButton.Create(Header);
    HeaderCopyButton.Parent := Header;
    HeaderCopyButton.Align := TAlignLayout.Right;
    HeaderCopyButton.Width := 54;
    HeaderCopyButton.Text := 'Copy';
    HeaderCopyButton.TagString := 'copy' + #9 + Index.ToString;
    HeaderCopyButton.OnClick := ChatTurnActionClick;
    SetControlMargins(HeaderCopyButton, GAP_S, 1, 0, 1);
    StyleButton(HeaderCopyButton, False);

    MetaLabel := TLabel.Create(Header);
    MetaLabel.Parent := Header;
    MetaLabel.Align := TAlignLayout.Right;
    MetaLabel.Width := 96;
    MetaLabel.HitTest := False;
    MetaText := Format('turn %d/%d', [Index + 1, Total]);
    MetaLabel.Text := MetaText;
    MetaLabel.TextSettings.HorzAlign := TTextAlign.Trailing;
    MetaLabel.TextSettings.VertAlign := TTextAlign.Center;
    { same tier as the turn-count footer -- both are notes about the
      transcript, not part of it }
    StyleLabel(MetaLabel, UI_MUTED, TXT_CAPTION, False);

    ActionRow := TLayout.Create(Card);
    ActionRow.Parent := Card;
    ActionRow.Align := TAlignLayout.Top;
    if Index = SelectedTurn then
      ActionRow.Height := 28
    else
      ActionRow.Height := 0;
    SetControlMargins(ActionRow, 0, 2, 0, 2);
    if Index = SelectedTurn then
    begin
      if SameText(RoleValue, 'user') then
      begin
        AddTurnButton('Edit', 'edit', 58);
        AddTurnButton('Regenerate', 'regen', 104);
      end;
    end;

    if HasRichText then
    begin
      BodyHost := TLayout.Create(Card);
      BodyHost.Parent := Card;
      BodyHost.Align := TAlignLayout.Top;
      BodyHost.Height := 0;
      SetControlMargins(BodyHost, 0, GAP_XS, 0, 0);
      if HasToolCards then
        RenderToolCardBlocks
      else
        RenderBodyBlocks;
      if HasToolDetails then
        RenderToolDetailBlocks;
    end
    else
    begin
      ContentHeight := Max(24, EstLines * 20 + 12);
      BodyLabel := TLabel.Create(Card);
      BodyLabel.Parent := Card;
      BodyLabel.Align := TAlignLayout.Top;
      BodyLabel.Height := ContentHeight;
      BodyLabel.HitTest := False;
      BodyLabel.Text := BodyText;
      BodyLabel.WordWrap := True;
      BodyLabel.TextSettings.VertAlign := TTextAlign.Leading;
      SetControlMargins(BodyLabel, 0, GAP_S, 0, 0);
      StyleLabel(BodyLabel, UI_CHAT_TEXT, TXT_TITLE, False);          { tier 1 }
    end;

    if BodyHost <> nil then
      BodyHost.Height := ContentHeight + 4;
    RowHeight := Min(CHAT_ROW_MAX, Max(76,
      Header.Height + ActionRow.Height + ContentHeight + 38));
    if TranscriptRow <> nil then
    begin
      TranscriptRow.Height := RowHeight;
      ChatFlowHeight := ChatFlowHeight + RowHeight;
    end;
    if TranscriptItem <> nil then
      TranscriptItem.Height := RowHeight;
  end;
begin
  AssistantCount := 0;
  OtherCount := 0;
  UserCount := 0;
  for I := 0 to FTurns.Count - 1 do
  begin
    Turn := FTurns[I];
    if SameText(Turn.Role, 'user') then
      Inc(UserCount)
    else if SameText(Turn.Role, 'assistant') then
      Inc(AssistantCount)
    else
      Inc(OtherCount);
  end;
  if FActiveSessionId = '' then
    SessionText := 'new session'
  else
    SessionText := FActiveSessionId;
  if FChatStatsLabel <> nil then
    FChatStatsLabel.Text := Format('%d turn(s) - %d user / %d assistant / %d other - %d queued - %d attachment(s) - %s',
      [FTurns.Count, UserCount, AssistantCount, OtherCount,
      FQueuedPrompts.Count, FAttachments.Count, SessionText]);

  SelectedTurn := -1;
  if (FChatList <> nil) and (FChatList.Selected <> nil) then
    SelectedTurn := StrToIntDef(FChatList.Selected.TagString, -1);
  if (SelectedTurn < 0) and (FChatTurnList <> nil) and
    (FChatTurnList.Selected <> nil) then
    SelectedTurn := StrToIntDef(FChatTurnList.Selected.TagString, -1);
  if (SelectedTurn < 0) and (FChatTurnEdit <> nil) and
    (Trim(FChatTurnEdit.Text) <> '') then
    SelectedTurn := StrToIntDef(Trim(FChatTurnEdit.Text), 0) - 1;

  if (FChatTurnList <> nil) and FChatTurnList.Visible then
  begin
    FChatTurnList.OnChange := nil;
    try
      FChatTurnList.Clear;
      for I := 0 to FTurns.Count - 1 do
      begin
        Turn := FTurns[I];
        if SameText(Turn.Role, 'user') then
          Preview := Trim(CompactUserBody(Turn.Text))
        else
          Preview := Trim(FormatChatDisplayText(Turn.Text));
        Preview := StringReplace(Preview, #13, ' ', [rfReplaceAll]);
        Preview := StringReplace(Preview, #10, ' ', [rfReplaceAll]);
        if Length(Preview) > 96 then
          Preview := Copy(Preview, 1, 93) + '...';
        if Preview = '' then
          Preview := '(empty)';
        if SameText(Turn.Role, 'user') then
          Prefix := 'YOU'
        else if SameText(Turn.Role, 'assistant') then
          Prefix := 'PASCLAW'
        else
          Prefix := UpperCase(Turn.Role);
        AddCardListItem(FChatTurnList, Format('%d  %s', [I + 1,
          Prefix]), Preview, I.ToString, 58, I = SelectedTurn);
        if I = SelectedTurn then
          FChatTurnList.ItemIndex := FChatTurnList.Count - 1;
      end;
    finally
      FChatTurnList.OnChange := ChatTurnListChange;
    end;
  end;

  if FChatFlow <> nil then
  begin
    { One realign for the whole rebuild instead of one per control. A long
      session with expanded tool cards creates thousands of controls, and
      without this every single Free and Create realigns the flow. }
    FChatFlow.BeginUpdate;
    try
      { Free from the END: removing index 0 shifts the entire children list
        down on every iteration, which turns clearing a long transcript into
        quadratic work before a single new control is built. }
      while FChatFlow.ChildrenCount > 0 do
        FChatFlow.Children[FChatFlow.ChildrenCount - 1].Free;
      ChatFlowHeight := 0;
      ApplyChatMeasure;   { the one authority on the flow's width + margins }
      if FTurns.Count = 0 then
        AddTranscriptCard(0, 1, 'assistant',
          'Connect to PasClaw, choose or create a session, then describe the code change you want.', '')
      else
        for I := 0 to FTurns.Count - 1 do
        begin
          Turn := FTurns[I];
          AddTranscriptCard(I, FTurns.Count, Turn.Role, Turn.Text,
            Turn.ToolDetails);
        end;
      if FChatScroll <> nil then
        FChatFlow.Height := Max(FChatScroll.Height, ChatFlowHeight + 8)
      else
        FChatFlow.Height := ChatFlowHeight + 8;
    finally
      FChatFlow.EndUpdate;
    end;
    if FChatScroll <> nil then
      FChatScroll.ViewportPosition := PointF(0,
        Max(0, FChatFlow.Height - FChatScroll.Height));
  end
  else if FChatList <> nil then
  begin
    FChatList.OnChange := nil;
    try
      FChatList.Clear;
      if FTurns.Count = 0 then
        AddTranscriptCard(0, 1, 'assistant',
          'Connect to PasClaw, choose or create a session, then describe the code change you want.', '')
      else
        for I := 0 to FTurns.Count - 1 do
        begin
          Turn := FTurns[I];
          AddTranscriptCard(I, FTurns.Count, Turn.Role, Turn.Text,
            Turn.ToolDetails);
        end;
      if (SelectedTurn >= 0) and (SelectedTurn < FChatList.Count) then
        FChatList.ItemIndex := SelectedTurn
      else if (FTurns.Count > 0) and (FChatList.Count > 0) then
        FChatList.ItemIndex := FChatList.Count - 1;
    finally
      FChatList.OnChange := ChatTranscriptChange;
    end;
  end;
end;

procedure TMasterDetailForm.UpdateLastAssistantTurn(const Text: string);
var
  I: Integer;
  Turn: TChatTurn;
begin
  for I := FTurns.Count - 1 downto 0 do
    if SameText(FTurns[I].Role, 'assistant') then
    begin
      Turn := FTurns[I];
      Turn.Text := Text;
      FTurns[I] := Turn;
      RenderChat;
      Exit;
    end;
  AddTurn('assistant', Text);
  RenderChat;
end;

procedure TMasterDetailForm.UpdateLastAssistantToolDetails(
  const ToolDetails: string);
var
  I: Integer;
  Turn: TChatTurn;
begin
  if Trim(ToolDetails) = '' then
    Exit;
  for I := FTurns.Count - 1 downto 0 do
    if SameText(FTurns[I].Role, 'assistant') then
    begin
      Turn := FTurns[I];
      Turn.ToolDetails := ToolDetails;
      FTurns[I] := Turn;
      RenderChat;
      Exit;
    end;
end;

procedure TMasterDetailForm.QueueAssistantUpdate(const Text: string);
begin
  TThread.Queue(nil,
    procedure
    begin
      UpdateLastAssistantTurn(Text);
    end);
end;

procedure TMasterDetailForm.QueueLogAppend(const Text: string);
begin
  TThread.Queue(nil,
    procedure
    var
      Memo: TMemo;
    begin
      if not FPaneMemos.TryGetValue('logs', Memo) then
        Exit;
      Memo.Lines.BeginUpdate;
      try
        Memo.Lines.Text := Memo.Lines.Text + Text;
        while Memo.Lines.Count > 1500 do
          Memo.Lines.Delete(0);
      finally
        Memo.Lines.EndUpdate;
      end;
    end);
end;

function TMasterDetailForm.BuildSessionPayload(
  const Turns: TArray<TChatTurn>): string;
var
  Arr: TJSONArray;
  DetailArr: TJSONArray;
  DetailValue: TJSONValue;
  HasToolDetails: Boolean;
  I: Integer;
  Msg: TJSONObject;
  Obj: TJSONObject;
begin
  Obj := TJSONObject.Create;
  try
    Arr := TJSONArray.Create;
    DetailArr := TJSONArray.Create;
    HasToolDetails := False;
    for I := 0 to Length(Turns) - 1 do
      if SameText(Turns[I].Role, 'user') or SameText(Turns[I].Role, 'assistant') then
      begin
        Msg := TJSONObject.Create;
        Msg.AddPair('role', Turns[I].Role);
        Msg.AddPair('content', Turns[I].Text);
        Arr.AddElement(Msg);

        DetailValue := nil;
        if Trim(Turns[I].ToolDetails) <> '' then
          DetailValue := TJSONObject.ParseJSONValue(Turns[I].ToolDetails);
        if DetailValue <> nil then
        begin
          DetailArr.AddElement(DetailValue);
          HasToolDetails := True;
        end
        else
          DetailArr.AddElement(TJSONNull.Create);
      end;
    Obj.AddPair('messages', Arr);
    if HasToolDetails then
      Obj.AddPair('tool_details', DetailArr)
    else
      DetailArr.Free;
    Result := Obj.ToJSON;
  finally
    Obj.Free;
  end;
end;

function TMasterDetailForm.BuildChatPayload(const Turns: TArray<TChatTurn>;
  const SystemPrompt, Model, Mode, Temperature, MaxTokens: string;
  Stream: Boolean): string;
var
  Arr: TJSONArray;
  D: Double;
  FS: TFormatSettings;
  I: Integer;
  MaxValue: Integer;
  Msg: TJSONObject;
  Obj: TJSONObject;
begin
  Obj := TJSONObject.Create;
  try
    if Stream then
      Obj.AddPair('stream', TJSONTrue.Create)
    else
      Obj.AddPair('stream', TJSONFalse.Create);
    Obj.AddPair('mode', Mode);
    if Model <> '' then
      Obj.AddPair('model', Model);

    FS := TFormatSettings.Create('en-US');
    if TryStrToFloat(Trim(Temperature), D, FS) and (D >= 0) then
      Obj.AddPair('temperature', TJSONNumber.Create(D));
    if TryStrToInt(Trim(MaxTokens), MaxValue) and (MaxValue > 0) then
      Obj.AddPair('max_tokens', TJSONNumber.Create(MaxValue));

    Arr := TJSONArray.Create;
    if Trim(SystemPrompt) <> '' then
    begin
      Msg := TJSONObject.Create;
      Msg.AddPair('role', 'system');
      Msg.AddPair('content', SystemPrompt);
      Arr.AddElement(Msg);
    end;

    for I := 0 to Length(Turns) - 1 do
      if SameText(Turns[I].Role, 'user') or SameText(Turns[I].Role, 'assistant') then
      begin
        Msg := TJSONObject.Create;
        Msg.AddPair('role', Turns[I].Role);
        Msg.AddPair('content', Turns[I].Text);
        Arr.AddElement(Msg);
      end;
    Obj.AddPair('messages', Arr);
    Result := Obj.ToJSON;
  finally
    Obj.Free;
  end;
end;

function TMasterDetailForm.ExtractSessionId(const JsonText: string): string;
var
  Obj: TJSONObject;
  Root: TJSONValue;
begin
  Result := '';
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if Root is TJSONObject then
    begin
      Obj := TJSONObject(Root);
      Result := JsonAsString(Obj, 'id');
      if Result = '' then
        Result := JsonAsString(Obj, 'session_id');
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.ExtractAssistantDelta(
  const JsonText: string): string;
var
  Arr: TJSONArray;
  Choice: TJSONObject;
  Msg: TJSONObject;
  Obj: TJSONObject;
  Root: TJSONValue;
  Value: TJSONValue;
begin
  Result := '';
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if Root is TJSONObject then
    begin
      Obj := TJSONObject(Root);
      Value := Obj.GetValue('error');
      if Value is TJSONObject then
      begin
        Result := 'Error: ' + JsonAsString(TJSONObject(Value), 'message');
        Exit;
      end;

      Arr := nil;
      Value := Obj.GetValue('choices');
      if Value is TJSONArray then
        Arr := TJSONArray(Value);
      if (Arr <> nil) and (Arr.Count > 0) and (Arr.Items[0] is TJSONObject) then
      begin
        Choice := TJSONObject(Arr.Items[0]);
        Value := Choice.GetValue('delta');
        if Value is TJSONObject then
        begin
          Msg := TJSONObject(Value);
          Result := JsonAsString(Msg, 'content');
          if Result <> '' then
            Exit;
        end;
        Value := Choice.GetValue('message');
        if Value is TJSONObject then
        begin
          Msg := TJSONObject(Value);
          Result := JsonAsString(Msg, 'content');
          if Result <> '' then
            Exit;
        end;
        Result := JsonAsString(Choice, 'text');
      end;
      if Result = '' then
        Result := JsonAsString(Obj, 'content');
    end;
  finally
    Root.Free;
  end;
end;

function TMasterDetailForm.ExtractSseDeltas(var Buffer: string;
  const ChunkText: string; out Done: Boolean; ToolDetails: TStrings): string;
var
  DataText: string;
  EventText: string;
  Line: string;
  Lines: TArray<string>;
  P: Integer;
begin
  Result := '';
  Done := False;
  Buffer := Buffer + ChunkText;
  Buffer := StringReplace(Buffer, #13#10, #10, [rfReplaceAll]);
  Buffer := StringReplace(Buffer, #13, #10, [rfReplaceAll]);

  while True do
  begin
    P := Pos(#10#10, Buffer);
    if P = 0 then
      Break;

    EventText := Copy(Buffer, 1, P - 1);
    Delete(Buffer, 1, P + 1);
    DataText := '';
    Lines := EventText.Split([#10]);
    for Line in Lines do
    begin
      if StartsText('data:', Line) then
      begin
        if DataText <> '' then
          DataText := DataText + #10;
        DataText := DataText + Trim(Copy(Line, 6, MaxInt));
      end
      else if (ToolDetails <> nil) and StartsText(':', Line) and
        StartsText('pasclaw-tool ', Trim(Copy(Line, 2, MaxInt))) then
        ToolDetails.Add(Trim(Copy(Trim(Copy(Line, 2, MaxInt)),
          Length('pasclaw-tool ') + 1, MaxInt)));
    end;

    if DataText = '' then
      Continue;
    if SameText(DataText, '[DONE]') then
    begin
      Done := True;
      Continue;
    end;
    Result := Result + ExtractAssistantDelta(DataText);
  end;
end;

function TMasterDetailForm.ExtractAssistantText(
  const JsonText: string): string;
var
  Arr: TJSONArray;
  Choice: TJSONObject;
  Msg: TJSONObject;
  Obj: TJSONObject;
  Root: TJSONValue;
  Value: TJSONValue;
begin
  Result := '';
  Root := TJSONObject.ParseJSONValue(JsonText);
  try
    if Root is TJSONObject then
    begin
      Obj := TJSONObject(Root);
      Value := Obj.GetValue('error');
      if Value is TJSONObject then
      begin
        Result := 'Error: ' + JsonAsString(TJSONObject(Value), 'message');
        Exit;
      end;

      Arr := nil;
      Value := Obj.GetValue('choices');
      if Value is TJSONArray then
        Arr := TJSONArray(Value);
      if (Arr <> nil) and (Arr.Count > 0) and (Arr.Items[0] is TJSONObject) then
      begin
        Choice := TJSONObject(Arr.Items[0]);
        Value := Choice.GetValue('message');
        if Value is TJSONObject then
        begin
          Msg := TJSONObject(Value);
          Result := JsonAsString(Msg, 'content');
          if Result <> '' then
            Exit;
        end;
        Value := Choice.GetValue('delta');
        if Value is TJSONObject then
        begin
          Msg := TJSONObject(Value);
          Result := JsonAsString(Msg, 'content');
          if Result <> '' then
            Exit;
        end;
        Result := JsonAsString(Choice, 'text');
      end;
      if Result = '' then
        Result := JsonAsString(Obj, 'content');
    end;
  finally
    Root.Free;
  end;
  if Result = '' then
    Result := JsonText;
end;

function TMasterDetailForm.SelectTabByText(const Caption: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if FTabControl = nil then
    Exit;

  for I := 0 to FTabControl.TabCount - 1 do
    if SameText(FTabControl.Tabs[I].Text, Caption) then
    begin
      FTabControl.TabIndex := I;
      UpdateNavButtons;
      ActivateCurrentTab(False);
      Exit(True);
    end;
end;

procedure TMasterDetailForm.SendQueuedPrompt(const Prompt: string);
begin
  if FPromptMemo = nil then
    Exit;
  FPromptMemo.Lines.Text := Prompt;
  SendClick(FSendButton);
end;

procedure TMasterDetailForm.PromptChange(Sender: TObject);
begin
  UpdateSlashPalette;
  UpdateComposerState;
end;

procedure TMasterDetailForm.SlashCommandItemClick(Sender: TObject);
var
  I: Integer;
begin
  if (FSlashList <> nil) and (Sender is TListBoxItem) then
    for I := 0 to FSlashList.Count - 1 do
      if FSlashList.ListItems[I] = Sender then
      begin
        FSlashList.ItemIndex := I;
        Break;
      end;
  SelectSlashSuggestion(True);
end;

procedure TMasterDetailForm.SelectSlashSuggestion(RunCommand: Boolean);
var
  Cmd: string;
begin
  if (FSlashList = nil) or (FSlashList.Selected = nil) then
    Exit;
  Cmd := Trim(FSlashList.Selected.TagString);
  if Cmd = '' then
    Exit;
  if FSlashPopup <> nil then
    FSlashPopup.IsOpen := False;

  if FPromptMemo <> nil then
  begin
    FPromptMemo.OnChange := nil;
    try
      if RunCommand then
        FPromptMemo.Lines.Text := '/' + Cmd
      else
        FPromptMemo.Lines.Text := '/' + Cmd + ' ';
    finally
      FPromptMemo.OnChange := PromptChange;
    end;
    FPromptMemo.SetFocus;
  end;

  if RunCommand then
  begin
    HandleSlashCommand('/' + Cmd);
    if FPromptMemo <> nil then
    begin
      FPromptMemo.OnChange := nil;
      try
        FPromptMemo.Lines.Text := '';
      finally
        FPromptMemo.OnChange := PromptChange;
      end;
    end;
  end;
  UpdateComposerState;
end;

procedure TMasterDetailForm.UpdateSlashPalette;
var
  Filter: string;
  I: Integer;
  MatchCount: Integer;
  Raw: string;
  Text: string;

  procedure HidePalette;
  begin
    if FSlashPopup <> nil then
      FSlashPopup.IsOpen := False;
    if FSlashList <> nil then
      FSlashList.Clear;
  end;

  procedure AddCommand(const Cmd, Description: string);
  var
    Item: TListBoxItem;
  begin
    if (Filter <> '') and (not StartsText(Filter, Cmd)) then
      Exit;
    Item := TListBoxItem.Create(FSlashList);
    Item.Parent := FSlashList;
    Item.Text := '/' + Cmd + '   ' + Description;
    Item.TagString := Cmd;
    Item.Height := ROW_FORM;
    Item.OnClick := SlashCommandItemClick;
    Inc(MatchCount);
  end;

begin
  if (FPromptMemo = nil) or (FSlashPopup = nil) or (FSlashList = nil) then
    Exit;

  Raw := FPromptMemo.Lines.Text.Replace(#13#10, #10).Replace(#13, #10);
  Text := Trim(Raw);
  if (Text = '') or (Text[1] <> '/') or (Pos(#10, Text) > 0) or
    (Pos(' ', Text) > 0) then
  begin
    HidePalette;
    Exit;
  end;

  Filter := LowerCase(Copy(Text, 2, MaxInt));
  for I := 1 to Length(Filter) do
    if not CharInSet(Filter[I], ['a'..'z', '0'..'9', '_', '-']) then
    begin
      HidePalette;
      Exit;
    end;

  FSlashList.Clear;
  MatchCount := 0;
  AddCommand('build', 'switch to build mode');
  AddCommand('chat', 'open the Chat tab');
  AddCommand('chatfiles', 'show files written in this chat');
  AddCommand('checkpoints', 'open workspace checkpoints');
  AddCommand('clear', 'clear the visible transcript');
  AddCommand('config', 'open gateway config');
  AddCommand('cron', 'open scheduled jobs');
  AddCommand('edit', 'edit a previous user turn');
  AddCommand('files', 'open workspace files');
  AddCommand('help', 'show slash command help');
  AddCommand('kb', 'search or browse knowledge base');
  AddCommand('logs', 'tail gateway logs');
  AddCommand('mcp', 'open MCP servers');
  AddCommand('memory', 'search or browse memory');
  AddCommand('model', 'select or load models');
  AddCommand('models', 'load available models');
  AddCommand('new', 'start a new session');
  AddCommand('onboard', 'configure provider and memory');
  AddCommand('plan', 'switch to plan mode');
  AddCommand('preset', 'load, save, or delete prompt presets');
  AddCommand('provider', 'open provider setup');
  AddCommand('refresh', 'connect and refresh gateway state');
  AddCommand('regen', 'regenerate from a previous turn');
  AddCommand('relay', 'open relay status');
  AddCommand('sessions', 'open the session drawer');
  AddCommand('settings', 'open settings');
  AddCommand('skills', 'open skills');
  AddCommand('stats', 'open usage stats');
  AddCommand('tools', 'list registered tools');
  AddCommand('vault', 'search PasClaw Code Vault');
  AddCommand('workflow', 'open workflow editor');

  if MatchCount = 0 then
  begin
    HidePalette;
    Exit;
  end;

  FSlashPopup.PlacementTarget := FPromptMemo;
  FSlashPopup.Width := Min(520.0, Max(300.0, FPromptMemo.Width));
  { stride from the token the items are built with, not a copy of its
    value -- they agreed only by coincidence }
  FSlashPopup.Height := Min(260.0,
    Max(54.0, MatchCount * ROW_FORM + GAP_S));
  FSlashList.ItemIndex := 0;
  FSlashPopup.IsOpen := True;
end;

function TMasterDetailForm.HandleSlashCommand(const Typed: string): Boolean;
var
  Action: string;
  Arg: string;
  Cmd: string;
  EncodedText: string;
  I: Integer;
  Index: Integer;
  Ini: TIniFile;
  Name: string;
  Names: TStringList;
  Text: string;
  SpacePos: Integer;
  Turn: TChatTurn;
  TurnIndex: Integer;
begin
  Result := False;
  Text := Trim(Typed);
  if (Text = '') or (Text[1] <> '/') then
    Exit;

  Delete(Text, 1, 1);
  Text := Trim(Text);
  if Text = '' then
    Exit;

  SpacePos := Pos(' ', Text);
  if SpacePos > 0 then
  begin
    Cmd := LowerCase(Copy(Text, 1, SpacePos - 1));
    Arg := Trim(Copy(Text, SpacePos + 1, MaxInt));
  end
  else
  begin
    Cmd := LowerCase(Text);
    Arg := '';
  end;

  Result := True;
  if (Cmd = 'help') or (Cmd = '?') then
  begin
    AddTurn('assistant', 'Slash commands:' + sLineBreak +
      '/new, /clear, /plan, /build, /chat, /sessions, /refresh, /model [name], /provider [name], /models, /preset' +
      sLineBreak +
      '/preset [name], /preset save <name>, /preset delete <name>' +
      sLineBreak +
      '/remember <fact>, /edit <turn>, /regen <turn>, /chatfiles, /onboard, /memory [query], /kb [query], /files [path], /mcp, /tools, /cron, /skills, /workflow [id], /vault [query], /logs, /stats, /checkpoints, /relay, /settings');
    RenderChat;
    SetStatus('slash help');
    Exit;
  end;

  if Cmd = 'clear' then
  begin
    FTurns.Clear;
    if FQueuedPrompts <> nil then
      FQueuedPrompts.Clear;
    RenderChat;
    RenderQueue;
    SetStatus('chat cleared');
    Exit;
  end;

  if Cmd = 'new' then
  begin
    NewSessionClick(nil);
    Exit;
  end;

  if Cmd = 'onboard' then
  begin
    FOnboardingStep := 0;
    ShowOnboarding;
    SetStatus('onboarding');
    Exit;
  end;

  if Cmd = 'remember' then
  begin
    if Arg = '' then
    begin
      SetStatus('usage: /remember <fact>');
      Exit;
    end;
    SelectTabByText('Memory');
    if FMemoryFactEdit <> nil then
      FMemoryFactEdit.Text := Arg;
    MemoryFactAddClick(nil);
    Exit;
  end;

  if (Cmd = 'chatfiles') or (Cmd = 'chat-files') then
  begin
    ChatFilesClick(nil);
    Exit;
  end;

  if Cmd = 'edit' then
  begin
    TurnIndex := StrToIntDef(Arg, 0) - 1;
    if (TurnIndex < 0) or (TurnIndex >= FTurns.Count) then
    begin
      SetStatus('usage: /edit <turn number>');
      Exit;
    end;
    Turn := FTurns[TurnIndex];
    if not SameText(Turn.Role, 'user') then
    begin
      SetStatus('only user turns can be edited');
      Exit;
    end;
    if FPromptMemo <> nil then
      FPromptMemo.Lines.Text := Turn.Text;
    while FTurns.Count > TurnIndex do
      FTurns.Delete(FTurns.Count - 1);
    RenderChat;
    SetStatus('turn loaded for editing');
    Exit;
  end;

  if (Cmd = 'regen') or (Cmd = 'regenerate') then
  begin
    TurnIndex := StrToIntDef(Arg, 0) - 1;
    if (TurnIndex < 0) or (TurnIndex >= FTurns.Count) then
    begin
      SetStatus('usage: /regen <turn number>');
      Exit;
    end;
    while (TurnIndex > 0) and (not SameText(FTurns[TurnIndex].Role, 'user')) do
      Dec(TurnIndex);
    if not SameText(FTurns[TurnIndex].Role, 'user') then
    begin
      SetStatus('no user turn found for regenerate');
      Exit;
    end;
    Turn := FTurns[TurnIndex];
    while FTurns.Count > TurnIndex do
      FTurns.Delete(FTurns.Count - 1);
    if FPromptMemo <> nil then
      FPromptMemo.Lines.Text := Turn.Text;
    RenderChat;
    SendClick(FSendButton);
    Exit;
  end;

  if (Cmd = 'plan') or (Cmd = 'build') then
  begin
    FMode := Cmd;
    RenderModeButton;
    SaveLocalSettings;
    SetStatus('mode: ' + Cmd);
    Exit;
  end;

  if Cmd = 'chat' then
  begin
    SelectTabByText('Chat');
    SetStatus('chat');
    Exit;
  end;

  if Cmd = 'sessions' then
  begin
    SetSidebarVisible(True, False);
    LoadSessions;
    SetStatus('sessions');
    Exit;
  end;

  if (Cmd = 'refresh') or (Cmd = 'connect') then
  begin
    RefreshClick(nil);
    Exit;
  end;

  if (Cmd = 'model') or (Cmd = 'models') then
  begin
    if Arg = '' then
    begin
      LoadModels;
      SelectTabByText('Settings');
      FetchEndpoint('settings', 'GET', '/v1/models', '');
      SetStatus('loading models...');
    end
    else
    begin
      if FModelCombo <> nil then
      begin
        Index := FModelCombo.Items.IndexOf(Arg);
        if Index < 0 then
          Index := FModelCombo.Items.Add(Arg);
        FModelCombo.ItemIndex := Index;
        FSavedModel := Arg;
        SaveLocalSettings;
      end;
      SetStatus('model: ' + Arg);
    end;
    Exit;
  end;

  if (Cmd = 'provider') or (Cmd = 'providers') then
  begin
    SelectTabByText('Settings');
    if Arg = '' then
    begin
      FetchEndpoint('settings', 'GET', '/v1/providers', '');
      SetStatus('loading providers...');
    end
    else
    begin
      if FProviderCatalogJson = '' then
        ProviderCatalogClick(nil)
      else if FProviderCombo <> nil then
      begin
        Index := FProviderCombo.Items.IndexOf(Arg);
        if Index >= 0 then
        begin
          FProviderCombo.ItemIndex := Index;
          ProviderComboChange(nil);
          SetStatus('provider selected: ' + Arg);
        end
        else
          SetStatus('provider not in loaded catalog: ' + Arg);
      end;
    end;
    Exit;
  end;

  if (Cmd = 'preset') or (Cmd = 'presets') then
  begin
    Action := '';
    Name := Arg;
    if Arg <> '' then
    begin
      SpacePos := Pos(' ', Arg);
      if SpacePos > 0 then
      begin
        Action := LowerCase(Copy(Arg, 1, SpacePos - 1));
        Name := Trim(Copy(Arg, SpacePos + 1, MaxInt));
      end
      else
      begin
        Action := 'load';
        Name := Arg;
      end;
    end;

    if (Arg = '') or ((Action <> 'load') and (Action <> 'save') and
      (Action <> 'delete') and (Action <> 'del')) then
    begin
      Names := TStringList.Create;
      Ini := TIniFile.Create(FConfigFile);
      try
        Ini.ReadSection('prompt_presets', Names);
        Names.Sort;
        if Names.Count = 0 then
          Text := 'No prompt presets saved.'
        else
        begin
          Text := 'Prompt presets:';
          for I := 0 to Names.Count - 1 do
            Text := Text + sLineBreak + '- ' + Names[I];
        end;
      finally
        Ini.Free;
        Names.Free;
      end;
      AddTurn('assistant', Text);
      RenderChat;
      SetStatus('presets');
      Exit;
    end;

    if Name = '' then
    begin
      SetStatus('preset name required');
      Exit;
    end;

    if Action = 'save' then
    begin
      Ini := TIniFile.Create(FConfigFile);
      try
        Ini.WriteString('prompt_presets', Name,
          EncodeIniText(FSystemMemo.Lines.Text));
      finally
        Ini.Free;
      end;
      LoadPromptPresets;
      if FPromptPresetCombo <> nil then
      begin
        Index := FPromptPresetCombo.Items.IndexOf(Name);
        if Index >= 0 then
          FPromptPresetCombo.ItemIndex := Index;
      end;
      if FPresetNameEdit <> nil then
        FPresetNameEdit.Text := Name;
      SetStatus('saved preset: ' + Name);
      Exit;
    end;

    if (Action = 'delete') or (Action = 'del') then
    begin
      Ini := TIniFile.Create(FConfigFile);
      try
        Ini.DeleteKey('prompt_presets', Name);
      finally
        Ini.Free;
      end;
      LoadPromptPresets;
      if FPresetNameEdit <> nil then
        FPresetNameEdit.Text := '';
      SetStatus('deleted preset: ' + Name);
      Exit;
    end;

    Ini := TIniFile.Create(FConfigFile);
    try
      EncodedText := Ini.ReadString('prompt_presets', Name, #1);
    finally
      Ini.Free;
    end;
    if EncodedText = #1 then
    begin
      SetStatus('preset not found: ' + Name);
      Exit;
    end;
    FSystemMemo.Lines.Text := DecodeIniText(EncodedText);
    if FPresetNameEdit <> nil then
      FPresetNameEdit.Text := Name;
    if FPromptPresetCombo <> nil then
    begin
      Index := FPromptPresetCombo.Items.IndexOf(Name);
      if Index >= 0 then
        FPromptPresetCombo.ItemIndex := Index;
    end;
    SetStatus('loaded preset: ' + Name);
    Exit;
  end;

  if Cmd = 'memory' then
  begin
    SelectTabByText('Memory');
    if Arg <> '' then
    begin
      if FMemorySearchEdit <> nil then
        FMemorySearchEdit.Text := Arg;
      MemorySearchClick(nil);
    end
    else
      MemoryFilesLoadClick(nil);
    Exit;
  end;

  if Cmd = 'kb' then
  begin
    SelectTabByText('KB');
    if Arg <> '' then
    begin
      if FKBSearchEdit <> nil then
        FKBSearchEdit.Text := Arg;
      KbSearchClick(nil);
    end
    else
      KbSourcesLoadClick(nil);
    Exit;
  end;

  if (Cmd = 'files') or (Cmd = 'file') then
  begin
    SelectTabByText('Files');
    if Arg <> '' then
      FilesOpenPath(Arg)
    else
      FilesOpenPath('');
    Exit;
  end;

  if Cmd = 'mcp' then
  begin
    SelectTabByText('MCP');
    FetchEndpoint('mcp', 'GET', '/v1/mcp', '');
    Exit;
  end;

  if Cmd = 'tools' then
  begin
    SelectTabByText('MCP');
    FetchEndpoint('mcp', 'GET', '/v1/tools', '');
    Exit;
  end;

  if Cmd = 'cron' then
  begin
    SelectTabByText('Cron');
    CronRefreshClick(nil);
    Exit;
  end;

  if Cmd = 'skills' then
  begin
    SelectTabByText('Skills');
    if Arg <> '' then
      FetchEndpoint('skills', 'GET', '/v1/skills/search?q=' + UrlEncode(Arg), '')
    else
      FetchEndpoint('skills', 'GET', '/v1/skills', '');
    Exit;
  end;

  if Cmd = 'workflow' then
  begin
    SelectTabByText('Workflow');
    if Arg <> '' then
      FetchEndpoint('workflow', 'GET', '/v1/workflows/' + UrlEncode(Arg), '')
    else
      FetchEndpoint('workflow', 'GET', '/v1/workflows', '');
    Exit;
  end;

  if Cmd = 'vault' then
  begin
    SelectTabByText('Vault');
    if Arg <> '' then
      FetchEndpoint('vault', 'GET', '/v1/vault?q=' + UrlEncode(Arg), '')
    else
      FetchEndpoint('vault', 'GET', '/v1/vault?q=delphi', '');
    Exit;
  end;

  if Cmd = 'logs' then
  begin
    SelectTabByText('Logs');
    LogsClick(nil);
    Exit;
  end;

  if Cmd = 'stats' then
  begin
    SelectTabByText('Stats');
    StatsRefreshClick(nil);
    Exit;
  end;

  if Cmd = 'checkpoints' then
  begin
    SelectTabByText('Checkpoints');
    CheckpointRefreshClick(nil);
    Exit;
  end;

  if Cmd = 'relay' then
  begin
    SelectTabByText('Relay');
    RelayRefreshClick(nil);
    Exit;
  end;

  if (Cmd = 'settings') or (Cmd = 'config') then
  begin
    SelectTabByText('Settings');
    FetchEndpoint('settings', 'GET', '/v1/config', '');
    Exit;
  end;

  AddTurn('assistant', 'Unknown slash command /' + Cmd +
    '. Type /help for available commands.');
  RenderChat;
  SetStatus('unknown command');
end;

procedure TMasterDetailForm.SendClick(Sender: TObject);
var
  Base: string;
  CurrentSession: string;
  MaxTokens: string;
  Mode: string;
  Model: string;
  Prompt: string;
  SystemPrompt: string;
  Temperature: string;
  Token: string;
  Turns: TArray<TChatTurn>;
begin
  if FSending then
  begin
    { Mid-turn parity with the web UI: a NON-EMPTY composer steers the
      running turn (POST /v1/steer; the gateway folds it in at the next
      loop iteration). An empty composer keeps the old behaviour: abort. }
    Prompt := Trim(FPromptMemo.Lines.Text);
    if Prompt <> '' then
    begin
      SteerActiveTurn(Prompt);
      FPromptMemo.Lines.Clear;
      UpdateComposerState;
      Exit;
    end;
    FChatAbort := True;
    UpdateComposerState;
    SetStatus('stopping chat...');
    Exit;
  end;
  Prompt := Trim(FPromptMemo.Lines.Text);
  if (Prompt = '') and ((FAttachments = nil) or (FAttachments.Count = 0)) then
  begin
    UpdateComposerState;
    Exit;
  end;
  if ((FAttachments = nil) or (FAttachments.Count = 0)) and
    HandleSlashCommand(Prompt) then
  begin
    FPromptMemo.Lines.Clear;
    UpdateComposerState;
    Exit;
  end;
  Prompt := ComposePrompt(Prompt);

  SaveLocalSettings;
  SaveChatParams(FActiveSessionId);
  AddTurn('user', Prompt);
  FPromptMemo.Lines.Clear;
  FAttachments.Clear;
  RenderAttachments;
  Turns := SnapshotTurns;
  AddTurn('assistant', '');
  RenderChat;

  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  CurrentSession := FActiveSessionId;
  SystemPrompt := FSystemMemo.Lines.Text;
  Model := CurrentModel;
  Mode := FMode;
  Temperature := Trim(FTemperatureEdit.Text);
  MaxTokens := Trim(FMaxTokensEdit.Text);

  FSending := True;
  FChatAbort := False;
  UpdateComposerState;
  SetStatus('PasClaw is working...');

  TTask.Run(
    procedure
    var
      AllTurns: TArray<TChatTurn>;
      AssistantText: string;
      ChatBody: string;
      DeltaText: string;
      Done: Boolean;
      ErrorText: string;
      PersistBody: string;
      ResponseText: string;
      SawSse: Boolean;
      SessionId: string;
      SseBuffer: string;
      Status: Integer;
      StreamToolDetails: TStringList;
      ToolDetailsText: string;
      WasAborted: Boolean;
    begin
      SessionId := CurrentSession;
      StreamToolDetails := TStringList.Create;
      WasAborted := False;
      try
        if SessionId = '' then
        begin
          PersistBody := BuildSessionPayload(Turns);
          ResponseText := HttpText(Base, Token, '', 'POST', '/v1/sessions',
            PersistBody, 'application/json', 'application/json', Status);
          if not IsHttpOk(Status) then
            raise Exception.CreateFmt('create session HTTP %d: %s',
              [Status, ResponseText]);
          SessionId := ExtractSessionId(ResponseText);
        end;

        ChatBody := BuildChatPayload(Turns, SystemPrompt, Model, Mode,
          Temperature, MaxTokens, True);
        SseBuffer := '';
        SawSse := False;
        ResponseText := HttpTextStreaming(Base, Token, SessionId, 'POST',
          '/v1/chat/completions', ChatBody, 'application/json',
          'text/event-stream, application/json',
          procedure(const ChunkText: string; var Abort: Boolean)
          var
            Delta: string;
            Done: Boolean;
            OldToolCount: Integer;
            ToolJson: string;
          begin
            Abort := FChatAbort;
            if Abort then
              Exit;
            if Pos('data:', ChunkText) > 0 then
              SawSse := True;
            OldToolCount := StreamToolDetails.Count;
            Delta := ExtractSseDeltas(SseBuffer, ChunkText, Done,
              StreamToolDetails);
            if StreamToolDetails.Count <> OldToolCount then
            begin
              ToolJson := RawToolDetailsToJson(StreamToolDetails);
              if ToolJson <> '' then
                TThread.Queue(nil,
                  procedure
                  begin
                    UpdateLastAssistantToolDetails(ToolJson);
                  end);
            end;
            if Delta <> '' then
            begin
              AssistantText := AssistantText + Delta;
              QueueAssistantUpdate(AssistantText);
            end;
          end, Status);
        WasAborted := FChatAbort;
        if (not WasAborted) and not IsHttpOk(Status) then
          raise Exception.CreateFmt('chat HTTP %d: %s', [Status, ResponseText]);

        if Pos('data:', ResponseText) > 0 then
          SawSse := True;
        if SseBuffer <> '' then
        begin
          DeltaText := ExtractSseDeltas(SseBuffer, #10#10, Done,
            StreamToolDetails);
          if DeltaText <> '' then
          begin
            AssistantText := AssistantText + DeltaText;
            QueueAssistantUpdate(AssistantText);
          end;
        end;
        if (not WasAborted) and (not SawSse) then
          AssistantText := ExtractAssistantText(ResponseText);
        if AssistantText = '' then
        begin
          if WasAborted then
            AssistantText := '(stopped)'
          else
            AssistantText := '(no response)';
        end;

        ToolDetailsText := RawToolDetailsToJson(StreamToolDetails);
        AllTurns := AppendTurnArray(Turns, 'assistant', AssistantText);
        if (ToolDetailsText <> '') and (Length(AllTurns) > 0) then
          AllTurns[High(AllTurns)].ToolDetails := ToolDetailsText;
        if SessionId <> '' then
        begin
          PersistBody := BuildSessionPayload(AllTurns);
          ResponseText := HttpText(Base, Token, SessionId, 'PUT',
            '/v1/sessions/' + UrlEncode(SessionId), PersistBody,
            'application/json', 'application/json', Status);
          if Status = 409 then
          begin
            ResponseText := HttpText(Base, Token, '', 'POST', '/v1/sessions',
              PersistBody, 'application/json', 'application/json', Status);
            if IsHttpOk(Status) then
              SessionId := ExtractSessionId(ResponseText);
          end;
        end;
      except
        on E: Exception do
          if FChatAbort then
          begin
            WasAborted := True;
            if AssistantText = '' then
              AssistantText := '(stopped)';
          end
          else
            ErrorText := E.Message;
      end;
      ToolDetailsText := RawToolDetailsToJson(StreamToolDetails);
      StreamToolDetails.Free;

      TThread.Queue(nil,
        procedure
        var
          NextPrompt: string;
        begin
          FSending := False;
          FChatAbort := False;
          UpdateComposerState;
          if SessionId <> '' then
          begin
            FActiveSessionId := SessionId;
            SaveChatParams(SessionId);
          end;

          if ErrorText <> '' then
          begin
            UpdateLastAssistantTurn('Error: ' + ErrorText);
            SetStatus('chat failed');
          end
          else
          begin
            UpdateLastAssistantTurn(AssistantText);
            UpdateLastAssistantToolDetails(ToolDetailsText);
            if WasAborted then
              SetStatus('chat stopped')
            else
              SetStatus('ready');
          end;
          LoadSessions;
          if (FQueuedPrompts <> nil) and (FQueuedPrompts.Count > 0) then
          begin
            NextPrompt := FQueuedPrompts.Dequeue;
            RenderQueue;
            SendQueuedPrompt(NextPrompt);
          end
          else
            RenderQueue;
        end);
    end);
end;

procedure TMasterDetailForm.PromptKeyDown(Sender: TObject; var Key: Word;
  var KeyChar: Char; Shift: TShiftState);
begin
  if (FSlashPopup <> nil) and FSlashPopup.IsOpen then
  begin
    if (Key = vkDown) and (FSlashList <> nil) and (FSlashList.Count > 0) then
    begin
      if FSlashList.ItemIndex < 0 then
        FSlashList.ItemIndex := 0
      else
        FSlashList.ItemIndex := (FSlashList.ItemIndex + 1) mod FSlashList.Count;
      Key := 0;
      KeyChar := #0;
      Exit;
    end;
    if (Key = vkUp) and (FSlashList <> nil) and (FSlashList.Count > 0) then
    begin
      if FSlashList.ItemIndex < 0 then
        FSlashList.ItemIndex := 0
      else
        FSlashList.ItemIndex := (FSlashList.ItemIndex - 1 + FSlashList.Count) mod
          FSlashList.Count;
      Key := 0;
      KeyChar := #0;
      Exit;
    end;
    if Key = vkTab then
    begin
      SelectSlashSuggestion(False);
      Key := 0;
      KeyChar := #0;
      Exit;
    end;
    if Key = vkReturn then
    begin
      SelectSlashSuggestion(True);
      Key := 0;
      KeyChar := #0;
      Exit;
    end;
    if Key = vkEscape then
    begin
      FSlashPopup.IsOpen := False;
      Key := 0;
      KeyChar := #0;
      Exit;
    end;
  end;

  if (Key = vkReturn) and (ssCtrl in Shift) then
  begin
    Key := 0;
    KeyChar := #0;
    if FSending then
      EnqueuePrompt
    else
      SendClick(FSendButton);
  end;
end;

procedure TMasterDetailForm.EndpointRunClick(Sender: TObject);
var
  Body: string;
  BodyMemo: TMemo;
  Combo: TComboBox;
  Edit: TEdit;
  Endpoint: string;
  Key: string;
  Method: string;
begin
  if not (Sender is TButton) then
    Exit;
  Key := TButton(Sender).TagString;
  if Key = '' then
    Exit;
  Endpoint := '';
  if FEndpointEdits.TryGetValue(Key, Edit) then
    Endpoint := Trim(Edit.Text);
  Method := 'GET';
  if FEndpointMethodCombos.TryGetValue(Key, Combo) then
    Method := ComboSelectedText(Combo);
  if Method = '' then
    Method := 'GET';
  Body := '';
  if FEndpointBodyMemos.TryGetValue(Key, BodyMemo) then
    Body := BodyMemo.Lines.Text;
  FetchEndpoint(Key, Method, Endpoint, Body);
end;

procedure TMasterDetailForm.FetchEndpoint(const Key, Method, Endpoint,
  Body: string);
var
  Base: string;
  Memo: TMemo;
  SessionId: string;
  Token: string;
begin
  if not FPaneMemos.TryGetValue(Key, Memo) then
    Exit;
  Base := GatewayBaseUrl;
  Token := FTokenEdit.Text;
  SessionId := FActiveSessionId;
  Memo.Lines.Text := Method + ' ' + Endpoint + sLineBreak + 'loading...';

  TTask.Run(
    procedure
    var
      ErrorText: string;
      ResponseText: string;
      Status: Integer;
    begin
      try
        ResponseText := HttpText(Base, Token, SessionId, Method, Endpoint, Body,
          'application/json', 'application/json, text/event-stream, text/plain',
          Status);
        if not IsHttpOk(Status) then
          ResponseText := Format('HTTP %d%s%s', [Status, sLineBreak,
            ResponseText]);
      except
        on E: Exception do
          ErrorText := E.Message;
      end;

      TThread.Queue(nil,
        procedure
        var
          BodyMemo: TMemo;
          DisplayText: string;
        begin
          if ErrorText <> '' then
          begin
            Memo.Lines.Text := Method + ' ' + Endpoint + sLineBreak +
              'Error: ' + ErrorText;
            if SameText(Key, 'workflow') and SameText(Method, 'POST') and
              EndsText('/run', Endpoint) then
              WorkflowRenderRunResult('Error: ' + ErrorText, 0);
            if SameText(Key, 'mcp') and SameText(Method, 'POST') and
              SameText(Endpoint, '/v1/mcp/rpc') then
              McpRenderInvokeResult('Error: ' + ErrorText, 0);
            if Key = 'settings' then
              SetStatus('offline');
          end
          else
          begin
            DisplayText := ResponseText;
            if SameText(Key, 'settings') and SameText(Method, 'GET') and
              IsHttpOk(Status) and SameText(Endpoint, '/v1/config') then
              DisplayText := FormatConfigText(ResponseText)
            else if SameText(Key, 'settings') and SameText(Method, 'GET') and
              IsHttpOk(Status) and SameText(Endpoint, '/v1/status') then
              DisplayText := FormatStatusText(ResponseText)
            else if SameText(Key, 'settings') and SameText(Method, 'GET') and
              IsHttpOk(Status) and SameText(Endpoint, '/v1/models') then
              DisplayText := FormatModelsText(ResponseText)
            else if SameText(Key, 'settings') and SameText(Method, 'GET') and
              IsHttpOk(Status) and
              (SameText(Endpoint, '/v1/providers/catalog') or
              SameText(Endpoint, '/v1/providers')) then
              DisplayText := FormatProviderText(ResponseText)
            else if SameText(Key, 'stats') and SameText(Method, 'GET') and
              IsHttpOk(Status) then
              DisplayText := FormatStatsText(ResponseText)
            else if SameText(Key, 'cron') and SameText(Method, 'GET') and
              IsHttpOk(Status) then
              DisplayText := FormatCronText(ResponseText)
            else if SameText(Key, 'checkpoints') and SameText(Method, 'GET') and
              IsHttpOk(Status) then
              DisplayText := FormatCheckpointText(ResponseText)
            else if SameText(Key, 'workflow') and SameText(Method, 'POST') and
              IsHttpOk(Status) and EndsText('/run', Endpoint) then
              DisplayText := FormatWorkflowRunText(ResponseText)
            else if SameText(Key, 'files') and SameText(Method, 'GET') and
              IsHttpOk(Status) and StartsText('/v1/fs/read', Endpoint) then
              DisplayText := FormatFilesReadText(ResponseText)
            else if SameText(Key, 'files') and SameText(Method, 'GET') and
              IsHttpOk(Status) and StartsText('/v1/fs', Endpoint) and
              not StartsText('/v1/fs/peek', Endpoint) and
              not StartsText('/v1/fs/download', Endpoint) then
              DisplayText := FormatFilesText(ResponseText)
            else if SameText(Key, 'kb') and SameText(Method, 'GET') and
              IsHttpOk(Status) and StartsText('/v1/kb/search', Endpoint) then
              DisplayText := FormatKbSearchText(ResponseText)
            else if SameText(Key, 'kb') and SameText(Method, 'GET') and
              IsHttpOk(Status) and SameText(Endpoint, '/v1/kb') then
              DisplayText := FormatKbSourcesText(ResponseText)
            else if SameText(Key, 'skills') and SameText(Method, 'GET') and
              IsHttpOk(Status) then
              DisplayText := FormatSkillsText(ResponseText)
            else if SameText(Key, 'mcp') and SameText(Method, 'GET') and
              IsHttpOk(Status) then
              DisplayText := FormatMcpText(ResponseText)
            else if SameText(Key, 'mcp') and SameText(Method, 'POST') and
              IsHttpOk(Status) and SameText(Endpoint, '/v1/mcp/rpc') then
              DisplayText := FormatMcpRpcText(ResponseText)
            else if SameText(Key, 'vault') and SameText(Method, 'GET') and
              IsHttpOk(Status) and StartsText('/v1/vault/', Endpoint) then
              DisplayText := FormatVaultDetailText(ResponseText)
            else if SameText(Key, 'vault') and SameText(Method, 'GET') and
              IsHttpOk(Status) then
              DisplayText := FormatVaultSearchText(ResponseText)
            else if SameText(Key, 'memory') and SameText(Method, 'GET') and
              IsHttpOk(Status) and SameText(Endpoint, '/v1/memory/provision') then
              DisplayText := FormatMemoryProvisionText(ResponseText)
            else if SameText(Key, 'memory') and SameText(Method, 'GET') and
              IsHttpOk(Status) and
              (SameText(Endpoint, '/v1/memory') or
              SameText(Endpoint, '/v1/memory/facts') or
              StartsText('/v1/memory/search', Endpoint)) then
              DisplayText := FormatMemoryText(ResponseText)
            else if SameText(Key, 'relay') and SameText(Method, 'GET') and
              IsHttpOk(Status) and SameText(Endpoint, '/v1/relay/status') then
              DisplayText := FormatRelayStatusText(ResponseText)
            else if SameText(Key, 'relay') and SameText(Method, 'GET') and
              IsHttpOk(Status) and SameText(Endpoint, '/v1/relay/worker-token') then
              DisplayText := FormatRelayTokenText(ResponseText);
            Memo.Lines.Text := Method + ' ' + Endpoint + sLineBreak +
              'HTTP ' + Status.ToString + sLineBreak + sLineBreak +
              DisplayText;
            if SameText(Key, 'workflow') and SameText(Method, 'POST') and
              EndsText('/run', Endpoint) then
              WorkflowRenderRunResult(ResponseText, Status);
            if SameText(Key, 'mcp') and SameText(Method, 'POST') and
              SameText(Endpoint, '/v1/mcp/rpc') then
              McpRenderInvokeResult(ResponseText, Status);
            if SameText(Key, 'settings') and SameText(Method, 'GET') and
              SameText(Endpoint, '/v1/config') and
              FEndpointBodyMemos.TryGetValue(Key, BodyMemo) then
            begin
              UpdateSandboxLabelFromConfig(ResponseText);
              BodyMemo.Lines.Text := ResponseText;
              ConfigRenderEditor;
            end;
            if SameText(Key, 'settings') and SameText(Method, 'PUT') and
              SameText(Endpoint, '/v1/config') and IsHttpOk(Status) then
              ConfigRenderEditor;
            if (Key = 'settings') and (Endpoint = '/v1/status') and
              IsHttpOk(Status) then
              SetStatus('connected');
            if SameText(Key, 'skills') and IsHttpOk(Status) and
              (SameText(Method, 'POST') or SameText(Method, 'DELETE')) then
            begin
              if SameText(Method, 'POST') and SameText(Endpoint, '/v1/skills') and
                (FSkillInstallEdit <> nil) then
                FSkillInstallEdit.Text := '';
              SkillsRefreshClick(nil);
            end;
            if SameText(Key, 'cron') and IsHttpOk(Status) and
              SameText(Method, 'GET') and SameText(Endpoint, '/v1/cron') then
              CronRefreshClick(nil)
            else if SameText(Key, 'stats') and IsHttpOk(Status) and
              SameText(Method, 'GET') and SameText(Endpoint, '/v1/stats') then
              StatsRefreshClick(nil)
            else if SameText(Key, 'checkpoints') and IsHttpOk(Status) then
            begin
              if SameText(Method, 'POST') or SameText(Method, 'GET') then
                CheckpointRefreshClick(nil);
            end
            else if SameText(Key, 'relay') and IsHttpOk(Status) and
              SameText(Method, 'GET') and SameText(Endpoint,
              '/v1/relay/status') then
              RelayRefreshClick(nil);
          end;
        end);
    end);
end;

end.
