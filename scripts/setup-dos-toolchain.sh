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
# With --win32 (`make xp-toolchain`), also the units `make xp` needs to
# build the full pasclaw.exe for 32-bit Windows, XP included:
#
#   units/i386-win32   the RTL and packages pasclaw uses, built for win32:
#                      from the official FPC 3.2.2 win32 installer, which
#                      innoextract unpacks (only those 23 packages, 96 MB)
#
# The same ppc386 builds for both. Everything goes into $DOS_TOOLCHAIN
# (default ~/.cache/pasclaw/dos-toolchain). Safe to run again: finished
# parts are skipped. Needs fpc 3.2.2 (the units are 3.2.2's), curl, unzip,
# and for --win32 innoextract.
set -eu

WIN32=0
for a in "$@"; do
  case "$a" in
    --win32) WIN32=1 ;;
    *) printf 'usage: setup-dos-toolchain.sh [--win32]\n' >&2; exit 2 ;;
  esac
done

DEST=${DOS_TOOLCHAIN:-$HOME/.cache/pasclaw/dos-toolchain}
ZIP_URL=https://downloads.freepascal.org/fpc/dist/3.2.2/i386-go32v2/dos322full.zip
ZIP_SHA256=c34887a4367286b9d46a66b505004b9a218eb58672612892909ee28838d2ee61
# rtl, rtl-objpas, fcl-base, fcl-json
UNIT_ZIPS="basedos.zip urtlodos.zip ufclbdos.zip ufcljdos.zip"
WIN32_URL=https://downloads.freepascal.org/fpc/dist/3.2.2/i386-win32/fpc-3.2.2.i386-win32.exe
WIN32_SHA256=7ec78b1790ecac7685f440b17f9e03865bc09846b7c068a9270c4d37704b5ac8
# What `make xp` loads (found with -vu); fcl-db pulls in its drivers' units.
WIN32_PKGS="rtl rtl-objpas rtl-generics rtl-extra fcl-base fcl-json fcl-net fcl-web fcl-process
  fcl-registry fcl-db sqlite postgres oracle mysql odbc ibase dblib paszlib hash regexpr
  openssl winunits-base"

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
  rm -rf "$DEST/units/go32v2"
  mkdir -p "$DEST/units"
  mv "$WORK/root/units/go32v2" "$DEST/units/go32v2"
  cp "$WORK/zips/cwsdpmi.exe" "$DEST/CWSDPMI.EXE"
  [ -f "$DEST/units/go32v2/rtl/system.ppu" ] || die "the zip did not hold the go32v2 RTL"
fi

# 3. i386-win32 units (--win32)
if [ "$WIN32" = 1 ]; then
  if [ -f "$DEST/units/i386-win32/rtl/system.ppu" ] && [ -f "$DEST/units/i386-win32/fcl-db/sqldb.ppu" ]; then
    say "i386-win32 units: already there"
  else
    command -v innoextract >/dev/null 2>&1 || die "--win32 needs innoextract (apt install innoextract)"
    INST=${WIN32_INSTALLER:-$DEST/fpc-3.2.2.i386-win32.exe}
    if [ ! -f "$INST" ]; then
      say "i386-win32 units: downloading $WIN32_URL (51 MB)"
      curl -fsSL -o "$INST.part" "$WIN32_URL" || die "download failed"
      mv "$INST.part" "$INST"
    fi
    GOT=$(sha256sum "$INST" | cut -d' ' -f1)
    [ "$GOT" = "$WIN32_SHA256" ] || die "$INST has sha256 $GOT, want $WIN32_SHA256 (delete it to download again)"
    INC=""
    for p in $WIN32_PKGS; do INC="$INC -I app/units/i386-win32/$p"; done
    mkdir -p "$WORK/win32"
    innoextract -q -d "$WORK/win32" $INC "$INST" >/dev/null
    [ -f "$WORK/win32/app/units/i386-win32/rtl/system.ppu" ] || die "the installer did not hold the win32 RTL"
    rm -rf "$DEST/units/i386-win32"
    mkdir -p "$DEST/units"
    mv "$WORK/win32/app/units/i386-win32" "$DEST/units/i386-win32"
  fi
  say "win32 units ready in $DEST/units/i386-win32 -- now: make xp"
fi

say "DOS toolchain ready in $DEST -- now: make dos"
