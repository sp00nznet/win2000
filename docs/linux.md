# Windows 2000 on Linux

Goal: Windows 2000's own userland, statically lifted, running directly on
Linux. No QEMU, no VirtualBox, no Wine. The lifted ntdll, kernel32 and msvcrt
are the same C files the Windows host builds; only the layer under
`int 2Eh` changes.

## What is Windows-specific today

Stage 2 on Windows (`src/nthost.c` + pcrecomp `runtime/native32`) leans on
the host in these places:

| Piece | Windows host | Needed on Linux |
|---|---|---|
| The lifted C itself (`src/gen/*`) | portable C, `RECOMP_FLAT_MEMORY`, registers in locals | nothing: compiles with gcc as is |
| Register file, dispatch, `call_guest` (native32.c) | MSVC inline asm bridge for calls into *host DLLs*, a VEH trampoline for host->guest callbacks | none of that: on Linux nothing native is ever called by address, so the core is a few hundred lines of plain C |
| TEB / `fs` | a guest TIB in VirtualAlloc'd memory, `g_fs_base` | same idea: a TEB page in guest memory; lifted code reads `fs:[n]` as `MEM32(g_fs_base + n)` |
| Memory (`NtAllocateVirtualMemory` ...) | forwarded to the host ntdll | a page map over the 4 GB guest space, reservations as `mmap(PROT_NONE)`, commits as `mprotect` |
| Files, directories, volumes | forwarded to the host ntdll (handles are the host's) | a handle table; NT paths (`\??\C:\x`) translated through a mount table (`C:\` -> a root directory, `C:\WINNT\system32` -> the lifted modules), components matched without case |
| Sections | host sections (NLS files, the CSR port memory) | `mmap` of the file (`MAP_PRIVATE`) or of a `memfd` (`MAP_SHARED`), at addresses from the page map |
| Image sections | lifted module -> its mapping; host DLL -> a proxy image of the host's exports | lifted module -> its mapping; user32/advapi32 for cmd -> a proxy image whose exports are host C stubs with known argument counts; anything else refused (the guard) |
| Events, waits | host events | objects in the handle table; one guest thread, so a wait is a check (an infinite wait on an unsignaled object is reported, not slept on) |
| Registry | regbox32 over the host registry | not found for now (cmd, kernel32 and msvcrt fall back to their defaults) |
| csrss (csr32.c) | the CSR port answered in process; console = the host's std handles | the same protocol answered the same way; console = stdin/stdout/stderr as files |
| KUSER_SHARED_DATA (GetTickCount, GetSystemTimeAsFileTime) | the host's real page at 0x7FFE0000 | a page we map at 0x7FFE0000, its times kept current by a small host thread |
| SEH | guest frames dispatched by the guest ntdll; `RtlUnwind` replaced with native32's (seh32.c) | `NtRaiseException` -> `KiUserExceptionDispatcher` as on Windows; landing pads (`recomp_eh_*`) with setjmp/longjmp, portable |
| Threads | host threads under native32's machine lock | none yet (cmd needs none); a pthread per guest thread under the same kind of lock later |

## Decision: an i386 build, guest at its real addresses

Two ways to run 32-bit guest code lifted to C on a 64-bit Linux:

1. **i386 (`gcc -m32`), flat.** The host process is 32-bit; a guest address
   *is* a host address. The guest's images are mapped at their own bases with
   `mmap(MAP_FIXED_NOREPLACE)`, guest memory comes from the low 2 GB.
2. **x86_64 with the guest in a reserved 4 GB arena (based).** `ADDR(va)`
   adds a base; every host pointer the guest sees has to live in the arena.

**Choice: (1), i386 flat.** Reasons:

- The lifted C was generated for flat memory (`RECOMP_FLAT_MEMORY`), the way
  the Windows host builds it. The same files compile unchanged; a based build
  would need the lift regenerated with `RECOMP_MEM_BASE` and checked again.
- The NT layer writes guest structures constantly: PEB, process parameters,
  `UNICODE_STRING`s, IO_STATUS_BLOCKs, directory entries, the CSR messages.
  Flat, those are plain C pointers, exactly as in `syscall32.c`/`csr32.c` on
  Windows; based, every one is a conversion, and a missed one is a silent
  truncation of a 64-bit pointer.
- Windows 2000's ntdll itself checks addresses against the user-mode range
  (`MmHighestUserAddress` 0x7FFEFFFF, `SystemRangeStart` 0x80000000). Under
  `-m32` on a 64-bit kernel a process has nearly 4 GB, and the page map hands
  the guest only addresses below 0x7FFE0000, as on Windows.
- pcrecomp already does this: `runtime/win32hle` builds with `gcc -m32` flat
  on Linux (Tiberian Sun, Red Alert 2), and keeps the based mode for macOS.

Costs: a multilib toolchain (Debian `gcc-multilib`; later `libx11-dev:i386`
or SDL2:i386 for a window), and the host's own images and libraries share
the 32-bit space. The host is linked non-PIE at 0x08048000 (well below
ntdll's 0x20000000), the guest images are mapped first, and the C library's
own mappings land high (0xF7xxxxxx), above everything the guest gets.

A based x86_64 build stays possible later: the lift supports
`RECOMP_MEM_BASE`, and the page map already treats guest memory as one 4 GB
space.

## Layout

- pcrecomp `runtime/native32/ntposix.c` (branch `w2k-linux`): the whole
  POSIX backend in one file: register file, dispatch, `call_guest`, landing
  pads, the page map, the handle table, the NT services, image sections and
  proxies, csrss, process start (PEB, parameters, `LdrInitializeThunk`),
  KUSER_SHARED_DATA. Interface in `ntposix.h`. Nothing in native32.c,
  syscall32.c or csr32.c changes: the Windows build is untouched.
- win2000 `src/nthost_linux.c`: the host (which modules at which bases,
  mounts, NLS sections, the command line), the Linux counterpart of
  `src/nthost.c`.
- win2000 `tools/linux_build.sh`: compiles host + backend + the lifted C with
  `gcc -m32` on a Linux box.

The service table is the guest ntdll's own, read from its stubs, as on
Windows: each build of Windows 2000 brings its own numbering.

## Running it (linuxbox)

Lifted output and Windows 2000 files never go in git; they go to a scratch
directory on the Linux box and are deleted afterwards:

```
# from Windows (Git Bash), win2000 checkout:
tools/linux_push.sh netlab@netlab-linux /tmp/w2k-scratch
# on the box:
cd /tmp/w2k-scratch && sh linux_build.sh
./cmd-linux --root /tmp/w2k-scratch/root -- /c ver
```

`--root DIR` is the guest's `C:\` (default: the current directory), `--sys`
the lifted modules (default `ROOT/sys`, seen by the guest as
`C:\WINNT\system32`), `--nls` the .nls files (default: `--sys`). The guest's
current directory is the host's when that is under the root.
`NATIVE32_SYSCALLS=1` traces every service and csrss request, as on Windows.
A build takes about two minutes on four cores (the lifted C at `-O0`).

## Status

**Stage 2 on Linux: done.** On netlab's Debian 13 box (x86_64 kernel, the
host an i386 ELF), Windows 2000 SP4's own cmd.exe on its own lifted msvcrt,
kernel32 and ntdll:

```
$ ./cmd-linux -- /c ver

Microsoft Windows 2000 [Version 5.00.2195]
```

and the piped session from Windows (`shots/session_pro_sp4.txt`), with the
same output line for line where the files are the same: `echo`, `ver`,
`cd sys`, `cd`, `if exist`, `for %f in (c*.nls)`, `cd ..`,
`dir /w sys\*.nls` (sorted as NTFS sorts, `966,606 bytes`), `set COMSPEC`,
`exit 7` (exit status 7). Starting `sys\cmd.exe` (Windows 2000's original)
prints `[guard]` and cmd says `Access is denied.`

What it took, beyond the services in the table above:

- **79 of ntdll's 248 services answered**; the rest log once and return
  STATUS_NOT_IMPLEMENTED. None of the unanswered ones is reached by the
  session.
- **user32 and advapi32 for cmd.exe** are proxy images of 15 host stubs
  (`src/nthost_linux.c`): no window station, an empty registry. The loader
  finds them because the file layer reports a proxy DLL's file as present.
- **The registry**: kernel32's `IsValidLocale` needs `Nls\Locale` and
  `Nls\Language Groups`; with no `HKCU\Control Panel\International` (and so
  no process token, which names the user's hive) `dir` printed sizes without
  a thousands separator. A token with one SID and the US-English
  International values setup writes fixed it. It is a read-only table.
- **Directory order**: Linux's readdir order is the disk's; NTFS returns
  names sorted by their upper case. Sorted at the first query, `for` and
  `dir` list in Windows' order.

### Gaps

- One guest thread. A wait on an unsignaled object returns a timeout (and
  says so) instead of blocking. `NtCreateThread` is not answered.
- No real console: the console csrss apis are answered empty, as on Windows
  (a terminal works as a plain file; no `cls`, `color`, cursor). Output keeps
  Windows' CRLF.
- No child processes (the guard refuses them, as on Windows).
- `RtlUnwind`'s `NtContinue` returns to its caller instead of jumping: a
  guest exception that is caught and unwound (`__except` after a raise) is
  untested here. seh32.c's replacement is Windows-only (it lives in
  native32.c); moving it into a shared file would bring it over.
- The registry is a fixed table; nothing a guest writes is kept.

## Stage 3 on Linux: winmine

**Done for winmine's client area.** Windows 2000's own winmine.exe on its own
lifted user32, gdi32, msvcrt, kernel32 and ntdll, an i386 ELF
(`winmine-linux`) on Debian 13, drawing into an offscreen framebuffer saved
as PNG. Every interact.py state compared with the Windows build's shot
(`tools/linuxcmp.py`, over the client area both show):

| state (interact.py) | Linux shot | pixels that differ |
|---|---|---|
| start (`int` 4) | `int_4_client.png` | 0 of 30,338 |
| a click on a cell (`int` 5.4) | `int_5_client.png` | 0 of 30,338 |
| Game > Intermediate (`int` 8) | `int_8_client.png` | 0 of 82,194 |
| Custom dialog driven to 20 x 30 (`dlg` 8) | `dlg_8_client.png` | 0 of 182,770 |
| Game menu open (`menu` 5, `menu2` 7) | `menu_5_client.png` | 0 under the menu; the drop-down itself is not in the Windows shot (a host popup hiddenrun does not capture) |
| Custom dialog open (`int` 10) | `int_10.png` | the board under it matches; the dialog differs by design: on Windows it is the host's #32770, Button and Edit (Windows 11 colours), here Windows 2000's own controls in user32 |

The Windows build's window is a host window with Windows 11's thicker frame,
so its client is cut at the right and bottom (154 x 197 of winmine's 164 x
207); the comparison is over what both show. The Linux frame, caption,
menu bar, drop-down and dialogs are drawn the classic Windows 2000 way, so
there is no Windows reference for them.

```
tools/linux_push.sh netlab@netlab-linux /tmp/w2k-scratch ../pcrecomp-w2k-linux ntwinmine
# on the box (2.5 minutes on 4 cores):
cd /tmp/w2k-scratch && sh linux_build.sh ntwinmine && cd root
W2K_FIXED_TICK=12345 W2K_FIXED_TIME=1000000000 ../winmine-linux --out out/int \
    --shot 4 --click 30,80@5 --shot 5.4 --command 522@7 --shot 8 --command 524@9 --shot 10
# out/int_4.png (the windows), out/int_4_client.png (the main window's client) ...
py -3 tools/linuxcmp.py shots/linux/int_5_client.png shots/int_ntwinmine_5.png
```

The script flags are hiddenrun's: `--click X,Y@T` (WM_LBUTTONDOWN/UP to the
main window), `--command ID@T`, `--post MSG,W,L@T`, `--dlgcommand ID@T` and
`--type ID=TEXT@T` (to the top window), `--shot T`, `--secs S`, `--out
PREFIX`. Times are on a **virtual clock** (ntposix `ntp_clock_virtual`):
the guest's tick count, system time and sleeps move only when it waits for
a message with nothing to deliver, then straight to the next scripted event
or timer. A run is the same every time, at any speed; winmine's 1-second
timer ticks exactly as often as on Windows. `W2K_FIXED_TICK`/`W2K_FIXED_TIME`
give the same mines as the Windows runs.

### How it works

- **ntposix.c** (pcrecomp): the win32k service table (services from 0x1000,
  numbered by user32/gdi32's own stubs, named from
  `work/names/win32k_2000sp4.txt`), win32k's **user-mode callbacks**
  (`ntp_callback`: KiUserCallbackDispatcher -> KernelCallbackTable,
  NtCallbackReturn and `int 2Bh`, the caller's registers kept), the csrss
  usersrv connect handed to the window manager, the virtual clock, and a
  SIGSEGV report (guest function, its last indirect calls, host frames for
  addr2line).
- **w32klayout.c/.h** (pcrecomp, new): the Windows 2000 shared state as
  host-independent code: the USER handle table entries, USERCONNECT /
  SHAREDINFO (DefWindowMsgs and the controls' awmControl bitmaps),
  CLIENTINFO, SERVERINFO offsets with Windows 2000's classic metrics and
  colours, the monitor, the GDI handle table entries, DEVCAPS, DC_ATTR
  offsets and the TEB batch walker.
- **w32kposix.c/.h** (pcrecomp, new): the win32k itself, ~1,900 lines.
  WNDs in a desktop heap kept in step with its own window records; classes;
  CreateWindowEx's message order (GETMINMAXINFO, NCCREATE, NCCALCSIZE,
  CREATE, SIZE, MOVE); window procedures called as win32k calls them
  (`__fnINLPCREATESTRUCT`, `__fnDWORD`, DispatchClientMessage found in
  PFNCLIENT); DefWindowProc's server half (frame, caption, buttons, menu bar,
  NCCALCSIZE by Windows 2000's GetWindowBorders, erase, text, control
  colours); the queue, WM_PAINT from update state, timers; menus (items
  mirrored into MENU/ITEM for user32's client-side lookups, a drop-down for
  SC_KEYMENU). GDI in software: memory and display DCs, 32-bit and
  monochrome bitmaps, solid and pattern brushes, pens, a ROP3 BitBlt /
  StretchBlt with GDI's mono/colour rules, PatBlt, DIBs in and out
  (1/4/8/16/24/32 bpp), lines with ROP2, pixels, text from Windows 2000's
  own sserife.fon / vgasys.fon (NE + FNT 2.0/3.0 parsed here; bold
  overstruck), the TEB batch. PNGs written with stored deflate (no zlib).
- **src/nthost_linux.c** `W2K_GUI`: winmine's module set at the Windows
  bases, proxies for what is not lifted (advapi32's registry: nothing kept,
  so the defaults; shell32's About box; winmm's PlaySound, silent).

Two things the Windows host never needed: user32's own Button, Edit and
Static controls (the Windows build used the host's), and with them two
window procedures only data points at (`EditWndProcW` 0x20307FF1, and
0x20327739, 0x2034E2F9). w32kposix reports a class procedure that is not
lifted as an `ICALL` line, `seed_from_log.py` seeds it, and user32 is
re-catalogued and re-lifted. That lift was made in a scratch tree (not
work/cat or work/seeds, which the Windows work shares); to make it
permanent: `tools/seed.sh` on a run's log, then `tools/lift.py ntwinmine ...`.

### Merge plan (w32klayout and the Windows host)

w32kuser.c and w32kgdi.c (branch `pcrecomp-w2k`, being worked on there)
were not edited. w32klayout.c holds the same layouts as functions; when that
branch is quiet, w32kuser.c's handle-table, USERCONNECT, CLIENTINFO and
SERVERINFO code and w32kgdi.c's table entries, DEVCAPS and batch walk become
calls into it (csr32.c's `client_connect` index 3 calls
`w2k_user_connect`; the batch becomes a `w2k_gdi_batch` callback). One
behaviour change comes with it: awmControl filled in (harmless while the
host's controls stand in for user32's). Then `w2k-linux` merges into the
Windows branch: ntposix.c, w32klayout.c and w32kposix.c are new files and
touch nothing the Windows build compiles.

### Gaps

- One thread, as before; hooks are accepted and never called.
- Clipping is one rectangle per DC; no regions beyond rectangles, no
  z-order clipping between windows (they draw in creation order).
- MM_TEXT only; no DIB sections read back (CreateDIBSection is a device
  bitmap with spare bits); no RLE DIBs; no palettes.
- Text: bitmap faces only (MS Sans Serif for every TrueType request), ANSI
  window procedures get Unicode text.
- The menu drop-down is drawn, not tracked (no keyboard or mouse in it);
  a click or key closes it.
- No real keyboard input; accelerators are not translated.
- Not yet run: notepad, calc, sol, freecell (cards.dll), mspaint, wordpad.

### Next

calc and notepad (Edit-heavy: the caret, EM_* through user32's own Edit),
then sol/freecell (cards.dll). An X11 or SDL window on the same framebuffer
for live use, with real input. Merge w32klayout into the Windows host when
that branch is quiet.
