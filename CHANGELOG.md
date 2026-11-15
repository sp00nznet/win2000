# Changelog

## Unreleased

### Added
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
- Stage 1 hosts give the guest its own command line through pcrecomp's
  native32_set_command_line (GetCommandLine and msvcrt's __getmainargs).
