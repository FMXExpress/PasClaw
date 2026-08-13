# Vendored: retro window manager

`FMX.RetroWindows.pas` and `FMX.RetroSkins.pas` are copied verbatim from
[Cross-Platform-Retro-OS-Styles](https://github.com/FMXExpress/Cross-Platform-Retro-OS-Styles)
(MIT, same author — `LICENSE` alongside them is that repo's).

They live here so `PasclawDesktop.dproj` opens and builds from a plain
checkout of this repository. Referencing them across a `..\..\` path meant
the project only compiled on a machine that happened to have the styles repo
checked out as a sibling, and failed with `F1026 File not found` everywhere
else.

**Do not edit these two files.** To pick up upstream changes, copy them over
again:

```sh
cp <styles-repo>/Source/FMX.Retro*.pas desktop/retro/
```

The `.style` files are vendored too, from the same upstream, but they live
in [`../FMXStyles/Retro`](../FMXStyles/Retro) rather than here — that path is
what `FindStyleDir` looks for at runtime, and keeping the upstream layout
means refreshing them is a straight copy:

```sh
cp -r <styles-repo>/FMXStyles/Retro desktop/FMXStyles/
```
