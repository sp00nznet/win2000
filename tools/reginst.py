#!/usr/bin/env python3
"""Seed a lifted program's registry box with Windows 2000's own COM classes.

    py -3 tools/reginst.py BOX DIR DLL...    (e.g. w2k\\explorer work/rebased-shell browseui shell32)

Each DLL's REGINST resource (the INF its DllRegisterServer hands to advpack)
is read, and its HKCR CLSID\\ and AppID\\ lines are written under
HKCU\\Software\\pcrecomp\\BOX\\HKLM\\SOFTWARE\\Classes: with a lifted ole32
only the box answers those keys (pcrecomp regbox32.c), never the host's.
The server path (%_SYS_MOD_PATH%) is the DLL in DIR, a lifted module's name.
Also the INFs' HKLM ...\\NameSpace lines (the desktop's and My Computer's items).
ponytail: the other HKLM extras (approved shell extensions,
ShellCompatibility) are left out until something asks for them.
"""
import csv, os, re, sys, winreg
import pefile

def reginst(path):
    p = pefile.PE(path, fast_load=True)
    p.parse_data_directories([pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_RESOURCE']])
    for t in getattr(p, 'DIRECTORY_ENTRY_RESOURCE', type('', (), {'entries': []})).entries:
        if t.name and str(t.name) == 'REGINST':
            e = t.directory.entries[0].directory.entries[0].data.struct
            return p.get_data(e.OffsetToData, e.Size).decode('latin-1')
    return ''

def lines(inf, mod):
    sec, strs = {}, {'_SYS_MOD_PATH': mod, '_MOD_PATH': mod}
    if mod: strs['11'] = os.path.dirname(mod)   # LDID 11, the system directory (LocalizedString's @%11%\shell32.dll,-8964): the lifted modules' own
    cur = None
    for l in re.sub(r'\\[ \t]*\r?\n\s*', '', inf).splitlines():   # INF line continuations
        l = l.split(';')[0].strip() if not l.strip().startswith('"') else l.strip()
        if l.startswith('['): cur = sec.setdefault(l[1:l.index(']')].lower(), [])
        elif l and cur is not None: cur.append(l)
    for l in sec.get('strings', []):
        m = re.match(r'(\w+)\s*=\s*"?(.*?)"?$', l)
        if m: strs[m.group(1)] = m.group(2)
    sub = lambda s: re.sub(r'%(\w+)%', lambda m: strs.get(m.group(1), m.group(0)), s)
    for l in [x for k, v in sec.items() if k != 'strings' and 'del' not in k for x in v]:
        f = [x.strip() for x in next(csv.reader([sub(l)], skipinitialspace=True))]
        if len(f) >= 2 and f[0].upper() == 'HKCR' and re.match(r'(CLSID|AppID)\\', f[1], re.I):
            yield f + [''] * (5 - len(f))
        # the shell's namespaces (Desktop, MyComputer, ...\NameSpace): with the box's own key the
        # host's is never enumerated (Win11's 33 desktop items were nameless folders on the desktop)
        elif len(f) >= 2 and f[0].upper() == 'HKLM' and re.search(r'\\NameSpace\\', f[1], re.I):
            yield f + [''] * (5 - len(f))

def hive_items(iso, dlls):
    """HIVESFT's Desktop\\NameSpace items served by one of DLLS, and HIVECLS's lines for those
    classes (Recycle Bin is shell32's, but HIVECLS registers it, not shell32's REGINST)."""
    rd = lambda f: open(os.path.join(iso, f), encoding='latin-1').read() if os.path.exists(os.path.join(iso, f)) else ''
    cls = list(lines(rd('HIVECLS.INF'), ''))
    srv = {x[1].split('\\')[1].upper(): x[4].lower() for x in cls
           if x[1].upper().endswith('\\INPROCSERVER32') and not x[2]}
    ns = [x for x in lines(rd('HIVESFT.INF'), '') if re.search(r'Desktop\\NameSpace\\\{.*\}$', x[1], re.I)
          and srv.get(x[1].rsplit('\\', 1)[1].upper(), '').replace('.dll', '') in dlls]
    want = {x[1].rsplit('\\', 1)[1].upper() for x in ns}
    return ns + [x for x in cls if x[1].split('\\')[1].upper() in want]

def main():
    box, d, dlls = sys.argv[1], sys.argv[2], sys.argv[3:]
    root = r'Software\pcrecomp\%s\HKLM\SOFTWARE\Classes' % box
    n = 0
    for dll in dlls:
        f = os.path.abspath(os.path.join(d, dll if '.' in dll else dll + '.dll'))
        items = list(lines(reginst(f), f))
        if dll == dlls[-1]:
            items += hive_items(os.path.join(os.path.dirname(__file__), '..', 'work', 'iso', 'I386'), [x.lower() for x in dlls])
        for hive, key, name, flags, val, *data in items:
            fl = int(flags, 0) if flags else 0
            # %SystemRoot%\System32\x.dll or a bare x.dll is the lifted module in DIR, never the host's
            val = re.sub(r'(?i)^(%SystemRoot%\\System32\\)?(\w+\.dll)',
                         lambda m: os.path.join(os.path.abspath(d), m.group(2)), val)
            # so is a file in an INF directory (LDID 10/25 Windows, 11 System32): My Computer's %25%\Explorer.exe,0
            val = re.sub(r'(?i)^%(?:10|11|25)%\\(\w+\.(?:dll|exe))',
                         lambda m: os.path.join(os.path.abspath(d), m.group(1).lower()), val)
            at = root if hive.upper() == 'HKCR' else r'Software\pcrecomp\%s\HKLM' % box
            with winreg.CreateKey(winreg.HKEY_CURRENT_USER, at + '\\' + key) as k:
                if fl & 1 and fl >> 16 == 3:                     # REG_BINARY, its bytes across the fields
                    winreg.SetValueEx(k, name or None, 0, winreg.REG_BINARY, bytes(int(x, 16) for x in [val] + data if x))
                elif fl & 1 and fl & 0x10000: winreg.SetValueEx(k, name or None, 0, winreg.REG_DWORD, int(val or '0', 0))
                elif not (fl & 0xFFFF0000 == 0 and fl & 2 and val == ''):
                    winreg.SetValueEx(k, name or None, 0, winreg.REG_EXPAND_SZ if fl & 0x20000 else winreg.REG_SZ, val)
            n += 1
    print('%d class lines into HKCU\\%s' % (n, root))
    # App Paths for each lifted program's runner (build\nt<name>.exe): the Run dialog's
    # "winmine" resolves there, and the host's launch guard starts only those
    b = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'build'))
    ap = r'Software\pcrecomp\%s\HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths' % box
    for f in os.listdir(b):
        if re.match(r'nt\w+\.exe$', f) and f != 'ntexplorer.exe':
            with winreg.CreateKey(winreg.HKEY_CURRENT_USER, ap + '\\' + f[2:]) as k:
                winreg.SetValueEx(k, None, 0, winreg.REG_SZ, os.path.join(b, f))

if __name__ == '__main__':
    main()
