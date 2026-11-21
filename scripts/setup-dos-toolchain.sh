#!/bin/sh
# setup-dos-toolchain.sh -- the cross toolchain `make dos` needs to build
# PCLAW.EXE, the DOS client (src/dos, docs/dos.md):
#
#   ppc386         an FPC compiler for i386 code, running here; built from
#                  the fpc-source package (apt install fpc fpc-source) in
#                  a few seconds
#   units/go32v2   the RTL and the few packages PCLAW uses, built for DOS:
#                  from the official FPC DOS release, dos322full.zip
#   CWSDPMI.EXE    the DPMI host PCLAW.EXE runs under; from the same zip
#
# into $DOS_TOOLCHAIN (default ~/.cache/pasclaw/dos-toolchain). Safe to
# run again: finished parts are skipped. Needs fpc 3.2.2 (the DOS units
# are 3.2.2's), curl and unzip.
set -eu

DEST=${DOS_TOOLCHAIN:-$HOME/.cache/pasclaw/dos-toolchain}
ZIP_URL=https://downloads.freepascal.org/fpc/dist/3.2.2/i386-go32v2/dos322full.zip
ZIP_SHA256=c34887a4367286b9d46a66b505004b9a218eb58672612892909ee28838d2ee61
# rtl, rtl-objpas, fcl-base, fcl-json
UNIT_ZIPS="basedos.zip urtlodos.zip ufclbdos.zip ufcljdos.zip"

say() { printf '%s\n' "$*"; }
die() { printf 'setup-dos-toolchain: %s\n' "$*" >&2; exit 1; }

command -v fpc >/dev/null 2>&1 || die "fpc is not installed (apt install fpc fpc-source)"
VER=$(fpc -iV)
[ "$VER" = "3.2.2" ] || die "fpc is $VER; the DOS units are for 3.2.2"
mkdir -p "$DEST"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 1. ppc386
if [ -x "$DEST/ppc386" ] && "$DEST/ppc386" -iTP 2>/dev/null | grep -q i386; then
  say "ppc386: already built"
else
  SRC=${FPCSRC:-/usr/share/fpcsrc/$VER}
  [ -f "$SRC/compiler/pp.pas" ] || die "no compiler source at $SRC (apt install fpc-source, or set FPCSRC)"
  MSG=""
  for d in "$SRC/compiler/msg" /usr/lib/x86_64-linux-gnu/fpc/$VER/msg /usr/lib/fpc/$VER/msg \
           /usr/local/lib/fpc/$VER/msg /usr/lib64/fpc/$VER/msg; do
    if [ -f "$d/errore.msg" ]; then MSG=$d; break; fi
  done
  [ -n "$MSG" ] || die "no errore.msg found (it ships with fpc; set FPCSRC to a full source tree)"
  say "ppc386: building from $SRC"
  cp -r "$SRC/compiler" "$WORK/compiler"
  cd "$WORK/compiler"
  mkdir -p msg out/units
  cp "$MSG/errore.msg" msg/
  fpc -O1 -FEutils utils/msg2inc.pp >"$WORK/msg2inc.log" 2>&1 || { cat "$WORK/msg2inc.log"; die "msg2inc did not build"; }
  ./utils/msg2inc msg/errore.msg msg msg >/dev/null
  fpc -di386 -dGDB -dBROWSERLOG -Fux86 -Fui386 -Fii386 -Fusystems -Fi. \
      -FUout/units -FEout -O2 pp.pas -oppc386 >"$WORK/ppc386.log" 2>&1 \
    || { tail -20 "$WORK/ppc386.log"; die "ppc386 did not build"; }
  cp out/ppc386 "$DEST/ppc386"
  cd - >/dev/null
  "$DEST/ppc386" -iTP | grep -q i386 || die "the built ppc386 does not target i386"
fi

# 2. go32v2 units + CWSDPMI.EXE
if [ -f "$DEST/units/go32v2/rtl/system.ppu" ] && [ -f "$DEST/units/go32v2/fcl-json/fpjson.ppu" ] \
   && [ -f "$DEST/CWSDPMI.EXE" ]; then
  say "go32v2 units: already there"
else
  ZIP=${DOS_ZIP:-$DEST/dos322full.zip}
  if [ ! -f "$ZIP" ]; then
    say "go32v2 units: downloading $ZIP_URL (76 MB)"
    curl -fsSL -o "$ZIP.part" "$ZIP_URL" || die "download failed"
    mv "$ZIP.part" "$ZIP"
  fi
  GOT=$(sha256sum "$ZIP" | cut -d' ' -f1)
  [ "$GOT" = "$ZIP_SHA256" ] || die "$ZIP has sha256 $GOT, want $ZIP_SHA256 (delete it to download again)"
  mkdir -p "$WORK/zips" "$WORK/root"
  # Each inner zip is extracted by name, into a directory of our own.
  (cd "$WORK/zips" && unzip -o -q "$ZIP" $UNIT_ZIPS cwsdpmi.exe)
  for z in $UNIT_ZIPS; do unzip -o -q "$WORK/zips/$z" -d "$WORK/root"; done
  rm -rf "$DEST/units"
  mkdir -p "$DEST/units"
  mv "$WORK/root/units/go32v2" "$DEST/units/go32v2"
  cp "$WORK/zips/cwsdpmi.exe" "$DEST/CWSDPMI.EXE"
  [ -f "$DEST/units/go32v2/rtl/system.ppu" ] || die "the zip did not hold the go32v2 RTL"
fi

say "DOS toolchain ready in $DEST -- now: make dos"
