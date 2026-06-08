# PasClaw container — multi-stage build.
#
# Builder stage:    debian:bookworm + apt-installed fpc 3.2.2 + units,
#                   runs `make get-indy && make` to produce build/pasclaw.
# openssl-1.0:      fetches libssl1.0.2_1.0.2u from snapshot.debian.org's
#                   immutable debian-archive, picks the right arch via
#                   $TARGETARCH for buildx multi-arch.
# Runtime stage:    debian:bookworm-slim with the pasclaw binary plus
#                   libssl.so.1.0.2 + libcrypto.so.1.0.2 bundled next to
#                   it at /opt/pasclaw/, RPATH=$ORIGIN so the binary
#                   resolves to them before /usr/lib/.
#
# Why bundled OpenSSL 1.0:
#   IndySockets/Indy master (what `make get-indy` clones) targets OpenSSL
#   0.9.8 / 1.0.x — its TLS path bails on 1.1+. Modern distros ship
#   OpenSSL 3.x as libssl.so.3 only, so without bundled 1.0 the binary
#   has no TLS at all. ~5 MB extra; deletes whenever Indy lands its
#   long-awaited 1.1/3 support upstream.
#
# Build:
#   docker build -f docker/Dockerfile -t pasclaw:dev .
# Run:
#   docker run --rm -p 8088:8088 \
#     -v $HOME/.pasclaw:/home/pasclaw/.pasclaw \
#     pasclaw:dev gateway
#
# Multi-arch (buildx):
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     -f docker/Dockerfile -t ghcr.io/fmxexpress/pasclaw:dev --push .

ARG DEBIAN_VERSION=bookworm

# --- builder ------------------------------------------------------------
# Why not freepascal/fpc:3.2.2-bookworm-full? It installs FPC from
# source under non-Debian paths (/usr/local/lib/fpc/), but our Makefile
# expects the Debian-packaged layout
# (/usr/lib/<arch>-linux-gnu/fpc/<version>/units/, /usr/lib/lazarus/).
# Using plain debian:bookworm + apt gives us the layout the Makefile
# was written against.
FROM debian:${DEBIAN_VERSION} AS builder

WORKDIR /src

# Build deps:
#   fpc                FPC 3.2.2 (bookworm ships this exact version)
#   fp-units-db        TSQLite3Connection + FCL DB units
#   fp-units-misc      iconvenc, ssockets
#   lazarus-src        lazutils (PasClaw's memory FTS5 link uses it)
#   libsqlite3-dev     SQLite link symbols
#   make, git, curl    build + `make get-indy` + Indy clone
#   ca-certificates    HTTPS for the Indy clone
RUN apt-get update && apt-get install -y --no-install-recommends \
        fpc \
        fp-units-db fp-units-misc \
        lazarus-src \
        libsqlite3-dev \
        make git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy source AFTER deps so dep-layer caching survives source edits.
COPY . .

# Vendor Indy + build. `make get-indy` clones IndySockets/Indy; `make`
# produces build/pasclaw.
#
# LAZUTILS_DIR override: bookworm's lazarus-src is 2.2.6+dfsg2-2 and
# installs to /usr/lib/lazarus/2.2.6/, but the Makefile defaults to
# /usr/lib/lazarus/3.0/ (which is what some Ubuntu releases ship).
# Without this override the `Masks` import in
# src/pkg/tools/PasClaw.Tools.FS.pas fails to resolve. Codex P1 on
# PR #121. When Debian trixie ships lazarus 3.x, bump this in lock-
# step with DEBIAN_VERSION.
ARG LAZUTILS_DIR=/usr/lib/lazarus/2.2.6/components/lazutils
# C2W: set to 1 (--build-arg C2W=1) to compile the container2wasm in-browser
# networking path (-dPASCLAW_C2W) so the binary routes HTTP through the
# c2w-net-proxy Fetch bridge. Off by default for normal native/container
# images. See docs/c2w.md.
ARG C2W=
RUN make get-indy \
    && make LAZUTILS_DIR="${LAZUTILS_DIR}" C2W="${C2W}" \
    && test -x build/pasclaw \
    && build/pasclaw version

# --- openssl-1.0 fetcher ------------------------------------------------
# Separate stage so the deb cache is reused across builder edits. Pulls
# the LAST OpenSSL 1.0.2u Debian stretch-security package from
# snapshot.debian.org's frozen debian-archive — that archive is
# immutable, so this URL won't rot even after Debian retires the
# codename. Package is libssl1.0.2 (which contains libssl.so.1.0.2);
# Indy's dlopen of plain `libssl.so` resolves via the symlink we
# create in the runtime stage.
FROM debian:bookworm-slim AS openssl-1.0

ARG TARGETARCH
ARG OPENSSL_SNAPSHOT=20240331T102506Z
ARG OPENSSL_DEB_VERSION=1.0.2u-1~deb9u7

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN set -e; \
    case "${TARGETARCH:-amd64}" in \
        amd64) ARCH=amd64 ;; \
        arm64) ARCH=arm64 ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH}"; exit 1 ;; \
    esac; \
    mkdir -p /openssl /tmp/x; \
    URL="https://snapshot.debian.org/archive/debian-archive/${OPENSSL_SNAPSHOT}/debian-security/pool/updates/main/o/openssl1.0/libssl1.0.2_${OPENSSL_DEB_VERSION}_${ARCH}.deb"; \
    echo "fetching $URL"; \
    curl -fsSL --retry 3 --max-time 90 "$URL" -o /tmp/libssl.deb; \
    dpkg-deb -x /tmp/libssl.deb /tmp/x; \
    cp /tmp/x/usr/lib/*-linux-*/libssl.so.1.0.2    /openssl/; \
    cp /tmp/x/usr/lib/*-linux-*/libcrypto.so.1.0.2 /openssl/; \
    ls -l /openssl/

# --- runtime ------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

ARG PASCLAW_UID=1000

# Runtime deps:
#   ca-certificates  HTTPS trust anchors (Anthropic / OpenAI / etc.)
#   libsqlite3-0     memory FTS5 backend
#   tzdata           timestamps in logs + session ids
#   curl             HEALTHCHECK probe (~250 KB)
#   patchelf         set RPATH on the binary at install time only
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libsqlite3-0 \
        tzdata \
        curl \
        patchelf \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid ${PASCLAW_UID} --shell /bin/bash pasclaw

# Place the binary + bundled libssl/libcrypto together so RPATH=$ORIGIN
# finds them via the binary's own directory. /opt/pasclaw stays
# root-owned, world-readable — only the workspace under $PASCLAW_HOME
# needs the pasclaw user to write to it.
RUN mkdir -p /opt/pasclaw

COPY --from=openssl-1.0 /openssl/libssl.so.1.0.2    /opt/pasclaw/
COPY --from=openssl-1.0 /openssl/libcrypto.so.1.0.2 /opt/pasclaw/
COPY --from=builder /src/build/pasclaw              /opt/pasclaw/pasclaw

# Symlinks for Indy's plain `libssl.so` / `libcrypto.so` dlopen names.
RUN ln -sf libssl.so.1.0.2    /opt/pasclaw/libssl.so \
 && ln -sf libcrypto.so.1.0.2 /opt/pasclaw/libcrypto.so \
 && chmod +x /opt/pasclaw/pasclaw \
 && patchelf --set-rpath '$ORIGIN' /opt/pasclaw/pasclaw \
 && apt-get purge -y patchelf \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

ENV PASCLAW_HOME=/home/pasclaw/.pasclaw \
    PATH=/opt/pasclaw:${PATH}

USER pasclaw
WORKDIR /home/pasclaw

# Pre-create the workspace so the very first `pasclaw gateway` doesn't
# race on directory creation under a bind-mounted volume that may not
# exist yet. Idempotent — `pasclaw onboard` is happy to skip an
# existing workspace.
RUN mkdir -p ${PASCLAW_HOME}/workspace

EXPOSE 8088

# Probe the gateway's model-listing endpoint — always returns 200 when
# the gateway is up, even with no providers configured. The probe is
# hardcoded to 8088 because the default CMD below pins the gateway to
# the same port; users who override CMD to a different `--port N` must
# either also rebuild with a matching port or override HEALTHCHECK at
# `docker run --health-cmd ...`. (Codex P2 on PR #121.)
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS http://localhost:8088/v1/models > /dev/null || exit 1

# `pasclaw` is the only thing the image runs. Default subcommand is the
# HTTP gateway; override with `docker run pasclaw <cmd>` to get agent /
# serve / status / etc.
#
# `--addr 0.0.0.0` is mandatory inside the container: pasclaw's default
# bind is 127.0.0.1 (sane for desktop CLI use), which inside a
# container means "container loopback only" — Docker's published host
# port couldn't reach it even though the in-container HEALTHCHECK
# would still pass. Codex P1 on PR #121.
# `--port 8088` is explicit so HEALTHCHECK and EXPOSE stay in sync
# even when a mounted config.json sets gateway.port to something else.
ENTRYPOINT ["pasclaw"]
CMD ["gateway", "--addr", "0.0.0.0", "--port", "8088"]
