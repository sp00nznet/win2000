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
