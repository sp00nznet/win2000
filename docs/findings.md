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

**Result:** Windows 2000's own cmd.exe, msvcrt.dll, kernel32.dll and
ntdll.dll, all lifted (about 20,400 dispatch entries), run on Windows 11.
Process start is the guest's own: the host maps the lifted modules and calls
ntdll's `LdrInitializeThunk`, which creates the heap, loads the NLS tables,
builds the loader lists, snaps every import and runs every DllMain, as on
Windows 2000. The host carries no build-specific address.

Three builds, one host source and one runtime (transcripts in `shots/`):

| Build | Source | `ver` | Session |
|---|---|---|---|
| Professional SP4, 5.00.2195 | EN_WIN2000_PRO_SP4.ISO | `Microsoft Windows 2000 [Version 5.00.2195]` | all commands below |
| Server SP4, 5.00.2195 | windows-2000-server-sp4.iso | same | same; its cmd/kernel32/ntdll/msvcrt are byte-identical to Pro SP4's, so `build\cmd.exe --sys work\rebased-server --nls work\sys-server` runs Server's own files on the same lift |
| build 2163 (pre-release) | pro.zip's ISO | `Microsoft Windows 2000 [Version 5.00.2163]` | all commands below; own lift (`build\cmd_rtm.exe`), different service numbers, different csrss data layout |

Session, the same in all three: banner, `echo`, `ver`, `cd work`, `cd`,
`if exist sys\cmd.exe ...`, `for %f in (sys\c*.nls) do @echo %f`, `cd ..`,
`dir /w`, `set COMSPEC`, `exit 7` (exit code 7). Starting
`work\sys\calc.exe` (Windows 2000's original) is refused by the guard.

Modules are rebased below the host's system DLLs: ntdll 0x20000000,
kernel32 0x20100000, msvcrt 0x20200000; cmd.exe stays at 0x4AD00000.

### The boundary (pcrecomp native32 syscall32.c, csr32.c)

- **System calls.** lift32 turns `int 2Eh` into `recomp_syscall()`. The
  service table comes from the guest ntdll's own stubs (number and argument
  count), so each build brings its own numbering; the Windows backend calls
  the host ntdll export of the same name. File, directory, section, memory,
  event, token and registry services work unchanged through the host.
- **The kernel's part of process creation** (`native32_nt_boot`): a PEB with
  the fields the kernel fills (image base, process parameters, NLS table
  pointers, OS version from the guest ntdll's version resource, heap
  defaults, subsystem, session), process parameters with a MAX_PATH current
  directory buffer and an open handle to it, the initial CONTEXT for
  `LdrInitializeThunk`.
- **Image sections.** The guest loader opens a DLL file and makes an image
  section of it. `NtCreateSection(SEC_IMAGE)` on a lifted module's file
  returns that module's existing mapping; on a host DLL (USER32 and ADVAPI32
  for cmd.exe, SHELL32 when cmd asks for it) a *proxy image*, a PE header
  and export directory whose exports are the host DLL's functions (the host
  resolves forwarders and API sets); `\KnownDlls` is hidden so the loader
  never maps the host's own system DLL sections.
- **The guard.** An EXE image that is not lifted is never mapped; process
  creation is refused; and a proxy's CreateProcess*/ShellExecute*/WinExec
  exports are refusals. That last one is from a test: with only the first
  two, cmd.exe fell back to the host shell32's ShellExecuteEx and the host
  ran the program (whoami.exe, a host binary, in that test). Now every route
  tried (an original Windows 2000 EXE, a host EXE, `start`) prints `[guard]`
  and cmd reports an error.
- **csrss** is answered at its LPC port: `NtSecureConnectPort` to
  `...\Windows\ApiPort` maps the client's port memory and returns the connect
  info (the static server data array, a shared section), so ntdll's own CSR
  client code sets up CsrPortHeap and the PEB; `NtRequestWaitReplyPort`
  dispatches the api:
  - csrsrv ClientConnect, consrv: CONSOLE_INFO with the host's std handles and
    the two init events. With real host handles, Windows 2000's kernel32
    reads and writes the console through NtReadFile/NtWriteFile.
  - basesrv 26 NlsGetUserInfo (2195): UserLocaleId. Build 2163 reads the
    same structure from the static data at 0x184 instead.
  - every other api gets an empty reply. Build 2163's GetConsoleOutputCP read
    stack garbage from the unanswered reply until then, and every write
    failed.
  - csrss's `NlsCacheMutant` (2163) is made when opened.
  - the BASE_STATIC_SERVER_DATA (directories, version, SYSTEM_BASIC_INFORMATION
    at 0x124, time of day) is the same in both builds up to 0x184.
- **csrss's NLS sections** (`\NLS\NlsSection*`) are served from the build's
  own .nls files; the per-locale sort section is sortkey.nls with its first
  WORD set to 1 ("built"), or kernel32 waits for csrss forever.

### Lifter and toolkit gaps this found (fixed in pcrecomp)

| Gap | Symptom | Fix |
|---|---|---|
| `int 2Eh` lifted as a trap | no system calls | `recomp_syscall` |
| forwarder exports seeded and lifted as code; native32_export returned the string | msvcrt's HeapAlloc jumped into "NTDLL.RtlAllocateHeap" | ExportEntry.forwarder; native32_export follows forwarders |
| SEH `__finally` blocks / filters not seeded | `cd` failed: unresolved call from `_local_unwind2` | disasm32 `seh_entries` |
| flags not carried into a body entered by `jmp` | every export lookup's hint check failed (CF read 0) | generate: `RECOMP_FLAGS_IN` at such entries; hidden by RECOMP_TRACE builds, which always reload |
| bound imports kept by rebase | the loader would trust stale IAT addresses | rebase drops them |
| `find_splits` IndexError on a branch below the code section | kernel32 would not lift | range check |
| image-section handles reused by the host | msvcrt's imports looked up in the user32 proxy | the image table forgets closed handles |

Windows 2000's `.dbg` symbols are not on Microsoft's symbol server, so every
layout here was read off the lifted code: the global a function stores, the
offsets a caller reads, the global a crash dereferenced.

### Gaps left

- Console csrss apis are answered empty: fine while stdout is a file or a
  pipe; a real console window (and `cls`, `color`, cursor control) needs
  them implemented.
- Programs cmd starts are refused (the guard). Running a *lifted* child
  needs process creation that starts another host with the child's lift.
- Guest exceptions raised through `NtRaiseException`/`KiUserExceptionDispatcher`
  are not wired (native32's own SEH covers lifted code's RaiseException);
  threads (NtCreateThread with a Windows 2000 CONTEXT/INITIAL_TEB), APCs and
  user-mode callbacks (`int 2Bh`) are not wired either. Stage 3
  (user32/gdi32 on win32k) needs the callbacks.
- The proxy images give host functions to a Windows 2000 caller as-is; a
  host function whose structures changed since 2000 would need a shim.

## Stage 3: winmine on its own user32 + gdi32 (the wall)

Host `build\ntwinmine.exe`: winmine.exe, ntdll, kernel32, msvcrt, **user32,
gdi32** all lifted (34,038 dispatch entries), from `work\rebased-gui`
(a directory of its own: cmd's loader must not find a user32 it has no lift
of; the guard refuses it). ADVAPI32, SHELL32, WINMM are host proxies.

**What runs.** Windows 2000's loader maps and snaps all six modules; gdi32's
and user32's DllMains complete (GdiDllInitialize, UserClientDllInitialize,
including user32's connect to csrss's user server); winmine's own WinMain
starts and calls RegisterClassExW, which reaches win32k as
`NtUserRegisterClassExWOW`. Unanswered, it returns 0 and winmine exits. No
window yet, so no screenshot.

**Naming win32k.** The service numbers and argument counts are the guest's
own: user32 and gdi32 contain 605 win32k stubs
(`mov eax, 0x1NNN / lea edx, [esp+4] / int 2Eh / ret 4n`), found by shape
since few are exported. Names for Windows 2000 SP4 (640 services, 0x1000 to
0x127F) come from j00ru's public syscall tables
(`tools/w32k_names.py`; the JSON is fetched into `work/names/`). pcrecomp's
syscall32 dispatches services from 0x1000 to a by-name table and logs every
unanswered one once.

**Wired in pcrecomp for it:**
- user-mode callbacks: `native32_nt_callback(api, in, len, ...)` runs the
  guest's KiUserCallbackDispatcher; NtCallbackReturn and `int 2Bh` record the
  result, and the dispatcher's trailing int3 (lifted as a return) comes back,
  with no longjmp. Not exercised yet: nothing calls back before the wall.
- exceptions: RtlRaiseException is the guest's own and dispatches over its
  own frames; NtRaiseException (second chance) ends the process with a
  report; NtContinue returns to the raiser.

**The wall: win32k's state.** Windows 2000's user32 is a thin client over
data win32k owns and maps into every process, read directly, not through
calls:
- the USERCONNECT reply (260 bytes) carries SHAREDINFO: `gpsi` (SERVERINFO,
  140 distinct fields read by user32: system metrics, colours, brushes,
  the function tables per window class), `aheList` (the handle table:
  every HWND/HMENU is validated against it), the display info, and the
  per-control-class message tables;
- every window, class and menu is a kernel structure (WND, CLS, MENU) in
  the desktop heap, which user32 reads at a fixed delta (GetWindowLong,
  IsWindowVisible, DefWindowProc and the message dispatch all read the WND);
- the thread's CLIENTINFO in the TEB, and GDI's DC attributes in the shared
  handle table (`Peb->GdiSharedHandleTable`, plus shared data after it).

So "shimming win32k calls" cannot be a mapping of NtUser* calls to the
host's: the host's win32k keeps that state in Windows 11's layout, which a
Windows 2000 user32 would misread. It needs a win32k of our own: the handle
table, WND/CLS/MENU in Windows 2000 layout kept in step with real host
windows, SERVERINFO, CLIENTINFO and GDI's DC_ATTR, with the NtUser*/NtGdi*
services answered against them (host windows and host GDI underneath) and
win32k's callbacks (window procedures, WM_CREATE during CreateWindow) through
`native32_nt_callback`. The layouts have to be read off the lifted user32 and
gdi32, as the csrss ones were. That is a project of its own (the size of a
small Wine USER/GDI layer); this stage maps it but does not do it.

What the probe answered, in the host (`src/nthost.c`, marked ponytail):
NtGdiInit (true, with a zeroed GDI shared section at `Peb+0x94`), and in
csr32 the user server connect (zeroed SERVERINFO, handle table and display
info). Logged unanswered on the way: NtGdiQueryFontAssocInfo,
NtUserGetThreadState, NtGdiGetStockObject, NtUserRegisterClassExWOW.
