#!/usr/bin/env python3
"""A private Windows 2000 profile for a lifted shell, so it never walks the
host's (the host's Start Menu, Desktop and their programs' icons).

    py -3 tools/profile.py BOX DIR      (e.g. w2k\\explorer work/profile)

Makes DIR/user and DIR/all with Windows 2000's folder names, and writes the
shell folder values (User Shell Folders as %USERPROFILE%/%ALLUSERSPROFILE%
paths, Shell Folders expanded) into the box under
HKCU\\Software\\pcrecomp\\BOX\\{HKCU,HKLM}: the box answers a value before the
real key (pcrecomp regbox32.c). The runner points USERPROFILE and
ALLUSERSPROFILE at DIR/user and DIR/all (tools/run_explorer.sh).
Also Windows 2000's own colour scheme (HIVEDEF.INF's HKCU Control Panel\\Colors,
from work/iso/I386): the emulated win32k takes the box's colours (pcrecomp w32kuser.c).
ponytail: Windows 2000's names only; a host-only value (a GUID-named folder)
still falls through to the host's key, which Windows 2000's shell32 never asks for.
"""
import os, re, sys, winreg

USER = {'AppData': r'Application Data', 'Cookies': 'Cookies', 'Desktop': 'Desktop', 'Favorites': 'Favorites',
        'NetHood': 'NetHood', 'Personal': 'My Documents', 'My Pictures': r'My Documents\My Pictures',
        'PrintHood': 'PrintHood', 'Recent': 'Recent', 'SendTo': 'SendTo', 'Start Menu': 'Start Menu',
        'Programs': r'Start Menu\Programs', 'Startup': r'Start Menu\Programs\Startup', 'Templates': 'Templates',
        'Local Settings': 'Local Settings', 'Local AppData': r'Local Settings\Application Data',
        'History': r'Local Settings\History', 'Cache': r'Local Settings\Temporary Internet Files'}
COMMON = {'Common Desktop': 'Desktop', 'Common Start Menu': 'Start Menu', 'Common Programs': r'Start Menu\Programs',
          'Common Startup': r'Start Menu\Programs\Startup', 'Common Documents': 'Documents',
          'Common AppData': 'Application Data', 'Common Favorites': 'Favorites', 'Common Templates': 'Templates'}
EXP = r'Software\Microsoft\Windows\CurrentVersion\Explorer'

def seed(box, hive, var, base, folders, guest):
    root = r'Software\pcrecomp\%s\%s\%s' % (box, hive, EXP)
    for key, kind, fmt in (('User Shell Folders', winreg.REG_EXPAND_SZ, '%%%s%%\\%s'), ('Shell Folders', winreg.REG_SZ, None)):
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, root + '\\' + key) as k:
            for name, rel in folders.items():
                winreg.SetValueEx(k, name, 0, kind, fmt % (var, rel) if fmt else guest + '\\' + rel)
    for rel in folders.values():
        os.makedirs(os.path.join(base, rel), exist_ok=True)

def colors(box, inf):
    """HKCU,"Control Panel\\Colors","Background",0x00000000,"58 110 165" lines into the box"""
    if not os.path.exists(inf):
        return
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, r'Software\pcrecomp\%s\HKCU\Control Panel\Colors' % box) as k:
        for l in open(inf, encoding='latin-1'):
            m = re.match(r'HKCU,"Control Panel\\Colors","(\w+)",0x0000000[02],"([\d ]+)"', l)
            if m:
                winreg.SetValueEx(k, m.group(1), 0, winreg.REG_SZ, m.group(2))

ACCESSORIES = [('Notepad', 'notepad.exe'), ('Calculator', 'calc.exe'), ('Paint', 'mspaint.exe'), ('WordPad', 'wordpad.exe'),
               (r'Games\FreeCell', 'freecell.exe'), (r'Games\Minesweeper', 'winmine.exe'), (r'Games\Solitaire', 'sol.exe')]

def lnk(path, guest):
    """A Windows 2000 shortcut to a guest path (C:\\WINNT\\system32\\x.exe, 8.3 names): only the
    target ID list (My Computer, the drive, one file-system item per component). No LinkInfo:
    linkinfo.dll is not in the guest. ponytail: no dates, sizes or icon location in the items."""
    import struct
    items = [bytes.fromhex('1F50E04FD020EA3A6910A2D808002B30309D')]          # My Computer
    items.append(b'\x2F' + guest[:3].encode() + bytes(19))                   # the drive: C:\ (25 bytes)
    parts = guest[3:].split('\\')
    for i, p in enumerate(parts):
        flag = 0x32 if i == len(parts) - 1 else 0x31                          # file, directory
        attr = 0x20 if flag == 0x32 else 0x10
        items.append(struct.pack('<BBIHHH', flag, 0, 0, 0, 0, attr) + p.encode() + b'\0' + (b'\0' if len(p) % 2 == 0 else b''))
    idl = b''.join(struct.pack('<H', len(it) + 2) + it for it in items) + b'\0\0'
    hdr = struct.pack('<I16sIIQQQIIIHHII', 0x4C, bytes.fromhex('0114020000000000C000000000000046'), 1, 0x20, 0, 0, 0,
                      0, 0, 1, 0, 0, 0, 0)
    with open(path, 'wb') as f:
        f.write(hdr + struct.pack('<H', len(idl)) + idl + b'\0\0\0\0')

def accessories(d, sysdir):
    """All Users' Start Menu\\Programs\\Accessories (Windows 2000's names) to the lifted accessories:
    the targets are Windows 2000's own files in the box's C:\\WINNT\\system32, for their icons only;
    the launch path starts the lifted runner by name (win2000 src/nthost.c), never the file."""
    import shutil
    box_sys = os.path.join(d, '..', 'WINNT', 'system32')
    os.makedirs(box_sys, exist_ok=True)
    for name, exe in ACCESSORIES:
        src = os.path.join(sysdir, exe)
        if os.path.exists(src) and not os.path.exists(os.path.join(box_sys, exe)):
            shutil.copyfile(src, os.path.join(box_sys, exe))
        p = os.path.join(d, 'all', 'Start Menu', 'Programs', 'Accessories', name + '.lnk')
        os.makedirs(os.path.dirname(p), exist_ok=True)
        lnk(p, 'C:\\WINNT\\system32\\' + exe)

if __name__ == '__main__':
    box, d = sys.argv[1], os.path.abspath(sys.argv[2])
    g = sys.argv[3] if len(sys.argv) > 3 else d     # the guest's name for DIR (in a file box: C:\...)
    seed(box, 'HKCU', 'USERPROFILE', os.path.join(d, 'user'), USER, g + r'\user')
    seed(box, 'HKLM', 'ALLUSERSPROFILE', os.path.join(d, 'all'), COMMON, g + r'\all')
    colors(box, os.path.join(os.path.dirname(__file__), '..', 'work', 'iso', 'I386', 'HIVEDEF.INF'))
    if g.startswith('C:\\'):     # in a file box: DIR is the box's C:\Documents and Settings
        accessories(d, os.path.join(os.path.dirname(__file__), '..', 'work', 'sys'))
    print('profile %s: %s' % (box, d))
