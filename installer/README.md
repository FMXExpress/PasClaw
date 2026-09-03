# PasClaw Windows installer (Inno Setup)

`pasclaw.iss` builds a Windows installer for PasClaw with [Inno Setup 6](https://jrsoftware.org/isinfo.php).

The Windows (Delphi/dcc64) build is **self-contained** — a single `PasClaw.exe`:

- SQLite is linked statically (FireDAC static wrapper), so no `sqlite3.dll`;
- TLS uses Windows **SChannel**, so no `libeay32.dll` / `ssleay32.dll`;
- the web UI is embedded in the binary (`webui.res`).

So the installer ships just the exe plus `LICENSE`, `README.md`, and `docs\`. There are no runtime DLLs to bundle.

> The FPC build links `libsqlite3` dynamically and would need `sqlite3.dll`; this installer targets the **Delphi Release** build, which does not.

There is a **separate installer per architecture** — `PasClaw-<version>-x64-setup.exe` and `PasClaw-<version>-x86-setup.exe`.

**Windows on ARM:** the x64 installer is marked `x64compatible`, so it also
installs and runs on Windows on ARM through the OS's built-in x64 emulation.
Delphi has no native Windows-ARM64 compiler target, so this emulated x64 build
is how PasClaw runs on ARM — there's no separate ARM64 installer. (The
`x64compatible` / `x86compatible` identifiers require **Inno Setup 6.3 or
newer**.)

## Build

1. Build the Release binary for each target in RAD Studio (or `dcc`), so they land at:

   ```
   build\delphi\Win64\Release\PasClaw.exe    (x64)
   build\delphi\Win32\Release\PasClaw.exe    (x86)
   ```

   (In the IDE: set the platform to **Win64** or **Win32**, config **Release**, and build `src\pasclaw\PasClaw.dproj`.)

2. Compile the installer(s) — one per architecture:

   ```
   iscc /DArch=x64 installer\pasclaw.iss
   iscc /DArch=x86 installer\pasclaw.iss
   ```

   The setup EXEs are written to `installer\Output\`.

   `build.bat [version]` builds both in one go (skipping any arch whose binary is missing).

### Options (ISCC `/D` defines)

| Define | Default | Purpose |
|--------|---------|---------|
| `Arch` | `x64` | Target architecture: `x64` or `x86`. Sets the default source path and the output filename suffix. |
| `MyAppVersion` | `0.1.3` | Version shown in the installer / Add-Remove Programs. Pass your release/tag: `iscc /DArch=x64 /DMyAppVersion=0.2.0 installer\pasclaw.iss`. |
| `SourceExe` | per-arch path above | Override the built-binary path, e.g. `iscc /DArch=x64 /DSourceExe=C:\out\PasClaw.exe installer\pasclaw.iss`. |

Both installers share one `AppId`, so they're the same application — installing the x86 build over an x64 install (or vice versa) upgrades in place rather than creating a duplicate.

## Release artifacts in CI

Publishing a GitHub Release triggers `.github/workflows/release-artifacts.yml`,
which attaches the downloadable builds. The two platforms are handled
differently because of tooling licenses:

### Windows installers (hybrid: you build, CI packages)

GitHub's hosted runners can't run Delphi (no license), but they *can* run Inno
Setup. So **you** compile the self-contained `PasClaw.exe` locally with Delphi,
and CI turns those exes into the two setup installers.

1. Build the Release binaries locally (Win64 and/or Win32), as above.
2. Create a GitHub **Release** (tag like `v0.2.0`) and attach the binaries,
   named **exactly**:

   | Attach this file | From this build |
   |------------------|-----------------|
   | `PasClaw-x64.exe` | `build\delphi\Win64\Release\PasClaw.exe` |
   | `PasClaw-x86.exe` | `build\delphi\Win32\Release\PasClaw.exe` |

   Attaching just one arch is fine — CI packages whatever is present and warns
   about the missing one.
3. Publishing the release runs the workflow. It downloads those exes, installs
   Inno Setup via Chocolatey, runs `iscc` with the matching `/DArch` + version,
   and uploads `PasClaw-<version>-x64-setup.exe` /
   `PasClaw-<version>-x86-setup.exe` back to the same release.
4. Because the Delphi build is self-contained, the same exe is also a working
   no-installer binary. The job zips it up as
   `PasClaw-<version>-x64-portable.zip` (and `-x86-`, each holding `PasClaw.exe`)
   and **removes the raw `PasClaw-x64.exe` / `PasClaw-x86.exe` upload name**, so
   the finished release lists intentional downloads (setup + portable zip)
   instead of the CI input. A re-run can still find the binary — it falls back to
   the portable zip (extracting the exe) when the raw name is gone.

### Linux tarballs (fully in CI)

Free Pascal has no license gate, so the hosted runner **compiles the Linux
binaries from source itself** — nothing to upload by hand. A matrix builds both
architectures on native runners (no cross toolchain):

| Tarball | Runner |
|---------|--------|
| `pasclaw-<version>-linux-x86_64.tar.gz`  | `ubuntu-latest` (x64) |
| `pasclaw-<version>-linux-aarch64.tar.gz` | `ubuntu-24.04-arm` (arm64) |

Each job builds inside `debian:bookworm` (the exact apt layout the `Makefile`
targets, same as `docker/Dockerfile`; the container auto-pulls the runner's
arch), then assembles a self-contained tarball containing the `pasclaw` binary,
arch-matched bundled OpenSSL 1.0.2 (`libssl`/`libcrypto`, `RPATH=$ORIGIN` —
Indy's TLS needs 1.0.x, which modern distros no longer ship), `LICENSE`,
`README.md`, and `docs/`. The only runtime dependency left is `libsqlite3`
(present on virtually every Linux install; `apt install libsqlite3-0`
otherwise).

> The `ubuntu-24.04-arm` runner is free for public repositories.

To (re-)produce artifacts for an existing release, run the workflow manually
("Run workflow") and pass its tag.

## What the installer does

- Installs to `Program Files\PasClaw` (per-machine, admin) or the per-user
  app folder — the user chooses in the privileges dialog.
- **Adds the install dir to `PATH`** (opt-in task, on by default) so `pasclaw`
  works from any terminal; removed cleanly on uninstall.
- Start Menu shortcuts: **PasClaw Web UI** (`pasclaw serve`), **PasClaw
  Terminal** (a console in the install dir), **Documentation**, **Uninstall**.
- Offers to run **`pasclaw onboard`** in a console when install finishes.
