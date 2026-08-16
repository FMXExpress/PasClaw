#!/usr/bin/env python3
"""Export the FireMonkey retro styles' palettes as CSS custom properties.

The desktop web UI (src/pkg/gateway/desktop.html) has to look like the FMX
desktop app, and both take their colors from the SAME source: the PALETTES
table in Cross-Platform-Retro-OS-Styles' tools/generate_retro_styles.py, which
is what the .style files themselves are generated from. This script imports
that table and emits the CSS.

Hand-copying hex values would guarantee drift the first time a style is
tweaked; importing the generator means a re-run picks the change up.

Usage:
    scripts/export-retro-palettes.py [--styles-repo PATH] [-o OUT]

Default --styles-repo is a sibling checkout:
    ../Cross-Platform-Retro-OS-Styles
(also tries the lowercase name, and $RETRO_STYLES_REPO).

Output is a CSS file defining, for each style, a
    [data-style="Win95"] { --face: #c0c0c0; ... }
block, plus a JS-readable manifest comment listing the style names. The
desktop page ships this inline.
"""

import argparse
import importlib.util
import json
import os
import sys

# The role names the desktop UI consumes. The generator carries more (every
# widget nuance the .style files need); these are the ones a CSS window
# manager can actually express. Anything missing from a palette falls back to
# a related role rather than to an arbitrary default -- see FALLBACKS.
ROLES = [
    "face", "light", "highlight", "shadow", "darkshadow", "darker",
    "window", "text", "black", "selection", "selectiontext", "disabledtext",
    "desktop", "progress",
    "titleA", "titleA2", "titleAText",
    "titleI", "titleI2", "titleIText",
    "accent", "track", "dot",
]

# When a palette omits a role, borrow the nearest one that means the same
# thing rather than inventing a color.
FALLBACKS = {
    "titleA2": "titleA",
    "titleI2": "titleI",
    "darker": "shadow",
    "light": "face",
    "highlight": "light",
    "track": "face",
    "dot": "text",
    "black": "text",
    "progress": "selection",
    "accent": "selection",
    "disabledtext": "shadow",
    "selectiontext": "window",
    "titleAText": "window",
    "titleIText": "face",
}


def fmx_to_css(value):
    """'xFFC0C0C0' (AARRGGBB) -> '#c0c0c0', or 'rgba(...)' when translucent."""
    if value is None:
        return None
    s = str(value)
    if s.startswith(("x", "X")):
        s = s[1:]
    if len(s) == 8:
        a, rgb = int(s[0:2], 16), s[2:]
        if a == 255:
            return "#" + rgb.lower()
        r, g, b = int(rgb[0:2], 16), int(rgb[2:4], 16), int(rgb[4:6], 16)
        return f"rgba({r},{g},{b},{a / 255:.3f})"
    if len(s) == 6:
        return "#" + s.lower()
    return None


def load_palettes(repo):
    gen = os.path.join(repo, "tools", "generate_retro_styles.py")
    if not os.path.isfile(gen):
        raise SystemExit(
            f"generator not found at {gen}\n"
            "Point --styles-repo at a checkout of "
            "https://github.com/FMXExpress/Cross-Platform-Retro-OS-Styles"
        )
    spec = importlib.util.spec_from_file_location("retro_gen", gen)
    mod = importlib.util.module_from_spec(spec)
    # The generator writes .style files when run as __main__; importing it as
    # a module executes only the table definitions.
    sys.modules["retro_gen"] = mod
    spec.loader.exec_module(mod)
    if not hasattr(mod, "PALETTES"):
        raise SystemExit("generator has no PALETTES table -- has it been restructured?")
    return mod.PALETTES


def resolve(pal, role, seen=None):
    """A role's value, following FALLBACKS until something concrete turns up."""
    seen = seen or set()
    if role in seen:
        return None
    seen.add(role)
    val = pal.get(role)
    if val is not None:
        return fmx_to_css(val)
    nxt = FALLBACKS.get(role)
    return resolve(pal, nxt, seen) if nxt else None


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    default_repo = os.environ.get("RETRO_STYLES_REPO") or ""
    if not default_repo:
        for cand in ("Cross-Platform-Retro-OS-Styles",
                     "cross-platform-retro-os-styles"):
            p = os.path.join(os.path.dirname(here), cand)
            if os.path.isdir(p):
                default_repo = p
                break
        else:
            default_repo = os.path.join(
                os.path.dirname(here), "Cross-Platform-Retro-OS-Styles")

    ap = argparse.ArgumentParser()
    ap.add_argument("--styles-repo", default=default_repo)
    ap.add_argument("-o", "--out",
                    default=os.path.join(here, "src", "pkg", "gateway",
                                         "desktop-palettes.css"))
    ap.add_argument("--json", help="also write the raw palette map here")
    ap.add_argument("--inject", nargs="?",
                    const=os.path.join(here, "src", "pkg", "gateway",
                                       "desktop.html"),
                    help="also splice the CSS into this HTML file between the "
                         "BEGIN/END GENERATED PALETTES markers (default: "
                         "src/pkg/gateway/desktop.html). This is how the "
                         "single-file desktop page stays single-file without "
                         "anyone hand-copying colors.")
    args = ap.parse_args()

    palettes = load_palettes(args.styles_repo)

    out, manifest = [], []
    out.append("/* GENERATED by scripts/export-retro-palettes.py -- do not edit.\n"
               "   Source: Cross-Platform-Retro-OS-Styles "
               "tools/generate_retro_styles.py PALETTES.\n"
               "   Re-run the script after changing a style's palette. */")

    for name in sorted(palettes):
        pal = palettes[name]
        decls = []
        for role in ROLES:
            css = resolve(pal, role)
            if css:
                decls.append(f"  --{role.lower()}: {css};")
        font = pal.get("font")
        if font:
            # The era's family first, then the platform's own fallbacks -- the
            # originals are not embedded (licensing), same as the .style files.
            decls.append(f'  --font: "{font}", Tahoma, Geneva, Verdana, sans-serif;')
        if not decls:
            continue
        title = pal.get("title", name)
        # Every theme is a homage, and the shipped names say so: the desktop
        # shows "<original> Vibes". Applied here, not hand-edited in the
        # HTML, so a regeneration from the styles repo keeps the suffix.
        if not title.endswith(" Vibes"):
            title += " Vibes"
        manifest.append({"id": name, "title": title,
                         "family": pal.get("family", "")})
        out.append(f'\n[data-style="{name}"] {{\n' + "\n".join(decls) + "\n}")

    out.append("\n/* STYLES = " + json.dumps(manifest, separators=(",", ":")) + " */")

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        f.write("\n".join(out) + "\n")
    print(f"wrote {args.out} ({len(manifest)} styles)")

    if args.json:
        with open(args.json, "w") as f:
            json.dump(manifest, f, indent=2)
        print(f"wrote {args.json}")

    if args.inject:
        inject(args.inject, "\n".join(out))


BEGIN = "/* BEGIN GENERATED PALETTES */"
END = "/* END GENERATED PALETTES */"


def inject(path, css):
    """Replace the marked block in an HTML file with the generated CSS."""
    with open(path) as f:
        html = f.read()
    i, j = html.find(BEGIN), html.find(END)
    if i < 0 or j < 0 or j < i:
        raise SystemExit(
            f"{path} has no {BEGIN} ... {END} block to fill -- add the markers "
            "inside its <style> element.")
    # The generated text carries its own provenance header; keep the markers
    # themselves so a re-run finds the block again.
    body = css
    if body.lstrip().startswith("/* GENERATED"):
        pass  # header already present
    html = html[:i] + BEGIN + "\n" + body.strip() + "\n" + html[j:]
    with open(path, "w") as f:
        f.write(html)
    print(f"injected palettes into {path}")


if __name__ == "__main__":
    main()
