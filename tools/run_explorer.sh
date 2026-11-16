#!/bin/sh
# tools/run_explorer.sh NAME [SECS] [hiddenrun args...]: ntexplorer on an 800x600 virtual screen, muted,
# on hiddenrun's private desktop; shots/exp/NAME_<t>.png and .log. $EXARGS go to ntexplorer.
# Fails (exit 1) if any host module other than the allowed proxies was mapped into the guest.
N=$1; S=${2:-20}; shift 2 2>/dev/null
export PCRECOMP_MUTE=1 W2K_SCREEN=${W2K_SCREEN:-800x600}
py -3 tools/hiddenrun.py --secs "$S" --shot $((S - 3)) --out shots/exp/$N "$@" -- "$(cygpath -m "$PWD")/build/ntexplorer.exe" --mute --watchdog $((S - 1)) $EXARGS | tail -2
grep -v "HOST DLL in the guest: .*advapi32.dll" shots/exp/$N.log | grep -v "RegisterClassExW .* failed: 1410" | head -${LINES_SHOWN:-40}
# ponytail: advapi32 is the only host DLL explorer may proxy; widen ALLOW when a new one is reviewed
ALLOW='advapi32\.dll'
BAD=$(grep -aiE "HOST DLL in the guest|the host.s, through a proxy" shots/exp/$N.log | grep -aivE "[\\\\/]($ALLOW)[,:]")
[ -z "$BAD" ] || { echo "!!! HOST MODULE IN THE GUEST (run failed):"; echo "$BAD"; exit 1; }
