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

### Next: winmine (stage 3) on Linux

On Windows, stage 3 runs Windows 2000's own user32 and gdi32 lifted, and
answers their win32k services with the *host's* USER and GDI
(`w32kuser.c`, `w32kgdi.c`: real HWNDs, real DCs, PrintWindow shots). None
of that exists on Linux, so winmine needs a win32k of its own, not a port:

1. Lift `ntwinmine`'s set (user32 + gdi32 at 0x20300000/0x20400000) into
   the Linux build and boot it; first wall: user32's DllMain connects to
   usersrv (csrss server 3) and wants SERVERINFO and the handle table
   (csr32.c's `client_connect` index 3 shows the layout).
2. A win32k on the guest's own data structures: windows (WND in the
   desktop heap user32 reads client-side), classes, a message queue,
   `KiUserCallbackDispatcher` for window procedures (the callback path in
   syscall32.c is host-independent and can be shared).
3. GDI into an offscreen 32-bit framebuffer, saved as a PNG per frame or on
   request; X11 later. winmine draws with BitBlt from its own bitmaps,
   rectangles, lines and text, so the first GDI set is small.

That is a project of its own (the Windows win32k layer is ~1,900 lines and
leans on the host for all of it).
