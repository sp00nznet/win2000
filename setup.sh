#!/bin/bash
# Linux setup: Windows 2000's own explorer (and the programs its Start menu
# starts), recompiled, built as i386 Linux programs (no Wine, no emulator) and
# run in a live X11 window (docs/linux.md).
#
# The lift itself is made on Windows: it needs Windows 2000's files, the
# registry box seeded in the Windows registry and MSVC for one stub DLL. So
# first, on Windows, run
#     Setup.cmd -Linux
# and copy the folder it fills, work\linux (about 2 GB; the build needs about 4 GB more), to work/linux in
# this repo here. This script builds what is in it:
#
#   ./setup.sh               # build, and leave "Windows 2000 (recomp).sh"
#   ./setup.sh --force       # rebuild every program
#   ./setup.sh --yes         # install missing packages (apt) without asking
#   ./setup.sh --from DIR    # the filled folder is DIR instead of work/linux
#
# A rerun skips the programs already built.
set -e
cd "$(dirname "$0")"
FORCE=0 YES=0 L=work/linux
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --yes) YES=1 ;;
    --from) L=$2; shift ;;
    *) echo "usage: ./setup.sh [--force] [--yes] [--from DIR]" >&2; exit 2 ;;
  esac
  shift
done
APPS="ntexplorer_lx ntwinmine ntnotepad ntcalc ntsol ntfreecell ntmspaint_lx ntwordpad_lx"
say()  { printf '%s\n' "$*"; }
STEP=0; STEPS=$((3 + $(set -- $APPS; echo $#)))
step() { STEP=$((STEP + 1)); printf '\n\033[36m[%d/%d] %s\033[0m\n' "$STEP" "$STEPS" "$*"; }
fail() { printf '\n\033[31mSetup stopped: %s\033[0m\n' "$*" >&2; exit 1; }
ask()  { [ "$YES" = 1 ] && { say "$1 yes"; return 0; }; read -r -p "$1 [Y/n] " r; [[ ! $r =~ ^[nN] ]]; }

say "Windows 2000 - static recompilation, Linux build"
[ "$(uname)" = Linux ] || fail "this is the Linux build. On Windows, double-click Setup.cmd."

# ---------------------------------------------------------------- tools
step "Checking the tools"
# gcc that builds 32-bit, and the i386 Xlib for the live window
need=()
command -v gcc >/dev/null || need+=(gcc)
printf 'int main(void){return 0;}' > /tmp/w2k_m32.c
gcc -m32 /tmp/w2k_m32.c -o /tmp/w2k_m32 2>/dev/null || need+=("gcc -m32")
printf '#include <X11/Xlib.h>\nint main(void){return XOpenDisplay(0)!=0;}' > /tmp/w2k_x11.c
gcc -m32 /tmp/w2k_x11.c -o /tmp/w2k_x11 -lX11 2>/dev/null || need+=("libX11 for i386")
rm -f /tmp/w2k_m32.c /tmp/w2k_m32 /tmp/w2k_x11.c /tmp/w2k_x11
if [ ${#need[@]} -gt 0 ]; then
  say "  Missing: ${need[*]}."
  if command -v apt-get >/dev/null && ask "  Install gcc-multilib and libx11-dev:i386 with apt (sudo)?"; then
    sudo dpkg --add-architecture i386 && sudo apt-get update && sudo apt-get install -y gcc-multilib libx11-dev:i386 ||
      fail "apt could not install them."
  else
    say "  From your package manager, for example:"
    say "    Debian, Ubuntu: sudo dpkg --add-architecture i386 && sudo apt update"
    say "                    sudo apt install gcc-multilib libx11-dev:i386"
    say "    Fedora:         sudo dnf install gcc glibc-devel.i686 libX11-devel.i686"
    say "    Arch:           enable [multilib], then sudo pacman -S gcc lib32-libx11"
    fail "install them, then run ./setup.sh again."
  fi
fi
say "  gcc: $(gcc -dumpversion), -m32 and X11 ok"

# ---------------------------------------------------------------- the lift
step "Finding the lift made on Windows ($L)"
if [ ! -f "$L/complete" ]; then
  say "  $L is not here (or not complete). The lift is made on Windows, from your Windows 2000 CD:"
  say "    1. on Windows, in this repo:  Setup.cmd -Linux"
  say "    2. copy its work\\linux folder here, to $L (or give it with --from DIR)"
  fail "no lifted tree: run Setup.cmd -Linux on Windows first."
fi
[ -f "$L/linux_build.sh" ] && [ -d "$L/sys-ex" ] || fail "$L is incomplete: fill it again with Setup.cmd -Linux."
say "  $L ($(du -sh "$L" | cut -f1))"

# ---------------------------------------------------------------- build
for a in $APPS; do
  e=${a#nt}; e=${e%_lx}
  step "Building $e-linux ($([ $a = ntexplorer_lx ] && echo "about 15 minutes" || echo "5 to 10 minutes"))"
  if [ "$FORCE" = 0 ] && [ -x "$L/$e-linux" ]; then say "  done (skipping)"; continue; fi
  [ -d "$L/gen/$a" ] || fail "$L/gen/$a is missing: fill $L again with Setup.cmd -Linux."
  [ "$FORCE" = 1 ] && rm -rf "$L/obj/$a"
  (cd "$L" && sh linux_build.sh "$a") > "$L/build_$a.log" 2>&1 || fail "the build failed: see $L/build_$a.log"
  tail -1 "$L/build_$a.log"
done

# ---------------------------------------------------------------- launcher
step "Making the launcher"
launcher="Windows 2000 (recomp).sh"
LA=$(cd "$L" && pwd)
cat > "$launcher" <<EOF
#!/bin/sh
# Windows 2000's own explorer, recompiled, in an X11 window (800x600; W2K_SCREEN=WxH to change it).
# Its C: is $LA/root, its registry $LA/root/ex.box (a fresh copy: rm it to start over).
cd "$LA/root" || exit 1
[ -f ex.box ] || cp ../explorer.box ex.box
exec ../explorer-linux --live --sys ../sys-ex --regbox ex.box --screen "\${W2K_SCREEN:-800x600}" "\$@"
EOF
chmod +x "$launcher"
say "  $launcher"
printf '\n\033[32mDone.\033[0m Run "./Windows 2000 (recomp).sh" on your desktop (it needs X11 or XWayland).\n'
