#!/usr/bin/env python3
"""Drive winmine the same way on the stage 1 build (host user32/gdi32) and on
build/ntwinmine.exe (Windows 2000's own user32/gdi32, lifted), and compare a
screenshot after each step pixel by pixel.

    py -3 tools/interact.py
Steps: start, a click on a cell, Game > Intermediate, Game > Custom (dialog).
The mines are the same in both (W2K_FIXED_TICK: winmine seeds with
GetTickCount). Shots: shots/int_<build>_<t>.png.
"""
import os, subprocess, sys
from PIL import Image, ImageChops
Image.MAX_IMAGE_PIXELS = None

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STEPS = [('start', 4, []), ('click', 5.4, ['--click', '30,80@5']), ('intermediate', 8, ['--command', '522@7']),
         ('custom', 10, ['--command', '524@9'])]
env = dict(os.environ, PCRECOMP_MUTE='1', MSYS_NO_PATHCONV='1', W2K_FIXED_TICK='12345')
shots = [t for _, t, _ in STEPS]
extra = sum((s for _, _, s in STEPS), [])
for build in ('winmine', 'ntwinmine'):
    cmd = [sys.executable, os.path.join(ROOT, 'tools', 'hiddenrun.py'), '--secs', str(int(max(shots)) + 2)]
    for t in shots:
        cmd += ['--shot', str(t)]
    cmd += extra + ['--out', os.path.join(ROOT, 'shots', 'int_' + build), '--',
                    os.path.join(ROOT, 'build', build + '.exe'), '--mute', '--watchdog', str(int(max(shots)) + 1)]
    subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True)
for name, t, _ in STEPS:
    a, b = (os.path.join(ROOT, 'shots', 'int_%s_%d.png' % (k, int(t))) for k in ('winmine', 'ntwinmine'))
    if not (os.path.exists(a) and os.path.exists(b)):
        print('%-13s missing shot (%s)' % (name, 'host' if not os.path.exists(a) else 'lifted'))
        continue
    A, B = Image.open(a).convert('RGB'), Image.open(b).convert('RGB')
    if A.size != B.size:
        print('%-13s sizes differ: %s vs %s' % (name, A.size, B.size))
        continue
    n = sum(1 for p in ImageChops.difference(A, B).get_flattened_data() if p != (0, 0, 0))
    print('%-13s %dx%d, %d pixels differ' % (name, A.size[0], A.size[1], n))
