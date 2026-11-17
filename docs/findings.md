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

### Interaction (tools/interact.py)

`tools/interact.py` drives the stage 1 build (host user32/gdi32) and
`build\ntwinmine.exe` (Windows 2000's own) the same way on a private desktop,
with posted input (`hiddenrun.py --click X,Y@T`, `--command ID@T`) and the
same mines in both (`W2K_FIXED_TICK`: winmine seeds with GetTickCount, which
the lifted kernel32 reads from shared memory, so it is replaced by address),
and compares a screenshot after each step:

| Step | Pixels differing |
|---|---|
| start | 0 |
| a click on a cell (shot within the first second: the game clock starts) | 0 |
| Game > Intermediate (the board resizes to 282x368) | 0 |
| Game > Custom (a dialog) | 37,327: no dialog yet |

What it took:
- **WND+0x5C, the window procedure.** Windows 2000's DispatchMessage calls it
  client-side (WND+0x16 bit 4 would make it server-side); left 0, every
  posted message (clicks, menu commands) went to a null call and was lost.
  Sent messages had worked, because the host calls the guest's procedure.
- **Timers** (NtUserSetTimer/KillTimer), the cursor, EnableWindow
  (NtUserCallHwndParamLock 0x53).
- For the dialog: DISPLAYINFO (SHAREDINFO's pDispInfo: monitor count, the
  primary and first MONITOR with its rectangles), class atoms in
  CreateWindowEx (#32770 is 0x8002 on both).

**Where it stops.** The Custom dialog's window is created (class #32770,
owner winmine), then user32's dialog manager deletes the dialog font,
re-enables the owner and returns, with no controls and nothing shown.
Windows 2000's dialog manager keeps its state with the window (the WND's
fnid and its extra bytes, DLGWINDOWEXTRA) and checks them client-side; the
WND here still has only the handle, self pointer and procedure. That is the
next piece: the WND's style, rectangles, class, fnid and extra bytes kept in
step with the host window. Message delivery is still the host calling the
guest's procedure directly, not KiUserCallbackDispatcher.

### The Custom dialog: pixel-identical

Windows 2000's dialog manager now builds winmine's Custom dialog through the
lifted user32: the #32770 window, its DIALOG structure, its controls, WM_SETFONT,
ShowWindow, its message loop. Read off user32's dialog code:
- ValidateDialogPwnd: WND+0x16 bit 0 (DIALOG attached), else WND+0x88
  cbwndExtra >= DLGWINDOWEXTRA and NtUserCallHwndParam 0x43 attaches it at
  WND+0x9C (the extra bytes; the Windows 2000 WND is 0x9C bytes). A window of a
  host class never calls the guest while it is made, so its WND is entered when
  CreateWindowEx returns.
- NtUserMessageCall fnid 0x2AE is SendMessage.
- A template's control ordinal (0x80 Button .. 0x85 ComboBox) becomes an atom
  from SERVERINFO+0x1A0; dialog base units at +0x800/+0x804.

The steps, with the pixels differing after each (Game > Custom, 282x368):
| Step | Differing |
|---|---|
| dialog built, placed at (-13108,-13108) | 37,327 (sizes differ) |
| ulSharedDelta = 0 (USERCONNECT's SHAREDINFO +0x0C: never written, so the caller's stack, 0xCCCC...; user32 subtracts it from pDispInfo->pMonitorPrimary, so the monitor it clamped the dialog to was garbage) | sizes still differ |
| SERVERINFO +0xE4A dmLogPixels (the dialog font's lfHeight = -MulDiv(8, it, 72); 0 gave a 25-pixel system font) and CLIENTINFO +0x08 dwExpWinVer 0x500 (>= 4.0 adds DS_3DLOOK and a normal-weight font; 0 gave bold) | sizes still differ |
| WND kept from the host window before every service and callback: +0x1C ExStyle, +0x20 style, +0x30 spwndParent, +0x38 spwndOwner, +0x3C rcWindow, +0x4C rcClient (ClientToScreen is client-side: the dialog sits at the owner's rcClient). The host frame is thicker than Windows 2000's GetWindowBorders count (padded borders): CreateWindowEx of a top-level frame adds the difference | 804 |
| dialogs run Windows 2000's own DefDlgProcW (the host's knows nothing of the guest's DIALOG and dialog procedure); WND +0x34 spwndChild, +0x2C spwndNext, +0x74 the control ID (GetDlgItem walks them); NtUserSetWindowFNID (+0x2A), SetFocus, QueryWindow (SetWindowText sends WM_SETTEXT only to a window of its own process: the guest TEB's ClientId), FillWindow (CTLCOLOR_* brush index), WM_CTLCOLOR* brushes back as guest handles | 658 |
| SERVERINFO +0xE50 UserPreferencesMask: UI effects (0x80000000) on and keyboard cues (0x20) off makes the dialog send itself WM_CHANGEUISTATE UIS_INITIALIZE (no underlines, no focus rectangle), as the host's does | **0** |

### Messages through KiUserCallbackDispatcher

A message the host sends a guest window now reaches it the way win32k
delivers it: KeUserModeCallback(2, FNDWORDMSG) through the guest ntdll's
KiUserCallbackDispatcher into user32's __fnDWORD (KernelCallbackTable[2],
user32 sets PEB+0x2C), which calls xpfnProc(pwnd, msg, wParam, lParam,
xParam) and returns with NtCallbackReturn (`int 2Bh`, a 0xC-byte result).
FNDWORDMSG is { pwnd, msg, wParam, lParam, xParam = the window procedure,
xpfnProc = DispatchClientMessage }. DispatchClientMessage(pwnd, msg, w, l,
pfn) is in no export and named by no code: only PFNCLIENT (apfnClientA/W,
user32's data, which csrss hands win32k) holds it, at +0x24 from
pfnDialogWndProc (DefDlgProcA/W) in both tables; it takes the HWND from
CLIENTINFO's CallbackWnd (TEB+0x6F4, pwnd at +0x6F8). Classes and dialogs
get a host thunk as their procedure; the guest's stays in WND+0x5C, which
DispatchMessage calls client-side for posted messages. Every message uses the
generic DWORD layout for now (one address space, so pointers need no copy);
win32k's per-message routines (__fnINLPCREATESTRUCT, __fnINSTRING, ...) and
A/W conversion are not used. All comparisons stayed at 0.

### Menus open (tools/interact.py)

Game opened with a posted WM_SYSCOMMAND SC_KEYMENU 'g' (`hiddenrun.py
--post MSG,WPARAM,LPARAM@T`). The check marks were missing: user32's
CheckMenuItem looks the item up client-side (MNLookUpItem) and calls
NtUserCheckMenuItem only when the state changes, so it never got there. The
MENU now carries its items from the host menu: +0x10 pSelf, +0x20 cItems,
+0x34 rgItems, ITEM 0x4C bytes { +0 fType, +4 fState, +8 wID, +0xC
spSubMenu }, synced (into submenus: a by-command lookup goes down) after
every call that changes a menu.

| Step | Pixels differing |
|---|---|
| start | 0 |
| a cell click | 0 |
| Game > Intermediate | 0 |
| Game > Custom (dialog) | 0 |
| Game menu open | 0 (75 before the MENU items: no check marks) |
| Game menu open after Intermediate | 0 (25 before submenus were synced: Beginner stayed checked) |

### Driving the Custom dialog

`hiddenrun.py --type ID=TEXT@T` (EM_SETSEL all, then a posted WM_CHAR per
character to the control of the top window) and `--dlgcommand ID@T`. The
`dlg` run opens Game > Custom, types 20 into Height (0x8D) and 30 into Width
(0x8E), presses OK: the board becomes 30x20 (506x432) on both builds, 0 pixels
differing. The keystrokes go through the guest's dialog loop
(IsDialogMessage) and the host edit; OK through DefDlgProcW and winmine's
dialog procedure (GetDlgItemInt).

NtUserCallHwndParam 0x46 is SetWindowState: param = (byte offset from WND
+0x14) << 8 | bit mask; user32 tests the bit client-side and asks win32k only
to set it (a dialog sets 0x502, WND+0x19 bit 1, at each WM_CTLCOLOR; 0x710
elsewhere). Answered by setting the bit.

Gaps: NtUserCallHwndParam 0x41 (once, in the dialog) is unanswered; NtUserCallHwndLock 0x4C/0x50 not
shimmed; a guest SetWindowLong(GWL_WNDPROC) subclass is not mirrored; the
WND's spmenu of a top-level window is not kept.

### Text messages through their own callbacks

KernelCallbackTable (user32 sets PEB+0x2C; 0x20321468 in this lift) has 91
entries. Read off the routines: the copying ones start with a 0x18-byte
capture-buffer header (+0 size, +8 pointers to fix up, +0x10 their offsets'
offset, +0x14 nonzero when already fixed) and take { pwnd, msg, wParam } at +0x18.

| Index | Routine | Layout after +0x24 |
|---|---|---|
| 2 | __fnDWORD | (no header) { pwnd, msg, w, l, xParam, xpfn } |
| 7 | __fnINCNTOUTSTRING (WM_GETTEXT) | +0x24 xParam, +0x28 xpfn, +0x2C buffer, +0x30 its size in bytes; user32 calls with its own stack buffer up to 0x800 bytes, reply { result, size, the buffer } for win32k to copy from |
| 9 | __fnINLPCREATESTRUCT | +0x24 lParam != 0, +0x28 the CREATESTRUCT inline (0x30), +0x58 xParam, +0x5C xpfn; name/class above the probe address are desktop pointers (pwnd - pSelf delta) |
| 10 | __fnINLPDELETEITEMSTRUCT (a 0x14-byte struct inline at +0xC, no header) | |
| 25, 26 | __fnINSTRING / __fnINSTRINGNULL (same code) | +0x24 xParam, +0x28 xpfn, +0x2C the string |

wnd_thunk chooses by message (WM_CREATE/NCCREATE, WM_SETTEXT, WM_GETTEXT; the
rest __fnDWORD). RegisterClassExA passes flags 2 (0x82 past 3.10), the W form
0 (0x80): bit 1 is CSF_ANSIPROC, kept per class, and an ANSI class gets its
text converted in wnd_thunk as win32k would. (None of the five accessories
registers ANSI, so that path is unexercised.) Winmine stayed at 0.

### notepad and calc on lifted user32 + gdi32

| App | State | Pixels differing |
|---|---|---|
| notepad | start (360x775) | 0 |
| notepad | "Hello, Windows 2000" typed into its edit (WM_CHAR) | 0 |
| calc | start (270x267) | 0 |
| calc | 12+3= pressed (WM_COMMAND, button IDs: digit n 0x7C+n, + 0x5C, - 0x5D, * 0x5B, / 0x5A, = 0x70); shows 15. | 0 |

notepad needed only NtUserRegisterWindowMessage. calc needed:
- **A dialog of the guest's own class keeps its procedure.** calc's main window
  is CreateDialog with CLASS SciCalc; NtUserCallHwndParam 0x43 replaced its
  procedure with DefDlgProcW, so calc's WndProc never ran (no WM_DRAWITEM:
  buttons blank).
- NtUserSetWindowPos (calc sizes itself to 270x267: 2 pixels off before),
  GetSystemMenu, GetForegroundWindow.
- **SERVERINFO +0x75C ahbrSystem[0x1D]**: GetSysColorBrush reads it, and
  DrawEdge (+0x79C BTNSHADOW, +0x7AC BTNHIGHLIGHT, +0x774 WINDOWFRAME). The
  display's white came from it. (+0xE48, a WORD, == 1 sends DrawEdge down a
  monochrome path.)
- **Regions** (DrawText saves the clip): NtGdiCreateRectRgn, whose handle
  entry needs a RGNATTR at +0xC (gdi32 writes the rectangle there itself, flags
  0x30), GetRandomRgn, IntersectClipRect, ExtSelectClipRgn.
- **The TEB batch is flushed when a callback returns**, as win32k does; and
  batch commands 1 PolyPatBlt { rop, mode, count, ?, colour, ?, ?, then count
  x { x, y, cx, cy, brush } at +0x24 } (DrawEdge's four edges) and 8
  DeleteObject { handle }. Flushing without command 1 left calc blank.

Harness: Windows 11 puts UAC input indicator windows (UAC_InputIndicator*,
in the program's own process) on the private desktop; hiddenrun took one for
the top window, so the Custom-dialog typing went nowhere while both builds
still compared equal (stale shots). Fixed, and interact.py drops shots older
than the run. Single runs still flake occasionally (an inactive menu bar after
Intermediate, 409 pixels); a rerun is 0.

### sol and freecell on lifted user32 + gdi32

cards.dll's bitmaps now load through lifted user32's LoadBitmap:
NtGdiCreateDIBitmapInternal (fInit 2, a DIB-format bitmap: the host's
CreateDIBitmap of the same header), NtGdiCreateBitmap (the mask),
NtUserGetDCEx, NtUserGetWindowDC, NtUserSystemParametersInfo (the host's),
NtUserPostMessage (sol posts itself its deal), NtUserValidateTimerCallback.
NtGdiGetDCforBitmap stays unanswered (0) with no visible effect.

**The frame.** The create-time frame correction (CreateWindowEx of a
top-level frame adds host-minus-Windows-2000 border) was right for winmine and
the dialogs, wrong for freecell (640x480 asked, a window size, not a client
size: 12 pixels too tall). It now applies only when x is not CW_USEDEFAULT.
sol sizes itself afterwards from AdjustWindowRect: the guest user32's
AdjustWindowRect/Ex exports are answered by the host's (nthost.c,
native32_replace; a program's IAT calls see it, user32's own direct calls
keep Windows 2000's). Both 0 after that.

| App | State | Pixels differing |
|---|---|---|
| sol | deal (500x443) | 0 |
| sol | a click on the deck | 0 |
| freecell | Game > New (500x480) | 0 |
| freecell | a click on a column, then a free cell | 0 |

**Caveat: neither build draws a card, because of the session's screen.** The
stage 1 shot from the first day (shots/sol_5.png, 601x443) has the deal; today
the session's display is 480x1131 (SM_CXSCREEN 480, portrait), so sol's
window is clamped to 500 wide (its maximum tracking size; SetWindowPos to
601 is clamped too) and on that client it draws no cards, in either build,
whatever the capture (PrintWindow flags 0 and 2 alike). Nothing in the
builds changed (W2K_FIXED_TIME off: the same). The sol/freecell comparisons
cover table, menus and status until a run happens on a screen at least ~610
wide; that is the session's display setting, not changed from here.

**A host heap corruption** (0xC0000374 in 2 of 5 ntcalc starts): a GDI handle
slot that had been a region (a 0x20-byte RGNATTR) was reused for a DC, whose
attributes are memset to ATTR_SIZE. Region attributes are now ATTR_SIZE.
Also answered: NtGdiGetRegionData, NtGdiGetDeviceWidth.

**The inactive-menu flake**: hiddenrun activates the top window
(SetForegroundWindow, 0.3 s) before a shot when it is not the foreground one.
`interact.py` all five apps three times in a row and `gdicmp` on all five:
all 0.

Harness: `hiddenrun.py` captures with PrintWindow (PW_RENDERFULLCONTENT); the
window DC is only there to make a compatible bitmap (a stale comment said
BitBlt).

### The remaining call indexes, read off user32

Found by scanning user32 for `push imm8; ...; call <stub>` and naming the
caller by its nearest export:

| Service, index | What (caller) | Answer |
|---|---|---|
| NtUserCallHwndParam 0x41 | ClearWindowState, 0x46's mirror (called only when the bit is set) | the WND bit cleared |
| NtUserCallHwndLock 0x48 | DrawMenuBar | the host's |
| NtUserCallHwndLock 0x50 | UpdateWindow | the host's |
| NtUserCallOneParam 0x24 | MessageBeep | the host's (silent under PCRECOMP_MUTE) |
| NtUserCallOneParam 0x26 | PostQuitMessage | the host's |
| NtUserCallOneParam 0x2D | ShowCursor | the host's |
| NtUserCallOneParam 0x33 | GetProcessDefaultLayout (param: the DWORD* it fills) | the host's |
| NtUserCallOneParam 0x19 | CreateIcon/CreateIconIndirect/LoadCursorFromFile: an empty cursor object, then NtUserSetCursorIconData | not answered |
| NtGdiGetDCforBitmap | the DC a bitmap is selected into | 0 (none known) |

NtUserSetWindowLong GWL_WNDPROC (guest subclassing): the new procedure goes in
WND+0x5C and the host window gets wnd_thunk, so sent and posted messages both
reach it; the old one is returned (a host control's own procedure is called
through the bridge by the guest's CallWindowProc). Untested: none of the
accessories subclasses.

### The ANSI path: clipbrd and packager (in progress)

clipbrd (ClipBook Viewer) and packager (Object Packager) register their
classes with RegisterClassA. Both lifted at stage 1 and on lifted user32
(`ntclipbrd`, `ntpackager`; expand CLIPBRD.EX_ and PACKAGER.EX_ into
work/sys and copy to work/rebased-gui).
- stage 1 clipbrd exits at once (0, no window): ClipBook needs its NetDDE
  service; a poor test.
- ntclipbrd: its ANSI class registers and a 16x39 window appears; then
  NtUserFindWindowEx, NtUserCallHwnd 0x3D, NtUserCallOneParam 0x25,
  NtUserCallHwndLock 0x4C, NtUserModifyUserStartupInfoFlags unanswered, and a
  CreateWindowExW fails with 87.
- stage 1 packager runs (501x179); ntpackager faults at once in host code
  (0x7800776E, sub_010095D0, a native call): next to look at.
- NtUserSetWindowLong answers GWL_WNDPROC only: other indexes forwarded to
  the host broke winmine's Custom dialog (82,473 pixels; a guest dialog's
  DWL_* live in its DIALOG). NtGdiGetDeviceWidth answered with HORZRES sent
  gdisol into a loop in gdi32: left unanswered.

### State at this handoff (the session screen is wide again)

Mid-session the session's display went back to a wide mode (SM_CXSCREEN no
longer 480; not changed from here): notepad now opens 1440x737, sol 601x443,
freecell 640x480, and stage 1 draws cards again.

| Compare | Result |
|---|---|
| interact winmine (7 states), notepad (2) | 0 |
| gdicmp sol, freecell, notepad, calc, winmine | 0 |
| interact calc start / 12+3= | 708: also with the previous commit's code (stash test), so from the display change, not this change; button-edge pixels |
| interact sol deal / deck click | 40,231 / 41,328: lifted user32 draws the face cards and the deck but the pip cards, empty piles and card backs come out black |
| interact freecell | 38,698: the same |

The black cards: cards.dll builds them in memory DCs from DIB-format bitmaps
(NtGdiCreateDIBitmapInternal fInit 2, no bits, here a device-compatible
bitmap) and fills them with SetDIBits / blits the face bitmaps; the face cards
come straight from resources and are right, the composed ones are not. Next:
trace cards.dll's cdtDraw on ntsol with NATIVE32_SYSCALLS and answer what its
composition needs (likely NtGdiSetDIBitsInternal or a bitmap's DC through
NtGdiGetDCforBitmap).

### Black cards fixed; packager on the ANSI path

**The black cards.** user32's LoadBitmap copies a DIB-format bitmap into a
device bitmap by selecting it into `ghdcBits2` (0x203591E8) and blitting.
user32 makes that DC in ClientThreadSetup (0x20322753), which win32k calls
back as `__ClientThreadSetup` (KernelCallbackTable 74) when a thread turns
GUI; nothing called it, so the DC was 0, the BitBlt had no source and the
composed bitmaps stayed black. Now called once, after the guest loader is
done (earlier, during user32's init, gdi32 faults). With the DC in place,
gdi32's SetDIBits asks NtGdiGetDCforBitmap for the DC holding the bitmap
(a second DC cannot select it) and saves it with NtGdiSaveDC: both answered
(SelectBitmap remembers bitmap -> DC). ClientThreadSetup also registers the
system control classes again; the host refuses (1410), harmlessly.

**packager.** It faulted at 0x7800776E: `work/rebased-gui/packager.exe` was a
plain copy whose bound imports pointed at msvcrt's linked base. rebase.py
drops them (run one exe per call: two exes both at 0x01000000 collide in its
layout). Then CreateWindowExA's WS_EX_ANSICREATOR (0x80000000) made the
host's CreateWindowExW fail with 87: stripped; the window name LARGE_STRING
with bAnsi is converted.

| Compare | Result |
|---|---|
| interact winmine (7), notepad (2), sol (2), freecell (2) | 0 |
| gdicmp all five | 0 |
| interact calc (2) | 708 (below) |
| packager stage 1 vs ntpackager, start (501x179) | 322 |

**calc's 708 and packager's 322** are ClearType pixels one level apart in
button/label text. calc never calls SetBkMode; its DRAWITEM DC is OPAQUE on
both builds. Forcing TRANSPARENT in NtGdiExtTextOutW gives calc 0, so the
host's DrawText draws OPAQUE text differently from Windows 2000's DrawText
calling ExtTextOutW. Emulating it for every OPAQUE ExtTextOutW (fill, then
transparent) broke freecell's status text (191), so it was reverted: the fix
belongs at DrawText level, not ExtTextOutW. packager also has 3 pixels at
the right edge of its "--Content--" highlight.

Not answered yet: NtUserCallNoParam 0x12 (asked by ClientThreadSetup; 0 continues),
NtUserGetThreadDesktop, NtGdiGetCharSet (packager), and on clipbrd the
calls the handoff listed. NtUserSystemParametersInfo passes SET actions to
the host as well; no accessory sends one, but a guest could change live
settings. Guard it before a program that does.

### SPI limited to queries; calc at 0; clipbrd needs DDEML

- NtUserSystemParametersInfo answers only GET actions (by name below 0x62,
  even from 0x62 and in 0x1000/0x2000; 0xD/0x18 with a buffer), fWinIni 0;
  SETs are refused and logged. No accessory sends one.
- **calc 0**: the guest's DrawTextW export is answered by the host's
  (nthost.c, like AdjustWindowRect; pcrecomp `native32_gdi_dc` gives the host
  DC with the guest attributes applied). freecell's TextOut stays on
  ExtTextOutW, so it stays 0.
- clipbrd: FindWindowEx and ModifyUserStartupInfoFlags answered. Its next
  CreateWindowEx has class 0 and flags 0x80000400: most likely one of the DDEML windows whose
  class atom win32k keeps in SERVERINFO (ClipBook talks DDE to NetDDE). The
  calls after it (CallOneParam 0x25 in SoftModalMessageBox, CallHwnd 0x3D,
  CallHwndLock 0x4C) are its error message box. clipbrd needs DDEML first, so it is a
  poor test of the ANSI path; packager covers that path.
- CallOneParam 0x19 callers: CreateIcon, CreateIconIndirect,
  LookupIconIdFromDirectoryEx, LoadCursorFromFileA (still unanswered; sol and
  freecell are 0 without it).

| Compare | Result |
|---|---|
| interact all five (17 states) | 0 (winmine custom once 658, 0 on rerun: the known flake) |
| gdicmp all five | 0 |

### Handoff state (after calc at 0)

All five accessories are 0 in every `interact.py` state and in `gdicmp`.
packager is still 322 against stage 1 (501x179, bbox 10,55-273,70): ClearType
text a level apart and 3 highlight pixels. The host DrawTextW did not change
it, so packager's labels reach ExtTextOutW another way (its own TextOut, or
user32's internal DrawText calls, which the export replacement does not see).
Find the caller with NATIVE32_SYSCALLS (NtGdiExtTextOutW's `from`).

Next, in order:
1. NtUserCallOneParam 0x19 (CreateIcon, CreateIconIndirect,
   LookupIconIdFromDirectoryEx, LoadCursorFromFileA): an empty cursor object,
   then NtUserSetCursorIconData(hcur, module UNICODE_STRING*, resource
   UNICODE_STRING*, CURSORDATA*). Read CURSORDATA's layout off user32's
   CreateIconIndirect (what it fills before the call), answer with a host
   CreateIconIndirect from its hbmMask/hbmColor/hotspot, and re-measure packager.
2. mspaint and wordpad (MFC: mfc42u.dll; riched20.dll) at stage 1 and on
   lifted user32/gdi32: expand from the CD, rebase with rebase.py (one exe per
   call; DLLs at free 0x205xxxxx bases), lift, add `w2k_user_host` targets
   with the extra DLLs as in ntsol's cards.dll, and extend interact.py.
Skip clipbrd (it needs DDEML's server-side classes).

### packager at 0; cursors; mspaint on lifted user32 (in progress)

**packager 0.** Its "--Content--" and "--Appearance--" labels are sized with
`DrawTextA(DT_CALCRECT)` (0x010089D9) and drawn with TextOutA. Windows 2000's
DrawTextA measured 1 pixel wider than the host's, so the highlight was 67
wide instead of 66 and the text sat in a different cell. Fix: the guest's
DrawTextA export is answered by the host's (nthost.c, like DrawTextW). Font,
colours and GetTextExtent (flOpts 1, the "Windows 3" extent) were checked
and were identical. `interact.py packager` gives 0.

**Cursors built client-side.** NtUserCallOneParam 0x19 returns a placeholder
host icon (a real, unique handle). NtUserSetCursorIconData(hcur, module,
resource, CURSORDATA*) builds the real host icon with CreateIconIndirect from
CURSORDATA (0x54 bytes, read off CreateIconIndirect: +8 rt, +0x10/+0x12
hotspot, +0x14 hbmMask, +0x18 hbmColor, +0x30 bpp, +0x34 cx, +0x38 cy*2).
cur_host() maps the placeholder to the real icon in SetCursor and
RegisterClass. No program here calls it yet, so it is untested.

**mspaint / wordpad.** MSPAINT.EX_, WORDPAD.EX_, MFC42U.DL_ and RICHED20.DL_
are expanded into work/sys and rebased into work/rebased-gui: mfc42u at
0x20600000, riched20 at 0x20700000 (`rebase.py ... mspaint.exe
mfc42u.dll=0x20600000`, then again with `wordpad.exe riched20.dll=0x20700000`).
Stage 1 (`mspaint`, `wordpad`, APP_SYS work/rebased-gui) lifts mfc42u and
riched20 too, so both builds run Windows 2000's MFC and RichEdit. The nt
targets are `ntmspaint` and `ntwordpad`.

disasm32 fixes, needed because Windows 2000 merges .rdata into .text:
- a NUL-terminated ASCII or UTF-16 string is not a function body
  (`push offset "GetLayout"` was decoded as code and covered a vtable);
- three aligned code addresses in a row are a table, not code;
- a vtable slot in code counts even when bad decoding marked its bytes;
- a code pointer with another one 24 bytes away is an MFC AFX_MSGMAP_ENTRY
  handler. This adds false starts: mspaint.exe's unimplemented count went
  from 22 to 584, all in dead code.

Answered for MFC (pcrecomp w32kuser/w32kgdi):
- SetWindowsHookEx: host hooks on this thread. The guest TEB's thread id is
  not the host's: passing it installed the hook nowhere. WH_CBT goes through
  cbt_thunk, which enters the WND at HCBT_CREATEWND so MFC's subclassing
  SetWindowLong validates.
- CallNextHookEx, GetProp(A/W) and GetScroll{Info,Pos,Range}: these exports
  are answered by the host's, because Windows 2000 reads the hook chain,
  properties and SBINFO client-side.
- WND +0x60 pcls: a shared zeroed CLS.
- Top-level spwndParent: a desktop WND (WS_VISIBLE, fnid 0x29D), because
  IsWindowVisible walks up to it.
- Other services: GetClassInfo, Set/GetWindowPlacement, DestroyCursor,
  Set/RemoveProp, SetScrollInfo, SetParent, SelectPalette, WindowFromPoint,
  SetActiveWindow, DeferWindowPos/EndDeferWindowPosEx, CallOneParam 0x16
  (BeginDeferWindowPos), CallNoParam 5 (GetMessagePos), CreateDIBSection,
  CreatePatternBrushInternal, GetDCObject, ExcludeClipRect.
- Batch commands: 3 (ExtTextOut with no text: { bk colour, options, RECT,
  attr+0x184/0x188 }) and 5 (ExtSelectClipRgn { mode, RECT }, mode bit 31 =
  no rect).
- `hiddenrun.py --drag X1,Y1,X2,Y2@T` posts a drag to the deepest child.

| Compare | Result |
|---|---|
| interact winmine (7), notepad (2), sol (2), freecell (2), calc (2), packager | 0 |
| gdicmp all five | 0 |
| interact mspaint start / line drawn | 23,990 / 24,247 (both builds draw the line; the toolbox, the frame's client offset (~1 px) and the status bar differ) |
| wordpad stage 1 | stops at once: ICALL unresolved 0x2070B6E0 (riched20, a vtable slot at 0x20711CA4 whose target lies inside a body decoded from bad evidence; a disasm32 tweak for it had no effect and was reverted) |
| ntwordpad | runs into the same riched20 miss. Unanswered: NtGdiStretchDIBitsInternal, CallOneParam 0x1E (GetKeyboardLayout), NtUserGetDoubleClickTime, NtUserGetKeyboardLayoutList |

Next:
1. riched20 0x2070B6E0: find which catalog entry covers it (mid vs covered
   in find_data_code_pointers) and seed it, or pass `--seed-functions`.
   Then answer ntwordpad's four calls.
2. mspaint pixels: compare the toolbox (CToolboxWnd, pressed button) and the
   frame's client edge. The client is about 1 px lower and to the right,
   which suggests WS_EX_CLIENTEDGE or border metrics.

### wordpad and mspaint at 0

**riched20 catalogue.** 0x2070B6E0 is named only by the vtable slot
0x20711CA4; the GUIDs before it decoded as code and `mov esi, imm32` covered
it, so the data scan dropped it as "mid-instruction". disasm32 now takes a
target of a three-pointer run in code even there, and keeps it through
drop_mid_instruction_entries. Next miss, 0x207108C0, is stored by
`mov eax, 0x207108C0` in an alias body whose span reaches past it; the
"loading its own data" skip now does not apply when another body's
instruction ends right at the target. Also: no function starts inside the IAT
(wordpad.exe's bound IAT made a 2,294-instruction body: 11,250 -> 8
unimplemented), and the MFC message-map rule checks the AFX_MSGMAP_ENTRY
fields (nMessage, nCode, IDs, nSig small, or 0xC000 with a pointer: ON_REGISTERED_MESSAGE) of a neighbour entry or a zero
terminator after a one-entry map (wordpad's WM_CREATE 0x0100C3C6): mspaint
584 -> 22.

**What wordpad needed, in the order it showed up:**
- NtUserSetWindowLong index >= 0: RichEdit keeps its object in the window
  bytes, read client-side at WND+0x98 (not +0x9C: that is a dialog's DIALOG
  pointer). Without it every RichEdit message returned 0 and
  IRichEditOle::SetHostNames ran on NULL.
- GWL_STYLE/GWL_EXSTYLE forwarded to the host. MFC's ModifyStyleEx drops
  WS_EX_CLIENTEDGE; without it no WM_MOVE/WM_SIZE, wordpad's frame rect stayed
  empty (136x39). The guest's style is read-modify-write from a WND that can
  predate ShowWindow, so WS_VISIBLE stays the host's (RichEdit hid its view).
  This was also mspaint's whole difference: mspaint is 0 at start and after
  the line with no mspaint-specific change.
- The host command line reached mfc42u (`__p___wargv`) and wordpad
  (`_wcmdln`) on stage 1: wordpad opened "12" from `--watchdog 12`.
- DC_ATTR: iMapMode +0x168 (RichEdit relaid out on 0 and never painted),
  viewport origin +0x184/0x188 (the ruler is drawn with SetViewportOrgEx(16,4)),
  applied in dc(). Batch command 2 is TextOut (XP's GDIBSTEXTOUT layout: fg,
  bk, bk mode, x +0x10, y +0x14, options +0x18 (bit 31 no rect), RECT +0x1C,
  count +0x30, font +0x38, align +0x3C, viewport +0x40, text +0x48).
- The display DEVCAPS at the shared table + 0x40000 (gdi32's GetDeviceCaps
  reads it for a DC with DC_ATTR+4 bit 0x10000): index -> offset map in
  w32kgdi.c s_init.
- Font enumeration: ENUMFONTDATAW entries { cj, dpNtmi 0x170, FontType,
  ENUMLOGFONTEXW, DESIGNVECTOR } + NTMW_INTERNAL { TMDIFF, NEWTEXTMETRICEXW,
  DESIGNVECTOR }; the W callback gets +0xC and dpNtmi + 8 ("Western").
- DeleteObject on a stock object forgot its guest handle (wordpad deletes
  DEFAULT_GUI_FONT and then sends it: combo text in the System font).
- CallWindowProcW/A to a host procedure (comctl32 toolbar): TB_ADDBITMAP /
  TB_REPLACEBITMAP bitmaps and a GDI wParam go over as the host's (nthost.c).
- Printer DC: the guest's CreateDCW answered by the host's (Windows 2000's
  gdi32 opened a NULL device without its spooler); EM_SETTARGETDEVICE then
  carried a host HDC into RichEdit, so cb_in maps a known host handle in
  wParam back to the guest's. Without it RichEdit made a 1-pixel font and
  wrapped every typed character.
- Services: StretchDIBitsInternal, CallOneParam 0x1E (GetKeyboardLayout),
  GetDoubleClickTime, GetKeyboardLayoutList, Show/Hide/Create/DestroyCaret
  (CallNoParam 2), CallTwoParam 0x5E (SetCaretPos), ShowScrollBar,
  GetKeyState, CountClipboardFormats, IsClipboardFormatAvailable,
  TranslateAccelerator, ScrollWindowEx, GetThreadDesktop, GetCharSet,
  GetCharWidthW, GetOutlineTextMetricsInternalW, GetDCDword (7 memory DC),
  GetAndSetDCDword (8 SetMapMode).

| Compare | Result |
|---|---|
| interact winmine (7), notepad, sol, freecell, calc, packager | 0 (freecell card-to-cell 316 once in the full run, 0 on rerun) |
| interact mspaint start / line | 0 / 0 |
| interact wordpad start / typed | 0 / 0 (typed: 16 px caret in one build in some runs, blink phase) |
| gdicmp all five | 0 (freecell 871 once, 0 on rerun: flake) |

Gaps: stage 1 wordpad/mspaint write their Applets\Wordpad / Paint keys in the
live HKCU through the host advapi32 (an MFC app saving its options; not a
system setting, but a guest writing the user's registry): route the guest's
HKCU to a private hive next. NtUserCallNoParam 0x12 still unanswered; window
origin/extents in DC_ATTR not applied; a style change that shows a window is
not passed on.

## The guest's registry: a private hive (regbox32)

Stage 1 wordpad/mspaint (and notepad, freecell, winmine) went through the host
advapi32 and wrote the user's live HKCU. Every guest registry write now lands
in `HKCU\Software\pcrecomp\w2k\<app>\{HKCU,HKLM,NT,INI}` (pcrecomp
regbox32.c, installed by apphost.c and nthost.c; a host that can't make the
key refuses to run):

- create: always in the box (the real NT path mapped under it);
- open: the box's key if it exists, else the real key with write access
  stripped (every real handle the guest holds is read-only);
- set/delete value, delete key: mapped by the handle's path (NtQueryKey) to
  the box, never the real key; value reads try the box first, then the real;
- RegSave/Restore/Load/Replace/UnLoadKey, SetKeySecurity, OverridePredefKey,
  ConnectRegistry, DeleteTree/KeyEx, SetKeyValue, transacted: refused;
- profiles: Write/GetProfileString(Int), Write/GetPrivateProfileString(Int)
  for win.ini or a Windows-directory/bare .ini go to `INI\<file>\<section>`;
  WriteProfileSection/PrivateProfileSection/Struct refused;
- lifted builds: the guest ntdll's NtCreateKey/OpenKey/SetValueKey/
  DeleteKey/DeleteValueKey/QueryValueKey follow the same rule (NtSaveKey,
  NtLoadKey, NtSetInformationKey... refused), the proxied host advapi32's
  Reg* exports are hooked, and the lifted kernel32's profile exports replaced.

Checked: a snapshot of Applets, winmine, Notepad and Windows NT\...\Windows
(keys, values, last-write times) is identical before and after two full
interact runs; win.ini untouched; the creates show up under the box.

Existing keys found on this machine (not touched; the user decides):

| HKCU key | last write | values |
|---|---|---|
| ...\Applets\Wordpad (+ IP, Options, Recent File List, RTF, Settings, Text, Word6, Write) | 2026-11-15 20:23:59 | none (empty keys) |
| ...\Applets\Paint | 2026-11-15 20:15:18 | none |
| ...\Applets\Paint\General-Summary | 2026-11-15 20:15:18 | none |
| ...\Applets\Paint\Colors, Recent File List, Settings, Text, View | 2026-11-15 20:14:08 | none |
| ...\Applets\FreeCell | 2026-11-15 12:50:26 | lost/won/losses/wins/streak/stype 0, AlreadyPlayed 1 |
| Software\Microsoft\winmine | 2026-11-15 12:46:34 | Difficulty 0, 9x9, 10 mines, Mark 1, AlreadyPlayed 1, Color 1, Sound 0, Xpos/Ypos 80, Time1-3 999, Name1-3 Anonymous |
| Software\Microsoft\Notepad | 2026-11-15 12:47:36 | none |
| ...\Applets\Regedit (2026-10-12), SysTray (2026-09-08) | older | the user's own |

Also: NtUserCallNoParam 0x12 is asked by user32's ClientThreadSetup (1 skips
its client-side setup), answered 0; DC_ATTR window origin +0x174, window
extent +0x17C, viewport extent +0x18C filled and applied (extents only in
MM_ISOTROPIC/ANISOTROPIC); a GWL_STYLE that sets WS_VISIBLE the WND lacks
passes on (a show). All 8 apps 0 in interact (freecell 949/4790 once, 0 on
rerun: the known flake).

Gaps: host DLLs in the process (comdlg32 MRU, shell32, shlwapi SHSetValue)
call the host advapi32 directly and are not boxed; RegEnum* see one side;
deleting a value that exists only in the real key is a no-op; A profile reads
skip the box.

### Host DLLs boxed too

The Windows DLLs in the process (comdlg32, shell32, shlwapi, the Explorer-style
Open dialog's COM servers) now go through regbox as well: every import slot
and delay-load slot that resolves to one of the boxed functions (whether it
names advapi32, kernel32 or an api-ms-win-core-registry set) is pointed at the
sandbox's, in every module except the host exe and ntdll/kernel32/kernelbase/
advapi32/sechost. Modules loaded later are patched by an
LdrRegisterDllNotification callback. A real key is opened from the caller's
own handle, not by NT path: a 32-bit process's HKLM\Software is WOW64-redirected
and HKCR is merged per user, and opening by NT path broke the Open dialog
("not enough memory").

Checked: notepad (stage 1 and lifted) File > Open, typed
G:\recomp\pc\win2000\CMakeLists.txt, OK: the file opens (title), the dialog's
ComDlg32 OpenSavePidlMRU/LastVisitedPidlMRU/CIDSizeMRU, CIDOpen, Accent, MrtCache
writes land in HKCU\Software\pcrecomp\w2k\notepad, and the snapshot (Applets,
winmine, Notepad, Explorer\ComDlg32, RecentDocs, Shell Folders, FileExts\.txt,
Windows NT\...\Windows) is identical before and after. hiddenrun --type now
reaches the Edit inside a combo box.

One diagnostic run with the host-DLL hooks switched off (23:06:43-44, to find
why the dialog failed) let the dialog write the live shell view caches; not
touched, for the user to judge: HKCU\Software\Classes\Local Settings\Software\
Microsoft\Windows\Shell\BagMRU (+ \1) and \Bags\4029\Shell, Local Settings\
MuiCache\1e6\52C64B7E, Local Settings\MrtCache\...WindowsNotepad...\1dd39a47c156308
(+ ad662cbc, b2467b14). Nothing in HKCU changed after 23:07 outside the box.

Gaps left: a host DLL that finds a registry function with GetProcAddress is not
boxed; the notepad window after the open shows no text in the shot (not looked
into).

## Windows inside Windows: explorer.exe on a virtual screen (design)

Goal: Windows 2000's own shell (explorer.exe: desktop, taskbar, Start menu)
in one host window, as if that window were Windows 2000's screen.

**The virtual screen** (pcrecomp w32kuser.c, on when `W2K_SCREEN=WxH` is set):

- One host window is the screen: `WS_POPUP | WS_CLIPCHILDREN`, W x H, at host
  (0,0) of the desktop it runs on (hiddenrun's private desktop). Being at
  (0,0) keeps the virtual screen's coordinates and the host's equal, so no
  rect, point or message needs translating (ponytail: a screen window
  elsewhere would need an offset on every rect the layer syncs).
- The screen window *is* Windows 2000's desktop window: the guest's
  GetDesktopWindow answers it, and a WND whose host parent is the screen
  gets the desktop WND as its spwndParent.
- A guest top-level window is made as the guest asked (popup or overlapped,
  menu and all), then `SetParent`ed to the screen: still a popup to the host
  (its menu bar stays), clipped to the screen and drawn inside it, so
  `PrintWindow(screen, PW_RENDERFULLCONTENT)` is the whole screen. Chosen
  over compositing because the windows stay real host windows and every
  existing pixel comparison keeps its path (the mode is off unless asked).
- Metrics: SM_CXSCREEN/CYSCREEN, the full-screen, maximized and virtual-
  screen metrics, the primary MONITOR's rcMonitor/rcWork and the work area
  are the virtual screen's. SPI_SETWORKAREA (the taskbar sets it) is kept
  in the layer for the guest; nothing reaches the host's settings.

**The shell's reach stays inside**: SetShellWindow(Ex), SetProgmanWindow,
SetTaskmanWindow, RegisterShellHookWindow, RegisterHotKey and the tray's
own messages are win32k services the layer answers itself (or the
unanswered-service default, 0): no host window becomes a shell, tray or
hotkey owner. Hooks stay thread-scoped as before. explorer's registry
(Streams, Desktop, Explorer\..., Tray state) goes to the box
`HKCU\Software\pcrecomp\w2k\explorer`.

**Launching**: explorer starts programs with CreateProcessW (Run dialog,
ShellExecuteEx in shell32). The guard: NtCreateProcess(Ex) and every host
CreateProcess*/ShellExecute*/WinExec stay refused. Instead the lifted
kernel32's CreateProcessW is replaced by the host's own check: the image's
file name must name a lifted program that has a host runner
(`build\nt<stem>.exe`, built from that program's lift); then the runner is
started as a new host process with the guest's command line, and the guest
gets a process handle/id for it. Anything else (an original exe, a host
exe, a .bat, an unknown program) fails with ERROR_ACCESS_DENIED and a
`[guard]` line. The runner joins the same virtual screen: it gets
`W2K_SCREEN_HWND=<screen>` and parents its top-level windows to it (a
cross-process SetParent; the child process keeps its own message loop).

### First runs (handoff)

State: `build\ntexplorer.exe` (explorer.exe + comctl32, shlwapi, shell32,
browseui, shdocvw, ole32, oleaut32, rpcrt4, actxprxy, desk.cpl, clbcatq, all
Windows 2000 SP4, lifted; `tools/lift_explorer.sh`, `tools/run_explorer.sh
NAME SECS`) starts, makes the screen window (`W2K_SCREEN=800x600`), creates
the desktop thread and its first windows (a caption is drawn), then exits 1
after about 1.5 s. **Nothing of Windows 2000's desktop is drawn yet.** The
shell's modules live in `work/rebased-shell` (copies of ntdll..gdi32 + the
shell's), apart from `work/rebased-gui`: with shell32 in rebased-gui every
other lifted program loaded Windows 2000's shell32 from its DLL path (invalid
image), and stage 1 mspaint's host loader found the original there and raised
"Entry Point Not Found" on the real desktop.

Fixed on the way (pcrecomp):

| What | Where |
|---|---|
| a guest LPC connect to any port but csrss's ApiPort went to the host (explorer reached the host RPCSS's `\RPC Control\epmapper`): refused, as if not running | csr32.c |
| the guest's RtlUnwind (native32's shim) unwound the HOST chain in an nt host and the process died with STATUS_UNWIND, no report: `native32_guest_seh = 1` with a lifted ntdll | syscall32.c |
| `__except` blocks: drive32 now passes the frame offset (RECOMP_EH_FRAME), eh32.py reads every scope-table level (the prologue alone sets none), disasm32 keeps blocks out of the data scan's starts | lift, disasm |
| delay-load stubs and lazy-import slots (`mov esi, [slot]; call esi`, shell32's DELAY_LOAD) seeded; a None read in close_dispatch_targets (ole32) | disasm32.py |
| NtCreateThread / NtTerminateThread: guest threads on host threads (their own TEB; the guest's stack committed, its guard page was fatal) | syscall32.c |
| proxied host DLL missing a Windows 2000 export (advapi32 GetSiteSidFromToken, GetMangledSiteSid, IsProcessRestricted): stubs in the proxy's name table | syscall32.c |
| NtUserUnregisterClass (ole32 re-registers OleMainThreadWndClass); CreateWindowEx with no hInstance finds a DLL's local class | w32kuser.c |
| host COM pieces proxied (host actxprxy, clbcatq, desk.cpl loaded natively): lifted Windows 2000's instead. A host DLL's SystemParametersInfo SETs are refused like the guest's (regbox) | CMake, regbox32.c |
| `NATIVE32_DEBUG_CHILD=1`: the held parent debugs the child and prints second-chance exceptions with the lifted function (found the STATUS_UNWIND death); `W2K_ALL_FAULTS`, entry/terminate reports | native32.c, nthost.c |

Launch path (written, not yet exercised): the lifted kernel32's
CreateProcessW/A are replaced (nthost.c `host_createprocess`): only a name with
a runner `build\nt<name>.exe` next to the host is started, as a new host
process with `--mute -- <args>` and `W2K_SCREEN_HWND` inherited; anything
else is `[guard] ... refused`. NtCreateProcess and host CreateProcess/
ShellExecute/WinExec stay refused.

Registry: before/after snapshot of HKCU\Software\Microsoft\Windows\
CurrentVersion, Windows NT\...\Windows, winmine, Control Panel, Classes\Local
Settings and HKLM Explorer/Winlogon around all these runs: the changes are the
user's own Windows 11 activity (UserAssist, TaskbarStateLastRun, AppModel,
Bags) except **HKCU\Control Panel\Desktop\WindowMetrics: last-write time
2026-11-16 08:34:42 UTC (values unchanged)**, during the run that loaded the
host's desk.cpl through a proxy: a host DLL calling SystemParametersInfo
natively. Now lifted, and host SETs refused. Nothing of explorer's own state
(StuckRects2, Streams, ShellState, DeskView) changed.

The "RTM 2195.1" archive (Y:) is build 2163: its ntdll, kernel32, msvcrt and
cmd.exe are byte-identical to pro.zip's (work/sys-rtm), so it adds nothing to
the cmd regression; its user32/gdi32 are 5.0.2180 (extracted in
work/sys-rtm2195, not lifted yet). cmd regression (Pro SP4, Server SP4, 2163):
ver/echo/cd/if/for as before.

Next: why explorer exits 1 after the desktop thread starts (NtUserBuildHwndList
and NtUserCallHwndOpt 0x3F are unanswered; Global\ComPlusCOMRegTable absent;
run `--calltrace` and filter one thread with tools/calls.py), then the first
desktop paint.

### Why explorer exited 1: the host's COM classes (and a host COM DLL in the guest)

`--calltrace` on the main thread (tools/calls.py over `work/rebased-shell`):
`CreateWindowEx("Progman")` fails inside its WM_CREATE: shell32's desktop
CoCreateInstance's browseui's CCommonBrowser `{AF604EFE-8897-11D1-B944-
00A0C90312E1}` (and the tray its BandSite `{ECD4FC4D-...}`), the call fails,
WM_CREATE returns -1, explorer PostQuitMessages and exits 1.
NtUserBuildHwndList, NtUserCallHwndOpt 0x3F and Global\ComPlusCOMRegTable
were not it (still unanswered, nothing waits on them yet).

Why it failed: the registry box answered reads with the **host's** keys, and
Windows 11's HKCR\CLSID names `explorerframe.dll` for those classes. The
guest's ole32 asked for it, the loader found `C:\Windows\SysWOW64\
ExplorerFrame.dll` under the system directory, and **the host's
ExplorerFrame.dll was proxied into the guest** (`[nt] ... the host's, through
a proxy image`), a host COM server in the guest process, which the rules
forbid. Fixed both ways (pcrecomp):

| What | Where |
|---|---|
| a host DLL that exports DllGetClassObject (a COM server) or a .cpl is never proxied into a lifted process: `[guard] ...: a host COM server or applet: not mapped` (shell32, ole32 and comdlg32 stay allowed: the other nt builds import them statically). Checked by mapping the file as an image resource, no code runs | syscall32.c |
| with Windows 2000's own ole32 lifted, `Classes\CLSID\...` and `Classes\AppID\...` are answered by the box only, never the host's; the per-user `<sid>_Classes` maps to the box's one merged `HKLM\SOFTWARE\Classes`. `PCRECOMP_REGTRACE=1` names each refused host class key | regbox32.c |
| tools/reginst.py: each DLL's REGINST resource (the INF its DllRegisterServer hands advpack) -> its HKCR CLSID/AppID lines into `HKCU\Software\pcrecomp\w2k\explorer\HKLM\SOFTWARE\Classes`, InprocServer32 = the module in work/rebased-shell (531 lines from browseui, shell32, shdocvw, comctl32); lift_explorer.sh runs it | win2000 tools |
| `--argtrace` also prints the 16 bytes the first argument points at (the CLSID of a CoCreateInstanceEx) | recomp_trace.c |
| the data scan's vtable rule: a slot that ends or starts a run of three (not only the middle one), and a slot a GUID-decoded body covers (the IID before a function decodes as code and runs over it: shdocvw 0x20E0AC30 inside 0x20E0AC20) is a start, kept | disasm32.py |

With that, browseui's and shdocvw's classes load from the lifted modules
(3 ICALL misses seeded on the way: browseui 0x20D0B840, shdocvw 0x20E11E4C,
0x20E0AC30, 0x20E076D8). explorer no longer exits: it runs until the watchdog.
**Nothing is drawn yet** (shots/exp/r9_13.png is the black 800x600 screen).

State now (handoff): two runs, two outcomes, so a race between the main and
the desktop thread:
- r9: the main thread waits (NtWaitForSingleObject, from oleaut32
  0x2117xxxx) while the desktop thread is in ole32's class-registry reads
  (0x2100777C, a RegOpenKey+RegQueryValue helper, called from 0x21008102);
- sc4: a fault in oleaut32 sub_2117AD70 (its small-block/BSTR cache) writing
  just past a fresh NtAllocateVirtualMemory: reserved, not committed, at
  0x069D1004. Next: who allocates that block (reserve 0x2000 / commit
  0x1000) and whether Windows 2000 commits on demand there (a guard page or
  an __except that commits); then the desktop thread's next wait.
Registry snapshots (HKCU\Control Panel, ...\CurrentVersion\Explorer,
...\Policies) before and after all these runs: only UserAssist counters of
the user's own programs changed.

Follow-up (same session): every host module proxied into a guest now logs
`[nt] HOST DLL in the guest: <path>, through a proxy image` (pcrecomp
syscall32.c), and `tools/run_explorer.sh` exits 1 with `!!! HOST MODULE IN THE
GUEST` if any such module other than its ALLOW list (advapi32 only) appears.
The oleaut32 crash reproduces every run now (a1, a2): sub_2117AD70 (a fill
into a {ptr, remaining, buf[0xF0]} block at 0x2118C5B0 in oleaut32's data)
runs with ptr = a fresh page-aligned address (0x07EE1000) and faults at +4.
The calls before it: oleaut32 0x21176360 -> kernel32 TlsAlloc, then
0x211786A0 -> ntdll. Not yet known whether that page is a reserve oleaut32
expects to be committed on demand (an __except that commits, which the lift
would have to resume into) or a pointer read from the wrong TLS slot (TlsAlloc
just before: check the slot index the lifted kernel32 hands back against the
TEB's TlsSlots/TlsExpansionSlots the guest reads). Next: `--argtrace` on
0x2117AD70 and its caller, and NATIVE32_SYSCALLS around the NtAllocate
VirtualMemory that returned that page.

### The oleaut32 fault was a reloaded DLL's stale data; then the threads' locks

**The crash (fixed).** Not a TLS slot and not commit-on-demand. `NATIVE32_SYSCALLS`
(which now prints the region a `Nt*VirtualMemory` ended with, `[base +size]`)
showed oleaut32's statically linked CRT small-block heap reserving its region
(0x400000 at 0x07EE0000, 0x10000 committed), then **releasing** it: a
`LoadLibrary(clbcatq)` that ole32 abandons unloads clbcatq and the new
dependencies it pulled in (oleaut32, msvcrt), and oleaut32's PROCESS_DETACH
frees its heap. The next CoCreateInstance loads oleaut32 again. A lifted
image is never really unmapped (`ovr_unmap_view` keeps it), so the second
PROCESS_ATTACH ran over the .data the detach left, and the heap's rover still
pointed into the freed region (then reused by a section view): the write at
+4. NT maps a fresh copy. Fix (pcrecomp syscall32.c): a lifted image's
writable sections are saved at its first map and put back on a map after an
unmap; a section for an image already known reuses its slot.

**Deadlock 1 (fixed): win32k services held the machine.** Explorer's main
thread SendMessages (0x55A) to the tray window, owned by the tray thread; the
shim called the host's SendMessageW with the machine lock held, so the tray
thread could never run. Now NtUserMessageCall to *another thread's* window,
NtUserGetMessage and NtUserWaitMessage give the machine up. Inside a window
procedure (a callback) the lock is held twice, so they use the new
`mach_release()/mach_reacquire(n)` (native32.c), which drops every level and
takes the same count back. Releasing it on every SendMessage, including a
send to the thread's own window, let the other thread run in the middle of
CDefView's processing and fault in shell32 (sub_20A18E70); hence own-thread
sends stay under the lock. Nt waits keep their one-level `mach_leave`.

**Still open: deadlock 2 (guest critical sections).** With the above, three
threads end like this (handles differ per run): the main thread is in a
SendMessage(0x55A) to the tray window, and the tray thread and a third thread
wait in RtlpWaitForCriticalSection on the same semaphore. Which section, and
which thread owns it, is not yet known. My watchdog walk of the guest's lock
list (nthost.c: from PEB->LoaderLock's DebugInfo, ProcessLocksList) prints
values that don't look like sections (0x210E60E8 "count 13, semaphore E"), so
check that layout first. The "waits in" trace line now prints 8 stack words
after the arguments. The suspect is a lock the main thread holds while it sends
(on real NT a thread blocked in a CS wait doesn't take sent messages either, so
either the main thread doesn't hold that lock on Windows 2000, or the tray
thread reaches its message loop before the send). Next: name the section
behind the semaphore (log every NtCreateEvent/NtCreateSemaphore's returned
handle next to its caller, or record RtlpWaitForCriticalSection's argument),
then its owner. Screen: still black (shots/exp/ta_27.png); the desktop
listview gets its items, and the tray window is created, shown, gets its
region and timer.

Tools added: `NATIVE32_SYSCALLS` prints `t<id> waits in ...` before a host
wait and `t<id> enters NtUserMessageCall(hwnd msg), window of t<owner>`
before a blocking win32k call; the fault report names the mapping behind a
fault address (lifted code is in ntexplorer.exe); the watchdog dumps the
guest's contended critical sections.

Regression after these runtime changes (all builds rebuilt; interact.py, one app
at a time): winmine 7/7, notepad 2/2, sol 2/2, freecell 2/2, calc 2/2,
packager 1/1, mspaint 2/2, wordpad 2/2, all 0 pixels differ. winmine
intermediate and custom were 499/1473 before and are 0 now. The mspaint
startup-heap crash did not recur. Registry (HKCU\Control Panel,
CurrentVersion\Explorer, Policies) before/after: only UserAssist counters of
the user's own programs changed.

### The tray thread spun in MsgWaitForMultipleObjectsEx; explorer's icons

**The "deadlock 2" above was not a lock.** With a `woke` line after every
traced wait (and `left` after a blocking win32k call), only the main thread
stays blocked (its SendMessage 0x55A to the tray window). The tray thread was
**spinning**: `NtUserCallOneParam(0xFF, 0x1D) not answered`, thousands of
times. 0x1D is GetInputEvent. Windows 2000's MsgWaitForMultipleObjectsEx asks
win32k for the queue's input event and waits on it with the caller's handles.
The host has no such event to hand out, so the call failed at once and
explorer's tray loop spun without ever taking the sent message. Fix
(nthost.c): user32's MsgWaitForMultipleObjects(Ex) are answered by the host's
(the guest's handles are host handles), with the machine given up
(mach_release). A message loop now runs (`NtUserWaitMessage` is reached).
(The CS-wait trace's "waits for lock X owned by tN" picks the first stack word
whose +0x10 equals the handle. It can be a false match, so check it.)

**Icons (fixed, pcrecomp w32kuser.c).** All of explorer's ~500
NtUserSetCursorIconData calls failed (CreateIconIndirect, error 87): Windows
2000's user32 hands over a double-height mask (the AND mask on top) even with
a colour bitmap, and the host wants the mask at the colour bitmap's height. The
top half is copied into a cx x cy mask. The placeholder table grew from 64 to
1024 (explorer makes over 100). One shell32 ICALL miss was seeded
(0x20A0FA88; seeds are now tracked in work/seeds).

**State (handoff).** Screen still black (shots/exp/tm_27.png). Two outcomes
by timing:
- tm: runs to the watchdog, no fault; one thread in a CS wait, the others idle;
  NtGdiBitBlt x105 and 4 InvalidateRects, but nothing reaches the screen
  window. Next: check whether the desktop window (Progman / SHELLDLL_DefView,
  800x600) ever gets WM_PAINT/WM_ERASEBKGND (`--calltrace` for PaintDesktop,
  BeginPaint), and whether w32kuser's virtual-screen blit picks up a guest
  window that was only SetWindowPos'd and shown.
- tl: a guest stack overflow in shell32 sub_20A13F31 (IExtractIcon::
  GetIconLocation into a MAX_PATH buffer; the registers hold UTF-16 text,
  esp=006F0084) after a storm of NtQueryAttributesFile -> C0000033 (invalid
  name). The trace now prints that call's path, but it didn't recur in tm.
  Next: catch the path it builds (likely an icon path expanded from the
  registry box, longer than 260 chars or malformed).
Regression and registry: see below.

Regression after the MsgWait and icon changes (all builds rebuilt):
calc 2/2, packager 1/1, mspaint 2/2, wordpad 2/2 at 0 pixels; winmine
start, intermediate, 20x30 and menu open at 0. **Not matching and not stable
between runs:**
- winmine click 1120, custom 0 / 1490, menu Interm. 0 / 316;
- notepad 153 / 740;
- sol and freecell show a different deal in the two builds (12-30k pixels).

notepad's diff is the caption icon (16,8-30,23). I first copied the half
mask unconditionally, which changed it; now the half mask is only a retry
when the host refuses, but the 153 px stayed, so the icon diff is probably not
the mask. The run right after the lock changes (mach_release) was 18/18 at 0.
So suspect what came after: the MsgWaitForMultipleObjects host replacement
(nthost.c, applies to every nt app) or timing. sol and freecell's deal comes
from their random seed; check that W2K_FIXED_TICK still reaches them. Next,
before more explorer work: run interact with the nthost MsgWait replacement
compiled out (explorer only) and bisect.

### The regression drift: native32_replace's 32-slot table; explorer's first paint

**Drift cause (fixed, pcrecomp 08023da).** `native32_replace` kept 32
entries and silently dropped the rest. nthost's two MsgWaitForMultipleObjects
replacements pushed the last ones out: `GetTickCount` (W2K_FIXED_TICK) and
msvcrt `time` (W2K_FIXED_TIME). So winmine's mines and sol's and freecell's
deals came from the real clock. The table is now 256 entries and a full table
aborts loudly. Bisecting the icon commit also found a second, real
difference: SERVERINFO +0xE48 BitCount, +0xE4C Planes and +0xE4D BitsPixel
were 0, so Windows 2000's user32 chose the 16-colour icon image where the
host chooses the 256-colour one (notepad's caption icon, 153 px). They are
now filled from the host. (The half-mask retry does fire for notepad's icon;
that is fine.) MsgWait and the lock changes were ruled out: notepad's 153 px
stayed with the MsgWait replacement compiled out.

**Harness (22ae1ce).** hiddenrun's "make the top window active" never
matched, because GetForegroundWindow only answers for the input desktop. It
now asks the window's thread (GetGUIThreadInfo), waits for the activation,
and leaves an open menu alone. interact.py keeps each run's hiddenrun
timeline in shots/<run>_<build>.out.

**Regression (this session, machine ~66% busy with other jobs).** winmine
7/7 and sol's/freecell's deals are back to matching. The remaining non-zero
states move between runs and between which build lags (host or lifted).
Every one checked was a half-painted shot: notepad's edit area, a winmine
cell row, sol's last card not yet turned, a packager pane, a wordpad toolbar
button, mspaint's line. Run interact again on an idle machine before calling
any of them a code difference. mspaint once hit the old startup-heap crash
(fault in ntdll sub_2004B37E, access 6F724644 = UTF-16 text): still open
and intermittent.

**Explorer (pcrecomp b358cb4, tools/profile.py, run_explorer.sh).**
- The shell32 sub_20A13F31 "stack overflow" is real recursion on the main
  thread (esp at the stack's guard page; the UTF-16 in the registers is
  leftover). Its icon-cache lookup (GetIconLocation, then
  Shell_GetCachedImageIndex = -1, then extract and add) never filled the
  cache, because NtUserGetIconInfo and NtUserGetIconSize were unanswered,
  so ImageList_ReplaceIcon failed. Both are answered now (GetIconSize's cy
  doubled, as win32k keeps it).
- The guest's environment had the host's 3.5 KB Path. Path is now the
  loader's own search path.
- Explorer walked the host's real Start Menu (C:\ProgramData\...) and
  opened host exes for icons. Windows 2000's PrivateExtractIconsW then
  faulted on a PE32+ exe (sub_2032550B). tools/profile.py gives explorer a
  private profile (work/profile/{user,all}): Windows 2000's User Shell
  Folders and Shell Folders in its box, HKCU and HKLM. run_explorer.sh points
  USERPROFILE, ALLUSERSPROFILE, ProgramData, APPDATA, TEMP, ... at it.
- The host's mpr.dll (WNet) was proxied into the guest. run_explorer.sh's
  check failed the run; it is now refused at the section guard (shell32's
  delay-load stubs answer failure).
- NtUserRedrawWindow is answered; with no window it means the virtual
  screen, never the host's desktop.

Now explorer runs to the watchdog with no fault (2/2). The **first paint
reaches the screen**: shots/exp/s13_22.png shows the desktop listview's item
labels at the top left, drawn as the raw string "@%1...", with no icons, on
a black background. Registry snapshot (HKCU\Control Panel,
CurrentVersion\Explorer, Policies) before the first explorer run and after
all of them: no change.

Next:
1. The labels' "@%1": a display name built from a format/indirect string
   (an "@dll,-id" resource string Windows 2000 does not resolve, or a
   FormatMessage insert never filled). Find which item names come out like
   this (the box's CLSID default values from reginst against the host's
   LocalizedString).
2. The icons: the cache adds now succeed. Check the listview draws them
   (ImageList_Draw goes through NtGdiBitBlt with the host icon bitmaps from
   GetIconInfo: guest handles?).
3. The background: the desktop colour/wallpaper (Control Panel\Colors
   Background, PaintDesktop).
4. The taskbar (the tray window's region: NtUserSetWindowRgn is still
   unanswered), then the Start menu and Run -> winmine.
Still unanswered and left alone on purpose: NtUserSetShellWindowEx,
RegisterHotKey, SendNotifyMessage(HWND_BROADCAST).

### interact under load: what an idle wait can and cannot fix (handoff)

Tried in hiddenrun, before each shot (not committed; it made sol worse):
1. WaitForInputIdle on each window's process plus no GetUpdateRect on any
   window or child. Changed nothing: WaitForInputIdle only reports a
   process's *first* idle.
2. A sent WM_NULL answered (SendMessageTimeout, SMTO_BLOCK|ABORTIFHUNG) plus
   no update region. Also nothing: the late states have no pending paint.
3. Plus the same pixels in three captures 0.25 s apart, 4 s limit. notepad
   start went to 0, but the host sol never settled within 4 s, and the
   delayed shot pushed past the process's lifetime (missing shot).

What the repeat diffs really are (machine ~66% busy):
- sol 6593 every time: the **host** build (stage 1) is still animating its
  deal at 8-10 s (the 7th pile's top card not yet turned); the lifted one
  has finished.
- notepad start 33262: the host notepad hasn't added its scrollbars yet at
  9 s (it is pumping and has nothing to paint).
So the lag is the app's own progress, and the fixed-time inputs (sol's
deck click at 9 s, freecell's clicks) land in a different game state.
Gating shots alone cannot make this deterministic.

Next (design): make hiddenrun's timeline event-driven. Each step (input or
shot) waits for the previous one to settle (WM_NULL answered, no update
region, pixels steady for ~0.5 s, ignoring a status-bar clock such as sol's
"Time:" by comparing everything but the bottom 20 rows, or by running with
W2K_FIXED_TICK, which already freezes the lifted build's clock but not the
host's) instead of firing at a fixed second, with --secs as an overall
limit only. interact.py's step lists keep their order; the times become
upper bounds.

### The event-driven timeline; the desktop's names (handoff)

**hiddenrun --settle (b11976d).** Inputs and shots run as one ordered list
on a thread joined to the hidden desktop. Before each step: the process's
first input idle (WaitForInputIdle), every window answers a sent WM_NULL
(SMTO_BLOCK|ABORTIFHUNG, 250 ms), no update region on any window or visible
child, and the composite capture equals one taken at least --hold s earlier.
The step's time (x --scale) is only an upper limit; the timeline prints
"settled" or "LIMIT" per step. Two things found on the way:
- PrintWindow sometimes reads a window half-drawn (winmine's grid, the
  host packager's left pane: 39 of 55 reads full, the rest without the
  pane). A capture that differs and comes back no longer restarts the wait,
  and the shot is the capture seen most often since the windows went idle.
- The lifted calc paints its buttons in bursts more than 0.5 s apart on a
  busy machine: interact uses --hold 1.5.
sol: the host build's clock is not frozen; its status bar (bottom 26 rows,
"Score/Time") is left out of the stability check (--still-crop) and of
interact's comparison. winmine's int run hits LIMIT after the click (its
counter ticks every second) in both builds alike and still matches.

Two full runs, every state 0 except:

| state | run 1 | run 2 |
|---|---|---|
| sol deck click | 6593 | 6593 |
| freecell deal / card to cell | 4790 / 4790 | 0 / 0 |

- sol 6593 is now deterministic and real, but in the **stage 1 (host)**
  build: its 7th pile's top card stays face down (seen still face down at
  20 s with Time: 16), while the lifted build turns it after the deck click.
  Windows 2000's sol deals that card face up: the lifted build is right.
  Not fixed: find what the stage-1 build misses after the deal animation.
- freecell 4790: the known flake (once in two, as before).

**Desktop names (b3a3ec6).** "@%1..." was Windows 2000's own
LocalizedString from shell32's INF, `@%11%\shell32.dll,-8964`: reginst left
LDID 11 unexpanded. It is now the lifted modules' directory; the desktop
shows My Computer, My Network Places, Recycle Bin, My Documents
(shots/exp/s14_22.png).

**Icons (pcrecomp 68b921f).** NtUserDrawIconEx is answered (the host draws
its icon into the host DC). The icon cache fills (98 GetIconInfo, 196
DrawIconEx, the image lists' 32x32 and 16x16 BitBlts), and LVM_SETIMAGELIST
reaches the desktop listview (wparam 0 and 1), but shots/exp/s15_22.png is
unchanged: no icons, and each label sits at the item's top (rows 44 px
apart, columns 88 px), as if the listview's icon height were 0. Next: ask
the listview (LVM_GETITEMRECT LVIR_ICON, LVM_GETIMAGELIST,
ImageList_GetIconSize on 03FF40B0) whether its image list has a size, and
check the listview's icon spacing (SM_CXICONSPACING from SERVERINFO on a
200% DPI host: AppliedDPI 0xC0).

Registry snapshot (HKCU\Control Panel, CurrentVersion\Explorer, Policies)
before the first explorer run and after the last: one change, Win11's own
SessionInfo\1\ApplicationViewManagement\W32:000000000177225A removed (the
host shell's per-window record for a host window that closed; the guest's
writes go to its box). No other change.

Next: the icons (above), the background (Control Panel\Colors Background
is the host's "0 0 0"; seed the box with Windows 2000's 58 110 165 if the
emulated win32k reads it), the taskbar (NtUserSetWindowRgn still
unanswered), the Start menu, Run -> winmine.

### The icon height: what the desktop listview holds (handoff)

A probe (SendMessage into the guest's listview from the hidden desktop,
ReadProcessMemory on the guest; note the windows belong to a *child*
process, not hiddenrun's pid) found:
- LVM_GETIMAGELIST 0/1: valid image lists ('HIML', +0x10/+0x14 cx/cy =
  32/32 and 16/16).
- The listview struct (GetWindowLong 0): +0xCC the large list, **+0xD0/+0xD4
  (its cxIcon/cyIcon) = 0**; +0xA8 the small list, +0xAC/+0xB0 = 0;
  +0xC4/+0xC8 icon spacing 44 = SM_CXICONSPACING 76 - SM_CXICON 32 + 0.
  LVM_GETITEMRECT LVIR_ICON = (14,0,30,4): no room for the icon, hence the
  labels at the top.
- comctl32's LVM_SETIMAGELIST (0x2080FCC0) stores the list and calls
  ImageList_GetIconSize (0x20806B26) for those fields. Re-sending
  LVM_SETIMAGELIST (0, then the list) from the probe leaves them 0 again,
  so the call fails now, with a valid list: its IsImageList (0x2080520F) is
  IsBadWritePtr(himl, 0x5F8) plus the magic. A test replacement of the
  lifted IsBadWritePtr logging every call saw 1463 calls, all 0 (not bad),
  and the icons stayed missing. The lifted C of all three functions reads
  right. Not found yet. Next: trace sub_20806B26's return and esi inside
  the guest (a W2K_TRACE-style ring of entries, or a temporary
  native32_replace of ImageList_GetIconSize that logs its arguments and
  answers from the list) to see whether it is reached with this list at
  all; the listview may be getting a different HIMAGELIST than LVM_GETIMAGELIST
  reports (+0xCC is written before the call).
- Windows 2000 deals sol's last card face up: the stage-1 (host) build's
  unturned card (above) is a native32 host-path bug, for later.
- Desktop colour: the virtual screen's COLOR_BACKGROUND comes from the
  host's GetSysColor (w32kuser.c server_info), not the registry, so a
  Windows 2000 "58 110 165" in the box would not reach it; server_info
  should take it from the box's Control Panel\Colors when there is one.
Not started: the taskbar (NtUserSetWindowRgn), the Start menu, Run -> winmine.

### Icons on the desktop: the listview was the host's (handoff)

**Root cause (pcrecomp 691d577).** ImageList_GetIconSize was never reached: a
probe in the lifted comctl32 (sub_20806B26, LVM_SETIMAGELIST sub_2080FCB6, the
listview procedure sub_208137F9) printed nothing. The guest's comctl32 registered
none of its classes. A DLL-load probe showed why: the first host window starts
Win11's text services (MSCTF, MSUTB), and the language bar loads the **host's
comctl32 5.82** into the process, which registers SysListView32, ToolbarWindow32,
... as global classes. The guest's comctl32 asks GetClassInfo first; the emulated
NtUserGetClassInfo fell back to GetClassInfoEx(NULL), found the host's, and
comctl32 skipped registering. Every guest control was a host control, which takes
none of the guest's handles (LVM_SETIMAGELIST's HIMAGELIST: icon size 0). Not a
lifter or calling-convention bug. (ImmDisableTextFrameService(-1) did not stop it.)
Fixed in w32kuser.c:
- NtUserGetClassInfo does not answer a host DLL's class (its procedure lives in a
  module other than the host user32, or ntdll's WOW64 stubs, which are the system
  classes'); RegisterClass retries a CS_GLOBALCLASS name a host DLL holds as the
  DLL's local class; CreateWindowEx picks the guest's class (procedure ==
  wnd_thunk) under the instance it was registered with. Atoms do not tell
  classes apart (the same name is the same string atom).

Then three more on the way to icons:
- the guest listview's WM_PAINT never painted (WM_PAINT forever): user32's
  GetUpdateRect answers FALSE client-side while WND+0x64 hrgnUpdate is 0. Now
  HRGN_FULL when the host window has an update region, and NtUserGetUpdateRect.
- NtGdiGetAppClipBox (GetClipBox) answered.
- the items had no text or icon: comctl32 sends WM_NOTIFY only to a parent in its
  own process (GetWindowThreadProcessId), which answered 0 because the handle
  entry's pOwner was 0. Now a stand-in THREADINFO (never the threads' shared one),
  so user32 asks NtUserQueryWindow.

**Desktop colour.** server_info takes COLOR_* from the box's
HKCU\Control Panel\Colors (native32_registry_box_sz, box only), else the host's;
those colours get their own brushes, and the virtual screen's class background
too. tools/profile.py seeds the box from Windows 2000's HIVEDEF.INF (Background
58 110 165). tools/reginst.py also writes the INFs' HKLM ...\NameSpace lines:
with the box's own Desktop\NameSpace key, Win11's 33 host entries are no longer
enumerated (they were 27 nameless folders on the desktop).

shots/exp/s16_22.png (local, as p17_22): blue desktop, My Computer, My Network
Places, Recycle Bin, My Documents with their icons (before the NameSpace fix: plus
nameless folders).

**Regression: a startup deadlock, 1-3 runs in 4.** With the guest's own comctl32
controls, some runs hang before the first paint (black shot, exit 4): the main
thread waits; one thread holds the loader lock (2004F170), the process heap lock
(+0x608) and ole32's lock 210E60E8 (count 13). Baseline (pcrecomp 68b921f) 0/4;
without the pOwner change still 1/4, so it comes from the guest controls
themselves. Next: run with NATIVE32_SYSCALLS until it hangs and read that
thread's last calls ("tX waits for lock ... owned by"); suspect a guest thread
blocked in a host call (a cross-thread SendMessage from a guest control's
create) while holding the heap lock.

interact (all 8, once, after the runtime change): every state 0 except sol deck
click 6593 (expected) and freecell card to cell 4790 (the known flake).

Registry snapshot (HKCU\Control Panel, CurrentVersion\Explorer, both Policies)
before the first explorer run and after the last: Control Panel and Policies
unchanged; Explorer: only the host shell's own UserAssist counters
(UEME_CTLSESSION, Chrome) and one SessionInfo\...\W32: window record removed:
the host's activity, not the guest's.

Not done: the taskbar (Shell_TrayWnd is 4x0 at -2,2: NtUserSetWindowRgn still
unanswered), the Start menu, Run -> winmine.

### The startup deadlock; the taskbar (handoff)

**Deadlock root cause (pcrecomp d6b47b1).** A trace of a hung run: the tray
thread holds the loader lock, the heap lock 04040608 and ole32's 210E60E8 and
is runnable; the main thread waits for 04040608. Neither "waits for lock"
line names the machine lock, and that was it: the main thread was inside a
window procedure (a host callback, machine depth 2) when it hit the heap
lock, and syscall32's Nt*Wait path gave up the machine with one mach_leave,
so it kept it at depth 1 while it slept. The tray thread could never re-enter
the machine to release the heap lock. The win32k blocking calls already used
mach_release (every level); the Nt wait path now does too. 8 of 8 runs
without a hang (d1..d8), and none in the ~15 explorer runs after.

**Desktop (shots/exp/t8_19.png, local).** The NameSpace fix removed Win11's
nameless folders, but also Recycle Bin: it is not in shell32's REGINST but in
HIVESFT.INF (Desktop\NameSpace) and HIVECLS.INF (its CLSID, ShellFolder
Attributes as a continued binary line). tools/reginst.py now adds HIVESFT's
desktop items served by one of the DLLs given, with HIVECLS's lines for them
(INF continuations and REG_BINARY handled; %SystemRoot%\System32\x.dll and a
bare x.dll map to the lifted module). Desktop: My Computer, My Network Places,
Recycle Bin. My Documents needs mydocs.dll (not lifted). My Computer and
Recycle Bin show a generic program icon (shell32 index lookup, not looked at).

**Taskbar (pcrecomp 75d3d88).** Three causes:
- The primary MONITOR had HEAD.h 0: MonitorFromRect answered 0 and
  GetMonitorInfo failed, so the tray sized itself to nothing (4x0 at -2,2). It
  now has handle 0x1FFFF in the handle table's last slot, TYPE_MONITOR (12).
  NtUserEnumDisplayMonitors calls the guest's MONITORENUMPROC with it.
- Progman covered the tray: SetShellWindowEx is answered locally and keeps the
  shell window the virtual screen's bottom child (also on ShowWindow).
- The tray's SetWindowRgn region reached the host as 0,0,1,1: gdi32 keeps a
  rect region's rectangle client-side (RGNATTR, ATTR_RGN_DIRTY 0x20) and
  win32k applies it on any call that takes the region. native32_gdi_rgn
  applies a dirty RGNATTR; only SetWindowRgn uses it (pcrecomp eb68b5f; in the
  first version, 75d3d88, it was native32_gdi_host for every caller, mspaint
  faulted at start (sub_2004BB49). Find why before widening it.
Taskbar: 804x34 at the bottom, Windows 2000 grey, Start button and band
present but the Start button has no logo/text and the clock is missing.
RegisterHotKey/UnregisterHotKey and SetShellWindowEx answer TRUE in the guest;
SendNotifyMessage only to this process's windows (a broadcast is dropped);
PostThreadMessage only to this process's threads (it was unanswered before:
explorer's posts to its own threads were lost).

**Start menu: not yet.** A click (hiddenrun --drag X,Y,X,Y@T reaches the
deepest child; --click posts to the main window only) focuses the Start
button and explorer builds the Start menu (menus, the menuband toolbar under
BaseBar) but never shows the BaseBar, even 26 s later. Leads:
NtUserCallHwndLock 0x4D on the tray window (likely SetForegroundWindow) and
NtUserCallOneParam(1, 0x21) are unanswered; NtUserDeleteMenu/RemoveMenu are
unshimmed. Next: trace from the WM_COMMAND 0x130 on the tray to
IMenuPopup::Popup and see where it stops. Then Run -> winmine.

interact (all 8, after the runtime change): every state 0 except freecell 4790
(the known flake, both states); sol's deck click was 0 this time. packager
10637 and mspaint's missing shots on the first pass were the RGNATTR sync in
every caller (above); after narrowing it, packager 0, mspaint 0/0.

Registry (HKCU\Control Panel, CurrentVersion\Explorer, both Policies): the
snapshot taken before the first run was lost (scratch dir gone); one taken
just before and after the final explorer run (start click included):
identical, 10128 lines. The box is the only thing written (reginst.py, under
HKCU\Software\pcrecomp\w2k\explorer).

Last shot shots/exp/f1_27.png: desktop + taskbar, Start button focused; My
Computer's label paints black after the click (seen before, a listview
label redraw, not looked at).

### Start menu still not shown (handoff)

pcrecomp (after eb68b5f): user32's exports confirm CallHwndLock 0x4D is
SetForegroundWindow and CallOneParam 0x21 LockSetForegroundWindow; both now
answered in the guest (0x4D: SetActiveWindow inside the virtual screen). The
Start menu still does not appear (m1, 19 s after the click). Next: trace from
the tray's WM_COMMAND 0x130 (the Start button) through CStartMenu /
IMenuPopup::Popup to the BaseBar's SetWindowPos/ShowWindow, which never comes;
check NtUserDeleteMenu/RemoveMenu (unshimmed, answer 0) and whether the popup
runs on a thread that is waiting. Then Run -> winmine, the Start logo and the clock.

Registry snapshots now in work/regsnap (ignored by git): before/after one
explorer run differ only in Win11's own SessionInfo\...\W32: record for a
window that closed (the host's tracking, as in earlier runs); Control Panel
and Policies unchanged.

### The Start menu shows (handoff)

pcrecomp dc92737. From the tray's WM_COMMAND 0x130 (NATIVE32_SYSCALLS, then
`--calltrace` + calls.py), four stops on the way to the BaseBar:
- explorer takes the Start menu out of its LoadMenu bar with RemoveMenu, then
  DestroyMenu(bar). NtUserRemoveMenu was unanswered (0), so the destroy took the
  Start menu with it and every later DeleteMenu failed. RemoveMenu/DeleteMenu
  answered (host menus, menu_sync after).
- CMenuDeskBar::Popup calls AnimateWindow. It prints the window into a memory
  DC and gives up if GetBoundsRect says nothing was drawn: NtGdiSet/GetBoundsRect
  (and RectVisible) answered on the host DC.
- AW_BLEND (menu fade) sets WS_EX_LAYERED, which a host child window cannot
  have without a Windows 8 manifest, so it failed. The slide then spun forever:
  the guest's GetTickCount reads KUSER_SHARED_DATA+0 (TickCountLow), which
  Windows 10/11 leave 0. On the virtual screen SPI_GETMENUANIMATION and
  SPI_GETMENUFADE answer FALSE, so menus show with no animation. A moving guest
  tick (the host's GetTickCount, even counted from start) sent ole32 into the
  COM+ catalog (clbcatq GetCatalogObject, unlifted vtables, then a fault) at
  startup. W2K_FIXED_TICK=1000 is fine. Not followed further (work/seeds/
  clbcatq.dll.json now seeds 113 vtable entries; harmless).
- SetWindowPos(HWND_TOPMOST) on a screen window is now HWND_TOP among the
  screen's children (GetAncestor(GA_PARENT): GetParent of a WS_POPUP is its owner).
Also BM_SETIMAGE/STM_SETIMAGE pass the host's bitmap: the Start button now
shows its image, but the image is black (the logo+text bitmap is drawn guest-side
into a DIB section or a mono bitmap that the host doesn't have; not looked at).
--calltrace buffers 64 KB (a TerminateProcess'd run kept nothing with 4 MB).

shots/exp/startmenu_19.png (local): the Start menu over the desktop, the
"Windows 2000 Terminal" banner (explorer picks the Terminal banner: probably
SM_REMOTESESSION from the host's RDP session) and its icons, **no item text**
(menuband toolbar text, not looked at).

Not done:
- Run -> winmine: a --drag on the Run item (47,507) does nothing; hiddenrun's
  "deepest child" may not be the menuband toolbar, or the menuband needs its
  message hook (WH_GETMESSAGE, set at popup) to see the click. Next: post the
  click to the toolbar's HWND directly, or a keyboard path (R accelerator).
- After a click, My Computer / My Network Places labels/icons sometimes vanish
  (the listview label redraw seen before).
- reginst.py maps INF directory files (%25%\Explorer.exe,0 for My Computer) to
  the lifted module; written to the box, the run after the change lost those
  icons to the redraw bug above, so unverified. Clock, mydocs.dll: not started.

interact (all 8, after the runtime change): every state 0 except freecell
4790/4790 (the known flake).

Registry: work/regsnap/before2.txt (before the first explorer run), after3.txt
(after the last): Control Panel and both Policies unchanged; Explorer differs
only in Win11's own UserAssist counters and SessionInfo\...\W32: records (the
host shell's tracking). The guest wrote only to its box.

### Start -> Run -> winmine (handoff)

pcrecomp (w2k, after dc92737). shots/exp (local): winmine_run_16.png (the Run
dialog, "winmine" typed, the Start button with its logo, the menu with text and
the Professional banner), winmine_run2_27.png (the lifted winmine on the same
virtual screen, started by explorer).

- **Menu item text.** Two causes. (1) menu_sync kept fType/state/id but not
  the ITEM's text: GetMenuItemInfo/GetMenuString are client-side in Windows
  2000 (ITEM +0x18 lpstr, +0x1C cch, +0x20 dwItemData, read off user32's
  GetMenuItemInfoW). Now copied into the desktop heap. (2) The menuband takes
  its font from SystemParametersInfoA(SPI_GETNONCLIENTMETRICS): Windows 2000's
  A wrapper passes its NONCLIENTMETRICSW with cbSize unset and uiParam 0x154;
  its own win32k filled it, the host refused, and CreateFontIndirectA made a
  font from stack garbage (every GetTextExtent failed: the menu was narrow and
  textless). The runtime now sets cbSize/uiParam to the NT 5 size (0x1F4).
- **One item painted, then nothing** (a WM_PAINT loop): Windows 2000's gdi32
  batches ExtSelectClipRgn(hdc, NULL, RGN_COPY) (DrawText's restore) as mode
  0x08000005, not bit 31 as the batch decoder assumed (read off gdi32's
  ExtSelectClipRgn). Read as a rect, the stale TEB bytes clipped the rest of
  the paint. This also makes desktop labels transparent (they were drawn on
  black) and wordpad's toolbar now draws its last button (Date/Time), which
  the stage 1 build does not: interact's wordpad diffs below are that button.
- **Banner "Windows 2000 Terminal"**: Windows 2000's user32 answers
  GetSystemMetrics(SM_REMOTESESSION) with PEB SessionId != 0, and the guest PEB
  carried the host's session (every Win10/11 desktop is 1+). The guest's PEB
  SessionId is now 0 (the local console); named objects already use the host
  session through BASE_STATIC_SERVER_DATA. Banner: "Windows 2000 Professional",
  last item Shut Down (Terminal had Windows Security); **the tray clock now shows**
  (explorer hides it in a remote session).
- **Start button image**: explorer draws the logo and "Start" into the button's
  bitmap with DrawCaptionTemp (DC_INBUTTON|DC_ICON|DC_TEXT); NtUserDrawCaptionTemp
  is now the host's DrawCaptionTempW (guest DC/font/icon translated). Also
  NtGdiGetBitmapBits and NtGdiGetNearestColor answered.
- **Run dialog**: RunDlgProc keeps its data in DWL_USER; s_setlong refused
  every extra-byte index on a dialog (WND+0x16 bit 0), so it read 0 and
  faulted at +0x28. DWL_USER is now stored at WND+0x98+8, where the guest's
  GetWindowLong reads it for dialogs.
- **Launch**: ShellExecuteEx("winmine") never reached CreateProcessW: nothing
  named winmine.exe is on the host's paths (and must not be). reginst.py now
  writes App Paths\<name>.exe -> build\nt<name>.exe into explorer's box for
  every runner, and nthost's guard accepts an image that is itself a runner
  (nt<name>.exe). Log: `[launch] ntwinmine -> ...\build\ntwinmine.exe`. Other
  names are still `[guard] ... refused`. run_explorer.sh's host-module check
  skips the launched runner's own startup lines (from [launch] to its banner;
  winmine proxies host shell32/winmm as in its own runs).

How the run is driven (run_explorer.sh, hiddenrun `--childpost`): drag on the
Start button (35,580); WM_COMMAND 0x191 (IDM_FILERUN, the Run item's id) posted
to Shell_TrayWnd; EM_SETSEL + WM_CHARs to the edit under 200,474; WM_COMMAND
IDOK to #32770. The menu item itself does not react to a posted click or key
(drag at 90,509 reaches ToolbarWindow32 at 60,176; WM_KEYDOWN 'R' to the
toolbar or the Start button: nothing). The menuband's input goes through its
WH_GETMESSAGE hook and checks the real cursor/focus; not followed. The Start
menu stays open after Run (the tray posted the command, not the menu).

Gaps: the Run dialog has no caption; winmine on the screen has no frame/caption
and is clipped to ~150 px wide; no taskbar button for winmine. A desktop click
(drag at 38,30) raised the desktop over the taskbar and winmine (the screen
went to icons only): Progman/the desktop listview should stay at the bottom
(probably the SetActiveWindow/HWND_TOP path when the desktop is activated).
NtUserAttachThreadInput and CallHwndLock 0x4C are still unanswered.
mydocs.dll and the My Computer icon check not started.

interact (all 8, after the runtime changes): every state 0 except wordpad 337
/ 930 (the Date/Time toolbar button above, now drawn by the lifted build only).
freecell 0/0 this time.

Registry: work/regsnap/before4.txt (before the first explorer run), after4.txt
(after the last). Control Panel and both Policies unchanged; Explorer differs
only in Win11's UserAssist counters (CTLSESSION, Windows Terminal, a Godot app:
the host's own activity) and SessionInfo\1\ApplicationViewManagement\W32:
records (the host shell's window tracking). The guest wrote only to its box.

Next: the desktop z-order on click (keep the desktop at the bottom), then the
menuband's own click/keyboard path (its GETMESSAGE hook), the launched
program's frame and taskbar button.

### Frames, a taskbar button, the desktop stays down (handoff)

pcrecomp af703b0 (w2k). shots/exp (local): w1_24.png / final_24.png (winmine
started from Run, framed, its taskbar button "Minesweeper", the desktop
clicked at 21 s and still under everything), z4_14.png (the Run dialog with
its caption).

- **Desktop click raised the desktop.** A host child without WS_CHILD is
  activated (and raised) by a click. wnd_thunk now pins the shell window
  (SetShellWindowEx's) to HWND_BOTTOM at every WM_WINDOWPOSCHANGING, before and
  after the guest sees it. The icons-vanish-after-a-click bug is separate: My
  Computer's icon/label still drops out of some shots and comes back (a
  listview redraw, not looked at).
- **No caption on winmine / the Run dialog.** The frame was there but never
  painted: a window created top-level keeps DWM's non-client rendering after
  SetParent onto the screen, and DWM draws nothing for a child. A captioned
  window ((style & WS_CAPTION) == WS_CAPTION; WS_BORDER/WS_DLGFRAME alone
  matched the tray and the BaseBar and lost both) put on the screen gets
  DWMWA_NCRENDERING_POLICY = disabled and SetWindowTheme(L"", L""): the
  classic, Windows 2000 caption and borders.
- **winmine clipped.** Windows 2000's AdjustWindowRectEx has no padded border,
  so every size the guest computes is short by the host's padding (10 px on
  winmine). Create already added it; frame_pad is now shared and added on every
  SetWindowPos/MoveWindow of a captioned window of the screen.
  ponytail: a guest that resizes from its own GetWindowRect would grow.
- **Taskbar button.** user32: CallHwnd 0x3C RegisterShellHookWindow, 0x39
  Deregister; CallHwndOpt 0x3E SetProgmanWindow, 0x3F SetTaskmanWindow.
  Answered locally (never the host's). The screen window (now screen_proc) has
  a 250 ms timer: its visible, unowned children of other processes are tasks,
  and it posts "SHELLHOOK" HSHELL_WINDOWCREATED / DESTROYED / ACTIVATED to
  explorer's registered window. Log: `[user] shell hook 1: <hwnd>`. The button
  then showed the icon but no text: explorer draws task buttons with
  DrawCaptionTemp(hwnd, ..., UNICODE_STRING with a NULL buffer), which means the
  window's own title; the shim passed "". Fixed.
  ponytail: explorer's own top-level windows (a folder window) are not reported.
- Also answered: NtUserGetClassName (explorer asks it of each task),
  NtUserInternalGetWindowText (explorer imports it), NtUserAttachThreadInput
  (both threads this process's, else 0), CallHwndLock 0x4C (user32's dialog
  creation trims the system menu of a WS_SYSMENU dialog with no size/min/max
  box: the host made its own, answered 1), SetForegroundWindow (0x4D) on
  another program of the screen raises it there (HWND_TOP, no activation).

**Start menu input: not solved (tried, reverted).** The menu filter is one
WH_GETMESSAGE hook from browseui (CMBMsgFilter, set on the tray thread at
popup). A posted WM_LBUTTONDOWN/UP on the Run item reaches the menuband
toolbar: it invalidates, notifies its parent (NM_CUSTOMDRAW, TB_GETBUTTONINFO
for 0x191), PeekMessage's for a drag; nothing runs and no hot item shows.
Two leads tried, neither changed anything, both reverted:
(1) a posted mouse message's MSG.pt is the host cursor, not its point: a
WH_GETMESSAGE thunk and GetMessage/PeekMessage setting pt = ClientToScreen
(lParam); (2) GetCapture is client-side NULL while gpsi+0x864 (cCaptures) is
0, else NtUserGetThreadState(2), which answers 0 (only 0x11 is answered;
focus 0 and active 1 are 0 too): set 0x864 = 1 and answered 2 from the host.
Next: `--calltrace` on the tray thread from the button-up, through comctl32's
toolbar WM_LBUTTONUP to browseui's CMenuToolbarBase (TBN_* / WM_COMMAND) and
see where it stops; GetThreadState 0/1 being always 0 is a likely suspect
(menuband checks focus), but answering them changes the 8 apps' runs.
Run is still reached with WM_COMMAND 0x191 to Shell_TrayWnd.

Not started: mydocs.dll, the My Computer icon.

interact (all 8, after the runtime change): winmine, notepad, calc, mspaint,
wordpad all 0 (wordpad's 337/930 did not show this time); freecell 4790/4790
(the known flake); sol deal 0 on a rerun, deck click 6593 both runs;
packager 10637 both runs, where the stage 1 reference shot is the half-drawn
one (PrintWindow's pane flake) and the lifted build is complete. sol's deck
click not looked at.

Registry: work/regsnap/before5.txt (before the first explorer run) and
after5.txt (after the last, final_24): identical (work/regsnap/snap.sh, the
four keys). The guest wrote only to its box.

Next: the Start menu's own input (above), then mydocs.dll / My Computer's icon.

### The Start menu takes real clicks (handoff)

pcrecomp 8c6700f (w2k). shots/exp (local): m20_8.png (Start menu open from a
click), m14_19.png (Run dialog opened by a click on the Run item, menu closed),
m20_23.png / m18_21.png (OK -> winmine framed, its taskbar button), m21_23.png
(My Computer selected on the desktop by a click).

**sol 6593: no regression.** Rerun: the lifted ntsol turns the 7th pile's card,
the stage-1 host sol.exe doesn't (as noted before). The stage-1 reference
fails to turn it some runs and not others (0 in the final run here).

**Root cause.** browseui's menu filter (CMBMsgFilter, WH_GETMESSAGE hook at
browseui 20D16197) only handles mouse messages while its flags at 0x20D7A158
have bit 0x10 set, which it sets on SetForegroundWindow(tray) and clears when
the tray gets WM_ACTIVATE(WA_INACTIVE) (IsMenuMessage, 20D020EE). Found with
`--poison 0x20D7A158` next to NATIVE32_SYSCALLS. The tray lost activation as
soon as explorer created any top-level window: SetParent onto the screen makes
the host activate it. Fixes:
- s_create_window: a thread WH_CBT hook refuses HCBT_ACTIVATE around the
  SetParent (win32k never activates at create).
- NtUserGetThreadState 0/1/2 = the host's GetFocus/GetActiveWindow/GetCapture
  (guest HWNDs are host HWNDs); SERVERINFO+0x864 (cCaptures) = 1 so GetCapture
  asks.
- The click then opened the Run dialog on its own thread, which hung in
  SetActiveWindow: NtUserAttachThreadInput had merged its host queue with the
  tray thread's, and the activation became a send to the tray thread, which
  was waiting for the dialog. Attach is now answered without merging.
- SPI_GETSELECTIONFADE is FALSE on the virtual screen: the chosen item's fade
  thread spun on UpdateLayeredWindow (a host child cannot be layered).
- explorer's own captioned, non-tool, unowned windows are tasks in shell_poll
  (own_task). Untested: a desktop double-click on My Computer selects it but
  opens no window yet.

Driven by run_explorer.sh with real clicks only: `--drag 35,580,35,580@6`
(Start), `--drag 90,509,90,509@10` (Run), `--childpost '#32770:0x111,1,0@14'`
(OK). No WM_COMMAND 0x191 any more.

**Gap: winmine's caption and menu bar stay grey.** The host has it active
(GetActiveWindow == it) but sends WM_NCACTIVATE(FALSE) while activating:
winmine's queue is not the desktop's foreground queue (another process). An
explicit SetActiveWindow + DefWindowProcW(WM_NCACTIVATE, TRUE) after
ShowWindow changed nothing (reverted). Next: give the launched program's
queue the foreground on the private desktop, or attach its input to the
screen thread (watch for the deadlock above).
Also: the selected My Computer icon draws black (selection blend).

interact (all 8, after the runtime change): every state 0, including sol
deck click, freecell, packager and wordpad (an own_task-only change followed;
it runs only with a shell hook registered, so the 8 apps don't reach it).
Run twice: once with GetThreadState only (packager 10637 / wordpad 337/930
at their known flake values, sol 0), once with all fixes (all 0).

Registry: work/regsnap/before6.txt / after6.txt. Differences only Win11's own:
UserAssist counters (Terminal, Chrome, Cortana) and GlobalAssocChangedCounter.
Control Panel and both Policies unchanged; the guest wrote only to its box.

Not started: mydocs.dll (needs adding to tools/lift_explorer.sh and a full
relift), My Computer's icon (generic icon: shell32 index lookup).
Next: a folder window opened by double-click (why the listview's DBLCLK does
nothing), then the launched program's active frame, then mydocs.dll.

### My Documents on the desktop; a double-click reaches the folder window (handoff)

pcrecomp f2f5b65 (w2k). shots/exp (local): w5_19.png (desktop with My
Documents, the launched winmine, its taskbar button), d4_17.png (before the
GetShellWindow fix: the double-click started a second explorer that became a
second shell).

- **mydocs.dll** lifted (tools/lift_explorer.sh, CMakeLists module list at
  0x21600000, reginst.py; its INF has `HKLM,key,,"My Documents"` with no flags
  field, now read as the value). My Documents shows on the desktop, first;
  My Computer moved to (38,106).
- **Double-click.** hiddenrun `--dblclick X,Y@T` posts down/up/DBLCLK/up (a
  posted click never becomes WM_LBUTTONDBLCLK). The listview then asked for
  the item's context menu and NtUserSetMenuDefaultItem was unanswered: no
  default verb, nothing opened. Answered (host + menu_sync; GetMenuDefaultItem
  is client-side).
- **The open verb starts explorer.exe** (Folder's ddeexec needs DDE, which the
  guest does not have; shell32 falls back to the command): `[launch] explorer
  -> build\ntexplorer.exe`. The second process read GetShellWindow (client-side,
  DESKTOPINFO +0x50) as NULL and became a second shell (its own tray/desktop
  thread; reported the first explorer's tray and Progman as tasks). SetShellWindowEx
  now also puts the shell HWND on the screen window (prop `pcrecomp.shell`);
  every process fills +0x50 from it. The second explorer then hands the
  folder to the first (WaitForInputIdle, AllowSetForegroundWindow 0x18 now 1)
  and exits.
- **The first explorer dies building the folder window.** Unlifted targets
  seeded and relifted (browseui 20D0EF78/20D10970, ole32 21006C14, shlwapi
  20914526). Runs alternate between (a) an RPC_S_SERVER_UNAVAILABLE (0x6BA)
  raised unhandled from rpcrt4 (NdrClientCall path; the epmapper connect is
  refused by design) and (b) a NULL path into user32!PrivateExtractIconsW from
  shell32 (via shdocvw, the browser frame's icon), right after SearchPathW /
  PathParseIconLocationW. Neither traced to its caller yet; both on the
  explorer process (pid printed now). The unhandled-exception report now lists
  guest code addresses on the raiser's stack, nthost's fault report too.
  `--calltrace` per thread + tools/calls.py finds the call sequence (work/ct_d.txt).
- setupapi.dll and linkinfo.dll (host) were proxied into the guest for the
  folder window: now refused like mpr.dll (`[guard] ... network/device/volume
  DLL: not mapped`). Next: lift Windows 2000's linkinfo (small) if shell32
  needs it to get past (b).
- **No folder window yet, so no C: view was opened**: the file-sandbox mapping
  of C: is still to do. Nothing in these runs listed a drive.

**Launched program's frame (not solved, reverted).** On WM_NCACTIVATE(FALSE)
to the screen's topmost captioned window that is its thread's active window,
tried: wParam forced TRUE to the guest, plus host DefWindowProc(NCACTIVATE,
TRUE); plus SetForegroundWindow on the private desktop only (guarded by
OpenInputDesktop name != thread desktop name). Hit every time (logged), the
caption and menu bar stay grey: the host's classic frame of a re-parented
top-level seems to follow the root window's (the screen's) activation, not
the queue. Next: draw the caption ourselves (DrawCaption DC_ACTIVE in
WM_NCPAINT) or activate the screen window itself.

**Black selected icon: not started** (a NATIVE32_SYSCALLS run is too slow for
the click to land; trace with --calltrace on ImageList_DrawIndirect instead).

interact (all 8, after the runtime changes): every state 0; first pass had
winmine click 86 / menu open size and mspaint missing (the build was still
linking), rerun 0.

Registry: work/regsnap/before7.txt / after7.txt. Control Panel and both
Policies unchanged. Explorer differs in RecentDocs (Win11-format entries:
shots/exp, m20_8.png, other host files: the host shell), Substrate,
UserAssist, GlobalAssocChangedCounter: the host's own. The guest wrote only
to its box.

Next: the folder window: trace (a)/(b) with --calltrace from the double-click,
then map C: to a sandbox root before the first drive view.

### The file box; the folder window opens; C: (handoff)

pcrecomp w2k 933423b, dfb1d7b, 8556a5c (+ the handoff commit). shots/exp
(local): folder_mydocs.png (a desktop double-click on My Documents: the
folder window with its tree), folder_mycomputer.png (My Computer: Local Disk
(C:) and Control Panel only), folder_drive_c.png (C: opened inside it:
Documents and Settings, Program Files, TEMP: the box's), b4_19.png (selected
icon blended, active caption), w5_23.png (Start -> Run -> winmine still works).

**The file box (pcrecomp syscall32.c, `PCRECOMP_FILEBOX=<dir>`).** The
guest's drives are directories: every drive path the guest names, `X:\rest`,
is `<box>\X\rest` in NtCreateFile, NtOpenFile, NtQueryAttributesFile,
NtQueryFullAttributesFile, NtDeleteFile and a rename/link target
(NtSetInformationFile 10/11). Rules, on the normalized name (any `.` or `..`
component is OBJECT_NAME_INVALID):
- under `<box>` itself: as it is;
- under a loader directory (the image's, the NLS directory, the runners'
  build/, the DLL path: the modules and, last, the host system directory for
  the proxies): **read-only files** (no write, delete, create, delete-on-close,
  no directory open, so no listing; FILE_WRITE_ATTRIBUTES is dropped, not
  refused: icon extraction asks for it). The guest's `C:\Windows\system32\x`
  is the modules' (then the runners') `x` when there is one, else the host
  system directory's file (the proxies: advapi32);
- every other absolute name is refused: `\Device\...` (KsecDD, GLOBALROOT),
  UNC, `\??\Volume{}`, pipes by name, `\SystemRoot`; CreatePipe's own
  `\Device\NamedPipe\Win32Pipes.*` passes;
- a relative open (RootDirectory) is relative to a handle the box gave; the
  current directory is `C:\` (the box's C, handle and DosPath).
Drive enumeration (ProcessDeviceMap) is the box's one-letter directories
(fixed); the volume label is empty and the serial the box's; `\??\X:`
symbolic links are not found (QueryDosDevice); FSCTL_SET_REPARSE_POINT is
refused (no junction out of the box). The guest's environment names box paths
as guest paths (`<box>\C\x` -> `C:\x`). run_explorer.sh puts the profile in
`work/profile/C/Documents and Settings/{user,all}` (profile.py writes the
Shell Folders as `C:\...`), TEMP in `C:\TEMP`, ProgramFiles at `C:\Program
Files` (Windows 2000's iexplore.exe there, as a file: never run).

**Check: tools/filebox_check.sh** (Windows 2000's cmd, lifted, in a box under
work/fbtest), 9/9: `dir /b C:\` lists only the box's two entries;
`C:\..\..\..` stays at the box's C:; D:, G:, `\?\GLOBALROOT\Device\
HarddiskVolume1\`, `\localhost\c$`, `\?\UNC\...` list nothing; `cd` is
`C:\`; `echo > C:\new.txt` lands in the box; a write to the host's build/
does not happen; `C:\Windows\system32` is not the host's; the modules
directory is not listed; `ver` still runs (the loader maps the modules).
Explorer's own view of C: (folder_drive_c.png) is the box's three folders.

**(a) RPC_S_SERVER_UNAVAILABLE raised unhandled.** Raiser: rpcrt4's
NdrClientCall2 (RpcRaiseException) under an ole32 MIDL stub (0x2100E190, to
rpcss, from the CoInitializeSecurity path); the guest SEH chain (now printed
in the unhandled report) holds only rpcrt4's own __finally and user32's
callback frame: Windows 2000's ole32 has no __except there (rpcss is always
up). native32 now guards the guest rpcrt4's NdrClientCall2/NdrClientCall: an
RPC status (0x6A4..0x7FF or its HRESULT) that no guest frame takes runs the
call's __finally blocks (an unwind) and returns the status from the stub, as
a [comm_status] procedure would (`[rpc] client call failed with 000006BA`).
The runs since: the line appears, explorer goes on.

**(b) The NULL/garbage icon path** was two things:
1. shdocvw sub_20E12126 reads `HKCR\http\DefaultIcon` into a stack buffer it
   never checks (SHGetValueW, PathParseIconLocationW, Shell_GetCachedImageIndex,
   ordinal 72). url.dll's registration code writes that key on Windows 2000;
   the host has none. reginst.py writes http/https/ftp DefaultIcon =
   `C:\Windows\System32\url.dll,0` (Windows 2000's url.dll in rebased-shell as
   a file).
2. `GetFileAttributesW("")` faulted in ntdll's __local_unwind2: a `return`
   out of RtlDosPathNameToNtPathName_U's __try runs its __finally through
   __local_unwind2, and that finally (AbnormalTermination) ends in code shared
   with the function's exit (`mov esp,[ebp-18h]` ... `ret 10h`). Lifted, it
   returned into __local_unwind2 with esp moved. Reproduced with the lifted cmd:
   `dir ""`. native32 finds every MSVC __local_unwind2 by its bytes in the
   guest modules; its funclet call undoes a moved esp (registers, fs:[0]) and
   the function's own continuation returns the same failure. `dir ""` lists.
linkinfo.dll: still refused, not needed so far.

**Other fixes found on the way.** Windows 2000's Folder/Directory/Drive verbs
in the box (HIVECLS): the host's `Folder\shell\open\command` has no
arguments, so every folder opened as My Documents; now `Explorer.exe
/idlist,%I,%L` and My Computer opens My Computer. My Computer's NameSpace key
in the box (the host's 11 Win11 items were nameless folders). App Paths name
`C:\Windows\System32\nt<app>.exe` (a host path on a drive the guest does not
have made the shell treat it as 8.3: `ntwinmin.exe`, nothing launched).
hiddenrun `--dblclick "TITLE:X,Y@T"` (client coordinates of a screen window;
the folder window's place varies run to run). `[launch]` prints the command.

**Black selected icon: fixed.** comctl32's ImageList_DrawIndirect with
ILD_SELECTED on a palettized image list copies through StretchDIBits with the
colour table from GetDIBColorTable = NtGdiDoPalette, which was unanswered
(NOT SHIMMED, a zero table: black). w32kgdi answers NtGdiDoPalette (iFunc 0-5,
Windows 2000's numbering: 4 GetDIBColorTable, 5 SetDIBColorTable).

**Active caption: drawn ourselves.** After the host's DefWindowProc paints a
screen window's frame (WM_NCPAINT/NCACTIVATE/SETTEXT), the screen's topmost
captioned window gets its caption repainted: the box's ACTIVECAPTION to
GRADIENTACTIVECAPTION gradient, small icon, Tahoma bold in CAPTIONTEXT, left
of the caption buttons (WM_GETTITLEBARINFOEX). The folder window and the Run
dialog are Windows 2000 blue now. Gap: winmine (its own process) shows the
host's light active caption, and its menu bar stays grey.

interact (all 8, after the runtime changes): every state 0 (winmine 7,
notepad 2, sol 2, freecell 2, packager 1, wordpad 2, calc 2; mspaint's two
missing on the first pass, 0/0 rerun).

Registry: work/regsnap/before8.txt / after8.txt. Control Panel and both
Policies unchanged. Explorer differs only in the host shell's own keys
(UserAssist, FeatureUsage\AppLaunch, SessionInfo, GlobalAssocChangedCounter,
Discardable\PostSetup): the host's activity. The guest wrote only its box.

Next: winmine's caption/menu bar (its own process: the active caption is
the host's light one; its menu bar is drawn inactive); the folder window's
place (cascade) varies run to run; "Disk free space" is the host volume's
(fake the box's in FileFsSizeInformation); the host HKCR still answers what
the box lacks (imageres.dll icons asked for); linkinfo.dll not yet needed.

### Pipes, launched programs' frames, free space, Accessories, HKCR (handoff)

pcrecomp w2k b38cf5a + the commit after it. shots/exp (local):
startmenu_accessories.png (Start -> Programs -> Accessories from the private
profile, Windows 2000's own icons), accessories_notepad.png (Notepad launched
from there by real clicks), winmine_active.png (Start -> Run -> winmine: blue
caption, black menu bar), w9_c6_23.png (C: again; My Computer and Recycle Bin
now draw Windows 2000's icons).

**Pipes never worked: not a sandbox regression.** The guard that refuses a
non-lifted image section (and NtCreateProcess) came in with the first boot
(pcrecomp 530efea); cmd's child for `echo hi | find "hi"` is cmd.exe, which
is refused with or without PCRECOMP_FILEBOX (shown on HEAD with the box off:
hard error on `C:\Windows\system32\cmd.exe`). Now:
- CreateProcessW/A is the launch path in every nthost build (not only the
  user-layer ones): build\nt<name>.exe, else build\<name>.exe (cmd, find,
  more); the guest's inherit flag and STARTF_USESTDHANDLES handles are passed
  (guest handles are host handles), creation flags only CREATE_SUSPENDED (the
  shell asks CREATE_NEW_CONSOLE; the runner logs to our stderr). The child gets
  `--raw` and the rest of the command line as it is (quotes kept: `find "hi"`).
- find.exe and more.com lifted on lifted ulib.dll (work/rebased-util,
  ulib at 0x20300000): `build\find.exe`, `build\more.exe`.
- The file box refused CreatePipe's own pipe: the `\Device\NamedPipe\
  Win32Pipes.` prefix is 29 characters, the check compared 30.
- cmd's program search lists PATH directories; the guest's system32 is not
  listable, so `PCRECOMP_GUEST_PATH` adds guest directories to the guest's
  Path, and the runners put names in the box's `C:\WINNT\system32` (find.exe,
  more.com placeholders; profile.py copies Windows 2000's accessory exes there
  as files for their icons: never run, the launch path starts by name).
`echo hi | find "hi"`, `find /c`, `dir | find /i`, `| more`, `||` on a miss
all work; filebox_check.sh 11/11 (a pipe to more in the box; free space).

**winmine's frame (its own process).** The light caption was the host's
colours: winmine's registry box had no Control Panel\Colors. A program a guest
launches now shares its launcher's box (`W2K_REGBOX`, one HKCU as on Windows
2000). Its menu bar was greyed by the host (not the foreground queue): the
screen's windows get their menu bar text redrawn in MENUTEXT on MENU after the
host's frame paint (w32kuser screen_menubar). hiddenrun: `HIDDENRUN_DESKTOP`
names the private desktop (another tool's DISPLAY.DRV window on the shared
`pcrecomp_hidden` desktop was screenshotted instead of ours twice).

**Free space** (FileFsSizeInformation / FileFsFullSizeInformation): a fixed
4 GB disk, 2.5 GB free (ponytail), `dir` says 2,684,354,560 bytes free.

**Accessories.** profile.py writes Windows 2000-style .lnk files (only a
target ID list: My Computer, C:\, 8.3 items; no LinkInfo, linkinfo.dll is not
in the guest) into All Users\Start Menu\Programs\Accessories (+ Games). The
first click showed "This file does not have a program associated": the box
had no `.lnk`/`lnkfile` and the shell link class {00021401} had no
InProcServer32. reginst.py now takes HIVECLS's lnkfile/.lnk/exefile/.exe and
every HIVECLS class a lifted DLL serves, writes named empty values
(IsShortcut), and maps `%SystemRoot%\x.exe` to the guest's system32 (My
Computer's Explorer.exe,0). Start -> Programs -> Accessories -> Notepad by
real clicks launches ntnotepad on the screen.

**HKCR.** regbox32: a class the box has (Classes\<name>, also under
WOW6432Node and the per-user _Classes) is answered by the box alone; the
host's subkeys and values under it are not seen. The per-user
`Explorer\CLSID\` overrides are hidden like CLSID (the Recycle Bin's imageres
icons came from HKCU there). `PCRECOMP_REGTRACE` also prints every host key
read. No imageres.dll request in the last runs; host-only classes (htmlfile,
.htm) still read through.

interact (all 8): every state 0 (winmine's click 21 pixels on the first pass,
0 on a rerun: its timer). filebox_check.sh 11/11.
Registry: work/regsnap/before9.txt / after9.txt: only the host's own
SessionInfo\ApplicationViewManagement and UserAssist counters changed;
Control Panel and both Policies unchanged.

Gaps: the Internet Explorer desktop item (now shown, from Windows 2000's data)
has a generic icon (iexplore.exe as a file is in Program Files, its CLSID's
icon path not mapped); winmine's frame borders are the host's; the guest's
environment block and directory are not passed to a child (ours, C:\);
`start` (a new console) runs in ours; NtUserSendMessageCallback is unshimmed.
Next: the IE icon, `Control Panel` from My Computer, a child's environment.

### Control Panel, its applets, a child's environment, host settings (handoff)

pcrecomp w2k 53b351b. shots/exp (local): cp10_29.png
(My Computer -> Control Panel: Administrative Tools, Date/Time, Display,
Keyboard, Mouse, Printers, Fonts; the Internet Explorer desktop icon now
Windows 2000's blue e), td11_52.png (Start -> Run -> `rundll32
shell32.dll,Control_RunDLL timedate.cpl`: Date/Time inside the virtual screen),
rd4_33.png (Date/Time, day 1 and Apply: `[guard] NtSetSystemTime: a host
setting, refused`), ms1_37.png (Mouse), kb1_37.png (Keyboard).

**A child's environment and directory.** The launch path (nthost.c) passes the
guest's environment block (its own from the guest PEB, or the one it passed;
A or W) and current directory (lpCurrentDirectory, else the guest's) as
PCRECOMP_GUEST_ENV (entries split by U+0001) and PCRECOMP_GUEST_CWD; the
child's process parameters (syscall32.c) take them. The child runner's HOST
environment stays the launcher's, so a guest `set PCRECOMP_FILEBOX=` or Path
never reaches a host loader; a guest directory is used only if it is a box
drive path with no `..`. filebox_check 13/13: `cd C:\inbox_dir & set
FBVAR=guestval & cmd /c "cd & echo %FBVAR%"` prints both; a write after `cd`
into a loader directory does not land.

**Host settings guarded at the system call** (syscall32.c): NtSetSystemTime
with a new time, every NtSetSystemInformation class (time zone, time
adjustment), NtSetDefaultLocale/UILanguage, shutdown/power, drivers, firmware
variables: STATUS_PRIVILEGE_NOT_HELD, logged. SeSystemtimePrivilege
(NtAdjustPrivilegesToken) reports enabled in the guest only, so Date/Time
opens (it refused itself before); its Apply hits the refusal. win32k:
NtUserChangeDisplaySettings refused unless CDS_TEST (DISP_CHANGE_FAILED);
SystemParametersInfo SETs were already refused; NtUserEnumDisplayDevices /
EnumDisplaySettings answered read-only (the current mode is the virtual
screen's size). NtUserSendMessageCallback: own windows sent now, the guest's
callback called with the result; broadcasts and other processes' windows
dropped. Lifted cmd's `time`/`date` already failed at the host token's
privilege check; the guard is the second layer (and the only one for the time
zone, which an ordinary user's token allows).

**Control Panel.** shell32 lists `HKLM\...\Control Panel\CPLs` paths with
FindFirstFile on each (and `*.CPL` in system32). The file box refused every
directory open in a loader directory; now a loader directory's handle is
allowed but NtQueryDirectoryFile on it answers one exact name only (a
wildcard or a NULL name is refused / no more files, logged), and it is never
the root of a relative open or rename. reginst.py writes CPLs (timedate, desk,
main), InProcCPLs, an empty ControlPanel\NameSpace (the two nameless host
folders remain: subkey enumeration still merges the host's), and empty
NetworkProvider\Order/HwOrder (Windows 2000's mpr loaded the host's ntlanman,
p9np, drprov, dokan providers before that: the run failed the host-module
check, now clean).
Lifted into ntexplorer and ntrundll32 (work/rebased-shell, from the CD):
timedate.cpl 0x21700000, imm32 0x21800000, main.cpl 0x21900000, comdlg32
0x21A00000, mpr 0x21B00000, devmgr.dll 0x21C00000 = our stand-in
(src/stub/devmgr.c, tools/devmgr_stub.cmd: DeviceCreateHardwarePage returns
NULL; Windows 2000's devmgr pulls setupapi/cfgmgr32/wmi).
**TlsFree** ended in NtSetInformationThread(ThreadZeroTlsCell) forwarded to
the host, which zeroed that slot in every HOST thread (comdlg32's detach after
Control Panel freed main.cpl: a fault in TlsFree, explorer gone). Now the
guest's slot in this thread's guest TIB (ponytail: other guest threads keep a
stale value).
**rundll32**: build\ntrundll32.exe (its own lift: rundll32.exe has no
relocations) on the same modules; the launch path starts it for
`rundll32 shell32.dll,Control_RunDLL x.cpl`. A comctl32 function reached by
the Run box's autocomplete was unlifted (ICALL 0x20823000): seeded.

Gaps / next:
- A double-click on an applet in the Control Panel window selects it and
  nothing more: shell32's CPL invoke (sub_20A7A107, the InProcCPLs check) is
  never entered (calltrace work/ct_td.txt); DefView's default-command path for
  the CP items is the place to look. Start -> Run with the rundll32 line works.
- Display: desk.cpl shows a message box that lays out at 16x39 (MessageBox
  from a lifted user32 in a rundll32 runner: SoftModalMessageBox's template
  size; timedate's privilege box had the same size). Its text is not known yet.
- rundll32.exe imports imagehlp: the host's imagehlp.dll is proxied into
  ntrundll32 (startup lines, so run_explorer's check skips them). Lift Windows
  2000's imagehlp next; not reviewed for the ALLOW list.
- Mouse/Keyboard draw without their tab strip; Keyboard asks for intl.cpl
  (host's refused: lift Windows 2000's for Input Locales).
- Date/Time's time zone line reads the host's MUI string (@tzres.dll,-212).
- `start` (CREATE_NEW_CONSOLE): a new console window on the virtual screen
  would need a guest-drawn console window (conhost is the host's): not cheap;
  the child still runs in the launcher's console.

### No host DLL in any guest process; message boxes; Display; the Control Panel double-click (handoff)

pcrecomp w2k 1935e5d. shots/exp (local): dp16_43.png
(Display Properties, Settings: 800 by 600, Apply refused), dp12_37.png (the
message box laid out: Display's old "driver" warning), cpf_37.png (Control
Panel, double-click on Date/Time: opens in explorer, tabs, "Current time
zone: Pacific Standard Time"), s_*.png (the strict-check scenarios).

**The host-module check covers every process.** run_explorer.sh no longer
skips a launched program's startup lines: any `HOST DLL in the guest` but
advapi32 fails the run. It then found, besides imagehlp in ntrundll32:
winmine (shell32, winmm), notepad (comdlg32, shell32, winspool), cmd (user32),
find/more (user32, through ulib). All lifted now:
- imagehlp (Windows 2000's, 0x21D00000) in ntrundll32.
- tools/lift_accessories.sh: the nine accessories on work/rebased-shell with
  the shell's module set plus winmm 0x21E00000, winspool.drv 0x21F00000,
  olecli32 0x22000000, olesvr32 0x22100000, nddeapi 0x22200000 (W2K_ACC_MODS
  in CMakeLists). cmd, find, more on lifted user32/gdi32 (W2K_USER_LAYER);
  ulib re-based to 0x22300000.
- lift.py re-catalogues a module whose base moved: ulib's old catalogue
  (0x20300000) lifted 0 functions silently (more: ICALL 0x2230D358).
Scenarios (work/scen.sh, all with the strict check): desktop, Run winmine,
Run notepad, Run `cmd /k echo hi | find "hi"`, Run rundll32 timedate / main /
main,@1 / desk, My Computer, Control Panel double-click on Date/Time and on
Display: all PASS. Delay-loads (winspool's ole32/netapi32, mfc42u's wininet,
winmm's drivers) are not lifted; reaching one fails the check (as it should).

**Message boxes** (pcrecomp w32kuser.c server_info): SoftModalMessageBox reads
SERVERINFO +0x808/+0x80C cxMsgFontChar/cyMsgFontChar, +0x854/+0x858
hCaptionFont/hMsgFont, +0x1D8 wMaxBtnSize, +0x1DC MBStrings[11] (0x28 each:
szName[16], uID, uStr). All were 0 (16x39). The fonts must be guest GDI
handles: server_info runs before gdi32's table exists, so msg_fonts() maps
them on a later win32k call (a host handle made the template's 0x7FFF font
GetObjectW fail: a garbage LOGFONT, a 16115-pixel dialog). PlayEventSound
(CallOneParam 0x25) answered silent.

**Display** (desk.cpl): "configuration parameters ... invalid" was a mode with
fields beyond BITSPERPEL|PELSWIDTH|PELSHEIGHT|DISPLAYFLAGS|DISPLAYFREQUENCY
(desk 0x214128ED); then "driver can not be used" was the host's second,
detached adapter with no modes. On a virtual screen the guest now sees one
adapter (the host's primary) and a Windows 2000 list (its size, 640x480 ..
1280x1024, host depth, 60 Hz). ChangeDisplaySettings stays refused but
CDS_TEST. hostsettings.py before/after a Display run: unchanged. The posted
click on the Screen area slider did not move it (Apply never enabled), so the
refusal path itself was not reached this time.

**The Control Panel double-click.** CDefFolderMenu::QueryContextMenu with
CMF_DEFAULTONLY (shell32 0x20A23470) deletes item 0 when GetMenuState has
MF_SEPARATOR: GetMenuState answered -1, the merged menu was empty on the
host. Shell_MergeMenus copies items with fMask 0x1FF (MIIM_TYPE with
FTYPE/STRING/BITMAP): Windows 2000 took it, Windows 11 answers
ERROR_INVALID_PARAMETER. NtUserThunkedMenuItemInfo drops MIIM_TYPE when the
newer bits are there (and logs a failed insert). Date/Time and Display open
in explorer (InProcCPLs), with their tab strips.

**Time zone.** NtQuerySystemInformation(44) names the zone with the host's
resolved names (Windows 11's kernel gives `@tzres.dll,-212`); reginst.py
seeds Windows 2000's Time Zones (HIVESFT.INF) and regbox32 answers Time
Zones and Control Panel's NameSpace (HKLM and HKCU) from the box alone.

interact (all 8, after the runtime changes): winmine, notepad, calc,
packager 0; freecell 0 / 4790 between runs (timing); sol deal 6593 (its
last pile's top card still face down at the shot), deck click 0; mspaint
6112 and wordpad 5555/6148: the lower panes sit 2 px lower. These two (and
probably sol) now load Windows 2000's comctl32 (through shell32) where the
stage 1 baseline has the host's: the status bar's height. Not yet checked
which way is Windows 2000's.

Gaps / next:
- The two nameless folders in Control Panel are not from any NameSpace key
  (regtrace: none read after the box-only change); find their source.
- Keyboard's Input Locales asks for intl.cpl: Windows 2000's imports
  setupapi, syssetup, userenv (none lifted; the host's are refused).
- Mouse/Keyboard tab strips through rundll32 (in-proc ones draw theirs).
- The interact baselines for mspaint/wordpad/sol (above).
- Display's Apply path with a moved slider (keyboard into the trackbar).

### interact goldens; Display's Apply refused end to end; Control Panel's nameless folders (handoff)

pcrecomp w2k 76881a8. shots/exp (local): dap_37.png (Settings, slider moved to 640 by
480, Apply enabled), dap_42.png (Windows 2000's "will now apply your new desktop settings"),
dap_47.png ("The display control panel is unable to change the display settings"), cp12_27.png
(Control Panel: Administrative Tools, Date/Time, Display, Fonts, Keyboard, Mouse, Printers).

**interact's gate is the lifted builds' approved goldens.** mspaint/wordpad load Windows
2000's own comctl32 (through shell32) and the stage 1 builds the host's; the lifted build is
the faithful one. tools/interact.py prints two columns: `stage1` (informational) and `golden`
(the gate, exit 1 on a difference or a missing golden). The goldens are local PNGs in
shots/golden; tools/golden.json (committed) holds each one's RGB sha256 (sol without its status
bar). A hash mismatch still passes as `0 (+-2)` when no channel differs from the golden PNG by
more than 2 (the host's ClearType drifts by 1 between sessions: calc's "0." moved by 1 in both
builds). **Re-approving**: run the apps, check each new lifted shot by eye (Read tool), then
`py -3 tools/interact.py --approve [app ...]` and commit tools/golden.json.
Recording them showed three apps whose settle caught a frame before their last paint (sol's
last pile still face down, freecell without "Cards Left", packager without its Appearance pane):
those hold 3 s instead of 1.5. Since: 20/20 golden in four runs (one with the calc drift); one run under load had wordpad
hang before its window (no shot in 22 s) and winmine's posted menu key missed; both clean in
two reruns of those apps. An intermittent wordpad startup hang is open.
Known harness quirks in the goldens, the same on the host build: winmine's `custom 20x30`
dialog still shows 16/16/40.

**Display's Apply.** `rundll32 shell32.dll,Control_RunDLL desk.cpl,,3` (Settings); VK_LEFT
posted to the trackbar (hiddenrun `--childpost ~msctls_trackbar32:...`: a point lands on the
"Screen area" group box, first in z-order), WM_COMMAND 0x3021 (Apply) to the sheet, Enter to
the confirmation box. Its OK faulted in MB_DlgProc: the MSGBOXDATA is in GWL_USERDATA, and
NtUserSetWindowLong(-21) was unanswered while the guest's GetWindowLong reads WND+0x94. Now
stored there (pcrecomp w32kuser.c). Then `[user] ChangeDisplaySettings (flags 10000051): the
host's display mode, refused` and desk.cpl's own failure box. hostsettings.py before/after:
unchanged. In work/scen.sh as s_dap (strict check: PASS).

**The nameless folders** were shell32's own required Control Panel regitems, CLSIDs in its
code: Scheduled Tasks {D6277990-...} (mstask.dll) and Network and Dial-up Connections
{7007ACC7-...} (netshell.dll); regtrace showed their CLSID\...\ShellFolder reads. Neither server
is lifted (both reach host services), so no name. reginst.py gives both ShellFolder Attributes
SFGAO_NONENUMERATED (0x00100000) in the box, Windows 2000's own way to keep a regitem out of
a listing.

**intl.cpl not lifted** (Keyboard's Input Locales stays out). It needs setupapi (INF parsing
and file queues), syssetup (SetupChangeLocaleEx) and userenv. syssetup imports 123 setupapi
functions, most of them device and class installation (SetupDi*, CMP_WaitNoPendingInstallEvents),
plus powrprof, sfc, sfcfiles and netapi32; setupapi imports rpcrt4 for the PnP manager. That
chain is device, power and service code; not lifted, by the rule that none of it may reach the
host's devices or services. A stand-in (like devmgr's) for syssetup and userenv, with
Windows 2000's setupapi INF code alone, would be the way if Input Locales is wanted.

Regression after the runtime change: work/scen.sh 12/12 PASS (strict check), hostsettings
unchanged across it, filebox_check 13/13, interact 20/20 golden, registry
(work/regsnap/after11 -> after12): only the host's UserAssist counters.

Gaps / next:
- Date/Time (cp11_29.png): today's date not drawn in the month calendar; the clock's hands
  leave cyan trails.
- Mouse/Keyboard tab strips through rundll32 (in-proc ones draw theirs).
- Scheduled Tasks / Network and Dial-up: hidden, not lifted.

### Date/Time draws right; charmap, Sound Recorder, Help in explorer (handoff)

shots/exp (local): td5_27.png (Date/Time: today's 16 highlighted, the clock without trails),
x_charmap_31.png (Character Map), x_sndrec32_31.png (Sound Recorder, no device),
x_winhlp32_31.png (winhlp32 showing Windows 2000's charmap.hlp).

**The clock's cyan trails.** timedate draws and erases its fat hands with Polygon under
its own ROP2 (0x21702390: SetROP2(hdc, mode), then Polygon). NtGdiPolyPolyDraw drew on the
bare host DC (HOST(), not dc()), so the guest's ROP2, pen and brush never reached it: every
erase drew a new hand. Now through dc() (fn 6, CreatePolyPolygonRgn, takes a fill mode);
PolylineTo/PolyBezierTo give the pen position back (pcrecomp w32kgdi.c).

**Today's date not drawn.** timedate's calendar draws the selected day with ExtTextOutW, no
options, after SetBkColor(COLOR_ACTIVECAPTION)/SetTextColor(COLOR_CAPTIONTEXT): the OPAQUE
background mode makes the blue cell. gdi32's TextOut batch entry (+0xC) takes the mode as
`lBkMode (DC_ATTR +0x4C) == OPAQUE ? 2 : 1`; GetBkMode reads +0x4C too; SetBkMode writes
both +0x4C and jBkMode +0x39. A new DC_ATTR filled only +0x39, so every fresh DC batched
TRANSPARENT: white on white. +0x4C (and lFillMode +0x50, lStretchBltMode +0x54) now filled.
Side effect, Windows 2000's look: the status bars' size grip now draws (mspaint, wordpad;
goldens re-approved after checking by eye).

**New programs** (tools/lift_accessories.sh charmap sndrec32 winhlp32; CMakeLists):
getuname 0x22400000, msacm32 0x22500000; each exe through rebase.py on its own (their bound
imports pointed at kernel32's and msvcrt's linked bases: faults at 0x7C4FEB3A, 0x7800776E).
- charmap: needs riched20 (its font box) and a kernel32 ITAIL seed (0x201558F3, code page
  enumeration; work/seeds/kernel32.dll.json). Enumerating code pages loads the host's
  converter DLLs named in Nls\CodePage (c_is2022, c_g18030, c_gsm7, c_iscii): refused at the
  guard now (pcrecomp syscall32.c), the code page reads as not installed. Its font list is the
  host's fonts (8514oem first).
- sndrec32 under PCRECOMP_MUTE: pcrecomp native32_mute_winmm() answers the lifted winmm's
  *GetNumDevs 0 and wave/midi/mixer opens MMSYSERR_NODRIVER; Sound Recorder shows Windows
  2000's own "a sound device is not installed". No host audio device is opened.
- winhlp32 C:\WINNT\Help\charmap.hlp (run_explorer.sh expands CHARMAP.HL_ there) shows the
  topic. Standalone (interact) it opens comdlg's Open box with black places-bar icons outside
  the profile: not a golden.
- Clipboard Viewer: Windows 2000's clipbrd is ClipBook, NetDDE (a network service): its own
  error 0x400F. Not brought further (network).
- cmd in a window: not done; a console window would be a guest-drawn conhost (see above).
Typing `charmap` into Run autocompleted to an earlier `winhlp32 ...charmap.hlp` MRU entry;
scen.sh types `charmap.exe`. interact: charmap start added (21 goldens); sndrec32 left out
(the host places its message box differently each run).

**Mouse/Keyboard tab strips through rundll32**: they draw (s_ms, s_kb shots); fixed by the
earlier lifted-comctl32 work. The trackbars' white backgrounds remain.

**wordpad's startup hang**: 47 runs of interact wordpad during lifts and builds, none hung
(one hang in the first 6, before this, its log was lost: hiddenrun's last limit, 22 s, came
before the guest's watchdog, 25 s). interact's watchdog is now 2 x the last step - 1 s, so a
hang leaves its watchdog dump (lock owners, last calls) in shots/wp_ntwordpad.log. Not found.

Gaps / next:
- The wordpad hang: wait for one with the watchdog dump.
- charmap's fonts are the host's; Windows 2000's own font list would need the guest's fonts.
- Trackbar backgrounds white in Mouse/Keyboard; Clipboard (NetDDE); console windows.
