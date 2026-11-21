# PasClaw on Windows XP

The full `pasclaw.exe` can be built for 32-bit Windows with Free Pascal,
and that build is made to load on Windows XP: the agent, the gateway and
web UI, every tool, sessions, memory. XP has TCP/IP but its own TLS stops
at 1.0, which model APIs refuse; PasClaw does not use it. HTTPS goes
through OpenSSL (via Indy), which speaks TLS 1.2 on XP like anywhere else.
So unlike [DOS](./dos.md), XP needs no bridge: pasclaw talks to the
provider directly.

> **Status: runs on Windows XP SP2; HTTPS and the agent not yet tried
> there.**
>
> - **Load check:** all 200 functions `pasclaw.exe` imports are in the
>   export tables of the XP SP2 system DLLs (5.1.2600.2180).
> - **Run on XP:** `pasclaw version`, `status` and `doctor` ran on XP in
>   [VirtualXP](https://lrusso.github.io/VirtualXP/VirtualXP.htm), a
>   LiveXP disc in the Halfix emulator. The exe was added to its CD, with a
>   `Run` registry entry to start it at logon.
> - **Console:** the banner rendered and colour turned itself off.
>   `version` and `status` exited 0. `doctor` exited 1, as it should
>   before `onboard`.
> - **Gateway:** that disc has no TCP/IP stack at all (no `TCPIP.SYS`,
>   `AFD.SYS` or `MSWSOCK.DLL`) and no browser, so the gateway cannot
>   listen there and the web UI cannot be opened. `pasclaw gateway` got as
>   far as opening its port and stopped with `cannot listen on
>   127.0.0.1:8088: Socket Error # 10044 -- Socket type not supported.`
>   and exit code 1. On the way it showed two bugs, now fixed: the disc's
>   crypto provider does not load (`CryptAcquireContext` fails with
>   `NTE_BAD_SIGNATURE`), so pasclaw now falls back to `RtlGenRandom`; and
>   a listener that could not be opened was an unhandled-exception dump.
> - **Not tried:** HTTPS (OpenSSL), a running gateway, the web UI in an
>   XP browser, and an agent turn. That needs an XP with networking.
>
> Reports welcome.

## Build

On Linux:

```sh
make xp-toolchain   # once: the i386 cross compiler and the FPC win32 units
make xp             # build/xp/pasclaw.exe
```

`make xp-toolchain` runs `scripts/setup-dos-toolchain.sh --win32`: the same
`ppc386` that `make dos` uses (built from `fpc-source`), plus the 23
win32 unit packages pasclaw needs, unpacked with `innoextract` from the
official FPC 3.2.2 win32 installer and checked against a pinned SHA-256.
It needs `fpc` 3.2.2, `fpc-source`, `curl`, `unzip` and `innoextract`, and
the Lazarus `lazutils` source the Linux build already uses.

## What goes on the XP machine

Put these in one folder:

| File | What |
|---|---|
| `pasclaw.exe` | from `build/xp/` |
| `libeay32.dll`, `ssleay32.dll` | OpenSSL **1.0.2**, 32-bit. Needed for HTTPS. Indy loads these two names; OpenSSL 1.1 and 3.x use other names and are not loaded. 1.0.2u does TLS 1.2. |
| `sqlite3.dll` | 32-bit. Needed by memory search and facts, the knowledgebase, session search and the database tools; pasclaw names it when it is missing. |

Get DLL builds that themselves run on XP. Many recent binary builds are
made with toolchains that no longer target it.

Then, as anywhere: `pasclaw onboard`, then `pasclaw agent` or
`pasclaw gateway`.

## What is different on XP

- **No colour.** XP's console cannot show ANSI colour sequences. At start
  pasclaw asks the console to accept them (Windows 10 and later do) and
  turns colour off when it refuses, so XP gets plain text instead of
  `←[31m`. Windows 7 and 8 behave the same way.
- **No UTF-8 console code page.** XP's console in code page 65001 reports
  characters written for bytes written, which the runtime takes for a
  failed write. On XP pasclaw leaves the code page alone and writes its
  output as UTF-16 with `WriteConsoleW`. Characters the console font
  lacks show as boxes or `?`; Lucida Console covers the box-drawing ones.
- **`CanonicalPath`** (resolving links when checking a path against the
  workspace's restricted folders) uses `GetFinalPathNameByHandleW`, which
  XP lacks. pasclaw looks it up at run time; on XP the check falls back
  to comparing the path as written, as it does on any failure.

## The XP check

```sh
make test-xp   # builds pasclaw.exe for win32, then scripts/check-xp-imports.py
```

`scripts/check-xp-imports.py` reads the exe's PE header and import table
(with `objdump`) and fails when:

- the header asks for a Windows newer than XP (5.1); or
- the exe imports a DLL XP does not have; or
- it imports, at load time, a function added in Vista or later. That would
  stop XP's loader with "entry point not found" before pasclaw runs at all.

A function looked up with `GetProcAddress` is not an import and is fine:
that is how code uses a newer API only where it exists. The list of
post-XP functions is long but not exhaustive, so a pass means "nothing
known to be missing". `make test` runs this check when the win32 toolchain
is installed and skips it otherwise.
