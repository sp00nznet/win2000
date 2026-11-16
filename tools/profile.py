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

if __name__ == '__main__':
    box, d = sys.argv[1], os.path.abspath(sys.argv[2])
    g = sys.argv[3] if len(sys.argv) > 3 else d     # the guest's name for DIR (in a file box: C:\...)
    seed(box, 'HKCU', 'USERPROFILE', os.path.join(d, 'user'), USER, g + r'\user')
    seed(box, 'HKLM', 'ALLUSERSPROFILE', os.path.join(d, 'all'), COMMON, g + r'\all')
    colors(box, os.path.join(os.path.dirname(__file__), '..', 'work', 'iso', 'I386', 'HIVEDEF.INF'))
    print('profile %s: %s' % (box, d))
