# Changelog

## Unreleased

### Added
- Stage 1: winmine, sol, freecell, notepad and calc from Windows 2000 SP4
  lifted with pcrecomp and run on native32 against the host's DLLs
  (cards.dll lifted as a second guest module).
- `tools/lift.py`: catalog and lift a set of modules into one dispatch table.
- `tools/hiddenrun.py`: run on a private desktop, screenshot only the
  program's own windows (PrintWindow).
