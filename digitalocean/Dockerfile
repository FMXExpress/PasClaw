# PasClaw on DigitalOcean App Platform.
#
# Two-stage build: stage 1 is a Debian Bookworm + FPC 3.2 toolchain that
# clones Indy at build time and compiles a single static-ish pasclaw binary.
# Stage 2 is bookworm-slim with just the runtime DLLs the binary actually
# links against (libssl3, libsqlite3). Final image is ~80-90 MB.
#
# Build context is the repo root (`docker build -f digitalocean/Dockerfile .`).
# The root-level .dockerignore strips docs/, samples/, cog/, browser/,
# vendor/Indy/, etc. so the build context stays small (a few MB instead
# of ~700 MB).
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
ARG PASCLAW_VERSION=do-appplatform
RUN make BIN=/out/pasclaw PASCLAW_VERSION=$PASCLAW_VERSION

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
