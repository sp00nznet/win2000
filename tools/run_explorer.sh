#!/bin/sh
# tools/run_explorer.sh NAME [SECS] [hiddenrun args...]: ntexplorer on an 800x600 virtual screen, muted,
# on hiddenrun's private desktop; shots/exp/NAME_<t>.png and .log. $EXARGS go to ntexplorer.
# Fails (exit 1) if any host module other than the allowed proxies was mapped into the guest.
N=$1; S=${2:-20}; shift 2 2>/dev/null
export PCRECOMP_MUTE=1 W2K_SCREEN=${W2K_SCREEN:-800x600}
# a private Windows 2000 profile (tools/profile.py): never the host's Start Menu, Desktop or AppData
py -3 tools/profile.py 'w2k\explorer' work/profile >/dev/null || exit 1
mkdir -p work/profile/temp; P=$(cygpath -w "$PWD/work/profile")
export USERPROFILE="$P\\user" ALLUSERSPROFILE="$P\\all" ProgramData="$P\\all" PUBLIC="$P\\all" \
  APPDATA="$P\\user\\Application Data" LOCALAPPDATA="$P\\user\\Local Settings\\Application Data" \
  HOMEDRIVE= HOMEPATH= TEMP="$P\\temp" TMP="$P\\temp"
py -3 tools/hiddenrun.py --secs "$S" --shot $((S - 3)) --out shots/exp/$N "$@" -- "$(cygpath -m "$PWD")/build/ntexplorer.exe" --mute --watchdog $((S - 1)) $EXARGS | tail -${TAIL_SHOWN:-2}
grep -v "HOST DLL in the guest: .*advapi32.dll" shots/exp/$N.log | grep -v "RegisterClassExW .* failed: 1410" | head -${LINES_SHOWN:-40}
# ponytail: advapi32 is the only host DLL explorer may proxy; widen ALLOW when a new one is reviewed
ALLOW='advapi32\.dll'
# a program explorer launched ([launch], its runner) prints its own startup until its banner: its rules, not explorer's
# ponytail: explorer lines interleaved in that window are skipped too; a per-process log if that ever matters
BAD=$(awk '/^\[launch\]/{c=1} c&&/ lifted functions, entering/{c=0;next} !c' shots/exp/$N.log |
  grep -aiE "HOST DLL in the guest|the host.s, through a proxy" | grep -aivE "[\\\\/]($ALLOW)[,:]")
[ -z "$BAD" ] || { echo "!!! HOST MODULE IN THE GUEST (run failed):"; echo "$BAD"; exit 1; }
