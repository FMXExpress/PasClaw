#!/usr/bin/env python3
"""Retone PasclawLight.style onto a warm, low-arousal palette.

Why
---
The light book was built from the stock FMX light style: pure #FFFFFF
grounds, perfectly neutral greys (chroma 0), and a single very saturated
blue (#0969DA, chroma 209) used sixty times. That combination is what makes
it tiring to read -- maximum glare from the paper, no warmth to soften it,
and an accent loud enough to pull the eye everywhere at once.

The approach is borrowed from FMXExpress/Cross-Platform-Retro-OS-Styles,
whose generator classifies every source colour "by chroma and lightness
before mapping it to a role" rather than editing values by hand, and whose
Vellum style is built on "low-arousal neutrals and processing fluency" --
warm paper, hairline rules, one accent. Same idea here:

  * neutrals become WARM neutrals on one hue, saturated at the paper end and
    fading to near-neutral ink, so paper and rules share a family instead of
    reading as clinical grey while the text stays honest black;
  * nothing stays pure white -- the lightest paper is capped, which is the
    single biggest comfort win;
  * chromatic colours all collapse onto ONE accent hue at roughly half the
    original saturation, keeping the blue identity while removing the glare,
    and folding in the stray cyans the stock style left behind.

Deterministic and idempotent: re-running maps the output to itself, which
`--check` verifies, so the style file and this script cannot drift.

    usage: python3 scripts/retone-light.py [--check] [--report]
"""
import colorsys
import re
import sys

TARGET = "studio/PasclawLight.style"

# FMX named colours (TAlphaColorRec) that appear in this book. They are just
# literals under another spelling, and skipping them left 16 claWhite and 10
# claWhitesmoke references pure white and cool while --check happily reported
# the file fully retoned. Only the 'cla' prefix is a colour: 'clearbutton' and
# 'clearingeditstyle' are STYLE NAMES and must not be touched.
NAMED = {
    "claBlack": "FF000000",
    "claWhite": "FFFFFFFF",
    "claWhitesmoke": "FFF5F5F5",
    "claGainsboro": "FFDCDCDC",
    "claGray": "FF808080",
    "claNull": "00000000",
}

# Classification must be a FIXED POINT: the output of a rule has to fall back
# into the same rule, or a second run would keep transforming. Neutrals land on
# a warm hue outside the accent band, and accents land inside it, so both are
# stable.
CHROMA_MIN = 25          # below this a colour is neutral whatever its hue
ACCENT_BAND = (160.0, 270.0)   # degrees: the blues and cyans in this book

WARM_HUE = 40.0 / 360.0  # the paper/ink family
# Warmth belongs to the PAPER, not the ink. The reference palette is warm at
# the light end (#FAF9F5 is ~24% saturated) and almost neutral at the dark end
# (#141413 is ~4%): tinting the darks instead turns mid greys olive, which is
# what the first attempt at this ramp did.
WARM_SAT_LIGHT = 0.20    # saturation at the paper end
WARM_SAT_DARK = 0.04     # saturation at the ink end
PAPER_CEILING = 0.972    # no pure white anywhere
PAPER_KNEE = 0.90        # above this lightness the ramp is compressed

ACCENT_HUE = 212.0 / 360.0
# A CAP, not a scale: capping is idempotent (min(x,c) applied twice is
# min(x,c)) and it leaves already-muted blues untouched instead of bleaching
# them further on every run.
ACCENT_SAT_CAP = 0.48


def parse(hexstr):
    a = int(hexstr[0:2], 16)
    r = int(hexstr[2:4], 16) / 255.0
    g = int(hexstr[4:6], 16) / 255.0
    b = int(hexstr[6:8], 16) / 255.0
    return a, r, g, b


def fmt(a, r, g, b):
    def c(v):
        return max(0, min(255, int(round(v * 255))))
    return "%02X%02X%02X%02X" % (a, c(r), c(g), c(b))


def chroma255(r, g, b):
    return (max(r, g, b) - min(r, g, b)) * 255.0


def in_gamut(h, l, s, chroma):
    """Is this colour already one of our own outputs?

    Needed because the paper compression is not a fixed point on its own --
    feeding F9F8F6 back through would compress it again, and again.

    The tolerance has to widen as chroma falls: at chroma 5 an 8-bit round
    trip can move the measured hue by eight degrees, so a tight test rejects
    the transform's own output and it drifts forever. Near-neutrals are
    therefore accepted on a warm BAND rather than an exact hue.
    """
    if chroma < 1.0:                       # pure grey/black/white: no hue
        return False
    hue_deg = h * 360.0
    if chroma < 30.0:                      # warm neutral family
        return 15.0 <= hue_deg <= 75.0 and l <= PAPER_CEILING + 1e-3
    if abs(hue_deg - ACCENT_HUE * 360.0) < 2.0:
        return s <= ACCENT_SAT_CAP + 1e-3
    if abs(hue_deg - WARM_HUE * 360.0) < 2.0:
        return l <= PAPER_CEILING + 1e-3
    return False


def retone(hexstr):
    a, r, g, b = parse(hexstr)
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    if in_gamut(h, l, s, chroma255(r, g, b)):
        return hexstr.upper()
    hue_deg = h * 360.0
    is_accent = (chroma255(r, g, b) >= CHROMA_MIN and
                 ACCENT_BAND[0] <= hue_deg <= ACCENT_BAND[1])
    if not is_accent:
        # neutral -> warm neutral; warmth grows as it darkens
        # squared, not linear: a linear ramp still leaves mid greys visibly
        # olive and drags body ink towards brown. Warmth has to fall away fast
        # so only the papers carry it.
        new_s = WARM_SAT_DARK + (WARM_SAT_LIGHT - WARM_SAT_DARK) * l * l
        # COMPRESS the top of the range instead of clamping it: a hard cap
        # mapped both #FFFFFF and #F6F8FA onto one value, collapsing panel and
        # background into the same colour and losing the layering entirely.
        if l > PAPER_KNEE:
            new_l = PAPER_KNEE + (l - PAPER_KNEE) * (
                (PAPER_CEILING - PAPER_KNEE) / (1.0 - PAPER_KNEE))
        else:
            new_l = l
        new_h = WARM_HUE
    else:
        new_h = ACCENT_HUE
        new_s = min(s, ACCENT_SAT_CAP)
        new_l = l
    nr, ng, nb = colorsys.hls_to_rgb(new_h, new_l, new_s)
    return fmt(a, nr, ng, nb)


def transform(text):
    """Retone every colour, however it is spelled. Returns (text, map, unknown)."""
    seen = {}
    unknown = set()

    def repl_hex(m):
        src = m.group(1).upper()
        if src not in seen:
            seen[src] = retone(src)
        return "x" + seen[src]

    def repl_named(m):
        name = m.group(0)
        hexval = NAMED.get(name)
        if hexval is None:
            unknown.add(name)
            return name
        out = retone(hexval)
        if out == hexval:
            # identity (claBlack, claNull): leave the name alone rather than
            # churn it into a literal -- gen-studio-icons.py writes claBlack
            # into this same file, and rewriting it here would set the two
            # generators fighting over the same bytes.
            return name
        seen[hexval] = out
        return "x" + out

    text = re.sub(r"\bx([0-9A-Fa-f]{8})\b", repl_hex, text)
    text = re.sub(r"\bcla[A-Za-z]\w*\b", repl_named, text)
    return text, seen, unknown


def main(argv):
    text = open(TARGET, encoding="utf-8", errors="replace").read()
    out, mapping, unknown = transform(text)

    # idempotence: the output must be a fixed point of the same transform
    again, _, _ = transform(out)
    if again != out:
        print("NOT IDEMPOTENT -- retoning twice changes the file")
        return 1

    if "--report" in argv:
        rows = sorted(set((s, d) for s, d in mapping.items() if s != d))
        print("%-10s -> %-10s" % ("from", "to"))
        for s, d in rows:
            print("x%-9s -> x%-9s" % (s, d))
        print("%d distinct colours, %d changed" % (len(mapping), len(rows)))

    if unknown:
        # an unrecognised colour constant would pass straight through and sit
        # outside the palette unnoticed, which is the exact failure this fix
        # is for -- refuse rather than half-retone.
        print("unknown FMX colour constants (add to NAMED): %s"
              % ", ".join(sorted(unknown)))
        return 1

    if "--check" in argv:
        if out != text:
            print("%s: OUT OF DATE -- run scripts/retone-light.py" % TARGET)
            return 1
        print("%s: retoned (%d colours)" % (TARGET, len(mapping)))
        return 0

    if out == text:
        print("%s: already retoned" % TARGET)
    else:
        open(TARGET, "w", encoding="utf-8", newline="").write(out)
        print("%s: retoned %d distinct colours" % (TARGET, len(mapping)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
