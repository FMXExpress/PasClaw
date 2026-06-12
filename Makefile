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
	src/cmd

# Indy unit + include dirs (only used when building under FPC).
INDY_UNIT_DIRS = \
	$(INDY_DIR)/Lib/Core \
	$(INDY_DIR)/Lib/Protocols \
	$(INDY_DIR)/Lib/System

INDY_INC_DIRS = $(INDY_UNIT_DIRS)

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
	-Fu$(ICONVENC_DIR) \
	-FE$(BUILDDIR) \
	-FU$(BUILDDIR)/lib

VERSION ?= $(shell git describe --tags --always 2>/dev/null || echo dev)

.PHONY: all clean run test smoke test-hashline test-toolview test-anthropic-server-tools test-openai-server-tools test-println-helper test-utf8-codepage-tag test-json-utf8-roundtrip test-model-discovery test-output-cache test-working-state test-ansi-width test-shell-filters test-learn test-stream-reliability test-kb-index print-version get-indy webui-res browser

all: $(WEBUI_RES) $(BIN)

# Compile the HTML resource into a .res that {$R webui.res} embeds.
WEBUI_RES = src/pkg/gateway/webui.res

webui-res: $(WEBUI_RES)

$(WEBUI_RES): src/pkg/gateway/webui.rc src/pkg/gateway/webui.html
	cd src/pkg/gateway && fpcres -of res -o webui.res webui.rc

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

test: smoke test-hashline test-toolview test-anthropic-server-tools test-openai-server-tools test-println-helper test-utf8-codepage-tag test-gemini-schema-strip test-markdown-render test-json-utf8-roundtrip test-model-discovery test-output-cache test-working-state test-ansi-width test-shell-filters test-learn test-export test-execute-code test-session-stats test-auto-router test-gateway-stats-buckets test-session-list-filter test-tool-rpc test-session-search test-subagent-bg test-stream-reliability test-mcp-server test-mcp-hub-projection test-checkpoints test-condense-json test-goals-runner test-kb-index test-promptware test-orient test-condense-reversible test-heartbeat test-shell-backend test-shell-output-decode test-fs-grep-tier1-4 test-fs-grep-tier5-6
