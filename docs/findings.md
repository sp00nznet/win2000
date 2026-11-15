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
