# PasClaw - Delphi Object Pascal port of picoclaw
# Builds with Free Pascal (FPC 3.2+, mode Delphi) or Delphi/RAD Studio.
#
# Indy is required for HTTP client/server (TIdHTTP, TIdHTTPServer). Under FPC
# we vendor it via `make get-indy` (clones IndySockets/Indy into vendor/Indy).
# Under Delphi, Indy ships with RAD Studio — no vendoring needed.
#
# OS / arch autodetect — picks the default fcl-db / sqlite / iconvenc /
# lazutils unit paths so `make` works on a fresh Debian or Homebrew install
# without the user having to override every dir. Override any of them by
# setting the variable on the make command line, e.g.
#   make FCLDB_DIR=/opt/fpc/units/x86_64-linux/fcl-db
UNAME_S      := $(shell uname -s)
UNAME_M      := $(shell uname -m)
FPC_VERSION  ?= 3.2.2

# Cross-target override. Set CROSS_TARGET to one of:
#
#   aarch64-win64   Windows on ARM64 (Delphi 13 / FPC 3.2+ with the
#                   aarch64-win64 cross-build installed). FPC switches
#                   target via -Twin64 -Paarch64; unit search path
#                   must point at the aarch64-win64 RTL fcl-db /
#                   sqlite / iconvenc ppu files via FPC_UNITS_DIR.
#                   Typical invocation:
#                     make CROSS_TARGET=aarch64-win64 \
#                          FPC_UNITS_DIR=/opt/fpc/units/aarch64-win64 \
#                          FPC='fpc -Twin64 -Paarch64' \
#                          BIN=build/pasclaw-arm64.exe
#
#   x86_64-win64    Windows x64 cross-compile. Set FPC='fpc -Twin64'
#                   and the corresponding unit dir.
#
# When CROSS_TARGET is empty the host-target autodetection below
# (Darwin / Linux × x86_64 / aarch64) wins, same as before.
ifneq ($(CROSS_TARGET),)
  FPC_ARCH ?= $(CROSS_TARGET)
  # Unit directory layout for cross-targets isn't standardised; the
  # caller knows where their cross-build's units live. Require
  # FPC_UNITS_DIR explicitly so the Makefile doesn't blindly hand a
  # wrong path to fpc.
  ifndef FPC_UNITS_DIR
    $(error CROSS_TARGET=$(CROSS_TARGET) requires FPC_UNITS_DIR pointing at the cross-build unit tree)
  endif
  # Lazarus's Masks unit (LAZUTILS_DIR) is platform-portable Pascal,
  # so the host build's lazutils tree works for cross-builds. Empty
  # disables the include.
  LAZUTILS_DIR ?=
else ifeq ($(UNAME_S),Darwin)
  # Homebrew FPC lays units under <prefix>/lib/fpc/<ver>/units/<arch>-darwin/.
  # Prefix is /opt/homebrew on Apple Silicon, /usr/local on Intel.
  ifeq ($(UNAME_M),arm64)
    HOMEBREW_PREFIX ?= /opt/homebrew
    FPC_ARCH        ?= aarch64-darwin
  else
    HOMEBREW_PREFIX ?= /usr/local
    FPC_ARCH        ?= x86_64-darwin
  endif
  FPC_UNITS_DIR ?= $(HOMEBREW_PREFIX)/lib/fpc/$(FPC_VERSION)/units/$(FPC_ARCH)
  LAZUTILS_DIR  ?= $(HOMEBREW_PREFIX)/share/lazarus/components/lazutils
else
  # Debian / Ubuntu default layout (apt: fp-units-db, fp-units-misc, lazarus-src).
  ifeq ($(UNAME_M),aarch64)
    FPC_ARCH ?= aarch64-linux
  else
    FPC_ARCH ?= x86_64-linux
  endif
  FPC_UNITS_DIR ?= /usr/lib/$(UNAME_M)-linux-gnu/fpc/$(FPC_VERSION)/units/$(FPC_ARCH)
  LAZUTILS_DIR  ?= /usr/lib/lazarus/3.0/components/lazutils
endif

FPC      ?= fpc
BUILDDIR ?= build
BIN      ?= $(BUILDDIR)/pasclaw

INDY_DIR     ?= vendor/Indy
INDY_REPO    ?= https://github.com/IndySockets/Indy.git

# ZPAQ vendor: Free Pascal port of libzpaq 7.15 (Xelitan), MIT-licensed.
# Vendored permanently under src/pkg/vendor/zpaq/ (only ~180 KB total)
# so a fresh clone Just Builds without a separate fetch step. The port
# is `{$mode objfpc}` so it's FPC-only -- Delphi builds fall back to the
# legacy blob-tree checkpoints backend.
ZPAQ_DIR  ?= src/pkg/vendor/zpaq
# iconvenc lives in fp-units-misc on Debian; FPC's default config picks it up
# on most distros but not always.
ICONVENC_DIR ?= $(FPC_UNITS_DIR)/iconvenc

# fcl-db + sqlite ship with FPC's standard distribution but live outside the
# default search path (Debian package: fp-units-db). PasClaw.Memory.Index
# pulls TSQLite3Connection / TSQLQuery from these. libsqlite3.{so,dylib} must
# be present at runtime — every modern Linux/Mac has it; Windows builds need
# sqlite3.dll on PATH.
FCLDB_DIR    ?= $(FPC_UNITS_DIR)/fcl-db
SQLITE_DIR   ?= $(FPC_UNITS_DIR)/sqlite

# PasClaw.Tools.FS uses the Masks unit (case-insensitive glob matching for
# fs_grep's `include` filter). On Debian, Masks lives in Lazarus's lazutils
# source tree rather than the fpc rtl. On macOS the Homebrew lazarus formula
# drops it under <prefix>/share/lazarus/components/lazutils. Set
# LAZUTILS_DIR= (empty) to skip the include when Masks is already on the
# default search path.

# PasClaw source dirs.
UNIT_DIRS = \
	src/pkg/cliui \
	src/pkg/utils \
	src/pkg/logger \
	src/pkg/config \
	src/pkg/json \
	src/pkg/providers \
	src/pkg/stream \
	src/pkg/tokenizer \
	src/pkg/tools \
	src/pkg/mcp \
	src/pkg/gateway \
	src/pkg/channels \
	src/pkg/crypto \
	src/pkg/net \
	src/pkg/search \
	src/pkg/cron \
	src/pkg/skills \
	src/pkg/checkpoints \
	src/pkg/condense \
	src/pkg/shell \
	src/pkg/session \
	src/pkg/identity \
	src/pkg/agent \
	src/pkg/memory \
	src/pkg/memory/localvector \
	src/pkg/kb \
	src/pkg/updater \
	src/pkg/membench \
	src/pkg/tui \
	src/pkg/platform \
	src/pkg/hashline \
	src/pkg/component \
	src/pkg/markdown \
	src/pkg/otel \
	src/cmd

# Indy unit + include dirs (only used when building under FPC).
INDY_UNIT_DIRS = \
	$(INDY_DIR)/Lib/Core \
	$(INDY_DIR)/Lib/Protocols \
	$(INDY_DIR)/Lib/System

INDY_INC_DIRS = $(INDY_UNIT_DIRS)

# zpaq vendor unit dir (FPC only; the port is {$mode objfpc} so it won't
# compile under Delphi). PasClaw.Checkpoints.Zpaq wraps it; the wrapper
# gates the `uses ZpaqClasses` import on {$IFDEF FPC} so Delphi builds
# silently fall back to PasClaw.Checkpoints' legacy blob backend.
ZPAQ_UNIT_DIRS = $(ZPAQ_DIR)

# C2W=1 turns on the container2wasm in-browser deployment path: PasClaw's HTTP
# layer routes through the c2w-net-proxy (HTTP_PROXY/HTTPS_PROXY env) and opts
# into Anthropic's browser/CORS mode. Off by default — only set it when
# producing the wasm/browser image. See docs/c2w.md.
C2W ?=
C2W_DEFINE = $(if $(C2W),-dPASCLAW_C2W)

FPCFLAGS = -MDelphi -Sh -O2 -Xs -XX \
	$(C2W_DEFINE) \
	-Fu$(FCLDB_DIR) -Fu$(SQLITE_DIR) \
	$(if $(LAZUTILS_DIR),-Fu$(LAZUTILS_DIR)) \
	$(foreach d,$(UNIT_DIRS),-Fu$(d)) \
	$(foreach d,$(INDY_UNIT_DIRS),-Fu$(d)) \
	$(foreach d,$(INDY_INC_DIRS),-Fi$(d)) \
	$(foreach d,$(ZPAQ_UNIT_DIRS),-Fu$(d)) \
	-Fu$(ICONVENC_DIR) \
	-FE$(BUILDDIR) \
	-FU$(BUILDDIR)/lib

VERSION ?= $(shell git describe --tags --always 2>/dev/null || echo dev)

.PHONY: all clean run test smoke test-hashline test-toolview test-anthropic-server-tools test-openai-server-tools test-tool-choice test-responses-tool-choice test-println-helper test-utf8-codepage-tag test-json-utf8-roundtrip test-model-discovery test-cron-tool test-provider-catalog test-output-cache test-working-state test-ansi-width test-shell-filters test-learn test-stream-reliability test-kb-index test-kb-pdf test-agents-md test-checkpoints-zpaq test-orient-preamble test-component-config test-autoroute-apply test-fallback-models test-memory-distill test-memory-facts test-memory-autodistill test-checkpoints-redo test-build-roundtrip test-delphi-build print-version get-indy webui-res browser

all: $(WEBUI_RES) $(BIN)

# Compile the HTML resource into a .res that {$R webui.res} embeds.
WEBUI_RES = src/pkg/gateway/webui.res

webui-res: $(WEBUI_RES)

$(WEBUI_RES): src/pkg/gateway/webui.rc src/pkg/gateway/webui.html
	cd src/pkg/gateway && fpcres -of res -o webui.res webui.rc
	@# {$R webui.res} is baked into PasClaw.Gateway.WebUI's object at unit-
	@# compile time. An incremental build that only regenerates the .res
	@# leaves FPC's cached unit untouched, shipping stale HTML/JS. Touch the
	@# unit so it -- and the embedded resource -- always recompiles.
	@touch src/pkg/gateway/PasClaw.Gateway.WebUI.pas

$(BIN): $(WEBUI_RES) | $(BUILDDIR) $(INDY_DIR)
	@mkdir -p $(BUILDDIR)/lib
	PASCLAW_VERSION='$(VERSION)' $(FPC) $(FPCFLAGS) src/pasclaw/PasClaw.dpr -o$(BIN)

$(INDY_DIR):
	@echo "Indy not found at $(INDY_DIR); run 'make get-indy' to clone it."
	@false

get-indy:
	@if [ ! -d $(INDY_DIR) ]; then \
	  mkdir -p $(dir $(INDY_DIR)); \
	  echo "Cloning Indy into $(INDY_DIR)..."; \
	  git clone --depth 1 $(INDY_REPO) $(INDY_DIR); \
	else \
	  echo "Indy already present at $(INDY_DIR)"; \
	fi

$(BUILDDIR):
	@mkdir -p $(BUILDDIR)

clean:
	rm -rf $(BUILDDIR)

run: $(BIN)
	@$(BIN)

# One command to produce the static in-browser bundle under browser/site/:
# builds the pasclaw image with C2W=1, converts it with container2wasm
# (c2w --to-js), and assembles the webpack harness + fetch network stack.
# Needs docker + node/npm (the c2w CLI is auto-fetched). See browser/README.md.
browser:
	./browser/build.sh

print-version:
	@echo $(VERSION)

# Quick smoke test that every top-level command at least prints help/status
# without crashing. Useful when adding subcommands.
smoke: $(BIN)
	@PASCLAW_HOME=$$(mktemp -d) ; export PASCLAW_HOME ; \
	echo "smoke: home=$$PASCLAW_HOME" ; \
	NO_COLOR=1 $(BIN) version                  >/dev/null && echo "  version   OK" ; \
	NO_COLOR=1 $(BIN) --help                   >/dev/null && echo "  help      OK" ; \
	NO_COLOR=1 $(BIN) config reset             >/dev/null && echo "  config    OK" ; \
	NO_COLOR=1 $(BIN) status                   >/dev/null && echo "  status    OK" ; \
	NO_COLOR=1 $(BIN) mcp list                 >/dev/null && echo "  mcp       OK" ; \
	NO_COLOR=1 $(BIN) cron list                >/dev/null && echo "  cron      OK" ; \
	NO_COLOR=1 $(BIN) skills list              >/dev/null && echo "  skills    OK" ; \
	NO_COLOR=1 $(BIN) model show               >/dev/null && echo "  model     OK" ; \
	NO_COLOR=1 $(BIN) migrate                  >/dev/null && echo "  migrate   OK" ; \
	NO_COLOR=1 $(BIN) update --check           >/dev/null && echo "  update    OK" ; \
	NO_COLOR=1 $(BIN) membench --records 100   >/dev/null && echo "  membench  OK" ; \
	NO_COLOR=1 $(BIN) learn                    >/dev/null && echo "  learn     OK" ; \
	NO_COLOR=1 $(BIN) kb status                >/dev/null && echo "  kb        OK" ; \
	echo "smoke: all commands OK"

test-hashline: $(WEBUI_RES) | $(BUILDDIR) $(INDY_DIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/hashline_patch_tests.pas -o$(BUILDDIR)/hashline_patch_tests
	@$(BUILDDIR)/hashline_patch_tests

# Pure tool-activity formatter tests. No Indy/webui resource needed — the
# ToolView unit only depends on PasClaw.JSON and PasClaw.Hashline.
test-toolview: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/toolview_tests.pas -o$(BUILDDIR)/toolview_tests
	@$(BUILDDIR)/toolview_tests

# Anthropic provider — server-side web_search / web_fetch wire shape.
test-anthropic-server-tools: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/anthropic_server_tools_tests.pas -o$(BUILDDIR)/anthropic_server_tools_tests
	@$(BUILDDIR)/anthropic_server_tools_tests

# OpenAI provider — server-side web_search_options wire shape.
test-openai-server-tools: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/openai_server_tools_tests.pas -o$(BUILDDIR)/openai_server_tools_tests
	@$(BUILDDIR)/openai_server_tools_tests

# tool_choice keyword + force-a-specific-tool forms (OpenAI + Anthropic).
test-tool-choice: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/tool_choice_tests.pas -o$(BUILDDIR)/tool_choice_tests
	@$(BUILDDIR)/tool_choice_tests

# /v1/responses tool_choice parse (flat top-level name + nested function.name).
test-responses-tool-choice: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/responses_tool_choice_tests.pas -o$(BUILDDIR)/responses_tool_choice_tests
	@$(BUILDDIR)/responses_tool_choice_tests

# PasClaw.CliUI Print/PrintLn helpers — link + UTF-8 byte round-trip.
test-println-helper: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/println_helper_tests.pas -o$(BUILDDIR)/println_helper_tests
	@$(BUILDDIR)/println_helper_tests

# PasClaw.Utils.TagUTF8 — codepage retag at byte-stream boundaries.
test-utf8-codepage-tag: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/utf8_codepage_tag_tests.pas -o$(BUILDDIR)/utf8_codepage_tag_tests
	@$(BUILDDIR)/utf8_codepage_tag_tests

# Gemini provider — JSON Schema scrub for additionalProperties etc.
test-gemini-schema-strip: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/gemini_schema_strip_tests.pas -o$(BUILDDIR)/gemini_schema_strip_tests
	@$(BUILDDIR)/gemini_schema_strip_tests

# Markdown -> ANSI terminal renderer.
test-markdown-render: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/markdown_render_tests.pas -o$(BUILDDIR)/markdown_render_tests
	@$(BUILDDIR)/markdown_render_tests

# PasClaw.JSON — UTF-8 byte preservation through Parse + GetStr/ItemStr.
test-json-utf8-roundtrip: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/json_utf8_roundtrip_tests.pas -o$(BUILDDIR)/json_utf8_roundtrip_tests
	@$(BUILDDIR)/json_utf8_roundtrip_tests

# PasClaw.Providers.Models — /v1/models cache schema round-trip + helpers.
test-model-discovery: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/model_discovery_tests.pas -o$(BUILDDIR)/model_discovery_tests
	@$(BUILDDIR)/model_discovery_tests

# Model-callable cron tool: config.json crons[] add/list/remove + validation.
test-cron-tool: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/cron_tool_tests.pas -o$(BUILDDIR)/cron_tool_tests
	@PASCLAW_HOME=$(BUILDDIR)/cron-tool-test-home $(BUILDDIR)/cron_tool_tests

# Provider catalog rows + ChatPath override (Perplexity uses /chat/completions).
test-provider-catalog: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/provider_catalog_tests.pas -o$(BUILDDIR)/provider_catalog_tests
	@$(BUILDDIR)/provider_catalog_tests

# PasClaw.Tools.OutputCache — truncation thresholds + handle round-trip.
test-output-cache: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/output_cache_tests.pas -o$(BUILDDIR)/output_cache_tests
	@$(BUILDDIR)/output_cache_tests

# PasClaw.Session.Store — working-state extraction + format + round-trip.
test-working-state: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/working_state_tests.pas -o$(BUILDDIR)/working_state_tests
	@$(BUILDDIR)/working_state_tests

# PasClaw.Utils — ANSI-aware width helpers (VisibleLength / PadVisibleRight /
# TruncateVisible). The TUI chat pane relies on these to render markdown
# without breaking the wrap math.
test-ansi-width: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/ansi_width_tests.pas -o$(BUILDDIR)/ansi_width_tests
	@$(BUILDDIR)/ansi_width_tests

# PasClaw.Tools.Shell.Filters — per-command output condensers with tee-on-failure.
test-shell-filters: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/shell_filters_tests.pas -o$(BUILDDIR)/shell_filters_tests
	@$(BUILDDIR)/shell_filters_tests

# PasClaw.Cmd.Learn — session-failure normaliser + LooksLikeFailure pre-filter.
test-learn: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/learn_tests.pas -o$(BUILDDIR)/learn_tests
	@$(BUILDDIR)/learn_tests

# PasClaw.Cmd.Export — canonical body + format-specific framing for AGENTS.md /
# CLAUDE.md / Cursor / Gemini / Zed adapter exports. PASCLAW_HOME is pointed at
# a build-dir scratchspace so the test fixtures don't pollute the operator's
# real ~/.pasclaw — see export_tests.pas FixtureHome for the contract.
test-export: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/export_tests.pas -o$(BUILDDIR)/export_tests
	@PASCLAW_HOME=$(BUILDDIR)/export-test-home $(BUILDDIR)/export_tests

# PasClaw.Tools.ExecuteCode — bash / PowerShell script runner. End-to-end run
# spawns bash on this Linux host; the BuildArgv tests pin the PowerShell shape
# without needing pwsh installed.
test-execute-code: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/execute_code_tests.pas -o$(BUILDDIR)/execute_code_tests
	@PASCLAW_HOME=$(BUILDDIR)/execute-code-test-home $(BUILDDIR)/execute_code_tests

# Auto-router heuristic + RouteProvider gating contract.
test-auto-router: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/auto_router_tests.pas -o$(BUILDDIR)/auto_router_tests
	@$(BUILDDIR)/auto_router_tests

# Per-endpoint stats buckets the gateway writes for stateless requests.
# PASCLAW_HOME isolated so the synthetic bucket files don't pollute the
# operator's real ~/.pasclaw.
test-gateway-stats-buckets: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/gateway_stats_buckets_tests.pas -o$(BUILDDIR)/gateway_stats_buckets_tests
	@PASCLAW_HOME=$(BUILDDIR)/gateway-stats-buckets-test-home $(BUILDDIR)/gateway_stats_buckets_tests

# Per-session stats schema + accumulator + config flag round-trip.
# PASCLAW_HOME isolated so test sessions don't pollute the operator's
# real ~/.pasclaw/workspace/sessions/.
test-session-stats: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/session_stats_tests.pas -o$(BUILDDIR)/session_stats_tests
	@PASCLAW_HOME=$(BUILDDIR)/session-stats-test-home $(BUILDDIR)/session_stats_tests

# ListSessions bucket-filter contract -- default call hides gateway
# stats buckets; /v1/stats opts back in via ListSessions(True).
test-session-list-filter: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/session_list_filter_tests.pas -o$(BUILDDIR)/session_list_filter_tests
	@PASCLAW_HOME=$(BUILDDIR)/session-list-filter-test-home $(BUILDDIR)/session_list_filter_tests

# Editable /v1/config secret-preservation merge (web UI Settings). Client
# can set secrets but never views them: masked fields are restored from the
# current config on write.
test-config-secret-merge: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/config_secret_merge_tests.pas -o$(BUILDDIR)/config_secret_merge_tests
	@$(BUILDDIR)/config_secret_merge_tests

# Durable /v1/sessions data layer -- ChatBodyToMessages parse + the
# POST/PUT/GET/DELETE round-trip via TSession. PASCLAW_HOME isolated so
# the fixtures don't touch the operator's real session store.
test-session-endpoints: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/session_endpoint_tests.pas -o$(BUILDDIR)/session_endpoint_tests
	@PASCLAW_HOME=$(BUILDDIR)/session-endpoints-test-home $(BUILDDIR)/session_endpoint_tests

# Skill install target classification + safe-name guard (web UI manage).
test-skills-install: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/skills_install_tests.pas -o$(BUILDDIR)/skills_install_tests
	@$(BUILDDIR)/skills_install_tests

# Self-improving skills: skill_manage staging/guard + pending approval flow.
test-self-improving-skills: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/self_improving_skills_tests.pas -o$(BUILDDIR)/self_improving_skills_tests
	@$(BUILDDIR)/self_improving_skills_tests

# Loop-shaping defaults + JSON round-trip (PR #289).
test-loop-shaping-defaults: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/loop_shaping_defaults_tests.pas -o$(BUILDDIR)/loop_shaping_defaults_tests
	@$(BUILDDIR)/loop_shaping_defaults_tests

# Max-iteration cutoff notice (FormatMaxIterNotice) surfaced in CLI/TUI/gateway.
test-max-iter-notice: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/max_iter_notice_tests.pas -o$(BUILDDIR)/max_iter_notice_tests
	@$(BUILDDIR)/max_iter_notice_tests

# Plan / Build mode plumbing + dispatch gate (PR #290).
test-plan-build-mode: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/plan_build_mode_tests.pas -o$(BUILDDIR)/plan_build_mode_tests
	@$(BUILDDIR)/plan_build_mode_tests

# Configuration profiles -- builtins, _inherits, user shadow, LoadConfig merge (PR #291).
# Uses PASCLAW_HOME pointing at a temp dir so it never touches the user's real config.
test-config-profile: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/config_profile_tests.pas -o$(BUILDDIR)/config_profile_tests
	@PASCLAW_HOME=$$(mktemp -d) ; \
	  trap "rm -rf $$PASCLAW_HOME" EXIT ; \
	  PASCLAW_HOME=$$PASCLAW_HOME $(BUILDDIR)/config_profile_tests

# Active Plan section -- pins BuildActivePlanSection's gating cases
# (NoPlan / pmPlan / missing) and the happy-path PLAN.md injection.
test-active-plan-section: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/active_plan_section_tests.pas -o$(BUILDDIR)/active_plan_section_tests
	@PASCLAW_HOME=$$(mktemp -d) ; \
	  trap "rm -rf $$PASCLAW_HOME" EXIT ; \
	  PASCLAW_HOME=$$PASCLAW_HOME $(BUILDDIR)/active_plan_section_tests

# Relay queue + provider envelope tests. Hermetic -- in-process
# synchronisation only; no HTTP, no real workers.
test-relay-queue: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/relay_queue_tests.pas -o$(BUILDDIR)/relay_queue_tests
	@$(BUILDDIR)/relay_queue_tests

# PasClaw.MCP.Disclosure -- Hermes-style progressive disclosure + Claude
# Code-style tool_search for MCP tools. Hermetic: synthetic TTool records
# only, no actual MCP server started.
test-mcp-disclosure: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/mcp_disclosure_tests.pas -o$(BUILDDIR)/mcp_disclosure_tests
	@PASCLAW_HOME=$$(mktemp -d) ; \
	  trap "rm -rf $$PASCLAW_HOME" EXIT ; \
	  PASCLAW_HOME=$$PASCLAW_HOME $(BUILDDIR)/mcp_disclosure_tests

# Tool-RPC server: the in-process callback the execute_code script uses
# to reach back into the parent's tool registry. PASCLAW_HOME isolated so
# the info file lands in a scratch dir.
test-tool-rpc: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/tool_rpc_tests.pas -o$(BUILDDIR)/tool_rpc_tests
	@PASCLAW_HOME=$(BUILDDIR)/tool-rpc-test-home $(BUILDDIR)/tool_rpc_tests

# session_search FTS5 index over saved transcripts. PASCLAW_HOME isolated so
# the synthetic sessions + .search.db don't touch the operator's real store.
# Needs libsqlite3 at runtime (same as the memory_search tests).
# Background subagents: coordinator + four tool handlers + drain hook.
# Uses a fake echo provider so the test doesn't need a real model.
test-subagent-bg: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/subagent_bg_tests.pas -o$(BUILDDIR)/subagent_bg_tests
	@$(BUILDDIR)/subagent_bg_tests

# Subagents on by default: built-in general-purpose agent + '*' tool inheritance.
test-subagent-default: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/subagent_default_tests.pas -o$(BUILDDIR)/subagent_default_tests
	@$(BUILDDIR)/subagent_default_tests

# Stream reliability: empty-turn retry, idle-timeout, tool-call repair.
# Uses a scripted fake provider; one test sleeps a few seconds to verify
# the idle-timeout watcher.
test-stream-reliability: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/stream_reliability_tests.pas -o$(BUILDDIR)/stream_reliability_tests
	@$(BUILDDIR)/stream_reliability_tests

# MCP server core: JSON-RPC dispatch over a synthetic TToolRegistry.
# Covers tools/list filtering, tools/call dispatch, allowlist, error shapes.
test-mcp-server: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/mcp_server_tests.pas -o$(BUILDDIR)/mcp_server_tests
	@$(BUILDDIR)/mcp_server_tests

# Checkpoints + /undo: file-edit rollback hooked into fs_write /
# fs_edit_hashline. Pure on-disk snapshots; no model, no agent loop.
test-checkpoints: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/checkpoints_tests.pas -o$(BUILDDIR)/checkpoints_tests
	@$(BUILDDIR)/checkpoints_tests

# Distilled-memory Phase 1: transcript -> normalised TFact[] via a
# scripted provider (no model, no DB). Pins the parse/normalise/dedup
# contract of PasClaw.Memory.Distill.
test-memory-distill: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/memory_distill_tests.pas -o$(BUILDDIR)/memory_distill_tests
	@$(BUILDDIR)/memory_distill_tests

# Distilled-memory Phase 2: SQLite fact store. Real temp DB; pins the
# add / active-excludes-expired / supersede / delete / durability contract
# of PasClaw.Memory.Facts.
test-memory-facts: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/memory_facts_tests.pas -o$(BUILDDIR)/memory_facts_tests
	@$(BUILDDIR)/memory_facts_tests

# Distilled-memory Phase 3: per-turn auto-distill windowing
# (BuildRecentTranscript). Pure logic; the thread/store glue is covered
# by the distill + facts suites.
test-memory-autodistill: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/memory_autodistill_tests.pas -o$(BUILDDIR)/memory_autodistill_tests
	@$(BUILDDIR)/memory_autodistill_tests

# JSON-aware condenser: pure string-in / string-out, no model. Pins
# the collapse-arrays / ellipsize-strings contract that
# PasClaw.Condense.JSON applies to tool output before it reaches the
# byte-budget truncate stage.
test-condense-json: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/condense_json_tests.pas -o$(BUILDDIR)/condense_json_tests
	@$(BUILDDIR)/condense_json_tests

# Promptware defense: injection-pattern scan at the three indirect-
# input chokepoints (tool output / recalled memory / skill
# descriptions). Pure string scan, no model.
test-promptware: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/promptware_tests.pas -o$(BUILDDIR)/promptware_tests
	@$(BUILDDIR)/promptware_tests

# Task-aware orientation: MEMORY.md section slicing/scoring against a
# task hint (PasClaw.Agent.Orient). Pure string functions, no model.
test-orient: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/orient_tests.pas -o$(BUILDDIR)/orient_tests
	@$(BUILDDIR)/orient_tests

# Code-driven component config surface (TPasClawAgent.Config / LoadConfigFromDisk).
# Compiles into its own clean unit dir: TPasClawAgent pulls in the
# PasClaw.Agent <-> PasClaw.Agent.Subagent circular-interface pair, which only
# resolves from scratch -- mixing with the main binary's cached .ppu in
# build/lib makes FPC half-recompile and hit the cycle.
test-component-config: $(BIN) | $(BUILDDIR) $(INDY_DIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) \
	  src/tests/component_config_tests.pas -o$(BUILDDIR)/component_config_tests
	@$(BUILDDIR)/component_config_tests

# Auto-router application helper (centralised across CLI/TUI/gateway/component).
test-autoroute-apply: $(BIN) | $(BUILDDIR) $(INDY_DIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) \
	  src/tests/autoroute_apply_tests.pas -o$(BUILDDIR)/autoroute_apply_tests
	@$(BUILDDIR)/autoroute_apply_tests

# Per-fallback model override (config round-trip + lockstep ResolveFallbacks).
test-fallback-models: $(BIN) | $(BUILDDIR) $(INDY_DIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) \
	  src/tests/fallback_models_tests.pas -o$(BUILDDIR)/fallback_models_tests
	@$(BUILDDIR)/fallback_models_tests

# Orient launch-preamble section (opt-in "announce a plan before tools").
test-orient-preamble: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/orient_preamble_tests.pas -o$(BUILDDIR)/orient_preamble_tests
	@$(BUILDDIR)/orient_preamble_tests

# Reversible condensation (CCR): when JSON/shell condensers shrink output,
# stash the original under a tool_output_get handle. PasClaw.Tools.OutputCache.
test-condense-reversible: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/condense_reversible_tests.pas -o$(BUILDDIR)/condense_reversible_tests
	@$(BUILDDIR)/condense_reversible_tests

# Heartbeat daemon: proactive periodic wake-up. Scripted provider fakes the model.
test-heartbeat: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/heartbeat_tests.pas -o$(BUILDDIR)/heartbeat_tests
	@$(BUILDDIR)/heartbeat_tests

# Shell backend abstraction (PasClaw.Shell.Backend + local impl + recording mock).
# Docker is exercised by a separate harness that requires Docker on the box.
test-shell-backend: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/shell_backend_tests.pas -o$(BUILDDIR)/shell_backend_tests
	@$(BUILDDIR)/shell_backend_tests

# Env-var injection into spawned children (RunOneShotWithEnv / Spawn ExtraEnv).
test-env-inject: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/env_inject_tests.pas -o$(BUILDDIR)/env_inject_tests
	@$(BUILDDIR)/env_inject_tests

# RunArgvCapture TimeoutMs cap -- proves a wedged child (e.g. a hung
# `docker info`) is killed at the deadline instead of hanging the caller.
test-run-timeout: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/run_timeout_tests.pas -o$(BUILDDIR)/run_timeout_tests
	@$(BUILDDIR)/run_timeout_tests

test-delphi-build: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/delphi_build_tests.pas -o$(BUILDDIR)/delphi_build_tests
	@$(BUILDDIR)/delphi_build_tests

# Shell output decode (PasClaw.Platform.DecodeShellOutputBytes) -- the OEM
# codepage fix for cmd.exe stdout. Exercises the explicit-codepage path so
# tests pin Windows behaviour without needing Windows itself.
test-shell-output-decode: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/shell_output_decode_tests.pas -o$(BUILDDIR)/shell_output_decode_tests
	@$(BUILDDIR)/shell_output_decode_tests

# Goals runner: the auto-continue Ralph loop. Scripted fake provider
# returns MET / CONTINUE / FAILED verdicts; pins parser + budget +
# abort + judge-outage semantics. No real model.
test-goals-runner: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/goals_runner_tests.pas -o$(BUILDDIR)/goals_runner_tests
	@$(BUILDDIR)/goals_runner_tests

# MCP hub projection: transport routing for pasclaw.dev catalog entries
# (http / sse / streamable-http / stdio). Pure JSON-in / record-out;
# no network. Pins the regression that "10 entries skipped -- non-HTTP
# transports not supported yet" actually meant "SSE-tagged HTTP
# endpoints our client already speaks were being dropped".
test-mcp-hub-projection: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/mcp_hub_projection_tests.pas -o$(BUILDDIR)/mcp_hub_projection_tests
	@$(BUILDDIR)/mcp_hub_projection_tests

test-session-search: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/session_search_tests.pas -o$(BUILDDIR)/session_search_tests
	@PASCLAW_HOME=$(BUILDDIR)/session-search-test-home $(BUILDDIR)/session_search_tests

# Knowledgebase — pure helpers (chunker, extension filter, binary sniff,
# HTML strip). The SQLite paths are covered by `kb status` in smoke.
test-kb-index: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/kb_index_tests.pas -o$(BUILDDIR)/kb_index_tests
	@$(BUILDDIR)/kb_index_tests

# PDF text extraction: builds a minimal uncompressed PDF in a temp file,
# runs it through PasClaw.KB.PDF.ExtractPDFText, and asserts the Tj
# content + Err strings on missing-file / non-PDF / empty-text cases.
# The Flate / /ToUnicode paths are covered by real-world PDFs in smoke.
test-kb-pdf: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/kb_pdf_extract_tests.pas -o$(BUILDDIR)/kb_pdf_extract_tests
	@$(BUILDDIR)/kb_pdf_extract_tests

# AGENTS.md project rules ingest: FindProjectAgentsMd walks up to git
# root, BuildProjectRulesSection injects/truncates, plus Cmd.Init's
# digest builder + markdown unfence helpers. Temp-dir fixtures, no
# network.
test-agents-md: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/agents_md_tests.pas -o$(BUILDDIR)/agents_md_tests
	@$(BUILDDIR)/agents_md_tests

# Checkpoints zpaq backend: round-trip Append/List/Extract via the
# vendored Free Pascal libzpaq port. When vendor/zpaq is missing the
# test prints "skipped" and exits 0 -- run `make get-zpaq` first to
# enable the assertions.
test-checkpoints-zpaq: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/checkpoints_zpaq_tests.pas -o$(BUILDDIR)/checkpoints_zpaq_tests
	@$(BUILDDIR)/checkpoints_zpaq_tests

# `pasclaw build` workspace.zip handshake: round-trips PackDirToZip +
# ExtractZipToDir over text + binary + nested + exclusion-denylist
# cases. The agent-loop / provider half of `pasclaw build` is covered
# by the smoke target on a temp PASCLAW_HOME with a real provider.
test-build-roundtrip: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/build_workspace_roundtrip_tests.pas -o$(BUILDDIR)/build_workspace_roundtrip_tests
	@$(BUILDDIR)/build_workspace_roundtrip_tests

# End-to-end undo/redo via the zpaq backend: spins a temp PASCLAW_HOME,
# drives BeginTurn / SnapshotBeforeWrite / UndoTurns / RedoTurns, and
# asserts the file contents and redo-stack semantics across the
# happy path + the "new-write invalidates redo" branch.
test-checkpoints-redo: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/checkpoints_redo_tests.pas -o$(BUILDDIR)/checkpoints_redo_tests
	@$(BUILDDIR)/checkpoints_redo_tests

# fs_grep ripgrep-tier1-4 optimisations: defer ComputeFileHash until first
# match (tier 1), skip blocked dir names like .git/node_modules/target
# (tier 2), skip binary files by NUL-byte sniff in the first kilobyte
# (tier 3), and skip files larger than max_file_bytes (default 10 MiB,
# tier 4). Pure-Pascal: spins temp-dir fixtures, calls Tool_FSGrep
# through the registered handler, asserts on observable output.
test-fs-grep-tier1-4: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/fs_grep_tier1_4_tests.pas -o$(BUILDDIR)/fs_grep_tier1_4_tests
	@$(BUILDDIR)/fs_grep_tier1_4_tests

# Verb_noun file-tool rename + hidden aliases + append_file + edit_file
# string-replacement mode.
test-fs-tool-naming: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/fs_tool_naming_tests.pas -o$(BUILDDIR)/fs_tool_naming_tests
	@$(BUILDDIR)/fs_tool_naming_tests

# Workspace-relative path resolution: fs tools resolve relative paths against
# the configured workspace, not the launch CWD.
test-workspace-paths: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/workspace_paths_tests.pas -o$(BUILDDIR)/workspace_paths_tests
	@$(BUILDDIR)/workspace_paths_tests

# Progress ledger: goal anchor + todo checklist fold, nothing-written nudge,
# max-iter resume summary (A1/A2).
test-progress-ledger: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/progress_ledger_tests.pas -o$(BUILDDIR)/progress_ledger_tests
	@$(BUILDDIR)/progress_ledger_tests

# Deterministic agent-loop harness bench (bench/agentloop) -- pure FPC, no
# external runtime. Spawns the built binary, plays the scripted model over
# the relay, asserts on what the loop did. Not part of `make test` (binds a
# port + spawns a server); run when touching ToolLoop / Stream.Reliability /
# the gateway loop paths.
bench-agentloop: $(BIN)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) bench/agentloop/agentloop_bench.pas -o$(BUILDDIR)/agentloop_bench
	@$(BUILDDIR)/agentloop_bench

# Logger level suppression: pins the contract PasClaw.dpr's
# IsQuietInvocation branch depends on (SetLogLevel(llError) drops
# Debug/Info/Warn while keeping Error). Without this regression
# test, a future Emit refactor that moves the level gate could
# silently re-enable [info] noise under `pasclaw agent --quiet`.
test-logger-level-quiet: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/logger_level_quiet_tests.pas -o$(BUILDDIR)/logger_level_quiet_tests
	@$(BUILDDIR)/logger_level_quiet_tests

# Gateway bearer-token middleware: pins the decision function the
# inbound /v1/* gate calls. No Indy server, no provider stack --
# tests exercise PasClaw.Gateway.Auth's helpers directly, so the
# contract (unauthenticated when empty, exempt routes, header
# beats query, constant-time compare, case-insensitive Bearer)
# is locked in even if OnCommandGet's wiring is refactored.
test-gateway-token: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/gateway_token_tests.pas -o$(BUILDDIR)/gateway_token_tests
	@$(BUILDDIR)/gateway_token_tests
	@PASCLAW_GATEWAY_TOKEN=sk-pasclaw-env-test-aaaaaaaa $(BUILDDIR)/gateway_token_tests --env-mode
	@OPENCLAW_GATEWAY_TOKEN=sk-openclaw-env-test-bbbbbb $(BUILDDIR)/gateway_token_tests --env-mode

# /v1/fs operator-browse secret gate: config.json (and .env / TLS keys)
# must never list or read through HandleFSList/HandleFSRead. PASCLAW_CONFIG
# points at a non-config.json name so the exact-resolved-path branch runs.
test-fs-secret-gate: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/fs_secret_gate_tests.pas -o$(BUILDDIR)/fs_secret_gate_tests
	@PASCLAW_CONFIG=$(BUILDDIR)/fs-gate-test.cfg $(BUILDDIR)/fs_secret_gate_tests

# ${VAR_NAME} env-substitution in config.json. Pins the pattern
# (uppercase only, [A-Z_][A-Z0-9_]*), the splice + JSON-escape, the
# unset-env "leave the literal in place" diagnostic behaviour, and
# the round-trip through TConfig.FromJSON when a marker is
# unresolved. --env-mode pass inherits fixture vars from this rule
# to exercise the actual splicing path FPC's startup-snapshotted
# envp would otherwise block.
test-config-env-subst: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/config_env_subst_tests.pas -o$(BUILDDIR)/config_env_subst_tests
	@$(BUILDDIR)/config_env_subst_tests
	@PASCLAW_CONFIG_TEST_VAR_A4F9='hello-from-env-aaaaaaaa' \
	 PASCLAW_CONFIG_TRICKY_VAR_A4F9='hello"world\backslash' \
	 $(BUILDDIR)/config_env_subst_tests --env-mode

# OpenTelemetry traces (OTLP/HTTP+JSON). Pins span hierarchy,
# attribute names (gen_ai.* semantic conventions), W3C traceparent
# propagation in/out, sampling toggle, env-var override, JSON
# escaping. Uses the test-export transport seam in PasClaw.Otel --
# no real collector spun up, just captures the POST body and asserts
# on its shape.
test-otel: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/otel_tests.pas -o$(BUILDDIR)/otel_tests
	@$(BUILDDIR)/otel_tests
	@OTEL_EXPORTER_OTLP_ENDPOINT=http://env-host:4318 $(BUILDDIR)/otel_tests --env-mode

# fs_grep ripgrep-tier5-6 optimisations: byte walker replacing the
# TStringList/StringReplace/per-line LowerCase path (tier 5), and
# Boyer-Moore-Horspool substring search replacing Pos() (tier 6).
# Output-equivalent rewrite: tests pin line numbers, CRLF handling,
# no-trailing-newline, multi-match-per-file, case-insensitive,
# overlapping/partial/embedded patterns, m=1 and m>n edge cases.
test-fs-grep-tier5-6: | $(BUILDDIR)
	@mkdir -p $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) src/tests/fs_grep_tier5_6_tests.pas -o$(BUILDDIR)/fs_grep_tier5_6_tests
	@$(BUILDDIR)/fs_grep_tier5_6_tests

test: smoke test-hashline test-toolview test-anthropic-server-tools test-openai-server-tools test-tool-choice test-responses-tool-choice test-println-helper test-utf8-codepage-tag test-gemini-schema-strip test-markdown-render test-json-utf8-roundtrip test-model-discovery test-cron-tool test-provider-catalog test-output-cache test-working-state test-ansi-width test-shell-filters test-learn test-export test-execute-code test-session-stats test-auto-router test-gateway-stats-buckets test-session-list-filter test-session-endpoints test-config-secret-merge test-skills-install test-self-improving-skills test-loop-shaping-defaults test-max-iter-notice test-max-iter-notice test-plan-build-mode test-config-profile test-tool-rpc test-session-search test-subagent-bg test-subagent-default test-stream-reliability test-mcp-server test-mcp-hub-projection test-checkpoints test-condense-json test-goals-runner test-kb-index test-kb-pdf test-agents-md test-checkpoints-zpaq test-orient-preamble test-component-config test-autoroute-apply test-fallback-models test-memory-distill test-memory-facts test-memory-autodistill test-checkpoints-redo test-build-roundtrip test-promptware test-orient test-condense-reversible test-heartbeat test-shell-backend test-env-inject test-run-timeout test-shell-output-decode test-fs-grep-tier1-4 test-fs-grep-tier5-6 test-fs-tool-naming test-workspace-paths test-progress-ledger test-otel test-logger-level-quiet test-gateway-token test-fs-secret-gate test-config-env-subst test-delphi-build
