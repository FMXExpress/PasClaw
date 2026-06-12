# Sample build: standalone FPC binaries that embed PasClaw.
#
# Three binaries from one Makefile:
#
#   SampleConsole — TPasClawAgent, legacy property-driven API
#                   (PC.Model := ...; PC.Chat(prompt, reply, err))
#   SampleSimple  — TPasClawAgent, code-driven one-liner API
#                   (Agent := TPasClawAgent.Create('model');
#                    Agent.RegisterTool(TWebSearchTool.Create);
#                    WriteLn(Agent.Run('prompt')))
#   SampleServer  — TPasClawServer, hosts the OpenAI-compatible
#                   HTTP gateway in-process
#                   (Server := TPasClawServer.Create('0.0.0.0', 8088);
#                    Server.RegisterTool(TWebSearchTool.Create);
#                    Server.Run)
#
# All three pick up the same unit search paths as the top-level
# PasClaw build (../../Makefile) so the samples stay in sync without
# duplicating the list. Run:
#
#   cd samples/component-console
#   make            # builds all three
#   make simple     # just SampleSimple
#   make console    # just SampleConsole
#   make server     # just SampleServer
#
# The first build needs Indy vendored under ../../vendor/Indy; the
# top-level Makefile's `make get-indy` target handles that. Run it
# once from the repository root before building the sample.
#
# Delphi / RAD Studio users have three project files alongside the
# .dpr sources:
#
#   SampleConsole.dproj   open in RAD Studio or build with msbuild
#   SampleSimple.dproj
#   SampleServer.dproj
#
# Each one carries the same DCC_UnitSearchPath as the main pasclaw
# binary, re-rooted at ..\..\src\. The dcc32.cfg / dcc64.cfg files
# in this directory carry the same paths for cmdline-only builds
# (dcc32 / dcc64 auto-load *.cfg from the current dir).
#
# Indy comes from RAD Studio's bundled packages — no vendoring needed
# on Delphi; this is the same pattern src/pasclaw/PasClaw.dproj uses.

ROOT     := ../..
FPC      ?= fpc
BUILDDIR ?= build

INDY_DIR     ?= $(ROOT)/vendor/Indy

# OS / arch autodetect — same approach as the root Makefile so a
# fresh Linux or Homebrew install picks up fcl-db, sqlite, iconvenc,
# and lazutils from the right place without per-machine config.
UNAME_S      := $(shell uname -s)
UNAME_M      := $(shell uname -m)
FPC_VERSION  ?= 3.2.2

ifeq ($(UNAME_S),Darwin)
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
  ifeq ($(UNAME_M),aarch64)
    FPC_ARCH ?= aarch64-linux
  else
    FPC_ARCH ?= x86_64-linux
  endif
  FPC_UNITS_DIR ?= /usr/lib/$(UNAME_M)-linux-gnu/fpc/$(FPC_VERSION)/units/$(FPC_ARCH)
  LAZUTILS_DIR  ?= /usr/lib/lazarus/3.0/components/lazutils
endif

ICONVENC_DIR ?= $(FPC_UNITS_DIR)/iconvenc
FCLDB_DIR    ?= $(FPC_UNITS_DIR)/fcl-db
SQLITE_DIR   ?= $(FPC_UNITS_DIR)/sqlite

# Every src/pkg/* the main binary uses, re-rooted at $(ROOT).
UNIT_DIRS = \
	$(ROOT)/src/pkg/cliui \
	$(ROOT)/src/pkg/utils \
	$(ROOT)/src/pkg/logger \
	$(ROOT)/src/pkg/config \
	$(ROOT)/src/pkg/json \
	$(ROOT)/src/pkg/providers \
	$(ROOT)/src/pkg/stream \
	$(ROOT)/src/pkg/tokenizer \
	$(ROOT)/src/pkg/tools \
	$(ROOT)/src/pkg/mcp \
	$(ROOT)/src/pkg/gateway \
	$(ROOT)/src/pkg/channels \
	$(ROOT)/src/pkg/crypto \
	$(ROOT)/src/pkg/net \
	$(ROOT)/src/pkg/search \
	$(ROOT)/src/pkg/cron \
	$(ROOT)/src/pkg/skills \
	$(ROOT)/src/pkg/checkpoints \
	$(ROOT)/src/pkg/condense \
	$(ROOT)/src/pkg/session \
	$(ROOT)/src/pkg/identity \
	$(ROOT)/src/pkg/agent \
	$(ROOT)/src/pkg/memory \
	$(ROOT)/src/pkg/kb \
	$(ROOT)/src/pkg/updater \
	$(ROOT)/src/pkg/membench \
	$(ROOT)/src/pkg/tui \
	$(ROOT)/src/pkg/platform \
	$(ROOT)/src/pkg/hashline \
	$(ROOT)/src/pkg/component \
	$(ROOT)/src/pkg/shell \
	$(ROOT)/src/cmd

INDY_UNIT_DIRS = \
	$(INDY_DIR)/Lib/Core \
	$(INDY_DIR)/Lib/Protocols \
	$(INDY_DIR)/Lib/System

FPCFLAGS = -MDelphi -Sh -O2 -Xs -XX \
	-Fu$(FCLDB_DIR) -Fu$(SQLITE_DIR) \
	$(if $(LAZUTILS_DIR),-Fu$(LAZUTILS_DIR)) \
	$(foreach d,$(UNIT_DIRS),-Fu$(d)) \
	$(foreach d,$(INDY_UNIT_DIRS),-Fu$(d)) \
	$(foreach d,$(INDY_UNIT_DIRS),-Fi$(d)) \
	-Fu$(ICONVENC_DIR) \
	-FE$(BUILDDIR) \
	-FU$(BUILDDIR)/lib

.PHONY: all clean console simple server

all: console simple server

console: $(BUILDDIR)/SampleConsole
simple:  $(BUILDDIR)/SampleSimple
server:  $(BUILDDIR)/SampleServer

$(BUILDDIR)/SampleConsole: SampleConsole.dpr | $(BUILDDIR) $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) SampleConsole.dpr

$(BUILDDIR)/SampleSimple: SampleSimple.dpr | $(BUILDDIR) $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) SampleSimple.dpr

$(BUILDDIR)/SampleServer: SampleServer.dpr | $(BUILDDIR) $(BUILDDIR)/lib
	$(FPC) $(FPCFLAGS) SampleServer.dpr

$(BUILDDIR):
	mkdir -p $@
$(BUILDDIR)/lib:
	mkdir -p $@

clean:
	rm -rf $(BUILDDIR)
