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

## Interim: winmine on its own lifted gdi32, the host's user32

Host `build\ntwmgdi.exe` (from `work\rebased-gdi`): winmine.exe, ntdll,
kernel32, msvcrt and **gdi32** lifted (24,653 entries); USER32, ADVAPI32,
SHELL32, WINMM are host proxies.

**Result:** winmine's window, drawn by Windows 2000's own gdi32, is
pixel-identical to the stage 1 render, which used the host's gdi32: 0 of
170x256 pixels differ (`shots\ntwmgdi_6.png` against `shots\winmine_5.png`,
PrintWindow on a private desktop). In one run the lifted gdi32 made 162
NtGdiBitBlt, 88 NtGdiLineTo, 33 NtGdiSetDIBitsToDeviceInternal, 16 each of
NtGdiCreateCompatibleDC / CompatibleBitmap / SelectBitmap, and a few stock
object and pen calls; none was unanswered.

**The GDI layer** (pcrecomp `runtime/native32/w32kgdi.c`, built to be shared
with a full win32k later):
- a Windows 2000-layout shared handle table at `Peb->GdiSharedHandleTable`
  (0x4000 entries of 16 bytes; gdi32 checks the index, the high word, the
  type byte and the owning process) and a DC_ATTR per DC;
- **handle translation**: host GDI indices run to 0xFFFF and Windows 2000's
  gdi32 rejects anything from 0x4000 up (winmine's window DC was 0x370150C4),
  so the guest gets its own handles (host high word, our index) and every
  service, and every hooked host user32 function, translates;
- **DC_ATTR sync**: gdi32 keeps the selected brush (+0x08) and pen (+0x0C),
  the ROP2 (+0x38) and the current position (+0x3C) in user mode and selects
  pens and brushes with no system call; before each draw they go onto the
  host DC. Without the pen, winmine's grey 3D lines came out black (1,442
  pixels);
- host user32's DC functions (BeginPaint/EndPaint, GetDC, GetWindowDC,
  GetDCEx, ReleaseDC) and RegisterClass* (the background brush; with a guest
  handle there, RegisterClassW failed and winmine quietly exited) are hooked
  in user32's proxy image (`native32_nt_proxy_hook`);
- gdi32 has no entry point on Windows 2000 (user32's DllMain calls its
  GdiDllInitialize); with the host's user32 the host calls it
  (`native32_gdi_start`).

**Exceptions, for real now.** winmine calls OutputDebugStringA, whose
`RaiseException` inside `__try/__except` is the first guest exception that
mattered: x86 RtlRaiseException asks the kernel first, so the first-chance
NtRaiseException now enters the guest's own KiUserExceptionDispatcher, the
guest's RtlDispatchException finds kernel32's frame, and native32's landing
pads take the jump into its `__except`. The guest ntdll's RtlUnwind ends in
NtContinue to its caller, which a lift cannot do; native32's own RtlUnwind
(seh32) is put in its place by address (`native32_replace`), since the
guest's loader, not native32, snaps the imports now.

**Gaps left in this layer:**
- only the services winmine uses are answered (see the table in w32kgdi.c);
  any other NtGdi* is logged once and returns 0;
- DC_ATTR fields beyond brush, pen, ROP2 and position (colours, text
  alignment, brush origin, mapping mode) are not synced;
- gdi32's TEB batch (`TEB+0x1D4`, used for font selection and some fills,
  flushed by NtGdiFlushUserBatch) is not processed;
- the host->guest handle lookup is a linear scan.

## The GDI layer on all five accessories

Every Windows 2000 accessory from stage 1 now draws on its own lifted gdi32
(host user32), each compared pixel by pixel with its stage 1 render on the
host's gdi32 (`tools/gdicmp.py <app>`, PrintWindow on a private desktop):

| App | Window | Pixels differing | Lifted |
|---|---|---|---|
| winmine | 170x256 | 0 | winmine, ntdll, kernel32, msvcrt, gdi32 |
| sol | 601x443 | 0 | + cards.dll |
| freecell | 640x480 | 0 | + cards.dll |
| calc | 270x267 | 0 | |
| notepad (a text file open) | 1440x737 | 0 | |

None of the runs left a win32k service unanswered or a batch command
dropped. Solitaire deals at random from `time()`: `W2K_FIXED_TIME` fixes it
in both hosts so the two runs deal the same hand.

What each program added to pcrecomp's w32kgdi.c:
- **freecell**: gdi32's TEB batch. PatBlt is not a system call on Windows
  2000; it is queued in the TEB (command 0, 0x34 bytes) and win32k runs the
  queue on entry to any GDI service. Without it freecell's table stayed
  unpainted. Also text extents and an information DC (NtGdiOpenDCW).
- **sol** (cards.dll): bitmaps from host user32's LoadBitmap, GetObject,
  GetPixel, the DC origin, the brush origin (batch command 4 and DC_ATTR
  +0x1B0).
- **calc**: owner-drawn buttons. Host user32 hands the window procedure its
  own HDC in WM_DRAWITEM, calc sets colours with the lifted gdi32 and draws
  with host user32's DrawText/DrawEdge. So: native32_cb_in/out (a look at
  every Windows -> guest call) translates the HDCs window messages carry
  (WM_DRAWITEM, WM_ERASEBKGND, WM_CTLCOLOR* and its brush back, WM_PRINT...),
  DefWindowProc/DefDlgProc/CallWindowProc translate them back, and host
  user32's drawing functions take a guest DC with its DC_ATTR applied. Also
  csrss's IniFileMapping (BASE_STATIC_SERVER_DATA+0x180), empty, so
  GetProfileInt reads win.ini instead of crashing.
- **notepad**: fonts (NtGdiHfontCreate, text metrics and face, DC_ATTR+0x90),
  WM_SETFONT/WM_GETFONT, and its edit buffer: EM_SETHANDLE passes an HLOCAL
  from the lifted kernel32's heap, which the host's edit control cannot use,
  so the text goes over instead.

The host -> guest handle lookup became a hash (freed indices are reused).

Gaps left in the layer: font enumeration opens with no fonts (the Windows
2000 ENUMFONTDATAW layout is not filled in; notepad copes); EM_GETHANDLE
still answers the host's buffer (notepad's save path); DC_ATTR mapping mode,
stretch mode and the rest; any NtGdi* service none of the five uses.

## The full win32k, first milestone: a window from lifted user32

`build\ntwinmine.exe` (winmine, ntdll, kernel32, msvcrt, **user32, gdi32**
lifted; pcrecomp w32kgdi.c + the new w32kuser.c): winmine registers its
class, creates, moves, shows and paints its window, and runs its message loop,
all through Windows 2000's own user32 and gdi32. `shots\ntwinmine_6.png`:
170x256 like stage 1, LEDs, smiley and minefield drawn; no menu bar and the
default window icon. Against the stage 1 render 18,331 of 43,520 pixels
differ; most is the missing menu bar (the client area sits 20 px higher):
aligned by that, 5,383 differ.

What user32 needed, read off the lifted code:
- **ValidateHwnd**: index `LOWORD(h)` < `psi->cHandleEntries` (+8), the
  handle table entry (12 bytes: phead, pOwner, bType 1, bFlags, wUniq =
  `HIWORD(h)`), phead within the thread's desktop (CLIENTINFO at TEB+0x6CC:
  +0x18 pDeskInfo { base, limit }), WND = phead - client delta (+0x1C). Host
  HWNDs are used with their own index and uniq; each gets a WND in a desktop
  heap of ours, entered when the guest first hears from the window
  (WM_GETMINMAXINFO, before CreateWindowEx returns).
- **DefWindowProc**: user32 hands a message to win32k only if SHAREDINFO's
  DefWindowMsgs bitmap (+0xE8) has it; with zeros it returned 0 for
  WM_NCCREATE and creation failed. All messages go, and NtUserMessageCall
  with fnid 0x29E is the host's DefWindowProc.
- **GetSystemMetrics / GetSysColor** read SERVERINFO +0x59C and +0x6E8, and
  only once the thread is a GUI thread (TEB+0x40, Win32ThreadInfo, set).
- Services so far: RegisterClassExWOW, CreateWindowEx (LARGE_STRING names,
  buffer at +8), MessageCall, ShowWindow, MoveWindow, SetMenu,
  InvalidateRect, Get/Peek/Translate/DispatchMessage, Begin/EndPaint (DCs
  translated by w32kgdi), GetDC, CreateAcceleratorTable, GetThreadState.

Not yet:
- messages reach the window procedure from the host directly (it is
  registered with the host as the class's procedure), not through
  KiUserCallbackDispatcher and user32's __fn* routines;
- menus (LoadMenu builds them through NtUser* calls not answered: SetMenu got
  0), cursors and icons (NtUserFindExistingCursorIcon,
  NtGdiCreateDIBitmapInternal), NtUserCallNoParam/OneParam indices;
- the WND carries only its handle and self pointer: user32's client-side
  reads of window fields (GetWindowLong, IsWindowVisible, GetClientRect,
  DispatchMessage's direct call of the window procedure: one unresolved call
  through a zero field is logged) need them filled from the host window.

### Pixel-identical: winmine on its own user32 + gdi32

`build\ntwinmine.exe` now draws winmine's window with 0 of 43,520 pixels
differing from the stage 1 render (`shots\ntwinmine_6.png` against
`shots\winmine_5.png`; repeated twice more, 0 each time). Every user32 and
gdi32 call winmine makes is Windows 2000's own lifted code; win32k is
pcrecomp's w32kuser.c + w32kgdi.c over host windows and host GDI.

The steps, with the differing pixels after each:
| Step | Differing |
|---|---|
| window created, no menu bar | 18,331 |
| menus: CreateMenu / CreatePopupMenu (NtUserCallNoParam 0/1), NtUserThunkedMenuItemInfo, menus as USER objects (bType 2) | 5,116 |
| GetMenuItemRect, icons and cursors (NtUserFindExistingCursorIcon answered with the host's load) | 4,999 |
| NtUserMessageCall hands the host its own DC back (WM_ERASEBKGND had erased nothing: white background, washed-out frame) | 94 |
| the icon loaded shared, at the size asked ({ ?, type, cx, cy, bpp }): the title bar's 16x16 is the resource's own | **0** |

Honest status of what was planned for this step but not needed for the
pixels: the WND still carries only its handle and self pointer (no
client-side read of window fields failed visibly; one unresolved call
through a zero field is still logged during the message loop), and messages
still reach the window procedure from the host directly, not through
KiUserCallbackDispatcher. Interaction (clicks, the menus opening, dialogs)
is untested.
