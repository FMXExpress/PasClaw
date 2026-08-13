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

## `.style` files must keep CRLF line endings

Each `.rolemap` records the **byte offsets** of the color literals in its
`.style`, and `TRetroSkins.Build` refuses a style whose size disagrees with
the map before patching a single color. The maps were generated against the
CRLF form, so converting a style to LF shifts every offset and makes all 221
skins unusable — a mismatch that shows up only as an exception when someone
picks a color scheme, never at build time.

`.gitattributes` marks `*.style -text` so git cannot normalize them on any
platform. That protects what is already committed; a refresh can still
reintroduce the problem, because the upstream repo stores these LF-normalized
and a Linux or macOS checkout of it hands you LF files. **After copying, put
the line endings back and check the result:**

```sh
python3 - <<'EOF'
import glob, io
for st in sorted(glob.glob('desktop/FMXStyles/Retro/*.style')):
    b = open(st, 'rb').read()
    if b'\r\n' not in b:
        open(st, 'wb').write(b.replace(b'\n', b'\r\n'))
    size = len(open(st, 'rb').read())
    want = next(int(l.split('=')[1]) for l in io.open(st[:-6] + '.rolemap')
                if l.startswith('bytes='))
    print('%-40s %s' % (st, 'ok' if size == want else
                        'MISMATCH %d != %d' % (size, want)))
EOF
```

Every line must say `ok`. On Windows the copy will already be CRLF and the
script is a no-op that just confirms it.
