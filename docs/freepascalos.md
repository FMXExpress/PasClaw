# PasClaw on FreePascalOS

[FreePascalOS](https://github.com/xeons/FreePascalOS) is a 64-bit UEFI
operating system written in Free Pascal, with its own kernel, TCP/IP stack,
TLS client and userland, and its own compiler target, `x86_64-freepascalos`.
`make fpos` builds `pasclaw` for it with that compiler. On FreePascalOS
pasclaw reaches models over HTTP and HTTPS through the system's own HTTP
client, runs commands through the system's shell, and keeps its sessions on
the system's disk.

> **Status: the agent runs inside FreePascalOS (in QEMU).**
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
> - `pasclaw gateway` says it is not available on FreePascalOS and exits 1.
>
> Not tried yet: a real provider over the internet (the system trusts the
> Mozilla CA list in `/etc/ssl/certs/ca-certificates.crt`, so it should
> work), the interactive `pasclaw agent` prompt, and real hardware.

## The license of a FreePascalOS build

PasClaw is MIT. That includes everything this port added: `src/fpos/`, the
`{$IFDEF FREEPASCALOS}` branches in shared units, the Makefile targets and
the test scripts.

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
DOS and Delphi builds never compile a FreePascalOS unit: `src/fpos` is on the
unit path of `make fpos` alone, and every reference to it in shared code is
inside `{$IFDEF FREEPASCALOS}`, a symbol only the FreePascalOS compiler
defines. The FPC package units the build compiles from source (fcl-json,
fcl-db, paszlib, ...) and FreePascalOS's port of fcl-process are under FPC's
LGPL with the static-linking exception, as on every other target.

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
   its path;
3. links with `ld -pie --no-dynamic-linker --hash-style=sysv`, as
   FreePascalOS links its own programs (`userland/userland.mk`), against
   `libhttp`, `libtls`, `libcompression`, `libcoreutils`, `libcryptography`
   and `libsystem`.

It takes about ten seconds. The result is a 9.9 MB position independent
x86-64 ELF program (symbols kept, as FreePascalOS keeps them in its own
programs for its crash reports).

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

## What works, and what is left out

| | On FreePascalOS |
|---|---|
"Tried" means `make test-fpos-qemu` ran it inside FreePascalOS; "built in"
means it compiles and links for FreePascalOS and has nothing specific to the
system in its way, but has not been run there yet.

| | On FreePascalOS |
|---|---|
| `version`, `agent -m` (one-shot, `--session`), `acp` | tried |
| `agent` (the prompt), `build`, `plan`, `init`, `runbook`, `onboard` | built in |
| An OpenAI-compatible provider over HTTP and HTTPS, SSE streaming | tried, through `libhttp` / `libtls`; the other providers (Anthropic, Gemini, ...) go through the same code, built in |
| `write_file`, `read_file`, `shell_exec` (and its timeout), `execute_code` | tried: commands run through the system's `/bin/sh` with `TProcess`; a command past its timeout is ended with the processes it started; `execute_code` runs `bash` scripts with `sh`, as FreePascalOS has no bash |
| The other file tools, sessions, memory notes, skills, checkpoints, backups, workflows, cron management, `config`, `model`, `status`, `doctor`, `session`, `workspace`, `project` | built in (plain files) |
| `web_fetch` and web search providers | built in; the SSRF guard resolves names with the system's resolver |
| MCP servers over stdio and HTTP | built in; the OAuth browser sign-in is left out (it needs a loopback HTTP server) -- copy a token file made elsewhere, refresh works |
| SQLite-backed features (memory search index, knowledge base index, facts, session search, the SQLite database tool) | compiled in, but FreePascalOS has no `libsqlite3` for them to load, so they report it as on a system without SQLite; the other database drivers are left out |
| Local embeddings (ONNX Runtime, sqlite-vec) | no: neither library exists there |
| `gateway`, `serve` (and so the web UI), `relay`, `bridge` | no: they need Indy's socket servers, and Indy has no stack for FreePascalOS. They print `pasclaw <command> is not available on FreePascalOS (...)` and exit 1 |
| `tui` | no: the full-screen UI needs a Unix terminal and the gateway client |
| `agent --attach` | no: the gateway client is Indy |
| `execute_code`'s `pasclaw __tool` callback | no: it needs a TCP server; the script runs, without the callback |
| LINE / WhatsApp webhooks, IMAP mail sync | no (pushing a message to a channel works) |
| `HTTP(S)_PROXY` | not read: `libhttp` has no proxy support |
| Ctrl-C / `kill` | end pasclaw at once; FreePascalOS has no signal handlers to catch them |
| `pasclaw update` | no FreePascalOS release to update to |

## Tests

- `make test-fpos-build` (in `make test`): builds pasclaw for FreePascalOS
  in a build folder of its own and checks, with `scripts/check-fpos-binary.py`,
  that it is a position independent x86-64 ELF program with no program
  interpreter, with `DT_HASH`, needing FreePascalOS's libraries and no
  Linux ones, and with nothing of Indy's or OpenSSL's in it. It is what keeps
  the FreePascalOS build building. Skips without the toolchain.
- `make test-fpos-qemu` (in `make test`, after `test-fpos-build`):
  `scripts/test-fpos-qemu.py` builds the FreePascalOS programs the session
  uses (`sh`, `ls`, `cat`, `mkdir`, ...), makes a system disk with them,
  the libraries and pasclaw with FreePascalOS's `scripts/make-system-disk.sh`,
  boots it in QEMU with `init=/bin/sh` (and `test-exit`, so QEMU ends with
  the shell), and drives the shell over the serial port as FreePascalOS's own
  `scripts/test-input.py` does. A fake OpenAI-compatible model runs on the
  host, over HTTP and over HTTPS. The checks are the ones in the status box
  above; `FPOS_QEMU_VERBOSE=1` prints the whole session. It takes about 30
  seconds under TCG. It needs `qemu-system-x86`, `ovmf`, `e2fsprogs`,
  `fdisk` and `openssl`, and `make esp` in FreePascalOS; it skips without
  them.

## Where the FreePascalOS code is

`src/fpos/`, built only by `make fpos`:

| Unit | What |
|---|---|
| `PasClaw.Platform.FreePascalOS` | the system calls: ending a process tree (the process list's parents), process checks, the console's size and echo, setting an environment variable, resolving a name |
| `PasClaw.HTTP.FreePascalOS` | HTTP and HTTPS through `libhttp`'s `THttpClient`; the body goes to the caller's stream as it arrives; redirects are followed hop by hop so a guard sees each one; credentials are not carried to another origin |
| `PasClaw.Cmd.Unavailable` | the commands left out, saying why |
| `fphttpclient`, `opensslsockets`, `dynlibs`, `dos`, `masks` | the small parts of FPC and Lazarus units PasClaw's units name that have no FreePascalOS version (`TFPHTTPClient.Get` over `libhttp`; FPC's dynlibs without its per-OS include; `GetFAttr` for paszlib's gzio; `MatchesMask`) |
| `fpospackages` | the list of FPC package units to compile first |

`{$IFDEF FREEPASCALOS}` branches in shared units: `PasClaw.Platform`
(process trees, pipe end of file), `PasClaw.Providers.HTTP` (the `libhttp`
backend), `PasClaw.Net.SSRF` (the resolver), `PasClaw.CliUI` (echo off for
secrets), `PasClaw.Gateway.RunFile` (process checks, no signal handler),
`PasClaw.DecisionModels.Gate` (rename), `PasClaw.Tools.ExecuteCode` (`sh`
for `bash`), `PasClaw.Cmd.Build` / `Cmd.Plan`
(setting `PASCLAW_HOME`), `PasClaw.Cmd.Root` and `Cmd.Agent` (the commands
and `--attach` left out), `PasClaw.Tools.RPC`, `PasClaw.MCP.OAuth`,
`PasClaw.Channels.LINE` / `WhatsApp`, `PasClaw.Suite.Mail` (their Indy parts
left out), `PasClaw.DB` (SQLite only) and `onnxruntime_pas_api` (a library
name). `make lint-pascal-shape` treats `src/fpos` and `{$IFDEF FREEPASCALOS}`
branches as FPC-only code.
