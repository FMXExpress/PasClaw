# PasClaw on FreePascalOS

[FreePascalOS](https://github.com/xeons/FreePascalOS) is a 64-bit UEFI
operating system written in Free Pascal, with its own kernel, TCP/IP stack,
TLS client and userland, and its own compiler target, `x86_64-freepascalos`.
`make fpos` builds `pasclaw` for it with that compiler. On FreePascalOS
pasclaw reaches models over HTTP and HTTPS through the system's own HTTP
client, runs commands through the system's shell, keeps its sessions on
the system's disk, and runs `pasclaw gateway`, its HTTP API and web UI, on
Indy over the system's sockets.

> **Status: the agent and the gateway run inside FreePascalOS (in QEMU).**
>
> `make test-fpos-qemu` boots FreePascalOS headless in QEMU, puts the
> `pasclaw` that `make fpos` built on its system disk, types into its shell
> over the serial port, and checks what comes back. On 2026-11-28 every
> check passed:
>
> - `pasclaw version` prints `pasclaw v0.1.5-77-g7bd1686 (fpc 3.2.2
>   FreePascalOS/x86_64)`.
> - `pasclaw agent -m "say hi"` reaches an OpenAI-compatible server on the
>   host (10.0.2.2 from inside QEMU's user networking) over plain HTTP and
>   prints its answer.
> - The same over HTTPS, to a server with a certificate from a CA made for
>   the test. Without that CA the turn is refused (`the certificate was issued
>   by an unknown authority (issuer: PasClaw test CA)`); with
>   `SSL_CERT_FILE` pointing at it, it answers.
> - A turn whose model asks for tools runs `write_file`, `read_file`,
>   `shell_exec` (`uname -s` through `/bin/sh` printed `FreePascalOS`,
>   exit 0), `shell_exec` of `sleep 60` with `timeout_sec: 2` (ended after
>   2 s, exit 124) and `execute_code` (its script run by `sh`) inside
>   FreePascalOS, and `--session` saves the session on the system's disk.
> - `pasclaw acp`, typed at on the console: the model's reply streams
>   (SSE over chunked HTTP/1.1). The fake model holds back the rest of its
>   stream until the first `agent_message_chunk` has come out of the serial
>   port, so the reply was shown while the model was still writing.
> - `pasclaw tui` says it is not available on FreePascalOS and exits 1.
>
> **The gateway, since 2026-11-28.** `pasclaw gateway --addr 0.0.0.0
> --port 18790`, started in the background inside FreePascalOS with a
> gateway token, was asked from the host through a port QEMU forwards to
> it (below), and every check passed:
>
> - `GET /v1/health` answers; `GET /` serves the web UI, byte for byte the
>   `webui.html` embedded in the binary as a resource.
> - `GET /v1/config` with the token answers with its secrets masked (the
>   provider key and the gateway token are not in it); the same request
>   without the token is refused with 401.
> - `POST /v1/chat` is answered by the fake model on the host (10.0.2.2).
> - `POST /v1/chat/completions` with `stream: true` streams (SSE): the
>   model asks for `write_file`, the gateway streams the call's line and
>   its result as they happen, then the answer. The fake model gives the
>   answer only once the call's line has reached the client on the host,
>   so the stream left FreePascalOS while the turn was still running.
> - `GET /v1/logs` streams the log, `GET /v1/desktop/events` says hello
>   (both SSE, kept open), `GET /v1/background` answers.
> - The web UI, loaded in headless Chromium (Playwright) through the
>   forwarded port with the token in its storage, sends a chat message and
>   shows the fake model's reply.
> - `pasclaw agent --attach` inside FreePascalOS runs a turn through that
>   gateway (Indy's client to Indy's server over the loopback interface).
> - `execute_code`'s script calls back into the tools with `pasclaw __tool`
>   (a TCP connection to the turn's tool server) and writes a file.
>
> Not tried yet: a real provider over the internet (the system trusts the
> Mozilla CA list in `/etc/ssl/certs/ca-certificates.crt`, so it should
> work), the interactive `pasclaw agent` prompt, `serve`, `relay`,
> `bridge --listen`, the chat channels, and real hardware.

## The license of a FreePascalOS build

PasClaw is MIT. That includes everything this port added: `src/fpos/`, the
`{$IFDEF FREEPASCALOS}` branches in shared units, the Makefile targets and
the test scripts -- except `src/fpos/indy/`, which holds Indy units: copies
of four of Indy's with FreePascalOS branches added, and the socket stack
written after Indy's Unix one. Those keep Indy's header and are under
Indy's dual licence, like the Indy clone in `vendor/Indy` every build uses.
None of it is copied from FreePascalOS's sources; it calls the system's
libraries through their interfaces.

FreePascalOS is GPLv3, **with no linking exception**. Its runtime library,
`libsystem`, `libhttp`, `libtls` and the other libraries are part of it. A
`pasclaw` built with `make fpos` links them: their units are compiled into
it, the start-up object `si_prc.o` is linked into it statically, and
`libsystem.so`, `libhttp.so`, `libtls.so`, `libcompression.so`,
`libcryptography.so` and `libcoreutils.so` are bound to it when it starts.
So that binary is a work based on GPLv3 code:

- **Giving a FreePascalOS binary of pasclaw to anyone else** (a download, a
  disk image, a machine you hand over) means doing so under the GPLv3: with
  the complete corresponding source (PasClaw's, which is MIT and so
  GPL-compatible, and FreePascalOS's) and the GPL's other terms.
- **Building it yourself and running it yourself** does not. The GPL places
  no conditions on running a program or on copies you make for your own
  use.

None of this touches the other builds. The Linux, macOS, Windows, Windows XP,
DOS and Delphi builds never compile a FreePascalOS unit: `src/fpos` and
`src/fpos/indy` are on the unit path of `make fpos` alone, and every
reference to them in shared code is inside `{$IFDEF FREEPASCALOS}`, a
symbol only the FreePascalOS compiler defines. The FPC package units the
build compiles from source (fcl-json, fcl-db, paszlib, ...) and
FreePascalOS's port of fcl-process are under FPC's LGPL with the
static-linking exception, as on every other target.

## Build

You need a FreePascalOS checkout with its compiler and userland libraries
built, and the Free Pascal 3.2.2 sources that compiler was built from
(Debian/Ubuntu: `fpc-source`, in `/usr/share/fpcsrc/3.2.2`).

```sh
git clone https://github.com/xeons/FreePascalOS ~/src/freepascalos
cd ~/src/freepascalos
export FPC_SOURCE=/usr/share/fpcsrc/3.2.2   # where fpc-source put them
make                                        # the compiler, the loader and the kernel
make build/amd64/user/lib/libhttp.so        # libsystem, libtls, libhttp and what they need

cd ~/src/PasClaw
make get-indy                               # vendor/Indy, as for every FPC build
make fpos FPOS_DIR=~/src/freepascalos       # build/fpos/pasclaw
```

`FPOS_DIR` defaults to `/home/user/xeons/freepascalos`. `FPOS_FPC_SOURCE`
(default `/usr/share/fpcsrc/3.2.2`, else `/usr/lib/fpc/src`) is where the FPC
package sources are read from. Without the toolchain, `make fpos` says what is
missing and stops; `make test-fpos-build` skips.

FreePascalOS's README covers building its compiler. Note that on Ubuntu 24.04
with Debian's `fpc-source` 3.2.2 its `toolchain/fpc/prepare-source.sh` needed
two local fixes when this port was made: one hunk of its compiler patch did
not apply and was applied by hand, and Debian's sources lack the generated
`msgtxt.inc`, which `msg2inc` regenerates from `errore.msg`.

What `make fpos` does, every time from a clean `build/fpos`:

1. compiles `src/fpos/fpospackages.pas` with the packages' own settings
   (`-S2h`, not PasClaw's `-MDelphi -Sh`), which brings in the FPC package
   units PasClaw uses (fcl-json, fcl-base, fcl-db with sqlite, hash,
   paszlib, regexpr, rtl-generics, and fcl-process with FreePascalOS's
   port of it) into `build/fpos/pkg` -- what an FPC install ships
   precompiled on the other targets; and `rtl/inc/uuchar.pp`, which
   `{$mode delphiunicode}` loads;
2. compiles `src/pasclaw/PasClaw.dpr` with `-Tfreepascalos -Cg -Cn` against
   FreePascalOS's runtime library and library units, `src/fpos` first on
   its path, then PasClaw's units, then Indy's (`vendor/Indy`) with
   `src/fpos/indy` ahead of them; the compiler puts the web UI's resource
   (`webui.res`, made by `fpcres` as for the other builds) in an object of
   its own, `PasClaw.or`;
3. links with `ld -pie --no-dynamic-linker --hash-style=sysv`, as
   FreePascalOS links its own programs (`userland/userland.mk`), that
   resource object with the rest, against `libhttp`, `libtls`,
   `libcompression`, `libcoreutils`, `libcryptography` and `libsystem`.

It takes about fifteen seconds. The result is a 14.5 MB position
independent x86-64 ELF program (symbols kept, as FreePascalOS keeps them in
its own programs for its crash reports): 9.9 MB before the gateway, and
about 4.5 MB of it is Indy, the gateway and the 1 MB web UI.

## Put it on a FreePascalOS system

Copy `build/fpos/pasclaw` into `/bin` of the system volume. Before
`make system-disk` in FreePascalOS, putting it in
`build/amd64/user/bin/` there is enough: `scripts/make-system-disk.sh` copies
everything in that folder. `make test-fpos-qemu` makes a small disk of its own
that way (below).

Then, in FreePascalOS's shell:

```sh
pasclaw onboard                  # or write $PASCLAW_HOME/config.json yourself
pasclaw agent -m "what is in /etc?"
pasclaw agent                    # the line-by-line prompt
```

The home is `$PASCLAW_HOME`, else `$HOME/.pasclaw` (`/.pasclaw` for the first
shell, whose `HOME` is `/`).

HTTPS: certificates are checked against the system's list,
`/etc/ssl/certs/ca-certificates.crt`. `SSL_CERT_FILE` (or `PASCLAW_CA_FILE`)
names a PEM file to trust instead, for a private CA or a local server;
`PASCLAW_TLS_INSECURE=1` turns the checks off.

## The gateway

`pasclaw gateway` runs there as everywhere: its HTTP API, the web UI at
`/`, SSE (`/v1/chat/completions` with `stream`, `/v1/logs`,
`/v1/desktop/events`), the inbound MCP server, the channel webhooks. It is
Indy's `TIdHTTPServer` on Indy's FreePascalOS socket stack
(`src/fpos/indy`, below), over the system's TCP/IP. FreePascalOS's shell
runs it in the background like any other job:

```sh
env PASCLAW_GATEWAY_TOKEN=pick-a-long-random-token \
  pasclaw gateway --addr 0.0.0.0 --port 8088 > /tmp/gateway.log 2>&1 &
```

`--addr 0.0.0.0` listens on every interface; the default, 127.0.0.1, only
answers inside the system. Set a token (`PASCLAW_GATEWAY_TOKEN` or
`gateway.token` in `config.json`) before it listens on a network: the web
UI asks for it once (the key button) and keeps it in the browser, and every
`/v1/*` route but `/v1/health` and `/v1/version` refuses a request without
it.

**From the host, when FreePascalOS runs in QEMU** with user networking:
forward a port on the host to the gateway's port inside, and open it in a
browser on the host.

```sh
qemu-system-x86_64 ... \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:8088-:8088 \
  -device virtio-net-pci,netdev=net0
# then, on the host: http://127.0.0.1:8088/
```

Inside, the host itself is 10.0.2.2: a model server running on the host is
`http://10.0.2.2:<port>/v1` in `config.json`. With bridged networking or on
real hardware, use the machine's own address instead of the forwarded port.
`make test-fpos-qemu` reaches its gateway this way.

What to know:

- **Plain HTTP only.** The gateway serves no TLS on any system (put a
  reverse proxy that terminates TLS in front of it), and Indy's TLS client
  is OpenSSL, which FreePascalOS does not have: `agent --attach` and
  `relay` reach a gateway over `http://` only. Model providers are not
  affected; they go through `libhttp` / `libtls`.
- `pasclaw agent --attach` inside the system finds the gateway through
  `$PASCLAW_HOME/run/gateway.json`, as elsewhere.
- Ctrl-C or `kill` ends it at once (FreePascalOS has no signal handlers to
  catch them), so the run file is left behind; readers see that its
  process is gone and treat it as absent.
- `--email` is refused: SMTP and IMAP over TLS need OpenSSL. Telegram and
  Matrix go through `libhttp`; LINE and WhatsApp webhooks are served by the
  gateway; IRC is plain TCP through Indy (without TLS, as on the other
  systems).

## What works, and what is left out

"Tried" means `make test-fpos-qemu` ran it inside FreePascalOS; "built in"
means it compiles and links for FreePascalOS and has nothing specific to the
system in its way, but has not been run there yet.

| | On FreePascalOS |
|---|---|
| `version`, `agent -m` (one-shot, `--session`), `acp` | tried |
| `agent` (the prompt), `build`, `plan`, `init`, `runbook`, `onboard` | built in |
| An OpenAI-compatible provider over HTTP and HTTPS, SSE streaming | tried, through `libhttp` / `libtls`; the other providers (Anthropic, Gemini, ...) go through the same code, built in |
| `write_file`, `read_file`, `shell_exec` (and its timeout), `execute_code` and its `pasclaw __tool` callback | tried: commands run through the system's `/bin/sh` with `TProcess`; a command past its timeout is ended with the processes it started; `execute_code` runs `bash` scripts with `sh`, as FreePascalOS has no bash; the callback is a TCP connection to the turn's tool server on the loopback interface |
| `gateway`: its API, the web UI, SSE, the token | tried, from the host through a forwarded port, and from Chromium; Indy's HTTP server on its FreePascalOS socket stack. Plain HTTP (see above) |
| `agent --attach` | tried, to a gateway on the same system; `http://` gateways only |
| `serve`, the inbound MCP server, LINE / WhatsApp webhooks, Telegram, Matrix, IRC | built in (the gateway's server, or `libhttp`) |
| `relay` | built in; `http://` gateways only (Indy's TLS is OpenSSL) |
| `bridge --listen` | built in; `--serial` says serial ports are not supported there |
| The other file tools, sessions, memory notes, skills, checkpoints, backups, workflows, cron management, `config`, `model`, `status`, `doctor`, `session`, `workspace`, `project` | built in (plain files) |
| `web_fetch` and web search providers | built in; the SSRF guard resolves names with the system's resolver |
| MCP servers over stdio and HTTP | built in; the OAuth browser sign-in is left out (it sends a browser on this machine back to a loopback server, and there is no browser there) -- copy a token file made elsewhere, refresh works |
| SQLite-backed features (memory search index, knowledge base index, facts, session search, the SQLite database tool) | compiled in, but FreePascalOS has no `libsqlite3` for them to load, so they report it as on a system without SQLite; the other database drivers are left out |
| Local embeddings (ONNX Runtime, sqlite-vec) | no: neither library exists there |
| `tui` | no: the full-screen UI drives a Unix terminal (termios). It prints `pasclaw tui is not available on FreePascalOS (...)` and exits 1; the gateway's web UI and `agent --attach` are there |
| The email channel (`gateway --email`), IMAP mail sync | no: SMTP and IMAP over TLS need OpenSSL for Indy; they say so |
| `HTTP(S)_PROXY` | not read: `libhttp` has no proxy support |
| Ctrl-C / `kill` | end pasclaw at once; FreePascalOS has no signal handlers to catch them |
| `pasclaw update` | no FreePascalOS release to update to |

## Tests

- `make test-fpos-build` (in `make test`): builds pasclaw for FreePascalOS
  in a build folder of its own and checks, with `scripts/check-fpos-binary.py`,
  that it is a position independent x86-64 ELF program with no program
  interpreter, with `DT_HASH`, needing FreePascalOS's libraries and no
  Linux ones, carrying Indy's FreePascalOS stack, the gateway's HTTP
  server and the web UI, and nothing of OpenSSL's. It is what keeps the
  FreePascalOS build building. Skips without the toolchain.
- `make test-fpos-qemu` (in `make test`, after `test-fpos-build`):
  `scripts/test-fpos-qemu.py` builds the FreePascalOS programs the session
  uses (`sh`, `ls`, `cat`, `mkdir`, ...), makes a system disk with them,
  the libraries and pasclaw with FreePascalOS's `scripts/make-system-disk.sh`,
  boots it in QEMU with `init=/bin/sh` (and `test-exit`, so QEMU ends with
  the shell), and drives the shell over the serial port as FreePascalOS's own
  `scripts/test-input.py` does. A fake OpenAI-compatible model runs on the
  host, over HTTP and over HTTPS. QEMU forwards a free port on the host's
  loopback to the gateway's port inside; the script starts the gateway in
  the background and asks it from the host with `http.client`, and loads
  its web UI in headless Chromium with `scripts/fpos-webui-chat.js` when
  node has Playwright (that check is skipped otherwise). The checks are
  the ones in the status box above; `FPOS_QEMU_VERBOSE=1` prints the whole
  session, the gateway's answers and its log. It takes about 45 seconds
  under TCG, the gateway's part about 15 of them. It needs
  `qemu-system-x86`, `ovmf`, `e2fsprogs`, `fdisk` and `openssl`, and
  `make esp` in FreePascalOS; it skips without them.

## Where the FreePascalOS code is

`src/fpos/`, built only by `make fpos`:

| Unit | What |
|---|---|
| `PasClaw.Platform.FreePascalOS` | the system calls: ending a process tree (the process list's parents), process checks, the console's size and echo, setting an environment variable, resolving a name |
| `PasClaw.HTTP.FreePascalOS` | HTTP and HTTPS through `libhttp`'s `THttpClient`; the body goes to the caller's stream as it arrives; redirects are followed hop by hop so a guard sees each one; credentials are not carried to another origin |
| `PasClaw.Cmd.Unavailable` | the command left out (`tui`), saying why |
| `fphttpclient`, `opensslsockets`, `dynlibs`, `dos`, `masks` | the small parts of FPC and Lazarus units PasClaw's units name that have no FreePascalOS version (`TFPHTTPClient.Get` over `libhttp`; FPC's dynlibs without its per-OS include; `GetFAttr` for paszlib's gzio; `MatchesMask`) |
| `fpospackages` | the list of FPC package units to compile first |

`src/fpos/indy/`, Indy for FreePascalOS, ahead of `vendor/Indy` on the
unit path of `make fpos` alone. Indy has no stack for a system that is
neither Unix nor Windows, and some of its units have nothing for one in
their platform branches. The copies are Indy's units of the clone `make
get-indy` takes (IndySockets/Indy 65007abe) with `{$IFDEF FREEPASCALOS}`
branches added and a note at the top on what changed; everything else is
as upstream. When Indy moves, these are the files to look at.

| Unit | What |
|---|---|
| `IdStackFreePascalOS` | new: Indy's socket stack, a `TIdStackBSDBase` over libsystem's `Sys.Sockets` (an Int64 handle per socket, errors returned by each call and kept per thread for `WSGetLastError`), names through `Sys.HostNames`, local addresses through `Sys.NetworkInterfaces`; Indy's socket options translated into the system's; readiness (`TIdSocketList`, Indy's `select()`) with `WaitForSocket` for one socket and `WaitForHandles` for several. It registers itself with `SetStackClass` |
| `IdStackConsts` | the BSD socket names the Unix headers give Indy elsewhere, with Linux's numbers; the `Id_WSAE*` errors (FreePascalOS's error codes are Linux's errno numbers) |
| `IdStack` | names `IdStackFreePascalOS` so every program using Indy links it, and leaves the stack class to its `SetStackClass` call |
| `IdGlobal` | thread and process types, `CurrentProcessId`, `Ticks64` (the monotonic `GetTickCount64`), `IndySleep`; text encodings without iconv (UTF-8, the system's own, and single byte code pages); `TextIsSame` and friends byte for byte: FreePascalOS's `AnsiCompareText` collates by the Unicode algorithm, which passes over punctuation (`'.'` and `' '` compare equal), and Indy found the HTTP version's space by it |
| `IdGlobalProtocols` | a file's GMT date, `GetClockValue`, the default charset |

Indy's TLS (`IdSSLOpenSSL`) is left out: `PasClaw.Client.Api` (the gateway
client), `Cmd.Relay` and `Cmd.Gateway` (the email channel) leave it out on
FreePascalOS.

`{$IFDEF FREEPASCALOS}` branches in shared units: `PasClaw.Platform`
(process trees, pipe end of file), `PasClaw.Providers.HTTP` (the `libhttp`
backend), `PasClaw.Net.SSRF` (the resolver), `PasClaw.CliUI` (echo off for
secrets), `PasClaw.Gateway.RunFile` (process checks, no signal handler),
`PasClaw.DecisionModels.Gate` (rename), `PasClaw.Tools.ExecuteCode` (`sh`
for `bash`), `PasClaw.Cmd.Build` / `Cmd.Plan`
(setting `PASCLAW_HOME`), `PasClaw.Cmd.Root` (`tui` left out),
`PasClaw.Cmd.Gateway` (the email channel left out), `PasClaw.Client.Api` /
`Cmd.Relay` (no OpenSSL: `http://` gateways), `PasClaw.MCP.OAuth` (the
browser sign-in left out), `PasClaw.Suite.Mail` (IMAP left out),
`PasClaw.DB` (SQLite only) and `onnxruntime_pas_api` (a library name).
`make lint-pascal-shape` treats `src/fpos` and `{$IFDEF FREEPASCALOS}`
branches as FPC-only code.
