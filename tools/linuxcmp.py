#!/usr/bin/env python3
"""Compare a Linux shot (winmine-linux's <out>_T_client.png, the main window's
client area) with the Windows shot of the same state (hiddenrun's PNG of the
window, Windows 11's frame around it), pixel by pixel.

    py -3 tools/linuxcmp.py shots/linux/int_5_client.png shots/int_ntwinmine_5.png [diff.png]

The Windows build's window is a host window whose frame is thicker than
Windows 2000's, so its client area is smaller than the program asked for
and the right and bottom of the board are cut (the black beyond is outside
the client). The comparison is over the part both show: the client's place
in the Windows shot is where the most pixels agree, and the columns and
rows past the Windows client's edge (all black) are left out.
"""
import sys
from PIL import Image

a = Image.open(sys.argv[1]).convert('RGB')
b = Image.open(sys.argv[2]).convert('RGB')
A, B = a.load(), b.load()
w, h = a.size
W, H = b.size

def extent(x, y):
    """the Windows client's visible size at (x, y): up to the all-black columns/rows"""
    ow, oh = min(w, W - x), min(h, H - y)
    while ow > 0 and all(B[x + ow - 1, y + j] == (0, 0, 0) for j in range(oh)): ow -= 1
    while oh > 0 and all(B[x + i, y + oh - 1] == (0, 0, 0) for i in range(ow)): oh -= 1
    return ow, oh

best = None
for y in range(0, H // 3):
    for x in range(0, W // 6):
        ow, oh = extent(x, y)
        if ow * oh < w * h // 2: continue
        n = sum(1 for j in range(0, oh, 4) for i in range(0, ow, 4) if A[i, j] != B[x + i, y + j])
        if best is None or n < best[0]: best = (n, x, y, ow, oh)
if best is None:
    print('no overlap found'); sys.exit(2)
_, x, y, ow, oh = best
d = Image.new('RGB', (ow, oh))
D = d.load()
n = 0
for j in range(oh):
    for i in range(ow):
        if A[i, j] != B[x + i, y + j]: n += 1; D[i, j] = (255, 0, 0)
        else: D[i, j] = tuple(v // 3 for v in A[i, j])
print('%s vs %s: Linux client %dx%d, the Windows one at (%d,%d) shows %dx%d of it: %d of %d pixels differ'
      % (sys.argv[1], sys.argv[2], w, h, x, y, ow, oh, n, ow * oh))
if len(sys.argv) > 3: d.save(sys.argv[3])
sys.exit(1 if n else 0)
