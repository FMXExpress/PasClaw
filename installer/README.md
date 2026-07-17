# PasClaw Windows installer (Inno Setup)

`pasclaw.iss` builds a Windows installer for PasClaw with [Inno Setup 6](https://jrsoftware.org/isinfo.php).

The Windows (Delphi/dcc64) build is **self-contained** — a single `PasClaw.exe`:

- SQLite is linked statically (FireDAC static wrapper), so no `sqlite3.dll`;
- TLS uses Windows **SChannel**, so no `libeay32.dll` / `ssleay32.dll`;
- the web UI is embedded in the binary (`webui.res`).

So the installer ships just the exe plus `LICENSE`, `README.md`, and `docs\`. There are no runtime DLLs to bundle.

> The FPC build links `libsqlite3` dynamically and would need `sqlite3.dll`; this installer targets the **Delphi Release** build, which does not.

## Build

1. Build the Release Win64 binary in RAD Studio (or `dcc64`) so it lands at:

   ```
   build\delphi\Win64\Release\PasClaw.exe
   ```

   (In the IDE: set the target to **Win64 / Release** and build `src\pasclaw\PasClaw.dproj`.)

2. Compile the installer:

   ```
   iscc installer\pasclaw.iss
   ```

   The setup EXE is written to `installer\Output\PasClaw-<version>-setup.exe`.

### Options (ISCC `/D` defines)

| Define | Default | Purpose |
|--------|---------|---------|
| `MyAppVersion` | `0.1.0` | Version shown in the installer / Add-Remove Programs. Pass your release/tag: `iscc /DMyAppVersion=0.2.0 installer\pasclaw.iss`. |
| `SourceExe` | `..\build\delphi\Win64\Release\PasClaw.exe` | Path to the built binary, e.g. if you output elsewhere: `iscc /DSourceExe=C:\out\PasClaw.exe installer\pasclaw.iss`. |

`build.bat` wraps step 2 (pass the version as the first argument).

## What the installer does

- Installs to `Program Files\PasClaw` (per-machine, admin) or the per-user
  app folder — the user chooses in the privileges dialog.
- **Adds the install dir to `PATH`** (opt-in task, on by default) so `pasclaw`
  works from any terminal; removed cleanly on uninstall.
- Start Menu shortcuts: **PasClaw Web UI** (`pasclaw serve`), **PasClaw
  Terminal** (a console in the install dir), **Documentation**, **Uninstall**.
- Offers to run **`pasclaw onboard`** in a console when install finishes.
