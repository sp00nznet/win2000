#!/bin/sh
# Build cmd-linux: Windows 2000's own cmd.exe + msvcrt + kernel32 + ntdll,
# lifted, on pcrecomp's POSIX NT backend (runtime/native32/ntposix.c).
# Run on the Linux box, in the scratch directory tools/linux_push.sh fills:
#   gen/cmd/...  pcrecomp/runtime/...  src/nthost_linux.c
# Needs gcc with -m32 (Debian: gcc-multilib). docs/linux.md.
set -eu
cd "$(dirname "$0")"
J=${J:-$(nproc)}
DEFS="-DRECOMP_RETADDR=0u -DRECOMP_FLAT_MEMORY -DRECOMP_LOCAL_REGS"
INC="-Ipcrecomp/runtime/recomp32 -Ipcrecomp/runtime/native32 -Igen/cmd"
CF="-m32 -fno-strict-aliasing -fwrapv -fno-pie $DEFS $INC"
mkdir -p obj
# the lifted C, unoptimised (as pcrecomp_gen.cmake does)
find gen/cmd -name '*.c' | while read -r f; do
  o=obj/$(echo "$f" | tr / _ | sed 's/\.c$/.o/')
  [ "$o" -nt "$f" ] || echo "$f $o"
done | xargs -r -P "$J" -n 2 sh -c 'gcc '"$CF"' -O0 -w -c "$0" -o "$1"'
gcc $CF -O1 -g -Wall -Wno-unused-function -c pcrecomp/runtime/native32/ntposix.c -o obj/ntposix.o
gcc $CF -O1 -g -Wall -Wno-unused-function -c src/nthost_linux.c -o obj/nthost_linux.o
gcc -m32 -no-pie obj/*.o -lpthread -lm -o cmd-linux
echo "built ./cmd-linux"
