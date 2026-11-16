#!/bin/sh
# Copy what a Linux build needs to a scratch directory on a Linux box:
#   tools/linux_push.sh user@host /tmp/w2k-scratch [PCRECOMP checkout] [cmd|ntwinmine]
# The lifted C and the Windows 2000 files are yours and stay out of git;
# delete the scratch directory when done (ssh user@host rm -rf DIR).
set -eu
HOST=$1 DIR=$2 PCR=${3:-../pcrecomp-w2k-linux} APP=${4:-cmd}
cd "$(dirname "$0")/.."
ssh "$HOST" "mkdir -p $DIR/root/sys $DIR/src $DIR/gen $DIR/pcrecomp/runtime"
tar cf - -C src/gen "$APP" | ssh "$HOST" "tar xf - -C $DIR/gen"
tar cf - -C "$PCR/runtime" recomp32/recomp_types.h native32/ntposix.c native32/ntposix.h \
    native32/w32klayout.c native32/w32klayout.h native32/w32kposix.c native32/w32kposix.h | ssh "$HOST" "tar xf - -C $DIR/pcrecomp/runtime"
tar cf - src/nthost_linux.c -C tools linux_build.sh | ssh "$HOST" "tar xf - -C $DIR && mv $DIR/src/linux_build.sh $DIR/ 2>/dev/null; true"
if [ "$APP" = cmd ]; then
  tar cf - -C work/rebased cmd.exe ntdll.dll kernel32.dll msvcrt.dll | ssh "$HOST" "tar xf - -C $DIR/root/sys"
else
  # stage 3: the GUI set, the win32k names, Windows 2000's bitmap fonts (expanded from the CD's .FO_)
  tar cf - -C work/rebased-gui "${APP#nt}.exe" ntdll.dll kernel32.dll msvcrt.dll user32.dll gdi32.dll | ssh "$HOST" "tar xf - -C $DIR/root/sys"
  tar cf - -C work/names win32k_2000sp4.txt -C ../fonts sserife.fon vgasys.fon | ssh "$HOST" "tar xf - -C $DIR/root/sys"
fi
tar cf - -C work/sys c_1252.nls c_437.nls l_intl.nls unicode.nls locale.nls ctype.nls sortkey.nls sorttbls.nls sortkey_00000409.nls | ssh "$HOST" "tar xf - -C $DIR/root/sys"
echo "pushed $APP to $HOST:$DIR"
