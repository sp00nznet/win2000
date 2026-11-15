# win2000-recomp

Windows 2000's own userland, statically recompiled with
[pcrecomp](https://github.com/sp00nznet/pcrecomp) and run on a modern
Windows host, with no emulator.

**This repository contains no Windows code or data.** Each user lifts
their own copy of Windows 2000; everything that comes from it (the extracted
files, catalogs and lifted C) goes into the gitignored `work/` and `src/gen/`.

## Status

| Stage | What | State |
|---|---|---|
| 1 | Stock accessories lifted on native32 against the host's DLLs | winmine, sol, freecell, notepad and calc run |
| 2 | Win2000's own ntdll + kernel32 lifted, `int 2Eh` mapped to the host by a syscall shim; cmd.exe on top | surveyed (docs/findings.md), not started |
| 3 | user32/gdi32 lifted, win32k calls shimmed; winmine on them | not started |

## Building

Prerequisites: Visual Studio 2022 (C++ x86 tools), CMake, Ninja, Python 3
with `capstone` and `pefile`, 7-Zip, and a pcrecomp checkout at
`../pcrecomp-w2k` (or `-DPCRECOMP=...` and `PCRECOMP=...`).

1. Extract your Windows 2000 CD's `I386` folder, then expand the files you
   need into `work/sys`:

   ```
   7z x -owork\iso <your Windows 2000 ISO> "I386/*"
   7z e -owork\sys work\iso\I386\WINMINE.EX_ work\iso\I386\CARDS.DL_ ...
   ```

2. Lift (catalog with pcrecomp's disasm32, lift with drive32):

   ```
   py -3 tools\lift.py winmine work\sys\winmine.exe
   py -3 tools\lift.py sol work\sys\sol.exe work\sys\cards.dll
   ```

3. `build.cmd`, then run it on a private desktop and screenshot the window:

   ```
   set PCRECOMP_MUTE=1
   py -3 tools\hiddenrun.py --secs 7 --shot 5 --out shots\winmine -- build\winmine.exe --mute
   ```

`build\<app>.exe --headless --mute` runs it on its own hidden desktop
without the harness. Arguments after `--` become the guest's command line.

## License

MIT (LICENSE). Windows 2000 is Microsoft's; bring your own copy.
