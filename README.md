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
| 2 | Win2000's own ntdll + kernel32 + msvcrt lifted, `int 2Eh` mapped to the host by a syscall shim; cmd.exe on top | cmd.exe runs: banner, ver, echo, dir, set, exit N. `cd` does not change directory yet |
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

### Stage 2: cmd.exe on its own kernel32 and ntdll

Also expand `CMD.EX_`, `KERNEL32.DL_`, `NTDLL.DLL`, `MSVCRT.DLL` and the NLS
files (`C_1252.NL_ C_437.NL_ L_INTL.NL_ UNICODE.NL_ LOCALE.NL_ CTYPE.NL_
SORTKEY.NL_ SORTTBLS.NL_`) into `work/sys`, then rebase the system DLLs out
of the host's way and lift all four:

```
py -3 ..\pcrecomp-w2k	ools\peebase.py work\sys workebased cmd.exe ntdll.dll=0x20000000 kernel32.dll=0x20100000 msvcrt.dll=0x20200000
py -3 tools\lift.py cmd workebased\cmd.exe workebased
tdll.dll workebased\kernel32.dll workebased\msvcrt.dll
build.cmd --target cmd
set PCRECOMP_MUTE=1
build\cmd.exe --mute -- /c ver
```

(In Git Bash set `MSYS_NO_PATHCONV=1`, or `/c` arrives as `C:/`.)
`NATIVE32_SYSCALLS=1` traces every system call and csrss request;
`--calltrace FILE` every lifted function entry. `tools/addr2name.py` names
guest addresses by the nearest export; `tools/faultline.sh` shows the lifted C
at a host fault address.

`build\<app>.exe --headless --mute` runs it on its own hidden desktop
without the harness. Arguments after `--` become the guest's command line.

## License

MIT (LICENSE). Windows 2000 is Microsoft's; bring your own copy.
