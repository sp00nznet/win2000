# Findings

## Stage 1: accessories on native32 (host DLLs)

| App | Lifted functions | Result |
|---|---|---|
| winmine | 119 | runs; new game board drawn |
| sol | 207 + cards.dll 18 | runs; deal drawn |
| freecell | 103 + cards.dll 18 | runs; idle table |
| notepad | 141 | runs; opens files from its command line |
| calc | 313 | runs, after the `_EH_prolog` fix |

Gaps found, and what happened to them:

- **msvcrt `_EH_prolog` through the bridge** (pcrecomp, fixed): it builds its
  caller's frame, so a bridged call built it on the host stack. calc's
  WinMain read hInstance 0. native32 now has it as a built-in shim.
- **Host flags leaked into the guest's command line**: notepad tried to open
  `--mute --watchdog 6.txt`. The host redirects GetCommandLineA/W to the guest's
  own line (args after `--`). msvcrt's `__getmainargs` still parses the
  host's; none of these five reads argv.
- **cards.dll is not on Windows 11**: lifted as a second guest module with
  modules32; worked unchanged.
- **Screenshot capture**: a BitBlt from the window DC on a private desktop
  also read screen pixels under the window; PrintWindow renders the window
  alone. Under hold_image the windows belong to a relaunched child, so the
  harness matches every window on its private desktop, not the pid.
- **winmine is cut off on the right**: it sizes its window from Win2000-era
  border metrics; Windows 11's frame is wider. Not fixed.
- Catalog noise: notepad/calc/sol report `insb`/`arpl`/`aaa`/`hlt`
  "unimplemented" instructions. These are data decoded as code in rarely
  reached bodies; none was hit at run time.

## Stage 2 survey: the system call boundary

- ntdll.dll (SP4, base 0x77F80000) has 248 system-call stubs, all the same
  shape: `mov eax, N; lea edx, [esp+4]; int 2Eh; ret K`. N runs 0x00-0xF7.
  The stubs are exported (`NtXxx`/`ZwXxx`), so the service-number table
  comes from the export names: no PDB needed.
- kernel32.dll imports only ntdll and has no `int 2Eh` of its own: lifting
  ntdll + kernel32 and replacing the 248 stubs is the whole kernel boundary
  for a console program like cmd.exe.
- user32.dll (254) and gdi32.dll (351) issue win32k services (0x1000-0x127F)
  inline; most of those stubs are not exported, so their names need
  Win2000's public symbols or win32k.sys's own service table.
- Bases: ntdll 0x77F80000, kernel32 0x7C4E0000, user32 0x77E10000, gdi32
  0x77F40000. In a WOW64 host these collide with the host's own system DLLs,
  so the guest set is rebased (pcrecomp tools/pe/rebase.py) below 0x60000000.

## Stage 2: cmd.exe on Windows 2000's own kernel32 + ntdll

**Result:** `cmd /c ver` prints `Microsoft Windows 2000 [Version 5.00.2195]`
and exits 0. Interactively (commands on stdin) the banner, prompt, `echo`,
`ver`, `dir` (NtQueryDirectoryFile, real listing), `set`, `exit 7` (exit
code 7) work. cmd.exe, msvcrt.dll, kernel32.dll and ntdll.dll are all
Windows 2000 SP4's own code, lifted (20,363 dispatch entries). Only USER32
(4 calls) and ADVAPI32 (registry) still bind to the host's DLLs.

Modules are rebased below the host's system DLLs: ntdll 0x20000000,
kernel32 0x20100000, msvcrt 0x20200000, cmd.exe at its own 0x4AD00000.

### The boundary

- **System calls.** lift32 turns `int 2Eh` into `recomp_syscall()`. The
  service table is read from the guest ntdll's own stubs (number and argument
  count); the Windows backend calls the host ntdll export of the same name.
  248 services, 10 with no Windows 11 counterpart; none of those 10 is hit by
  cmd. Every NT call cmd's startup and these commands make (file, directory,
  section, virtual memory, event, token, registry, volume) worked unchanged
  through the host's ntdll. Overrides: NtQueryInformationProcess (guest PEB),
  NtOpenSection (csrss's named NLS sections), NtTerminateProcess (host flush).
- **csrss.** Another process on Windows 2000, so it is answered in the host
  (pcrecomp csr32.c), replacing ntdll's two CsrClient* exports:
  - connect to basesrv: BASE_STATIC_SERVER_DATA (directories, version,
    SYSTEM_BASIC_INFORMATION at 0x124, time of day) via
    `Peb->ReadOnlyStaticServerData[1]`;
  - connect to consrv: CONSOLE_INFO with the host's std handles and the two
    init events (the first signaled). With real host handles, Windows 2000's
    kernel32 writes and reads the console through NtWriteFile/NtReadFile.
  - basesrv api 26 (NlsGetUserInfo): UserLocaleId at +0x1860. Without it
    `LCMapStringW(0, ...)` failed, msvcrt's locale-aware towupper/_wcsicmp
    returned the input, and cmd recognised no built-in typed in lower case
    (`VER` worked, `ver` did not).
  - About 90 console api calls per session (2:520, 529, 550, 551, 575, ...)
    are logged and answered with success and an empty reply. Output is
    unaffected because stdout is a file or pipe; a real console window needs
    them implemented.
- **NLS sections.** kernel32 opens `\NLS\NlsSectionUnicode`, `CType`,
  `Locale`, `Sortkey00000409`: served from Windows 2000's own .nls files. The
  per-locale sort section is sortkey.nls with its first WORD set to 1
  ("built"); with 0 kernel32 sleeps forever waiting for csrss to finish it.

### What the host does instead of LdrpInitializeProcess

The host's loader (pcrecomp modules32) maps and binds; ntdll's own process
init is not run. So the host does its steps itself, all SP4-specific
addresses, found by reading the lifted code:

| Step | How |
|---|---|
| NT 5 PEB, process parameters, NLS tables | native32_nt_process (pcrecomp) |
| RtlpInitDeferedCriticalSection (0x20003A3B, seeds the critical sections' debug-info pool) | native32_nt_preinit |
| RtlInitializeHeapManager (0x20003B6A, heap-list lock, Peb->ProcessHeaps) | native32_nt_preinit |
| process heap | the guest's RtlCreateHeap |
| RtlAllocateStringRoutine / RtlFreeStringRoutine globals | host writes 0x2004F1BC/0x2004F1B0 |
| loader lists + LdrpHashTable (0x2004F040) | native32_nt_module through the guest's LdrpInsertMemoryTableEntry (0x2000EEFB) |
| CsrPortHeap (0x2004F634) | host sets it to the process heap |

Windows 2000 SP4's `.dbg` symbols are not on Microsoft's symbol server (404),
so these were found from the lifted C: the writer of a global, the caller of
a function, the global a crash dereferenced.

### Gaps left

- `cd DIR` does not change the directory, and relative paths (`if exist`,
  `for`) then find nothing; no NtOpenFile is issued, so the failure is above
  the boundary (current-directory handling in lifted kernel32/ntdll, or the
  process parameters' CurrentDirectory). Not investigated yet.
- Starting an external program would go through Windows 2000 kernel32's
  CreateProcessW (NtCreateProcess + NtCreateThread + csrss): not supported,
  and it must never start a non-recompiled Windows 2000 binary natively.
- Console APIs to csrss are stubbed (above); no real console window yet.
- The LdrpInitializeProcess replacement is a list of SP4 addresses. The
  better design is to run the guest's own LdrpInitializeProcess with the
  kernel's part emulated (image sections for pre-mapped modules in
  NtCreateSection/NtMapViewOfSection, loader entries marked processed).
- Threads (NtCreateThread with a Win2000 CONTEXT/INITIAL_TEB), APCs, and
  user-mode callbacks (KiUserCallbackDispatcher, `int 2Bh`) are not wired;
  stage 3 (user32/gdi32 on win32k) needs the callbacks.
- No screenshot for cmd: its output is the evidence (transcripts in shots/).
