# Changelog

## Unreleased

### Added
- interact gates on approved lifted-build goldens: shots/golden (local) with their RGB hashes
  in tools/golden.json (committed); `py -3 tools/interact.py --approve [app ...]` re-approves
  after the new shots are checked by eye. The stage 1 comparison stays as an informational
  column (mspaint and wordpad load Windows 2000's own comctl32 and differ from it by design).
- Display's Apply: the Screen area slider moved (640 by 480), Apply and Windows 2000's own
  "will now apply" box answered; ChangeDisplaySettings is refused and desk.cpl says it is
  unable to change the display settings; the host's mode unchanged (hostsettings.py).
  GWL_USERDATA lives in the guest's WND (message boxes faulted at OK without it).
  hiddenrun `--childpost ~CLASS:...` posts to the first descendant of a class.
- Control Panel's two nameless folders gone: shell32's own Scheduled Tasks and Network and
  Dial-up items (mstask, netshell not lifted) are SFGAO_NONENUMERATED in the box.
- No host DLL but advapi32 in any guest process: run_explorer.sh's host-module check covers
  every process of the run (launched children from their first line). Windows 2000's
  imagehlp (rundll32), and for the accessories (tools/lift_accessories.sh, on the shell's
  module set) shell32, comdlg32, winmm, winspool, olecli32/olesvr32, nddeapi; cmd, find and
  more on lifted user32/gdi32 (ulib moved to 0x22300000). lift.py re-catalogues a rebased
  module. Message boxes lay out (SERVERINFO's message font, button texts); Display opens
  (one display adapter, a Windows 2000 mode list) and its settings stay in the guest; a
  double-click on a Control Panel applet opens it (menu items copied with every MIIM bit);
  Date/Time names the zone (Windows 2000's Time Zones in the box).
- Pipes in the lifted cmd (`echo hi | find "hi"`, `| more`): every nthost build's CreateProcess
  is the launch path (build\nt<name>.exe, else build\<name>.exe) with the guest's handles;
  find.exe and more.com lifted on lifted ulib.dll. Start -> Programs -> Accessories from the
  private profile (profile.py .lnk files) launches Notepad. A launched program shares its
  launcher's registry box (winmine's caption in the box's colours, its menu bar not greyed).
  reginst.py: lnkfile/exefile and every HIVECLS class a lifted DLL serves. filebox_check 11/11.
- Start -> Run -> winmine: the Run dialog opens (WM_COMMAND 0x191 on the tray), "winmine"
  resolves through App Paths in explorer's box (reginst.py: one per build
t<name>.exe) and
  the launch guard starts build
twinmine.exe on the same virtual screen. The Start menu
  has its item text, the "Professional" banner (the guest's PEB SessionId is 0, the local
  console) and the Start button its logo and "Start" (NtUserDrawCaptionTemp). The tray
  clock shows. Desktop labels draw transparent. hiddenrun.py `--childpost`.
- explorer no longer exits 1: its desktop's and tray's COM classes (browseui's CCommonBrowser,
  BandSite) resolved to the host's ExplorerFrame.dll, which was proxied into the guest. Now
  a host COM server or .cpl is never mapped into a lifted process, the host's CLSID/AppID
  keys are not answered when ole32 is lifted, and `tools/reginst.py` seeds explorer's box
  with Windows 2000's own registrations (each DLL's REGINST INF). Runs to the watchdog; no
  desktop drawn yet (a main/desktop-thread race in ole32/oleaut32, see findings).
- Stage 4 on Linux: calc, notepad, sol and freecell (with cards.dll lifted) as i386 ELFs on
  their own lifted user32/gdi32 and pcrecomp's w32kposix, compared with the Windows build
  (`linuxcmp.py --syscolors`: sol 1 of 224,640 pixels, calc only ClearType glyphs). A live
  X11 window (`--live`) with real mouse and keyboard; `tools/linux_live.sh` drives it under
  Xvfb with xdotool. user32 re-lifted with the Stage 3 seeds (work/seeds via tools/seed.sh).
- Stage 3 on Linux, no Wine: Windows 2000's own winmine.exe on its own lifted user32,
  gdi32, msvcrt, kernel32 and ntdll (`winmine-linux`), with win32k answered in software
  by pcrecomp's new w32kposix.c (windows, messages, DefWindowProc's frame/caption/menu
  bar, menus, GDI with ROP3 blits, DIBs, pens, text from Windows 2000's own .fon files)
  over the shared Windows 2000 layouts in w32klayout.c. An offscreen framebuffer saved
  as PNG; hiddenrun's --click/--command/--post/--type/--dlgcommand/--shot on a virtual
  clock. interact.py's start, click, Intermediate and Custom 20x30 states: 0 pixels
  differ from the Windows build over the client area (`tools/linuxcmp.py`).
  `linux_build.sh`/`linux_push.sh` take the app; `.gitattributes` keeps .sh files LF.
- Stage 2 on Linux, no Wine: Windows 2000's own cmd.exe on its own lifted msvcrt,
  kernel32 and ntdll, an i386 ELF (`cmd-linux`) on pcrecomp's POSIX NT backend
  (runtime/native32/ntposix.c, branch w2k-linux). `cmd /c ver` and the piped session
  match Windows. `src/nthost_linux.c`, `tools/linux_push.sh`, `tools/linux_build.sh`,
  docs/linux.md (design: i386 flat over a 4 GB arena, and why).
- The guest never writes the user's registry: every Reg*/NtXxxKey/profile write goes to
  HKCU\Software\pcrecomp\w2k\<app> (pcrecomp regbox32.c), reads fall through read-only.
  NtUserCallNoParam 0x12, DC_ATTR window origin/extents, WS_VISIBLE shows.
- wordpad and mspaint pixel-identical on lifted user32 + gdi32 (`interact.py`
  wordpad start/typed, mspaint start/line: 0; wordpad's typed state can show a
  16-pixel caret in one build only, blink phase). riched20's vtable-only
  0x2070B6E0 and 0x207108C0 catalogued; RichEdit's window bytes, styles,
  caret, font enumeration, printer DC, batched TextOut and the viewport
  origin answered (pcrecomp native32). The guest's CreateDCW, and
  CallWindowProcW/A to a host procedure, answered by the host (nthost.c).
  The fault line names the access address.
- packager pixel-identical on lifted user32 (the guest's DrawTextA answered by
  the host's). mspaint and wordpad targets (Windows 2000's mfc42u and riched20
  lifted on both builds); mspaint starts and draws a line on lifted user32
  (not yet pixel-identical); wordpad blocked on one riched20 function the
  catalog misses. `hiddenrun.py --drag`.
- sol and freecell draw every card on lifted user32 (0 pixels): win32k's
  `__ClientThreadSetup` callback (user32 makes ghdcBits2 there),
  NtGdiGetDCforBitmap answered from SelectBitmap, NtGdiSaveDC/RestoreDC.
- packager on lifted user32 (`ntpackager`, the ANSI path): rebased with
  rebase.py (its bound imports dropped), WS_EX_ANSICREATOR stripped, ANSI
  window names converted, NtUserEnableScrollBar.
- notepad and calc on their own lifted user32 + gdi32 (`build/ntnotepad.exe`,
  `build/ntcalc.exe`, CMake `w2k_user_host`): pixel-identical to stage 1 at
  start, with text typed (notepad) and after 12+3= (calc). `interact.py`
  takes app names (`winmine notepad calc sol freecell`).
- sol and freecell on lifted user32 + gdi32 (`ntsol`, `ntfreecell`):
  table, menus and status pixel-identical after the deal and a click; no
  cards drawn on either build yet. The guest's AdjustWindowRect(Ex) answered
  by the host's; the create-time frame correction skipped for CW_USEDEFAULT.
- Text messages through win32k's own callbacks: `__fnINLPCREATESTRUCT`,
  `__fnINSTRING`, `__fnINCNTOUTSTRING`, with A/W conversion for ANSI classes
  (pcrecomp w32kuser.c).
- Custom dialog driven: typed size, OK, the board resizes, pixel-identical
  (`interact.py` dlg run; `hiddenrun.py --type`, `--dlgcommand`).
- winmine's Game > Custom dialog and its Game menu (open, at start and after
  Intermediate) pixel-identical on lifted user32 + gdi32; sent messages go
  through ntdll's KiUserCallbackDispatcher and user32's __fnDWORD (pcrecomp
  w32kuser.c, csr32.c). `interact.py` menu runs; `hiddenrun.py --post`, and
  `HIDDENRUN_RECTS=1` prints each captured window's rectangle.
- `tools/interact.py`: winmine driven by posted input on both builds, compared
  per step; `hiddenrun.py --click/--command`; `W2K_FIXED_TICK`.
- winmine on its own lifted user32 + gdi32: pixel-identical to stage 1
  (menus, icons, DC messages in pcrecomp w32kuser.c).
- Full win32k, first milestone: `build/ntwinmine.exe` creates, shows and
  paints winmine's window through Windows 2000's own user32 and gdi32
  (pcrecomp w32kuser.c).
- sol, freecell, calc, notepad on lifted gdi32 (`build/gdi<app>.exe`), all
  pixel-identical to stage 1; `tools/gdicmp.py`; `W2K_FIXED_TIME`,
  `W2K_IAT_DUMP`, `W2K_PEEK` diagnostics.
- `build/ntwmgdi.exe`: winmine on Windows 2000's own lifted gdi32 (host
  user32), pixel-identical to the host-gdi32 render; pcrecomp w32kgdi.c.
- Stage 3 probe: `build/ntwinmine.exe`, winmine with its own lifted user32
  and gdi32: both initialize, WinMain reaches RegisterClassExW.
  `tools/w32k_names.py` names win32k services from j00ru's public tables.
- Process start by Windows 2000's own ntdll (`LdrInitializeThunk`): no
  build-specific addresses in the host; csrss answered at its LPC port.
- Windows 2000 Server SP4 and build 2163 (pro.zip's ISO) cmd.exe brought up
  on the same host source (`cmd_rtm` for 2163).
- The guard: no program that is not lifted is started (`[guard]`).
- `tools/disas.py`, `tools/calls.py`.
- Stage 2: Windows 2000's own cmd.exe on its own lifted msvcrt, kernel32 and
  ntdll; the guest's `int 2Eh` is the only kernel boundary (pcrecomp
  native32 syscall32.c, csrss in csr32.c). Host: `src/nthost.c`.
- `tools/addr2name.py`, `tools/faultline.sh`: bring-up diagnostics.
- Stage 1: winmine, sol, freecell, notepad and calc from Windows 2000 SP4
  lifted with pcrecomp and run on native32 against the host's DLLs
  (cards.dll lifted as a second guest module).
- `tools/lift.py`: catalog and lift a set of modules into one dispatch table.
- `tools/hiddenrun.py`: run on a private desktop, screenshot only the
  program's own windows (PrintWindow).

### Fixed
- ntcalc's occasional heap corruption (a region's attributes too small when
  its handle slot became a DC's; pcrecomp w32kgdi.c).
- The inactive-menu flake: hiddenrun activates the top window before a shot.
- `hiddenrun.py` skipped Windows 11's UAC input indicator windows, which it
  took for the program's top window (`--type`/`--dlgcommand` went nowhere);
  `interact.py` no longer compares stale shots.
- `cd DIR` (the current directory buffer; a SEH `__finally` not seeded),
  relative paths in `if exist` and `for`.
- Stage 1 hosts give the guest its own command line through pcrecomp's
  native32_set_command_line (GetCommandLine and msvcrt's __getmainargs).
