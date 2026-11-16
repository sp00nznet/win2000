#!/bin/sh
# Lift and build ntexplorer (explorer.exe and the shell's DLLs, rebased into work/rebased-gui)
R=work/rebased-shell
py -3 tools/lift.py ntexplorer $R/explorer.exe $R/ntdll.dll $R/kernel32.dll $R/msvcrt.dll $R/user32.dll $R/gdi32.dll \
  $R/comctl32.dll $R/shlwapi.dll $R/shell32.dll $R/browseui.dll $R/shdocvw.dll $R/ole32.dll $R/oleaut32.dll $R/rpcrt4.dll $R/actxprxy.dll $R/desk.cpl $R/clbcatq.dll \
  > work/lift_ntexplorer.log 2>&1 || { tail -3 work/lift_ntexplorer.log; exit 1; }
tail -1 work/lift_ntexplorer.log
cmd //d //c "$(cygpath -w "$PWD")\build.cmd --target ntexplorer" > work/build_ntexplorer.log 2>&1 || { grep -E "error|FAILED" work/build_ntexplorer.log | head; exit 1; }
echo built
# Windows 2000's own COM classes into explorer's registry box (with a lifted ole32 the host's are not answered)
py -3 tools/reginst.py 'w2k\explorer' $R browseui shell32 shdocvw comctl32
