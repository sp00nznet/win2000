#!/bin/sh
# Build a Linux host on pcrecomp's POSIX NT backend (runtime/native32/ntposix.c):
#   sh linux_build.sh            cmd-linux: cmd.exe + msvcrt + kernel32 + ntdll
#   sh linux_build.sh ntwinmine  winmine-linux: + user32 + gdi32, win32k in w32kposix.c
# Run on the Linux box, in the scratch directory tools/linux_push.sh fills:
#   gen/APP/...  pcrecomp/runtime/...  src/nthost_linux.c
# Needs gcc with -m32 (Debian: gcc-multilib). docs/linux.md.
# ARCH=x86_64 or ARCH=aarch64 builds a 64-bit host instead, the guest's 4 GB
# at one base (RECOMP_MEM_BASE, docs/a64.md): gcc -m64, or aarch64-linux-gnu-gcc
# (a cross build; run it on an arm64 box, or under qemu-aarch64 as a stand-in).
set -eu
cd "$(dirname "$0")"
APP=${1:-cmd}
J=${J:-$(nproc)}
ARCH=${ARCH:-i386}
INC="-Ipcrecomp/runtime/recomp32 -Ipcrecomp/runtime/native32 -Igen/$APP"
case $ARCH in
  i386)    CC=gcc M=-m32 LIB=/usr/lib/i386-linux-gnu SFX= MEM="-DRECOMP_FLAT_MEMORY" ;;
  x86_64)  CC=gcc M=-m64 LIB=/usr/lib/x86_64-linux-gnu SFX=-x64 ;;
  aarch64) CC=aarch64-linux-gnu-gcc M= LIB=/usr/lib/aarch64-linux-gnu SFX=-a64
           [ "$(uname -m)" = aarch64 ] && CC=gcc ;;   # (on an arm64 box: its own gcc)
  *) echo "ARCH: i386, x86_64 or aarch64"; exit 1 ;;
esac
[ "$ARCH" = i386 ] || MEM="-DRECOMP_MEM_BASE=${MEM_BASE:-0x2000000000ull}"   # below a 39-bit arm64 kernel's 512 GB
DEFS="-DRECOMP_RETADDR=0u $MEM -DRECOMP_LOCAL_REGS"
CF="$M -fno-strict-aliasing -fwrapv -fno-pie $DEFS $INC"
O=obj$SFX/$APP
mkdir -p "$O"
# the lifted C, unoptimised (as pcrecomp_gen.cmake does; recomp_part.c, a part DLL's table, is left out there too)
find "gen/$APP" -name '*.c' ! -name recomp_part.c | while read -r f; do
  o=$O/$(echo "$f" | tr / _ | sed 's/\.c$/.o/')
  [ "$o" -nt "$f" ] || echo "$f $o"
done | xargs -r -P "$J" -n 2 sh -c "$CC"' '"$CF"' -O0 -w -c "$0" -o "$1"'
HOST="$CF -O1 -g -Wall -Wno-unused-function"
N=pcrecomp/runtime/native32
H=obj$SFX
if [ "$APP" = cmd ]; then
  $CC $HOST -c $N/ntposix.c -o $H/ntposix.o
  $CC $HOST -c src/nthost_linux.c -o $H/nthost_cmd.o
  $CC $M -no-pie "$O"/*.o $H/ntposix.o $H/nthost_cmd.o -lpthread -lm -o cmd-linux$SFX
  echo "built ./cmd-linux$SFX"
else
  EXE=${APP#nt}; EXE=${EXE%_lx}                 # (ntmspaint_lx: mspaint's Linux set, with comctl32)
  $CC $HOST -c $N/ntposix.c -o $H/ntposix.o
  $CC $HOST -c $N/w32klayout.c -o $H/w32klayout.o
  X=; LX=; [ -e $LIB/libX11.so ] && X=-DW2K_X11 LX=-lX11   # --live
  $CC $HOST $X -c $N/w32kposix.c -o $H/w32kposix.o
  CARDS=; [ -d "gen/$APP/cards" ] && CARDS=-DW2K_CARDS
  [ -d "gen/$APP/mfc42u" ] && CARDS="$CARDS -DW2K_MFC"
  [ -d "gen/$APP/riched20" ] && CARDS="$CARDS -DW2K_RICHED"
  [ -d "gen/$APP/explorer" ] && CARDS="$CARDS -DW2K_EXPLORER"
  $CC $HOST -DW2K_GUI $CARDS "-DW2K_SFX=\"$SFX\"" "-DW2K_EXE=\"$EXE.exe\"" -c src/nthost_linux.c -o $H/nthost_$EXE.o
  $CC $M -no-pie "$O"/*.o $H/ntposix.o $H/w32klayout.o $H/w32kposix.o $H/nthost_$EXE.o $LX -lpthread -lm -o "$EXE-linux$SFX"
  echo "built ./$EXE-linux$SFX"
fi
