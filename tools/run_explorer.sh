#!/bin/sh
# tools/run_explorer.sh NAME [SECS] [hiddenrun args...]: ntexplorer on an 800x600 virtual screen, muted,
# on hiddenrun's private desktop; shots/exp/NAME_<t>.png and .log
N=$1; S=${2:-20}; shift 2 2>/dev/null
export PCRECOMP_MUTE=1 W2K_SCREEN=${W2K_SCREEN:-800x600}
py -3 tools/hiddenrun.py --secs "$S" --shot $((S - 3)) --out shots/exp/$N "$@" -- "$(cygpath -m "$PWD")/build/ntexplorer.exe" --mute --watchdog $((S - 1)) | tail -2
grep -v "^\[nt\] .*proxy" shots/exp/$N.log | grep -v "RegisterClassExW .* failed: 1410" | head -${LINES_SHOWN:-40}
