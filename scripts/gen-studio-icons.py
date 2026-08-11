#!/usr/bin/env python3
"""Generate the platform icon button styles for the bundled Studio styles.

Why this exists
---------------
`ApplyButtonIcon` in studio/MasterDetail.pas gives toolbar buttons an icon by
assigning `TButton.StyleLookup`. Those lookup names are *Embarcadero platform
style* resources -- they are not free-form strings, and they only resolve when
the ACTIVE style defines them. PasclawDark/PasclawLight are custom style books,
so with them applied not one of the lookups resolved and every button kept its
caption (which is what `StyleLookupExists` is for: it refuses to blank a caption
for a lookup the style does not have). Correct, but it meant no icons ever.

This script closes that hole: it clones each style book's own `buttonstyle`
entry once per icon name, swaps the TGlyph placeholder for a TPath glyph, and
writes the result back. Cloning rather than authoring from scratch means the
icon buttons inherit the theme's exact background, hover/press animations and
focus glow -- they cannot drift from the rest of the chrome.

The names below are the subset of
https://docwiki.embarcadero.com/RADStudio/Sydney/en/Using_Styled_and_Colored_Buttons_on_Target_Platforms
that (a) is available on Windows and (b) has an IconTintColor entry -- the
column is the giveaway for which lookups actually carry a glyph. Names such as
DeleteToolButton or DoneToolButton are real but tint-less: they are coloured
button *shapes*, not icons, so an icon-only button using one renders blank.
Do not add a name here that is not in that table.

Glyph geometry is in a 0..1 box; TPath.WrapMode defaults to Fit, so it scales
to whatever size the style gives the path. Data.Path streams as
`Int32 count` then `Int32 kind, Single X, Single Y` per point
(kind 0 = MoveTo, 1 = LineTo) -- verified against the paths already in the
style files.

    usage: python3 scripts/gen-studio-icons.py [--check]

`--check` regenerates in memory and fails if the files are out of date, so CI
can catch a hand-edit that diverges from this source of truth.

DFM has NO comment syntax. The first version of this script bracketed its
output with '{ --- generated --- }' marker lines; to the object-text parser a
'{' opens BINARY HEX DATA, so TStyleBook.LoadFromFile raised on the marker,
the loader swallowed the exception, and the app silently fell back to the
platform default style -- broken theme, dead Light/Dark toggle, and the
platform's own glyphs where ours should be. Generated blocks are therefore
identified by their StyleName (the 16 lookup names belong to this script and
nothing else), and validate() enforces the real parser rule -- everything
inside braces must be hex -- across the whole file before a byte is written.
"""
import math
import re
import struct
import sys

STYLES = [
    # path,                       icon fill,   hover wash,  focus ring
    ("studio/PasclawDark.style",  "xFFD6DDE6", "claWhite",  "xFF3BA7FF"),
    ("studio/PasclawLight.style", "xFF4A5563", "claBlack",  "xFF0969DA"),
]

# Lookups with NO Embarcadero platform equivalent -- they exist only because
# this script writes them into the bundled books. MasterDetail.pas must treat
# them as unavailable when no book is loaded (otherwise an icon-only button
# blanks its caption and renders empty on the fallback path), so it carries the
# same list as PASCLAW_ONLY_LOOKUPS and --check verifies the two agree.
CUSTOM = {"SunToolButton", "MoonToolButton",
          "ImportToolButton", "ExportToolButton",
          "MenuToolButton", "SlidersToolButton",
          "ExpandToolButton", "CollapseToolButton",
          "LinkedToolButton", "UnlinkedToolButton"}

PAS_SOURCE = "studio/MasterDetail.pas"

# legacy marker lines from the first version; stripped on sight (migration)
LEGACY_MARKERS = {
    "{ --- generated icon button styles: scripts/gen-studio-icons.py --- }",
    "{ --- end generated icon button styles --- }",
}


# ---------------------------------------------------------------- geometry --

def arc(cx, cy, r, a0, a1, steps=28):
    """Points along a circular arc; angles in degrees, screen y (down)."""
    return [(cx + r * math.cos(math.radians(a)), cy - r * math.sin(math.radians(a)))
            for a in (a0 + (a1 - a0) * i / steps for i in range(steps + 1))]


def ring(cx, cy, r_out, r_in, a0=0.0, a1=360.0, steps=32):
    """An annulus as ONE closed polygon: outer arc out, inner arc back.

    Reversing the inner arc makes the hole wind opposite the rim, so nonzero
    fill leaves it empty -- no reliance on an even-odd fill rule.
    """
    return arc(cx, cy, r_out, a0, a1, steps) + arc(cx, cy, r_in, a1, a0, steps)


def polar(cx, cy, a, r):
    return (cx + r * math.cos(math.radians(a)), cy - r * math.sin(math.radians(a)))


def rect(x0, y0, x1, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def rect_rev(x0, y0, x1, y1):
    return [(x0, y0), (x0, y1), (x1, y1), (x1, y0)]


def area(sub):
    """Signed area -- its sign is the subpath's winding direction."""
    return sum(x0 * y1 - x1 * y0
               for (x0, y0), (x1, y1) in zip(sub, sub[1:] + sub[:1])) / 2.0


def wind(sub, like):
    """Make `sub` wind the same way as `like`.

    Overlapping subpaths of OPPOSITE winding cancel under the nonzero fill
    rule -- that is what makes ring()'s hole work, and it is also what turned
    the refresh arrowhead into a sliver where it met the rim. Anything meant
    to ADD to a shape it touches has to turn the same way.
    """
    return sub if (area(sub) >= 0) == (area(like) >= 0) else list(reversed(sub))


def flip_y(sub):
    return [(x, 1.0 - y) for x, y in sub]


def flip_x(sub):
    return [(1.0 - x, y) for x, y in sub]


def swap(sub):
    return [(y, x) for x, y in sub]


ARROW_UP = [(0.50, 0.03), (0.97, 0.50), (0.70, 0.50), (0.70, 0.97),
            (0.30, 0.97), (0.30, 0.50), (0.03, 0.50)]

# Refresh: an open ring plus the arrowhead that closes its sweep. The sweep
# runs 100 -> 365 degrees, so "forward" at the open end is a larger angle --
# the head sits past the rim's last point, not on top of it.
_REFRESH_RING = ring(0.5, 0.5, 0.45, 0.30, 100.0, 365.0)
_REFRESH_HEAD = wind([polar(0.5, 0.5, 5.0, 0.60),
                      polar(0.5, 0.5, 5.0, 0.15),
                      polar(0.5, 0.5, 52.0, 0.375)], _REFRESH_RING)

# Sun: disc + 8 rays; moon: one closed path -- an outer arc plus a concave
# return arc, so nonzero winding needs no cancellation tricks. These two are
# PASCLAW-CUSTOM lookup names (no platform equivalent exists for a theme
# toggle); they are safe for the same reason every name here is: only styles
# this generator writes define them, and StyleLookupExists keeps captions on
# any style that does not.
_SUN = [ring(0.5, 0.5, 0.30, 0.19)] + [
    wind([polar(0.5, 0.5, a - 7.0, 0.38), polar(0.5, 0.5, a + 7.0, 0.38),
          polar(0.5, 0.5, a + 5.0, 0.50), polar(0.5, 0.5, a - 5.0, 0.50)],
         [(0, 0), (1, 0), (1, 1), (0, 1)])
    for a in range(0, 360, 45)]

_MOON = [arc(0.5, 0.5, 0.42, 50.0, 310.0) +
         arc(0.78, 0.5, 0.322, 268.0, 92.0)]

# import/export: a tray with an arrow entering or leaving it
_TRAY = [(0.06, 0.60), (0.20, 0.60), (0.20, 0.80), (0.80, 0.80),
         (0.80, 0.60), (0.94, 0.60), (0.94, 0.96), (0.06, 0.96)]
_ARROW_INTO = [(0.42, 0.02), (0.58, 0.02), (0.58, 0.34), (0.76, 0.34),
               (0.50, 0.66), (0.24, 0.34), (0.42, 0.34)]

# pager ends: a double chevron
_CHEV_L = [[(x, 0.50), (x + 0.26, 0.06), (x + 0.40, 0.14),
            (x + 0.19, 0.50), (x + 0.40, 0.86), (x + 0.26, 0.94)]
           for x in (0.06, 0.48)]

# Chrome controls that carry no caption at all. Each is a shape that has to
# survive at 8px, so they are built from bars, discs and blunt arrows -- a
# chain link or a plug would be mush at this size.
_MENU = [rect(0.05, 0.13, 0.95, 0.27),
         rect(0.05, 0.43, 0.95, 0.57),
         rect(0.05, 0.73, 0.95, 0.87)]

# two tracks, each with its handle at a different position
_SLIDERS = [rect(0.04, 0.17, 0.96, 0.29), rect(0.58, 0.07, 0.78, 0.39),
            rect(0.04, 0.61, 0.96, 0.73), rect(0.22, 0.51, 0.42, 0.83)]

# arrows leaving the centre (expand) and arriving at it (collapse)
_ARROW_OUT_L = [(0.02, 0.50), (0.30, 0.20), (0.30, 0.39),
                (0.46, 0.39), (0.46, 0.61), (0.30, 0.61), (0.30, 0.80)]
_EXPAND = [_ARROW_OUT_L, flip_x(_ARROW_OUT_L)]
_ARROW_IN_L = [(0.46, 0.50), (0.18, 0.20), (0.18, 0.39),
               (0.02, 0.39), (0.02, 0.61), (0.18, 0.61), (0.18, 0.80)]
_COLLAPSE = [_ARROW_IN_L, flip_x(_ARROW_IN_L)]

# live = solid, offline = hollow; the oldest status convention there is
_LINKED = [arc(0.5, 0.5, 0.35, 0.0, 360.0)]
_UNLINKED = [ring(0.5, 0.5, 0.37, 0.21)]

# ------------------------------------------------------------------ glyphs --
# Each entry: lookup name -> list of closed subpaths.

GLYPHS = {
    "ArrowUpToolButton":    [ARROW_UP],
    "ArrowDownToolButton":  [flip_y(ARROW_UP)],
    "ArrowLeftToolButton":  [swap(ARROW_UP)],
    "ArrowRightToolButton": [flip_x(swap(ARROW_UP))],

    "StopToolButton":       [rect(0.18, 0.18, 0.82, 0.82)],

    "PlayToolButton":       [[(0.22, 0.06), (0.92, 0.50), (0.22, 0.94)]],
    "PauseToolButton":      [rect(0.20, 0.08, 0.42, 0.92),
                             rect(0.58, 0.08, 0.80, 0.92)],

    "AddToolButton":        [[(0.36, 0.05), (0.64, 0.05), (0.64, 0.36),
                              (0.95, 0.36), (0.95, 0.64), (0.64, 0.64),
                              (0.64, 0.95), (0.36, 0.95), (0.36, 0.64),
                              (0.05, 0.64), (0.05, 0.36), (0.36, 0.36)]],

    # lid bar + lid handle + tapered body
    "TrashToolButton":      [rect(0.08, 0.17, 0.92, 0.29),
                             rect(0.37, 0.04, 0.63, 0.17),
                             [(0.17, 0.33), (0.83, 0.33),
                              (0.74, 0.96), (0.26, 0.96)]],

    "RefreshToolButton":    [_REFRESH_RING, _REFRESH_HEAD],

    # lens ring + handle
    "MenuToolButton":       _MENU,
    "SlidersToolButton":    _SLIDERS,
    "ExpandToolButton":     _EXPAND,
    "CollapseToolButton":   _COLLAPSE,
    "LinkedToolButton":     _LINKED,
    "UnlinkedToolButton":   _UNLINKED,

    "SunToolButton":        _SUN,
    "MoonToolButton":       _MOON,

    "ImportToolButton":     [_TRAY, _ARROW_INTO],
    "ExportToolButton":     [_TRAY, flip_y([(x, y + 0.36) for x, y in _ARROW_INTO])],
    "PriorToolButton":      _CHEV_L,
    "NextToolButton":       [flip_x(s) for s in _CHEV_L],

    "SearchToolButton":     [ring(0.42, 0.40, 0.36, 0.23),
                             [(0.60, 0.66), (0.70, 0.56),
                              (0.98, 0.84), (0.88, 0.94)]],

    # pencil body + tip
    "ComposeToolButton":    [[(0.79, 0.09), (0.91, 0.21),
                              (0.34, 0.78), (0.22, 0.66)],
                             [(0.22, 0.66), (0.34, 0.78), (0.12, 0.88)]],

    # back sheet (L) + front sheet drawn as an outlined rectangle
    "ActionToolButton":     [[(0.05, 0.05), (0.62, 0.05), (0.62, 0.18),
                              (0.23, 0.18), (0.23, 0.76), (0.05, 0.76)],
                             rect(0.32, 0.24, 0.95, 0.95),
                             rect_rev(0.44, 0.36, 0.83, 0.83)],

    "OrganizeToolButton":   [[(0.04, 0.16), (0.40, 0.16), (0.49, 0.30),
                              (0.96, 0.30), (0.96, 0.86), (0.04, 0.86)]],

    # ring + dot + stem
    "InfoToolButton":       [ring(0.5, 0.5, 0.48, 0.36),
                             rect(0.42, 0.18, 0.58, 0.32),
                             rect(0.42, 0.40, 0.58, 0.82)],

    # three rows of "dot + bar"
    "DetailsToolButton":    [s for i, y in enumerate((0.09, 0.42, 0.75))
                             for s in (rect(0.03, y, 0.19, y + 0.16),
                                       rect(0.29, y, 0.97, y + 0.16))],
}


# ------------------------------------------------------------- DFM encoding --

def path_hex(subpaths):
    pts = []
    for sub in subpaths:
        for i, (x, y) in enumerate(sub):
            pts.append((0 if i == 0 else 1, x, y))
        pts.append((1, sub[0][0], sub[0][1]))     # explicit close
    blob = struct.pack("<i", len(pts))
    for kind, x, y in pts:
        blob += struct.pack("<iff", kind, x, y)
    return blob.hex().upper()


def path_object(name, fill, indent):
    hx = path_hex(GLYPHS[name])
    rows = [hx[i:i + 64] for i in range(0, len(hx), 64)]
    body = ("\n" + indent + "    ").join(rows)
    return "\n".join([
        indent + "object TPath",
        indent + "  StyleName = 'icon'",
        indent + "  Align = Center",
        indent + "  Fill.Color = " + fill,
        indent + "  Fill.Kind = Solid",
        indent + "  HitTest = False",
        indent + "  Locked = True",
        indent + "  Stroke.Kind = None",
        indent + "  WrapMode = Fit",
        indent + "  Height = 8.000000000000000000",
        indent + "  Width = 8.000000000000000000",
        indent + "  Data.Path = {",
        indent + "    " + body + "}",
        indent + "end",
    ])


# ---------------------------------------------------------------- emission --

def block_at(lines, style_name):
    """(start, end) line indices of the `object T...` whose StyleName matches."""
    for i, ln in enumerate(lines):
        if ln.strip() == "StyleName = '%s'" % style_name:
            start = i - 1
            indent = len(lines[start]) - len(lines[start].lstrip())
            j = start + 1
            while j < len(lines):
                s = lines[j]
                if s.strip() == "end" and (len(s) - len(s.lstrip())) == indent:
                    return start, j
                j += 1
            break
    raise SystemExit("no '%s' block found" % style_name)


def icon_style(name, fill, hover, focus, indent):
    """A FLAT icon button style: glyph, hover wash, focus ring -- no box.

    Deliberately NOT a clone of the theme's buttonstyle: icon buttons carry no
    border and no gradient face ("can we have them not have an
    edge/outline"). Affordance comes from the wash, a rounded rectangle that
    fades in under the pointer (opacity 0 -> 0.10) and presses slightly
    darker, which is how flat icon buttons behave everywhere else.

    The focus ring is not optional: these buttons have no caption, so a
    keyboard user Tabbing through them has NOTHING saying which icon Enter
    will press unless the style shows it. The clone approach inherited the
    theme's IsFocused glow; the flat style must provide its own.
    """
    pad = indent + "  "
    return "\n".join([
        indent + "object TLayout",
        pad + "StyleName = '%s'" % name.lower(),
        pad + "DesignVisible = False",
        pad + "Height = 24.000000000000000000",
        pad + "Width = 34.000000000000000000",
        pad + "object TRectangle",
        pad + "  StyleName = 'hoverwash'",
        pad + "  Align = Contents",
        pad + "  Fill.Color = " + hover,
        pad + "  HitTest = False",
        pad + "  Locked = True",
        pad + "  Opacity = 0.000000000000000000",
        pad + "  Stroke.Kind = None",
        pad + "  XRadius = 6.000000000000000000",
        pad + "  YRadius = 6.000000000000000000",
        pad + "  object TFloatAnimation",
        pad + "    Duration = 0.150000005960464500",
        pad + "    PropertyName = 'Opacity'",
        pad + "    StartValue = 0.000000000000000000",
        pad + "    StopValue = 0.100000001490116100",
        pad + "    Trigger = 'IsMouseOver=true'",
        pad + "    TriggerInverse = 'IsMouseOver=false'",
        pad + "  end",
        pad + "  object TFloatAnimation",
        pad + "    Duration = 0.100000001490116100",
        pad + "    PropertyName = 'Opacity'",
        pad + "    StartValue = 0.100000001490116100",
        pad + "    StopValue = 0.200000002980232200",
        pad + "    Trigger = 'IsPressed=true'",
        pad + "    TriggerInverse = 'IsPressed=false'",
        pad + "  end",
        pad + "end",
        pad + "object TRectangle",
        pad + "  StyleName = 'focusring'",
        pad + "  Align = Contents",
        pad + "  Fill.Kind = None",
        pad + "  HitTest = False",
        pad + "  Locked = True",
        pad + "  Opacity = 0.000000000000000000",
        pad + "  Stroke.Color = " + focus,
        pad + "  Stroke.Thickness = 1.500000000000000000",
        pad + "  XRadius = 6.000000000000000000",
        pad + "  YRadius = 6.000000000000000000",
        pad + "  object TFloatAnimation",
        pad + "    Duration = 0.100000001490116100",
        pad + "    PropertyName = 'Opacity'",
        pad + "    StartValue = 0.000000000000000000",
        pad + "    StopValue = 1.000000000000000000",
        pad + "    Trigger = 'IsFocused=true'",
        pad + "    TriggerInverse = 'IsFocused=false'",
        pad + "  end",
        pad + "end",
        path_object(name, fill, pad),
        indent + "end",
    ])


def strip_generated(lines):
    """Remove this script's previous output: legacy marker lines, and any
    object whose StyleName is one of the 16 generated lookup names."""
    gen_names = {n.lower() for n in GLYPHS}
    out, i = [], 0
    while i < len(lines):
        s = lines[i].strip()
        if s in LEGACY_MARKERS:
            i += 1
            continue
        if s.startswith("object ") and i + 1 < len(lines):
            m = re.match(r"^StyleName = '([a-z]+)'$", lines[i + 1].strip())
            if m and m.group(1) in gen_names:
                indent = len(lines[i]) - len(lines[i].lstrip())
                j = i + 1
                while j < len(lines) and not (
                        lines[j].strip() == "end"
                        and (len(lines[j]) - len(lines[j].lstrip())) == indent):
                    j += 1
                i = j + 1
                continue
        out.append(lines[i])
        i += 1
    return out


def validate(text, path):
    """Enforce the object-text parser's brace rule over the whole file.

    DFM text has no comments: '{' opens a binary-data token and everything up
    to '}' must be hexadecimal. A violation anywhere makes LoadFromFile raise
    and the app silently fall back to the platform style, so this checks the
    ENTIRE file -- hand-written parts included -- not just this script's own
    output. Quoted strings are skipped, as the parser skips them.
    """
    errs, i, line, n = [], 0, 1, len(text)
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
        elif c == "'":
            j = i + 1
            while j < n and text[j] != "'" and text[j] != "\n":
                j += 1
            i = j
        elif c == "{":
            j = text.find("}", i + 1)
            if j < 0:
                errs.append((line, "unterminated '{' binary-data token"))
                break
            blob = text[i + 1:j]
            if re.search(r"[^0-9A-Fa-f\s]", blob):
                errs.append(
                    (line, "non-hex inside {...}: DFM has no comment syntax; "
                           "braces open binary data"))
            line += blob.count("\n")
            i = j
        i += 1
    for ln, msg in errs:
        print("%s(%d): %s" % (path, ln, msg))
    return not errs


def build(path, fill, hover, focus):
    src = open(path, encoding="utf-8", errors="replace").read()
    lines = strip_generated(src.split("\n"))

    # anchor after the theme's own buttonstyle so the icons live beside it
    start, end = block_at(lines, "buttonstyle")
    indent = " " * (len(lines[start]) - len(lines[start].lstrip()))

    generated = []
    for name in sorted(GLYPHS):
        generated.append(icon_style(name, fill, hover, focus, indent))

    return "\n".join(lines[:end + 1] + generated + lines[end + 1:])


def check_custom_list():
    """PASCLAW_ONLY_LOOKUPS in the Pascal source must equal CUSTOM."""
    try:
        src = open(PAS_SOURCE, encoding="utf-8", errors="replace").read()
    except OSError as exc:
        print("%s: cannot read (%s)" % (PAS_SOURCE, exc))
        return False
    m = re.search(r"PASCLAW_ONLY_LOOKUPS:\s*array\[[^\]]*\]\s*of\s*string\s*=\s*\(([^)]*)\)",
                  src, re.S)
    if not m:
        print("%s: PASCLAW_ONLY_LOOKUPS not found" % PAS_SOURCE)
        return False
    listed = set(re.findall(r"'([^']+)'", m.group(1)))
    want = {n.lower() for n in CUSTOM}
    if listed != want:
        print("%s: PASCLAW_ONLY_LOOKUPS disagrees with this script's CUSTOM set"
              % PAS_SOURCE)
        for n in sorted(want - listed):
            print("    missing from Pascal: %s" % n)
        for n in sorted(listed - want):
            print("    not a custom lookup: %s" % n)
        return False
    unknown = CUSTOM - set(GLYPHS)
    if unknown:
        print("CUSTOM names with no glyph: %s" % ", ".join(sorted(unknown)))
        return False
    print("%s: PASCLAW_ONLY_LOOKUPS matches (%d custom)" % (PAS_SOURCE, len(want)))
    return True


def main(argv):
    check = "--check" in argv
    bad = 0
    if not check_custom_list():
        bad += 1
    for path, fill, hover, focus in STYLES:
        want = build(path, fill, hover, focus)
        if not validate(want, path):
            print("%s: INVALID -- refusing to %s" %
                  (path, "pass" if check else "write"))
            bad += 1
            continue
        have = open(path, encoding="utf-8", errors="replace").read()
        if want == have:
            print("%s: up to date (%d icons)" % (path, len(GLYPHS)))
            continue
        if check:
            print("%s: OUT OF DATE -- run scripts/gen-studio-icons.py" % path)
            bad += 1
        else:
            open(path, "w", encoding="utf-8", newline="").write(want)
            print("%s: wrote %d icon styles" % (path, len(GLYPHS)))
    return bad


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
