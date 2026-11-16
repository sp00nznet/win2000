#!/bin/sh
# tools/filebox_check.sh: the guest's drives are the box (pcrecomp syscall32.c, PCRECOMP_FILEBOX).
# Windows 2000's own cmd.exe (lifted) lists and writes C:\ in a box under work/fbtest; the check
# fails unless the guest sees only the box's files, and nothing outside the box changed.
cd "$(dirname "$0")/.." || exit 1
B=work/fbtest; rm -rf $B; mkdir -p $B/C/inbox_dir; echo hi > $B/C/inbox_marker.txt
export MSYS_NO_PATHCONV=1 PCRECOMP_MUTE=1 PCRECOMP_FILEBOX="$(cygpath -w "$PWD/$B")"
run() { timeout 30 ./build/cmd.exe --mute -- /c "$1" 2>&1 | tr -d '\r' | grep -v '^\[' | grep -v 'lifted functions, entering' ; }
fail=0; ok() { echo "ok   $1"; }; bad() { echo "FAIL $1"; fail=1; }
L=$(run 'dir /b C:\')
[ "$(echo "$L" | sort | tr '\n' ' ')" = "inbox_dir inbox_marker.txt " ] && ok "dir C:\\ lists only the box: $(echo $L)" || bad "dir C:\\: $L"
L=$(run 'dir /b C:\..\..\..')
echo "$L" | grep -qi "inbox_marker" && ok "C:\\..\\..\\.. stays at the box's C:\\" || bad "C:\\..: $L"
L=$(run 'dir /b D:\ G:\ \\?\GLOBALROOT\Device\HarddiskVolume1\ \\localhost\c$ \\?\UNC\localhost\c$')
[ -z "$(echo "$L" | grep -iv 'not find\|not found\|cannot find\|network\|denied\|incorrect\|invalid\|^$')" ] && ok "D:, G:, GLOBALROOT, UNC: nothing listed" || bad "other names listed: $L"
L=$(run 'cd'); [ "$L" = 'C:\' ] && ok "current directory C:\\" || bad "cd: $L"
run 'echo boxed> C:\new.txt' >/dev/null
[ "$(tr -d '\r ' < $B/C/new.txt 2>/dev/null)" = boxed ] && ok "C:\\new.txt written into the box" || bad "C:\\new.txt not in the box"
run 'echo x> G:\recomp\pc\win2000\build\fbtest_evil.txt' >/dev/null
[ ! -e build/fbtest_evil.txt ] && ok "a write to the host's G:\\...\\build: not written" || { rm -f build/fbtest_evil.txt; bad "wrote into build"; }
L=$(run 'dir /b C:\Windows\system32')
echo "$L" | grep -qi kernel32 && bad "host system32 listed" || ok "C:\Windows\system32: the box's, not the host's"
L=$(run 'dir /b G:\recomp\pc\win2000\work\rebased')
echo "$L" | grep -qi kernel32 && bad "loader directory listed" || ok "loader directory: files only, not listed"
L=$(run 'ver'); echo "$L" | grep -q "Windows 2000" && ok "the loader still maps the lifted modules (ver)" || bad "ver: $L"
exit $fail
