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

(Gaps and next steps for all the apps are at the end of Stage 4.)

## Stage 4 on Linux: calc, notepad, sol, freecell, and a live window

**Done.** The four apps run as i386 ELFs (`calc-linux`, `notepad-linux`,
`sol-linux` and `freecell-linux`, the last two with Windows 2000's own
cards.dll lifted). Each one runs on its own lifted user32, gdi32, msvcrt,
kernel32 and ntdll. Each interact.py state was compared with the Windows
build's shot using `tools/linuxcmp.py --syscolors`:

| state (interact.py) | pixels that differ | what differs |
|---|---|---|
| calc start (`calc` 5) | 1,486 of 52,832 | only the glyphs: Windows draws calc's button text with the host's ClearType |
| calc 12+3= (`calc` 8) | 1,504 of 52,832 | the same, and the display reads `15.` on both |
| sol deal (`sol` 8) | **1 of 224,640** | one card-corner pixel at (85,8) |
| sol deck click (`sol` 10) | **1 of 224,640** | the same pixel |
| freecell deal (`fc` 8) | 15,463 of 264,388 | the column x positions: freecell lays out by client width, and the Windows host's client is 8 px narrower (Windows 11 frame), so the outer columns shift by 1-4 px. The centre columns, cells, home cells and king match. |
| freecell card to cell (`fc` 11) | 15,945 of 264,388 | the same |
| notepad start / typed (`np` 9, 11) | not pixel-comparable | text: notepad asks for Lucida Console, drawn by the host's TrueType on Windows and as MS Sans Serif here. Size: CW_USEDEFAULT is the host's on Windows. Scroll bars: Windows 11's on Windows. |

What `--syscolors` counts: the Windows build draws with the host's system
colours (Windows 11's button face is 240,240,240, Windows 2000's is
212,208,200). A pixel that is the same system colour on both sides is
counted apart (calc has 44,152 of them; sol has 585, the status bar's
frame). winmine is unchanged after all of this: 0 differing pixels in
`int` 4, 5, 8 and `dlg` 8.

```
tools/linux_push.sh netlab@netlab-linux /tmp/w2k-scratch ../pcrecomp-w2k-linux ntsol   # (ntcalc, ntnotepad, ntfreecell)
# on the box:
cd /tmp/w2k-scratch && sh linux_build.sh ntsol && cd root
W2K_FIXED_TICK=12345 W2K_FIXED_TIME=1000000000 ../sol-linux --out out/sol --shot 8 --click 40,60@9 --shot 10
# calc:     --shot 5 --command 125@5.5 --command 126@5.8 --command 92@6.1 --command 127@6.4 --command 112@6.7 --shot 8
# notepad:  --shot 9 --type "15=Hello, Windows 2000@9.5" --shot 11
# freecell: --command 102@3 --shot 8 --click 40,300@9 --click 40,50@10 --shot 11
py -3 tools/linuxcmp.py shots/linux/sol_10_client.png shots/sol_ntsol_10.png diff.png --syscolors
```

### The live window

`--live` opens an X11 window over the framebuffer and takes real mouse and
keyboard input. It is in w32kposix.c, built with `-DW2K_X11 -lX11` when
the box has i386 libX11, which netlab's Debian box does; no packages were
installed. The virtual clock follows the real one while the app waits, so
timers tick in real time. Scripted events and `--shot` still work on top.
Input goes where win32k would send it:

- **Mouse:** the capture window, or the window under the pointer.
  - In the client area: WM_MOUSEMOVE and button messages with MK_ flags.
    The second click within 500 ms is a WM_LBUTTONDBLCLK for a CS_DBLCLKS
    class.
  - Outside it: WM_NCHITTEST. A click on HTMENU drops that menu bar item
    down, and a click in the drop-down sends the item's WM_COMMAND.
  - A click activates the top-level window it lands in.
- **Keyboard:** WM_KEYDOWN and WM_KEYUP to the focus window, with Windows
  VKs. NtUserTranslateMessage makes WM_CHAR from the character X typed, so
  Shift and punctuation come out right. GetKeyState and GetAsyncKeyState
  read the keys that are down. Alt+letter and F10 open the menu, and Esc
  closes it.
- **Closing:** the window manager's close button sends WM_CLOSE.

`tools/linux_live.sh APP OUT steps...` runs an app under Xvfb (or the
`DISPLAY` you have) and drives it with xdotool, a real X input path
(XTEST). Each step is an xdotool command line, or `shot NAME` (xwd of the
window, then PNG). Verified, with shots in `shots/linux/live_*.png`:

- sol: a click on the deck turns three cards. Dragging the ace of spades
  (mousedown, two moves, mouseup) puts it on a home cell (`Score: 10`).
  A click on `Game` drops the menu down.
- notepad: `type 'Hello from X11, live!'`, Return, and a second line with
  capitals, digits and punctuation all appear in its Edit. Alt+F opens File.

```
cd /tmp/w2k-scratch/root
sh ../linux_live.sh sol out/live "mousemove 60 200" "mousedown 1" "mousemove 300 100" "mouseup 1" "sleep 1" "shot drag"
DISPLAY=:0 ../notepad-linux --live      # on a desktop session, by hand
```

### What it took

**pcrecomp `w32kposix.c`:**

- **gclBorder** (SERVERINFO +0x7E4) is 1. With 0, user32's own
  AdjustWindowRect computed a thick frame 1 px short. sol then sized its
  window 2 px narrower than it needs for a 10-px margin, never laid its
  piles out, and drew every card at (0,0).
- **WM_SIZE / WM_MOVE are sent at the first show**, as win32k's
  WFSENDSIZEMOVE does, not inside CreateWindowEx.
- **CW_USEDEFAULT:** with x = CW_USEDEFAULT, y is the show command, so a
  `WS_VISIBLE` window with y = 0 (calc's CalcMsgPumpWnd) stays hidden. Dialogs pass
  0x8000 (win32k's CW2_USEDEFAULT). The main window is the first top-level
  window shown, not the first created.
- **Class menus:** win32k loads them through `__ClientLoadMenu`
  (KernelCallbackTable 65, found by its call to LoadMenuW). That is
  notepad's menu bar.
- **System cursors and icons:** NtUserFindExistingCursorIcon answers the
  OCR/IDI ids with empty cursor objects. Without them, notepad's
  `LoadCursor(NULL, IDC_WAIT)` failed and it exited at once.
- **Window text:** NtUserDefSetText is DefWindowProc's WM_SETTEXT. It is
  calc's display, which goes through user32's own Static/Edit.
- **Scroll bars:** NtUserSetScrollInfo, the client shrunk in
  WM_NCCALCSIZE, and the bars drawn in the non-client area (arrows, the
  dithered track, the thumb; greyed with no range). This is notepad's Edit.
- **Regions:** NtGdiCombineRgn for rectangles, and RGN_ATTR read back after
  gdi32's client-side SetRectRgn. freecell's card glide left trails without
  it.

**win2000:**

- `src/nthost_linux.c` (W2K_GUI): stubs for what notepad, freecell and
  calc import from comdlg32 (every dialog cancelled), winspool, shell32's
  drag-and-drop, and advapi32 (RegCreateKeyW, RegDeleteValueW,
  RegFlushKey, IsTextUnicode). cards.dll is mapped at 0x20500000 when the
  app has it (`W2K_CARDS`). Script options can take one argument
  (`--live`).
- `tools/linux_build.sh` and `linux_push.sh` handle cards.dll and X11.
- user32 is re-lifted with the three seeds from Stage 3 (`EditWndProcW`
  and two more), now in `work/seeds/user32.dll.json` through
  `tools/seed.sh`. All five Linux sets were re-lifted: ntwinmine, ntcalc,
  ntnotepad, ntsol and ntfreecell.

**Threads and hooks:** none of the four apps sets a hook. Only calc asks
for a thread: one NtCreateThread, created suspended, after `=`. It is
refused, calc carries on, and it shows the right result, so no app needs
a second thread yet.

### Gaps

- One thread (NtCreateThread is refused). Hooks are accepted and never
  called.
- No caret (NtUserCreateCaret and NtUserShowCaret are accepted, nothing is
  drawn).
- Text: bitmap faces only. MS Sans Serif stands in for every TrueType
  request, including notepad's Lucida Console. ANSI window procedures get
  Unicode text.
- Drop-down menus: the mouse and Esc work in them; there is no arrow-key
  tracking, no hot-tracking highlight, and separators draw as gaps.
- No accelerators are translated (NtUserTranslateAccelerator returns 0):
  F2 in sol and Ctrl+N in notepad do nothing.
- Clipping is one rectangle per DC, and regions are rectangles (a result
  that is not one is kept as its bounding box). There is no z-order
  clipping between windows.
- The live window is the whole 1024x768 screen. There is no cursor shape
  and no window dragging or resizing (WM_NCLBUTTONDOWN is posted, and
  DefWindowProc's server half does nothing with it).
- Comparison: notepad's Edit text and freecell's layout cannot match the
  Windows build pixel for pixel. The Windows build's text and client size
  come from the host's win32k.
- One sol pixel (85,8) differs. It is a card corner; cards.dll restores
  corners with GetPixel/SetPixel.

### Next

- A caret.
- TranslateAccelerator.
- A TrueType rasterizer for lucon.ttf, which Windows 2000 ships. That
  would let notepad's text be compared.
- Menu keyboard tracking.
- Threads: guest threads on host pthreads under one big lock, switched at
  waits. calc is the first taker.
- mspaint and wordpad (comctl32, riched20).
- Merge w32klayout into the Windows host when `pcrecomp-w2k` is quiet.

## Stage 5 on Linux: caret, accelerators, TrueType, menu keys, threads

**Done** (pcrecomp `w32kposix.c` and `ntposix.c`, branch `w2k-linux`):

- **Caret.** NtUserCreateCaret, ShowCaret, HideCaret, SetCaretPos
  (CallTwoParam 0x5E) and DestroyCaret (CallNoParam 2) keep one caret. It
  is inverted over the live window each time it is presented, blinking at
  530 ms, and is never drawn into the framebuffer, so painting never has to
  hide it. Shots leave it out (the Windows build's shots do too).
- **Accelerators.** NtUserCreateAcceleratorTable copies the ACCEL table
  (6-byte entries). NtUserTranslateAccelerator matches WM_KEYDOWN /
  WM_SYSKEYDOWN against FVIRTKEY entries with Shift/Ctrl/Alt read from the
  keys down, and WM_CHAR against the others. It sends WM_COMMAND with
  HIWORD 1. F2 deals again in sol and F5 puts the time and date into
  notepad. Alt+letter still opens the menu first.
- **TrueType.** w32kposix reads Windows 2000's own .ttf files (head, hhea,
  OS/2, cmap 3/1 format 4, loca, glyf, hmtx, name) and scan-converts the
  outlines itself: quadratics flattened, a pixel on when its centre is
  inside (non-zero winding), monochrome as Windows 2000 draws without font
  smoothing. Each face and size is made into an fnt_t of cp1252 glyphs, so
  the bitmap text path, metrics and widths need no change. ppem is
  -lfHeight, or lfHeight scaled by unitsPerEm / (winAscent + winDescent).
  Bitmap faces still win when the .fon has the face (MS Sans Serif).
  notepad's Edit is now Lucida Console from lucon.ttf. Put the faces in
  work/fonts: `expand work\iso\I386\LUCON.TT_ work\fonts\lucon.ttf` (and
  TAHOMA.TT_), and linux_push.sh copies them.
- **Menu keys.** With a menu down: Up/Down move the highlight (skipping
  separators), Left/Right drop the next bar item's menu down, Enter chooses,
  Esc closes and a mnemonic letter chooses. The mouse hot-tracks. Menu
  items given as MFT_STRING with no string are separators, as win32k makes
  them (user32 loads notepad's separators that way, mask 0x103), and are
  drawn as the etched line.
- **Threads.** NtCreateThread, NtResumeThread and NtTerminateThread run a
  guest thread on a host pthread. One big lock: the thread holding it runs
  guest code. The register file is global, so a thread that gives the lock
  up keeps its registers on its own host stack (ntp_yield). Waits
  (NtWaitForSingle/MultipleObjects, NtDelayExecution) poll every 1 ms while
  other threads exist, and w32kposix's idle loop yields. A thread object is
  signalled when its thread ends. The new TEB is a copy of the first
  thread's (USER's thread info with it) with its own stack, id and self
  pointer. calc's worker thread (BaseThreadStartThunk, start 0x010045F7)
  now runs; calc's result is unchanged.

| state | pixels that differ |
|---|---|
| calc start / 12+3= (`calc` 5, 8) | 1,486 / 1,504 of 52,832 (as before: ClearType glyphs on the Windows side), with the worker thread running |
| sol deal (`sol` 8) | 1 of 224,640 (as before) |
| winmine `int` 4, 5, 8 | 0 (as before) |
| notepad typed (`np` 11) | still not pixel-comparable: the Windows build's text is the host's ClearType Lucida Console. Ours is the same face and advance (8 px at -13), drawn mono and unhinted |

Live, under Xvfb with xdotool (`tools/linux_live.sh`): the caret blinks
after `abc` in notepad; F5 inserts the time; Alt+E, Down, Down highlights
Cut past the separator; Right drops Format down; Alt+E then `a` selects
all; a click on File and a move hot-tracks Open. In sol, F2 deals anew.

### Gaps

- TrueType: no hinting (no bytecode interpreter), so stems can land one
  pixel off Windows 2000's hinted output; no embedded bitmaps (lucon.ttf
  has EBDT strikes for 5-8 ppem only); composites keep offsets but not
  their scale; glyphs are cut at their advance; no bold or italic face
  files (bold is still overstruck).
- Threads: waits poll; one message queue for all threads (a second thread
  calling GetMessage would take the first one's messages); MMX/SSE and the
  x87 ring are not switched (a syscall is never reached mid-expression).
- The scripted `--type` posts WM_CHAR and notepad shows `windows` where the
  text has `Windows` (seen in np 11; not chased).
- Disabled menu items take the highlight (as Windows does) but Enter on one
  does nothing.

### Next

- mspaint and wordpad. Neither imports comctl32 (MFC loads it), but both
  import ole32, shell32, comdlg32, advapi32 and (mspaint) imm32, which
  nthost_linux.c needs stubs for, and mfc42u (0x20600000) and riched20
  (0x20700000) need mapping. comctl32 itself is lifted in the ntexplorer
  set; it has to be in the mspaint/wordpad sets for MFC's toolbar and
  status bar.
- A TrueType bytecode interpreter (fpgm, prep, glyph programs) so
  notepad's text can be compared pixel for pixel with a Windows 2000 VM.
- Per-thread message queues when a second thread makes a window.

## Stage 6 on Linux: mspaint and wordpad (done)

**State:** `mspaint-linux` builds and runs to its message loop on its own
lifted mspaint, mfc42u **and comctl32**, plus user32, gdi32, kernel32,
msvcrt and ntdll. It exits cleanly, but the only shot is 6x25, so the frame
window is not sized or shown yet.

The Linux set is `ntmspaint_lx`. It is separate from the explorer agent's
work: its own comctl32 copy in `work/lx` and its own catalogs in `work/cat-lx`.

```
expand work\iso\I386\COMCTL32.DL_ work\lx\src\comctl32.dll
py -3 ../pcrecomp-w2k-linux/tools/pe/rebase.py work/lx/src work/lx/reb comctl32.dll=0x20800000
R=work/rebased-gui; PCRECOMP=../pcrecomp-w2k-linux py -3 tools/lift.py ntmspaint_lx $R/mspaint.exe \
  $R/mfc42u.dll work/lx/reb/comctl32.dll $R/ntdll.dll $R/kernel32.dll $R/msvcrt.dll $R/user32.dll $R/gdi32.dll
tools/linux_push.sh netlab@netlab-linux /tmp/w2k-s6 ../pcrecomp-w2k-linux ntmspaint_lx
# box: sh linux_build.sh ntmspaint_lx; cd root; ../mspaint-linux --out out/mp --shot 8
```

That takes about 13 minutes of lifting (mfc42u: 0 unimplemented; comctl32: 61,
all in dead code). A set named `ntX_lx` builds `X-linux`.
`linux_build.sh` adds `-DW2K_MFC` (mfc42u at 0x20600000, comctl32 at
0x20800000) and `-DW2K_RICHED` (riched20 at 0x20700000) when the set has
them. `nthost_linux.c` has stubs for what mspaint, mfc42u and comctl32
import from advapi32, shell32 (`CommandLineToArgvW` gives one argument),
ole32 and imm32 (all failing or empty).

**Not answered yet:**
- NtUserGetThreadState(1)
- NtUserCallHwnd(…, 0x3D)
- NtUserCallOneParam 0x25
- NtUserGetIconSize
- NtUserGetCursorFrameInfo
- NtGdiGetTextCharsetInfo
- NtGdiGetRandomRgn
- NtGdiGetLayout (no service name)

Since then (pcrecomp `w2k-linux`): NtUserGetThreadState (0 focus,
1 active, 2 capture) and NtUserGetIconSize are answered. The shot is still
6x25, and W2K_TRACE logs no window creation, so the next run needs a trace
of NtUserCreateWindowEx/ShowWindow (class, style, size) to see where MFC's
frame goes.

### mspaint: up (pcrecomp 765d2e4, win2000 241742e)

Why the frame stayed 6x25: that window was a message box, "OLE 2.0 was
unable to start" (the ole32 stub failed OleInitialize, so AfxOleInit did).
`NATIVE32_SYSCALLS=1` now logs every CreateWindowEx (class, text, style,
size, parent) and ShowWindow. Then, in order:

- OleInitialize succeeds. CommandLineToArgvW's array is GlobalAlloc'd
  (mspaint GlobalFrees it; host memory crashed RtlFreeHeap).
- **WH_CBT is called.** MFC registers its classes with DefWindowProc and
  subclasses each window in its CBT hook at HCBT_CREATEWND. w32kposix keeps
  one CBT hook and calls it straight from CreateWindowEx (`ntp_guest`, a
  guest stdcall with the registers kept). CallNextHookEx reads CLIENTINFO's
  phkCurrent (TEB +0x6EC, less the delta at +0x6E8); a fake HOOK with no
  next and flag 1 makes it return 0.
- NtUserDeferWindowPos (applied at once), EndDeferWindowPosEx, SetParent
  (the tool box goes into its dock bar), SelectPalette: MFC's RecalcLayout.
- **RLE4/RLE8 DIBs** (the tool icons are one 448x32 RLE bitmap).
- CallHwnd 0x3D (SetMsgBox), CallOneParam 0x25 (PlayEventSound),
  GetCursorFrameInfo, GetTextCharsetInfo (ANSI, Latin 1), GetRandomRgn
  (the DC's visible rect), RectVisible, GetNearestColor. NtGdiGetLayout has
  no service in this build (gdi32 never calls it).

Compared with `shots/paint_ntmspaint_9.png` (the Windows build). The whole
client does not line up: the Windows build's client is smaller (Windows
11's frame), so MFC lays out a smaller view with scrollbars. Per region,
each placed where it fits best, host system colours mapped to Windows
2000's:

| region | pixels that differ |
|---|---|
| tool box (58x272) | 1,232 of 15,776 |
| colour box (250x52) | 500 of 13,000 |
| whole client, linuxcmp `--syscolors` | 17,518 of 91,686 (layout) |

Live under Xvfb (`linux_live.sh mspaint out/live "mousemove 110 100"
"mousedown 1" "mousemove 160 150" "mousemove 200 190" "mouseup 1"`): the
pencil draws the line on the canvas.

### wordpad (`ntwordpad_lx`)

Lifted: wordpad, mfc42u, riched20, comctl32 (work/lx) and the base set
(64,868 functions, ~25 min). nthost_linux.c stubs (all failing or empty):
ole32 StgOpenStorage, OleRegGetUserType, ReadClassStg,
StgCreateDocfileOnILockBytes, CreateILockBytesOnHGlobal, ReleaseStgMedium;
advapi32 RegDeleteKeyW; shell32 SHGetSpecialFolderPathW. riched20 and
mfc42u import nothing from ole32.

Fixed on the way:
- **A new thread's TLS slots start empty.** The TEB copy carried the first
  thread's TlsSlots, so MFC's worker thread (wordpad starts one) shared the
  main thread's thread state and took m_pMainWnd; InitInstance then
  returned FALSE with no message loop.
- SERVERINFO's atomSysClass has MDIClient (6) and ComboLBox (7): a combo
  box makes its list box by atom.

### wordpad: up (pcrecomp 0dec007, win2000 this commit)

**The heap corruption was a stack imbalance, not a heap bug.** riched20
loads ole32 lazily: at its first message it GetProcAddresses
`RegisterDragDrop` (riched20 0x2071B9D8: `if (!p) p = resolve(...); p(a, b);
ret 8`). The ole32 proxy had no such name, so the pointer stayed NULL and
the lifted `RECOMP_ICALL` miss returned without popping the two stdcall
arguments. Each call left 8 bytes on the stack, the caller's frame shifted,
and riched20 later wrote through a stale pointer into the process heap.
The next LocalAlloc (EM_SETOLECALLBACK) fell over. `ICALL: unresolved VA
0x00000000 from 0x2071B9D8` in the log was the clue. With
`NTP_GLOBALFLAG=0x470` (ntdll's own heap checks, below) the heap layout
moved and nothing crashed, so the heap was never at fault.

Fix: the ole32 stubs have `RegisterDragDrop` (2) and `RevokeDragDrop` (1).
riched20 resolves about 75 names this way (oleaut32, ole32, oleacc, imm32,
user32). A missing one is always this bug, so any `ICALL: unresolved VA
0x00000000` in a log needs a stub with the right argument count.

New in pcrecomp:
- `NTP_GLOBALFLAG=n` sets the PEB's NtGlobalFlag (0x470: tail, free and
  parameter checks, validate on every call). int 2Dh (DbgPrint) text goes to
  stderr as `[dbgprint]`.
- win32k: NtGdiGetTextFaceW, NtGdiEnumFontOpen/EnumFontChunk (one
  ENUMFONTDATAW per .fon face, Western; a named face is answered as
  itself), NtUserGetClassName, NtUserFindWindowEx, NtUserUnregisterClass,
  NtUserCountClipboardFormats (empty), NtUserScrollWindowEx (no bits moved:
  the whole client is repainted), CallHwndParam 0x41/0x46 on ExStyle and
  style (the combo box clears WS_VSCROLL|WS_HSCROLL|WS_BORDER, offset 0xE).
- InvalidateRect repaints the window's children too. The rect is not kept,
  so a toolbar repainted for its B button painted over its combo boxes.
- SetActiveWindow on a child does nothing (win32k refuses it). mspaint asks
  for its view's, and the frame's caption went inactive at the first click.

Compared with `shots/wp_ntwordpad_9.png` by region (the Windows client is
wider: Windows 11's frame and CW_USEDEFAULT). Each region was placed where
it fits best, with host system colours mapped to Windows 2000's:

| region (Linux client) | pixels that differ |
|---|---|
| standard toolbar (292x23) | 584 of 6,716 |
| ruler (712x24) | 391 of 17,088 |
| status text (100x18) | 265 of 1,800 (ClearType vs MS Sans Serif) |
| format bar buttons (208x26) | 3,335 of 5,408 (button spacing differs; the glyphs match) |

Live under Xvfb (`linux_live.sh wordpad out/live "sleep 6" "mousemove 300
300" "click 1" "type 'Hello, Windows 2000'" "key Return" "key ctrl+b" "type
'bold on Linux'" ...`): the text appears with the caret, Ctrl+B makes it bold
and presses the B button, Undo enables, and 26 Returns scroll the text up.

**Still missing:**
- The combo boxes' drop arrows are blank. DrawFrameControl takes them from
  the OEM system bitmaps (gpsi's oembmi / hdcBits), which SERVERINFO lacks,
  not from Marlett text (no ExtTextOut with the Marlett font is made).
- The script combo is empty: wordpad's default face, Arial, is not among the
  enumerated .fon faces.
- NtUserShowScrollBar: answering it (style bits only) drew a 2 px strip,
  because RichEdit gets no WM_SIZE, so it was taken out again.
- No NUM indicator or size grip in the status bar.

Regression (same scripts as Stage 4), with this runtime and with 79c4dbd's:
winmine int 4, 5, 8: 0. calc 5: 1,486. freecell 8 / 11: 15,463 / 15,945.
calc 8 is 1,661 and sol 10 is 3,480 (sol 8: 1). Both runtimes give
byte-identical calc 8 images, so this baseline drifted since the last doc
(1,504 / 1). calc's '%' button frame and sol's last column (5♥ face up)
differ; the cause was not looked into.

Build note: building four sets at once on the 4-core, 8 GB box (J=nproc
each) ran it out of memory for about 20 minutes. Build one set at a time
with `J=3`.

### Next

1. The OEM system bitmaps in SERVERINFO (combo and scroll arrows).
2. RichEdit's scroll bar: ShowScrollBar plus WM_SIZE to the window.
3. wordpad's font list: TrueType faces (Tahoma, Lucida Console) or an
   Arial alias, so the script combo fills.
4. mspaint: the canvas's DIB section (`CreateDIBSection ... bits are not
   read back`).
5. calc 8 / sol 10 baseline drift (see above).

## Stage 7 on Linux: explorer (in progress, handoff)

**Merge.** pcrecomp `w2k-linux` has origin/main (a9fe1aa) merged in
(e13a149, no conflicts). The Linux backend files (ntposix, w32kposix,
w32klayout) were not touched by main; only the lifter tools changed. With
the merged runtime, winmine-linux's `int` 4, 5, 8 and 10 shots are
pixel-identical (0 differing) to the earlier Linux shots in `shots/linux`.
(Against the Windows build's shots, int 5 is now 107 and int 10 37,852: the
Windows goldens moved since Stage 3, the Linux output did not.)
With this stage's runtime (registry box, unwind, RPC guard, stack growth,
image restore) winmine-linux, rebuilt from today's `src/gen/ntwinmine`,
is again 0 differing at int 4, 5, 8 and 10. linux_build.sh/linux_push.sh
key the explorer build on `gen/APP/explorer` (today's ntwinmine lift has
shell32 in it too).

**The set.** `ntexplorer_lx` = the Win11 explorer set (work/rebased-shell:
explorer, ntdll, kernel32, msvcrt, user32, gdi32, comctl32, shlwapi,
shell32, browseui, shdocvw, ole32, oleaut32, rpcrt4, actxprxy, clbcatq,
mydocs) plus **Windows 2000's own advapi32** at 0x21F00000 (work/lx/reb). On
Windows advapi32 is the host's, boxed; here there is no host registry, so
the lifted advapi32's Reg* reach the guest ntdll and ntposix's registry box.
Catalogs are work/cat-lx (copied from work/cat), seeds work/seeds-lx (a copy
of work/seeds plus what Linux runs find: tools/lift.py picks it for the
`_lx` sets). 132,290 functions; about 10 minutes to lift, 8 to build (J=3).

```
expand work\iso\I386\ADVAPI32.DL_ -> work/lx/src; rebase.py work/lx/src work/lx/reb advapi32.dll=0x21F00000
R=work/rebased-shell; PCRECOMP=../pcrecomp-w2k-linux py -3 tools/lift.py ntexplorer_lx $R/explorer.exe ... $R/mydocs.dll work/lx/reb/advapi32.dll
reg export HKCU\Software\pcrecomp\w2k\explorer box.reg; py -3 tools/regbox_lx.py box.reg work/lx/explorer.box
tools/linux_push.sh netlab@netlab-linux /tmp/w2k-ex ../pcrecomp-w2k-linux ntexplorer_lx
# box: sh linux_build.sh ntexplorer_lx; cd root; cp ../explorer.box out/ex.box
#      W2K_FIXED_TICK=1000 ../explorer-linux --regbox out/ex.box --screen 800x600 --out out/ex --shot 10
```

**The registry box (POSIX).** ntposix keeps one tree of keys and values in
memory, seeded with the NLS/International table it had, then loaded from
the box file (`ntp_regbox`, `--regbox FILE`) and rewritten after every
write. Nothing else is read or written: no host registry exists. The file is
text, `[\Registry\...]` per key and `"name"=hex(T):..` per value.
tools/regbox_lx.py makes it from the Windows box (reginst.py's COM classes,
profile.py's folders and colours), with paths moved to C:\WINNT\system32 and
values naming another host drive, and UserAssist, left out. Services: Open/
CreateKey, Query/Set/Delete/EnumerateValueKey, Query/Enumerate/DeleteKey,
FlushKey, NotifyChangeKey (pending forever).

**The drive sandbox (POSIX).** Already the shape it needs: the guest sees
only the mounts (C: = the scratch root, C:\WINNT\system32 = root/sys), `..`
stops at a mount's root, and now a symlink anywhere on a path is refused, so
nothing under the root leads out of it. The profile (work/profile/C/
Documents and Settings: the Start Menu's .lnk files point at
C:\WINNT\system32\*.exe) goes to root/, and the guest's environment has
USERPROFILE, ALLUSERSPROFILE, APPDATA, ProgramFiles and HOMEPATH under C:.

**The guard.** Unchanged in ntposix (NtCreateProcess refused; an EXE that is
not lifted is never mapped). nthost_linux's launch path replaces kernel32's
CreateProcessW/A: the program's name must have a lifted runner next to
ours (winmine.exe: ./winmine-linux), which starts as our child process
(same --root, --live if we are live; it dies with us). Anything else prints
`[guard] ...: a program that is not lifted: not run` and fails. Not yet
exercised (explorer does not reach the Run dialog).

**New in ntposix** (all also needed by any bigger guest): I/O completion
ports (the thread pool), the global atom table, RtlUnwind over the guest's
fs:[0] chain (the guest's own ends in NtContinue, which a lift cannot do),
the RPC client call guard (ole32 calls rpcss, which does not exist: the
call fails with the status instead of raising), a thread stack grows into
its reserved pages, and a lifted image mapped again gets its writable
sections back (as syscall32.c). Host: GetUserNameW/A answer "user" (advapi32
asks LSA over \PIPE\lsarpc).

**State.** explorer-linux runs its process start, the tray thread starts,
and the desktop window paints Windows 2000's background colour
(`shots/linux-ex/ex1_10.png`, 800x600, 58,110,165). Then:

- With clbcatq mapped, ole32 enters the COM+ catalog: clbcatq creates
  C:\WINNT\Registration\R000000000001.clb (52 bytes), and a vtable call
  inside its setup (sub_21547DA0, `call [ecx+0xc8]`) reads NULL, then a
  call to 0x003A0043 ("C:") faults. On Windows (findings, "clbcatq's failed
  load, twice") clbcatq's load fails and ole32 uses the registry; why it
  fails there is not known yet.
- With `W2K_SKIP=clbcatq.dll` (a debug switch in nthost_linux: the module
  is not mapped, so its load fails as on Windows), ole32 goes on, then
  explorer starts shutting down (NtUserUnregisterHotKey) and ole32's
  teardown faults in user32 sub_2032348C reading 0x44. Most likely a
  CoCreateInstance that the desktop needs failed: trace it with
  NATIVE32_SYSCALLS=1 (the CLSID keys opened under
  \Registry\Machine\Software\Classes and which one is missing from the box).

### Stage 7, second session: the taskbar on Linux

`shots/linux-ex/taskbar_30.png` (not in git): Windows 2000's desktop colour,
the taskbar with the Start button (logo and bold "Start", drawn through
DrawCaptionTemp), the quick-launch gap and the clock. No crash in 30 s.

**Why clbcatq "fails" on Windows (root cause).** It does not fail: its
DllMain succeeds (`--calltrace`: 21517A60 -> 2152051A -> GetVersionEx ->
TRUE). While clbcatq's imports resolve, the guest loader finds ole32.dll on
its search path as the *host's* C:\Windows\system32\ole32.dll;
NtAreMappedFilesTheSame says it is not the loaded work/rebased-shell ole32,
so the loader maps "another" ole32 (syscall32 hands back the same lifted
image) and runs ole32's DllMain a second time (entry 21002CE2, calltrace
line 78888). That resets ole32's catalog state ([esi+0x18] in ole32's
sub_2100D690), so after LoadLibrary ole32 sees the state changed and frees
clbcatq without calling GetCatalogObject. It is a Windows-host loader
artifact, not Windows 2000 behaviour. The faithful way to the same outcome
is Windows 2000's own switch: ole32 checks `%windir%\System32\~CLBCATQ.DLL`
(setup's marker) and, when it exists, never loads the catalog and reads the
registry. linux_push.sh puts that empty file in explorer's system32; it is
only GetFileAttributes'd, never loaded.

**The failing CoCreateInstance.** CLSID {ECD4FC4D-521C-11D0-B792-00A0C90312E1}
(browseui's Shell Rebar BandSite): its InprocServer32 had no default value
in the box. regbox_lx.py dropped every value naming a host drive *before*
moving the rebased-shell path (`G:\recomp\...\rebased-shell\browseui.dll` ->
`C:\WINNT\system32\browseui.dll`). Fixed (rewrite first, then check). The
values are reginst.py's, from Windows 2000's own self-registration data.

**Explorer's own --sys.** `DIR/sys-ex` holds the shell set (the Win11
explorer set plus Windows 2000's advapi32), the fonts, NLS files, win32k
names, ~clbcatq.dll and an empty winmine.exe (a name for Run's search; the
launch path starts ./winmine-linux, never a file). `root/sys` stays the GUI
set a launched `NAME-linux` child maps.

```
tools/linux_push.sh netlab@netlab-linux /tmp/w2k-ex ../pcrecomp-w2k-linux ntexplorer_lx
# box: J=3 sh linux_build.sh ntexplorer_lx; cd root; cp ../explorer.box out/ex.box
#      W2K_FIXED_TICK=1000 ../explorer-linux --sys ../sys-ex --regbox out/ex.box --screen 800x600 --out out/ex --shot 30
```

**pcrecomp (w2k-linux 2b0a275, 0c83c6f).** Answered: GetIconInfo,
DrawCaptionTemp, CreateHalftonePalette, CreatePaletteInternal, DoPalette,
GetBitmapBits, (Un)RegisterHotKey, PaintDesktop, SetShellWindowEx,
EnumDisplayMonitors, EnumDisplaySettings, BuildHwndList (ends with HWND 1),
GetProcessWindowStation, GetObjectInformation(UOI_NAME), SetWindowPlacement,
CallOneParam 0x18/0x21/0x1D (the input event), CallHwnd 0x3C/0x39,
CallHwndLock 0x4D, CallHwndOpt; NtOpenProcess (the guest's own process),
NtQuerySecurityObject (a NULL DACL), ProcessSessionInformation. Fixed:

- The desktop window had no class: GetClassLong(GetDesktopWindow()) read
  0x44 (the old "user32 teardown" fault).
- comctl32's zero-width toolbar got WM_PAINT forever: an empty window gets
  none.
- The idle clock jumped straight to the next event, so a shot came before
  the tray thread had run: now at most 100 ms per idle.
- The monitor had no handle (MONITOR +0 = 0), so user32's GetMonitorInfo
  failed and the taskbar placed itself on a 0x0 monitor.
- No z-order: Progman painted over the taskbar. HWND_TOPMOST now sets
  WS_EX_TOPMOST, and a topmost window's edge band is left out of the other
  top-level trees' DCs (one rectangle per DC; real regions later).

One relift: the ole32 seed 0x2108E539 (work/seeds-lx).

**Regression (Linux: this runtime against cd6b8f0's, the same lifted sets).**

| app | shots | differing pixels |
|---|---|---|
| calc | 5, 8 (+client) | 0 |
| freecell | 8, 11 (+client) | 0 (also 0 against shots/linux) |
| mspaint | 8 (+client) | 0 |
| wordpad | 9 (+client) | 0 |
| notepad | 9, 11 client | 0 |
| sol | 8, 10 client | 0 |
| notepad / sol whole window | 9, 11 / 8, 10 | 10 / 1, all inside the 16x16 caption icon |

The caption-icon pixels do not come from this runtime: a binary with the
*old* ntposix.c and w32kposix.c linked against the same lifted objects shows
the same pixel. They depend on the build (probably an uninitialised read on
the icon path). Not chased. (The first SetWindowPlacement left wordpad 0x0
and mspaint at CW_USEDEFAULT: empty and CW_USEDEFAULT rects are now ignored.)

### Handoff (next)

1. **Desktop icons.** The SysListView32 stays 0x0. DefView sizes itself to
   800x572 before it creates the list view, and its second SetWindowPos has
   the same size, so no WM_SIZE follows (on Windows the work area changed in
   between). DefView passes WM_WINDOWPOSCHANGED to DefWindowProcW, yet no
   kernel DefWindowProc call follows here: read user32's client-side
   DefWindowProcWorker for 0x47.
2. **Live mode crashes** (the Start menu click under Xvfb): signal 11 in
   user32 sub_203172D0 reading 0xE79E7020, a host stack address handed to
   the guest (an lParam?). `W2K_FIXED_TICK=1000 LIVEARGS="--sys ../sys-ex
   --regbox out/ex.box --screen 800x600" sh ../linux_live.sh explorer out/lv
   "sleep 8" "mousemove 25 588" "click 1" "sleep 3" "shot start"`. Scripted
   `--click 25,588@N` is the other way in.
3. Then the Start menu and Run -> winmine (build ntwinmine in the same
   scratch directory: root/sys is its set).
4. Windows host: stop the guest loader from mapping ole32 twice (the host
   System32 on its search path); then the Windows run takes the same path.
5. Not answered: CallNoParam 21 (92 calls), SPI 0x2B/0x66, csr 1:1, 1:12,
   3:1029, SendNotifyMessage(HWND_BROADCAST).
