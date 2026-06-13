# Docker

PasClaw ships as a single ~110 MB image. Multi-stage Dockerfile: `debian:bookworm` builder (apt-installs FPC 3.2.2 + units), `debian:bookworm-slim` runtime with the resulting `pasclaw` binary and `libssl.so.1.0.2` + `libcrypto.so.1.0.2` (the `libssl1.0.2_1.0.2u-1~deb9u7` Debian package) bundled next to the binary so the TLS path works without depending on the host's OpenSSL 3.x.

The builder uses Debian-packaged FPC rather than the upstream `freepascal/fpc:*` image because our Makefile is written against the `/usr/lib/x86_64-linux-gnu/fpc/3.2.2/units/x86_64-linux/` layout that `apt install fpc fp-units-*` produces; the upstream image puts units under `/usr/local/lib/fpc/` and the Makefile would need a Docker-specific override fork.

## Quick start

```sh
# Build for the local arch (Dockerfile lives at the repo root since
# PR #252 so DigitalOcean App Platform's auto-detect picks it up
# without operator config; same Dockerfile, same build for any host).
docker build -t pasclaw:dev .

# Run the gateway, persist workspace to ~/.pasclaw on the host
docker run --rm -p 8088:8088 \
  -v $HOME/.pasclaw:/home/pasclaw/.pasclaw \
  pasclaw:dev

# `pasclaw <anything>` works — pass through to the entrypoint
docker run --rm pasclaw:dev version
docker run --rm -it pasclaw:dev agent   # interactive chat
docker run --rm \
  -v $HOME/.pasclaw:/home/pasclaw/.pasclaw \
  pasclaw:dev session list
```

## Configuration

The container reads from `$PASCLAW_HOME` (set to `/home/pasclaw/.pasclaw` inside). Bind-mount your host workspace into that path — it carries `config.json`, `workspace/sessions/`, `workspace/memory/`, `workspace/skills/`, `workspace/cron/state.json`, etc.

```sh
# Read-only config + writable workspace
docker run --rm -p 8088:8088 \
  -v $HOME/.pasclaw/config.json:/home/pasclaw/.pasclaw/config.json:ro \
  -v pasclaw-workspace:/home/pasclaw/.pasclaw/workspace \
  pasclaw:dev
```

Provider API keys live in `config.json` under `providers[].api_key`. Alternatively set them via env on `docker run` and reference `${ENV_VAR}` from config — env vars take precedence when both are set.

## Pinned port + bind

The image's default `CMD` is `gateway --addr 0.0.0.0 --port 8088` — both flags matter:

- `--addr 0.0.0.0` overrides PasClaw's default `127.0.0.1` bind, which inside a container would mean "container-loopback only" and Docker's `-p 8088:8088` mapping wouldn't actually reach the gateway.
- `--port 8088` is explicit so `HEALTHCHECK`, `EXPOSE`, and the in-container gateway port stay in sync even if a mounted `config.json` sets `gateway.port` to something else (the CLI flag wins).

If you want the container to listen on a different in-container port, override **both** `CMD` and `HEALTHCHECK`:

```sh
docker run --rm \
  -p 9000:9000 \
  --health-cmd 'curl -fsS http://localhost:9000/v1/models > /dev/null' \
  pasclaw:dev gateway --addr 0.0.0.0 --port 9000
```

The simpler path is to keep the in-container port at 8088 and remap on the host (`-p 9000:8088`).

## Multi-arch builds

The Dockerfile is `linux/amd64` + `linux/arm64` ready (the bundled-OpenSSL stage picks the right `.deb` by `$TARGETARCH`).

```sh
docker buildx create --use --name pasclaw-builder
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t ghcr.io/fmxexpress/pasclaw:dev \
  --push .
```

## Subcommand variants (compose pattern, planned)

A `docker-compose.yml` shipping multiple services under one image (gateway / agent / serve / channel daemons) is the obvious next step — picoclaw's profile-driven layout maps cleanly. Not included in this v1; for now use `docker run pasclaw:dev <subcommand>`.

## Why the bundled OpenSSL?

`make get-indy` clones [IndySockets/Indy](https://github.com/IndySockets/Indy), whose TLS path (`Lib/Protocols/IdSSLOpenSSLHeaders.pas`) targets OpenSSL 0.9.8–1.0.x and explicitly refuses to operate against 1.1+. Debian bookworm and every other modern distro ship OpenSSL 3.x as `libssl.so.3` — without intervention the PasClaw binary would have no working TLS at all.

The Dockerfile fetches `libssl1.0.2_1.0.2u-1~deb9u7` from `snapshot.debian.org`'s frozen `debian-archive` (an immutable archive, won't rot), bundles `libssl.so.1.0.2` + `libcrypto.so.1.0.2` next to the binary in `/opt/pasclaw/`, and sets `RPATH=$ORIGIN` on the binary via `patchelf` so the bundled `.so` files resolve before `/usr/lib/x86_64-linux-gnu/`. ~5 MB extra. The verify step at the end of the builder stage (`build/pasclaw version`) doesn't exercise TLS — first real TLS use is a provider call, which manual smoke or a follow-up CI job will cover.

When Indy lands OpenSSL 3 support upstream, drop the `openssl-1.0` stage entirely, switch to `libssl3` from the base image, and `RPATH` becomes unnecessary.

## Image layout

```
/opt/pasclaw/
  pasclaw                  # the binary, RPATH=$ORIGIN
  libssl.so.1.0.2          # bundled OpenSSL 1.0.2u
  libcrypto.so.1.0.2
  libssl.so   -> libssl.so.1.0.2     (Indy's dlopen name)
  libcrypto.so -> libcrypto.so.1.0.2

/home/pasclaw/.pasclaw/    # $PASCLAW_HOME — bind-mount or volume here
  config.json
  workspace/
    sessions/
    memory/
    skills/
    cron/state.json
```

The image runs as user `pasclaw` (uid 1000 by default; override with `--build-arg PASCLAW_UID=…`). The workspace is writable; the binary directory is not.

## Health check

`HEALTHCHECK` probes `http://localhost:8088/v1/models` every 30 s. Always 200 when the gateway is up — even with no providers configured the endpoint returns an empty model list. Wired so `docker compose ps` / `kubectl readiness` will accurately reflect gateway state.

## Out of scope for this v1

- `docker-compose.yml` with profiles for gateway / agent / channel daemons
- CI matrix (`.github/workflows/docker.yml`) for multi-arch publish to `ghcr.io`
- Distroless / chainguard runtime base
- A `Dockerfile.dev` with FPC + source mount for inner-loop development
- The Indy OpenSSL 3 upgrade itself — that's a separate PR with real TLS-path risk
