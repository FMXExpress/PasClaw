# PasClaw on DigitalOcean App Platform (and any docker-build-aware host).
#
# Two-stage build: stage 1 is a Debian Bookworm + FPC 3.2 toolchain that
# clones Indy at build time and compiles a single static-ish pasclaw binary.
# Stage 2 is bookworm-slim with just the runtime DLLs the binary actually
# links against (libssl1.0 via snapshot.debian.org, libsqlite3). Final
# image is ~80-90 MB.
#
# Lives at the repo root (rather than under digitalocean/) so DO App
# Platform's UI auto-detect picks it up without the operator having to
# touch the "Source Directory" / "Dockerfile Path" fields. Build context
# is the repo root; the root-level .dockerignore strips docs/, samples/,
# cog/, browser/, vendor/Indy/, etc. so the upload to the daemon stays
# small (a few MB instead of ~700 MB).
#
# Runtime contract:
#   - Listens on $PORT (default 8088) bound to 0.0.0.0.
#   - PASCLAW_HOME defaults to /data/pasclaw -- ephemeral by default; mount
#     a persistent volume there if you want sessions / memory / KB to
#     survive restarts. See digitalocean/README.md.
#   - On first boot, entrypoint stamps config.template.json into
#     $PASCLAW_HOME/config.json. Template carries ${VAR_NAME} markers the
#     PasClaw config loader resolves from env (PR #247) -- secrets stay in
#     env vars, never baked into the image.
#   - /v1/health is exempt from gateway-token auth, so DO App Platform's
#     health probe works whether PASCLAW_GATEWAY_TOKEN is set or not.

# -----------------------------------------------------------------------
# Stage 1: build
# -----------------------------------------------------------------------
FROM debian:bookworm AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      fp-compiler \
      fp-units-db \
      fp-units-misc \
      lazarus-src \
      libssl-dev \
      libsqlite3-dev \
      git \
      make \
      ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Copy only the source needed to build the binary. The .dockerignore at the
# repo root already excludes docs/, samples/, cog/, browser/, vendor/Indy/,
# so this COPY pulls just src/, Makefile, and the digitalocean overlay.
COPY Makefile        ./Makefile
COPY src             ./src

# Clone Indy fresh (vendor/Indy is .dockerignore'd so we don't pull the
# ~600 MB working copy from the host). `make get-indy` is idempotent.
RUN make get-indy

# Build into /out so the runtime stage can copy a single file. PASCLAW_VERSION
# is injected by the Makefile from `git describe` when available; we pass an
# explicit value so the binary reports something stable even though .git is
# .dockerignore'd.
#
# Two overrides vs. the Makefile autodetect:
#  - mkdir /out: BIN=/out/pasclaw points the linker at a directory the
#    Makefile doesn't itself create. Without the explicit mkdir the link
#    step errors with "no such file or directory" and the runtime stage
#    has nothing to copy. (Codex P1 on PR #248.)
#  - LAZUTILS_DIR: the Makefile defaults to /usr/lib/lazarus/3.0/... which
#    is the Lazarus 3.x layout (Trixie/sid). Debian Bookworm ships
#    lazarus-src 2.2.6 under /usr/share/lazarus/2.2.6/components/lazutils,
#    so we pin the path explicitly here. If a future base image bumps the
#    lazarus-src version, the build fails loudly and the path is
#    obvious to fix. (Codex P1 on PR #248.)
ARG PASCLAW_VERSION=do-appplatform
RUN mkdir -p /out \
 && make BIN=/out/pasclaw \
         PASCLAW_VERSION=$PASCLAW_VERSION \
         LAZUTILS_DIR=/usr/share/lazarus/2.2.6/components/lazutils

# -----------------------------------------------------------------------
# Stage 2: runtime
# -----------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      libsqlite3-0 \
      libssl3 \
      ca-certificates \
      tini \
      curl \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --create-home --shell /bin/sh pasclaw

# OpenSSL 1.0.x for Indy.
#
# The vendored Indy ships only the legacy TIdSSLIOHandlerSocketOpenSSL,
# whose IdSSLOpenSSLHeaders.SSLDLLVers array dynamic-loads libssl.so.10
# / libssl.so.1.0.x (RHEL- and pre-bullseye-style names). It does NOT
# know about libssl.so.1.1 or libssl.so.3. Without libssl1.0.2 in the
# runtime image every outbound HTTPS call (provider chats, MCP, OTel
# exports, ...) fails with EIdOSSLCouldNotLoadSSLLibrary on the first
# attempt. Codex P1 on PR #248.
#
# Bookworm doesn't carry libssl1.0 in its default archive. snapshot.debian.org
# hosts the last Debian-published libssl1.0.2 .deb indefinitely as part of
# Debian's long-term archive; we ADD it from there.
#
# If snapshot.debian.org changes its URL pattern, this needs updating --
# operators see the failure at first HTTPS call, surfaced via the same
# error path docs/troubleshooting.md already covers under
# "EIdOSSLCouldNotLoadSSLLibrary".
ADD https://snapshot.debian.org/archive/debian/20230102T211522Z/pool/main/o/openssl1.0/libssl1.0.2_1.0.2u-1~deb9u8_amd64.deb \
    /tmp/libssl1.0.2.deb
RUN dpkg -i /tmp/libssl1.0.2.deb \
 && rm /tmp/libssl1.0.2.deb

COPY --from=builder /out/pasclaw                     /usr/local/bin/pasclaw
COPY digitalocean/entrypoint.sh                      /usr/local/bin/entrypoint.sh
COPY digitalocean/config.template.json               /etc/pasclaw/config.template.json
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/pasclaw

# Workspace location -- ephemeral when no volume mounted. Mount a persistent
# disk here (see digitalocean/.do/app.yaml's persistent_disk block when you
# want one) to keep sessions / memory / KB across restarts.
ENV PASCLAW_HOME=/data/pasclaw
ENV PORT=8088

# Pre-create the home dir owned by the unprivileged user so first boot
# doesn't need root to mkdir.
RUN mkdir -p /data/pasclaw && chown -R pasclaw:pasclaw /data/pasclaw /etc/pasclaw
USER pasclaw

EXPOSE 8088

# Tini reaps zombie child processes (shell_exec / execute_code spawn lots).
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
