# Changelog

## Unreleased

### Added
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
- `cd DIR` (the current directory buffer; a SEH `__finally` not seeded),
  relative paths in `if exist` and `for`.
- Stage 1 hosts give the guest its own command line through pcrecomp's
  native32_set_command_line (GetCommandLine and msvcrt's __getmainargs).
