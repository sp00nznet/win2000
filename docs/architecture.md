# How win2000-recomp works

Windows 2000 is an NT system: a small kernel (ntoskrnl + win32k.sys) and a
userland that talks to it through numbered **system calls**. This project
statically recompiles Windows 2000's own userland (ntdll, kernel32, user32,
gdi32, shell32, explorer, the accessories…) into C, runs it as ordinary host
processes, and replaces only the kernel side. The same lifted code runs on
**Windows 11** and on **Linux**; only the bottom layer changes. Nothing is
emulated and no original instruction ever runs.

                    Windows 2000's own userland, lifted to C
     ┌──────────────────────────────────────────────────────────────────┐
     │  explorer  notepad  calc  winmine  mspaint  wordpad  cmd  …      │
     │  shell32  browseui  shdocvw  comctl32  ole32  oleaut32  rpcrt4   │
     │  user32   gdi32   advapi32   kernel32   msvcrt                    │
     │                         ntdll                                    │
     └───────────────┬───────────────────────────────┬──────────────────┘
          int 2Eh    │ NT services                    │ win32k services
         (eax = id)  │ (files, memory, threads…)      │ (windows, GDI)
                     ▼                                ▼
     ┌──────────────────────────────┐  ┌───────────────────────────────────┐
     │ syscall32.c   (Win11 host)   │  │ w32kuser.c / w32kgdi.c (Win11)    │
     │ ntposix.c     (Linux host)   │  │ w32kposix.c            (Linux)    │
     │ + csr32.c  (csrss stand-in)  │  │ + w32klayout.c (shared structs)   │
     └──────────────┬───────────────┘  └──────────────────┬────────────────┘
                    ▼                                     ▼
        host kernel (NtXxx / POSIX)          host windows & GDI  /  X11 + our
                                             own software renderer

## 1. Static recompilation

pcrecomp disassembles each Windows 2000 PE from its entry points, exports and
seeds, and lifts every function into a C function over a CPU-state struct.
Indirect calls go through a dispatch table keyed by guest address. Each DLL is
rebased to a free range (Win2000's own system DLL addresses collide with the
host's) and loaded at that fixed address, so guest pointers stay valid.

     ntdll.dll bytes ─disassemble─▶ catalog ─lift─▶ ntdll_*.c ─cc─▶ host code
     the original bytes stay in memory as data only; they are never executed

## 2. The NT boundary

Every ntdll export that enters the kernel is the same five instructions:
`mov eax, <service>; lea edx, [esp+4]; int 2Eh; ret N`. The lifter turns
`int 2Eh` into a call to the runtime, which looks the service number up in a
table built from ntdll's own export names (no symbols needed):

     kernel32!CreateFileW
        └─▶ ntdll!NtCreateFile            mov eax,0x20 ; int 2Eh
               └─▶ recomp_syscall(c)      (lifted int 2Eh)
                      └─▶ table[0x20] = "NtCreateFile"
                             ├─ Win11: path → sandbox, then the host's NtCreateFile
                             └─ Linux: path → sandbox, then open(2)

     service ids ≥ 0x1000 are win32k's (NtUser*, NtGdi*) and go to the
     window/graphics layer instead.

Startup is Windows 2000's own: the host maps the lifted modules, builds the
PEB/TEB the kernel would build, and calls ntdll's `LdrInitializeThunk`.
Win2000's loader then snaps imports, runs every DllMain and enters the
program, exactly as on real NT.

     host ─▶ map modules ─▶ PEB/TEB/process params ─▶ ntdll!LdrInitializeThunk
                                                       ├ heap, loader lists
                                                       ├ snap imports
                                                       ├ DllMain × N
                                                       └ program entry

**csrss** (the Win32 subsystem server, another process on real NT) is
answered at its LPC port by `csr32.c`: console connections, process and
thread registration, the user server's shared data.

## 3. Windows and drawing: a win32k of our own

Windows 2000's user32 and gdi32 don't just call the kernel. They read
win32k's state directly from memory the kernel shares with every process:
the handle table, each window's record, the system metrics, GDI's per-DC
attributes, a batch of queued drawing commands. So the runtime keeps those
structures **in Windows 2000's layout**, read off the lifted code.

     user32 (lifted)                       runtime (w32kuser/w32kgdi)
     ───────────────                       ──────────────────────────
     IsWindow(h) ──reads──▶ shared handle table ◀──keeps── in sync with
     GetWindowLong ─reads─▶ WND record (0x9C B) ◀──keeps── the real window
     GetSysColor ──reads──▶ SERVERINFO          ◀──fills── from the box/host
     SelectObject ─writes▶ DC_ATTR             ──read on draw──▶ host GDI
     PatBlt ──queues──────▶ TEB GDI batch      ──flushed──▶ host GDI

     messages go through Windows 2000's own callback path:
       host window proc ─▶ KiUserCallbackDispatcher ─▶ user32 __fnXXX ─▶ app WndProc

On **Windows 11** each guest window is a real host window, and drawing goes
to host GDI with the guest's handles translated both ways. On **Linux** there
is no Windows GDI at all, so `w32kposix.c` is a small window manager and
software renderer: windows, clipping, BitBlt, DIBs, pens and brushes, menus,
and a TrueType rasterizer of its own, drawing into a framebuffer shown in an
X11 window.

## 4. Explorer in a box: the virtual screen

Explorer expects to own the whole screen. In virtual-screen mode, one host
window *is* Windows 2000's screen, and every guest top-level window lives
inside it.

     ┌──────────────── host window: "the screen" (800×600) ───────────────┐
     │  [My Computer]                                                      │
     │  [Recycle Bin]      ┌────── Minesweeper (separate process) ──┐      │
     │                     │  launched by Start ▸ Run ▸ winmine,    │      │
     │                     │  through the guarded launch path       │      │
     │                     └────────────────────────────────────────┘      │
     │ [Start] [Minesweeper]                                  10:42 AM     │
     └─────────────────────────────────────────────────────────────────────┘

     shell hooks, the shell window, hotkeys, "foreground": all answered
     inside the virtual screen; the host's real taskbar is never touched.

On Linux, launched programs run as child processes that draw into a shared
memory surface in the scratch directory; explorer composites them into its
screen, forwards input, and gives each a taskbar button.

## 5. Launching programs: the guard

     guest CreateProcess("C:\WINNT\system32\notepad.exe")
        └─▶ runtime launch path
              ├─ is there a lifted runner for "notepad"?  ──yes──▶ start
              │     Win11: build\ntnotepad.exe   Linux: ./notepad-linux
              └─ no ──▶ refused, "[guard]" on stderr

     an original Windows 2000 executable is never run, on either host.

## 6. The walls

     ┌────────────────────────────── guest ───────────────────────────────┐
     │ registry ─▶ regbox32: HKCU\Software\pcrecomp\w2k\<app>  (Win11)     │
     │             a box file in the scratch dir              (Linux)      │
     │             Win2000-owned keys are box-only; seeded from its INFs   │
     │ drives   ─▶ every drive letter maps under work/profile (FILEBOX);   │
     │             \Device, UNC, ..-escapes and junctions refused          │
     │ settings ─▶ SystemParametersInfo/ChangeDisplaySettings/SetSystemTime│
     │             setters refused at the system call                      │
     │ host DLLs─▶ only advapi32 may load into a guest (strict check)      │
     │ RPC/LPC  ─▶ only the emulated csrss port                            │
     │ audio    ─▶ PCRECOMP_MUTE: no devices                               │
     │ errors   ─▶ hard errors answered locally, SetErrorMode everywhere   │
     └────────────────────────────────────────────────────────────────────┘

## 7. Two hosts, one userland

                       same lifted Windows 2000 modules
                    ┌──────────────┴───────────────┐
             Windows 11 host                    Linux host (i386)
     ──────────────────────────────    ──────────────────────────────────
     syscall32.c → host ntdll           ntposix.c → POSIX (files, mmap,
                                          pthreads, events)
     csr32.c                            csr32-equivalent in ntposix.c
     w32kuser/w32kgdi → host USER/GDI   w32kposix → own window manager,
                                          renderer, TrueType, X11 window
     registry box in the host registry  registry box in a file
     regbox32 / FILEBOX                 the same sandbox rules in POSIX form

## 8. Gates

| Gate | What it proves |
|---|---|
| `tools/interact.py` | 8+ apps driven through scripted states, compared pixel-for-pixel with approved goldens (per display) and with the host-library build |
| `work/scen.sh` | explorer scenarios under the strict host-module check |
| `tools/filebox_check.sh` | the guest can't see or touch anything outside the sandbox |
| `tools/hostsettings.py` | the host's display, clock and settings are unchanged after a run |
| `tools/linuxcmp.py` | the Linux builds against their previous output |

## 9. What lives where

| Piece | Where |
|---|---|
| Lifter, disassembler, rebase | pcrecomp `tools/` |
| NT services, csrss, win32k (Win11) | pcrecomp `runtime/native32/` (`syscall32.c`, `csr32.c`, `w32kuser.c`, `w32kgdi.c`, `regbox32.c`) |
| NT services, win32k (Linux) | pcrecomp branch `w2k-linux`: `ntposix.c`, `w32kposix.c`, `w32klayout.c` |
| Hosts, launch path | this repo, `src/` |
| Lifting, profiles, registry seeding, harness | this repo, `tools/` |
| Findings, session by session | `docs/findings.md` (Win11), `docs/linux.md` (Linux) |
