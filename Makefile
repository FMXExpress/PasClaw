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
	src/pkg/session \
	src/pkg/identity \
	src/pkg/agent \
	src/pkg/memory \
	src/pkg/memory/localvector \
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

FPCFLAGS = -MDelphi -Sh -O2 -Xs -XX \
	-Fu$(FCLDB_DIR) -Fu$(SQLITE_DIR) \
	$(if $(LAZUTILS_DIR),-Fu$(LAZUTILS_DIR)) \
	$(foreach d,$(UNIT_DIRS),-Fu$(d)) \
	$(foreach d,$(INDY_UNIT_DIRS),-Fu$(d)) \
	$(foreach d,$(INDY_INC_DIRS),-Fi$(d)) \
	-Fu$(ICONVENC_DIR) \
	-FE$(BUILDDIR) \
	-FU$(BUILDDIR)/lib

VERSION ?= $(shell git describe --tags --always 2>/dev/null || echo dev)

.PHONY: all clean run test smoke test-hashline test-toolview test-anthropic-server-tools test-openai-server-tools test-println-helper test-utf8-codepage-tag test-json-utf8-roundtrip test-model-discovery print-version get-indy webui-res

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

test: smoke test-hashline test-toolview test-anthropic-server-tools test-openai-server-tools test-println-helper test-utf8-codepage-tag test-gemini-schema-strip test-markdown-render test-json-utf8-roundtrip test-model-discovery
