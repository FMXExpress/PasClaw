# PasClaw Windows installer (Inno Setup)

`pasclaw.iss` builds a Windows installer for PasClaw with [Inno Setup 6](https://jrsoftware.org/isinfo.php).

The Windows (Delphi/dcc64) build is **self-contained** — a single `PasClaw.exe`:

- SQLite is linked statically (FireDAC static wrapper), so no `sqlite3.dll`;
- TLS uses Windows **SChannel**, so no `libeay32.dll` / `ssleay32.dll`;
- the web UI is embedded in the binary (`webui.res`).

So the installer ships just the exe plus `LICENSE`, `README.md`, and `docs\`. There are no runtime DLLs to bundle.

> The FPC build links `libsqlite3` dynamically and would need `sqlite3.dll`; this installer targets the **Delphi Release** build, which does not.

There is a **separate installer per architecture** — `PasClaw-<version>-x64-setup.exe` and `PasClaw-<version>-x86-setup.exe`.

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
| `MyAppVersion` | `0.1.0` | Version shown in the installer / Add-Remove Programs. Pass your release/tag: `iscc /DArch=x64 /DMyAppVersion=0.2.0 installer\pasclaw.iss`. |
| `SourceExe` | per-arch path above | Override the built-binary path, e.g. `iscc /DArch=x64 /DSourceExe=C:\out\PasClaw.exe installer\pasclaw.iss`. |

Both installers share one `AppId`, so they're the same application — installing the x86 build over an x64 install (or vice versa) upgrades in place rather than creating a duplicate.

## What the installer does

- Installs to `Program Files\PasClaw` (per-machine, admin) or the per-user
  app folder — the user chooses in the privileges dialog.
- **Adds the install dir to `PATH`** (opt-in task, on by default) so `pasclaw`
  works from any terminal; removed cleanly on uninstall.
- Start Menu shortcuts: **PasClaw Web UI** (`pasclaw serve`), **PasClaw
  Terminal** (a console in the install dir), **Documentation**, **Uninstall**.
- Offers to run **`pasclaw onboard`** in a console when install finishes.
