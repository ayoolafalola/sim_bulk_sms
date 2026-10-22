#!/usr/bin/env python3
"""Placeholder app icon: a white SIM card with a message bubble on the app's green.

Draws two 1024x1024 masters into assets/icon/ (no third-party packages), then uses
macOS `sips` to write every Android and iOS size. To use your own design instead,
replace assets/icon/icon_full.png (opaque, 1024x1024) and
assets/icon/icon_foreground.png (transparent, art inside the middle ~60%) and run:

    python3 tool/make_icon.py --resize-only
"""
import json
import os
import struct
import subprocess
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GREEN = (0x1B, 0x6B, 0x5A)
LIGHT = (0xD8, 0xF3, 0xEA)
WHITE = (0xFF, 0xFF, 0xFF)
SIZE = 1024


def in_round_rect(x, y, x0, y0, x1, y1, r):
    if x < x0 or x > x1 or y < y0 or y > y1:
        return False
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def in_triangle(x, y, a, b, c):
    def side(p, q, r):
        return (p[0] - r[0]) * (q[1] - r[1]) - (q[0] - r[0]) * (p[1] - r[1])
    d1, d2, d3 = side((x, y), a, b), side((x, y), b, c), side((x, y), c, a)
    neg = d1 < 0 or d2 < 0 or d3 < 0
    pos = d1 > 0 or d2 > 0 or d3 > 0
    return not (neg and pos)


def art(x, y):
    """Colour of the artwork at unit coordinates, or None for empty."""
    # Message bubble (drawn on top), with a green ring separating it from the card.
    bubble = (0.47, 0.55, 0.81, 0.79, 0.07)
    tail = ((0.53, 0.77), (0.63, 0.77), (0.49, 0.87))
    if in_round_rect(x, y, *bubble) or in_triangle(x, y, *tail):
        for cx in (0.56, 0.64, 0.72):
            if (x - cx) ** 2 + (y - 0.67) ** 2 <= 0.024 ** 2:
                return GREEN
        return LIGHT
    ring = 0.03
    if in_round_rect(x, y, bubble[0] - ring, bubble[1] - ring, bubble[2] + ring, bubble[3] + ring, bubble[4] + ring) \
            or in_triangle(x, y, (0.51, 0.75), (0.67, 0.75), (0.47, 0.91)):
        return GREEN
    # SIM card with a cut top-right corner and a chip.
    x0, y0, x1, y1 = 0.25, 0.17, 0.63, 0.73
    if in_round_rect(x, y, x0, y0, x1, y1, 0.04) and not ((x - (x1 - 0.12)) > (y - y0)):
        if in_round_rect(x, y, 0.32, 0.37, 0.53, 0.60, 0.03):
            on_line = abs(y - 0.445) < 0.008 or abs(y - 0.525) < 0.008 or (abs(x - 0.425) < 0.008 and y > 0.445)
            return WHITE if on_line else GREEN
        return WHITE
    return None


def render(foreground):
    """RGBA rows. foreground=True: transparent background, art shrunk into the adaptive-icon safe zone."""
    scale = 0.78 if foreground else 1.0
    rows = []
    offs = (0.25, 0.75)
    for py in range(SIZE):
        row = bytearray()
        for px in range(SIZE):
            acc = [0, 0, 0, 0]
            for oy in offs:
                for ox in offs:
                    ux = 0.5 + ((px + ox) / SIZE - 0.5) / scale + 0.03 * (scale < 1)
                    uy = 0.5 + ((py + oy) / SIZE - 0.5) / scale + 0.02 * (scale < 1)
                    c = art(ux, uy)
                    if c is None and not foreground:
                        c = GREEN
                    if c is not None:
                        acc[0] += c[0]; acc[1] += c[1]; acc[2] += c[2]; acc[3] += 255
            n = len(offs) ** 2
            a = acc[3] // n
            if a:
                k = acc[3] / 255
                row += bytes((int(acc[0] / k), int(acc[1] / k), int(acc[2] / k), a))
            else:
                row += b'\x00\x00\x00\x00'
        rows.append(bytes(row))
    return rows


def write_png(path, rows):
    raw = b''.join(b'\x00' + r for r in rows)
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', SIZE, SIZE, 8, 6, 0, 0, 0)) \
        + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)


def resize(src, dst, px):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    subprocess.run(['sips', '-z', str(px), str(px), src, '--out', dst], check=True, capture_output=True)


def main():
    icon_dir = os.path.join(ROOT, 'assets', 'icon')
    full, fg = os.path.join(icon_dir, 'icon_full.png'), os.path.join(icon_dir, 'icon_foreground.png')
    if '--resize-only' not in sys.argv:
        os.makedirs(icon_dir, exist_ok=True)
        print('Drawing masters (about a minute)…')
        write_png(full, render(False))
        write_png(fg, render(True))

    res = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
    for density, mult in (('mdpi', 1), ('hdpi', 1.5), ('xhdpi', 2), ('xxhdpi', 3), ('xxxhdpi', 4)):
        resize(full, os.path.join(res, f'mipmap-{density}', 'ic_launcher.png'), int(48 * mult))
        resize(fg, os.path.join(res, f'mipmap-{density}', 'ic_launcher_foreground.png'), int(108 * mult))
    os.makedirs(os.path.join(res, 'mipmap-anydpi-v26'), exist_ok=True)
    with open(os.path.join(res, 'mipmap-anydpi-v26', 'ic_launcher.xml'), 'w') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable="@color/ic_launcher_background" />\n'
                '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
                '    <monochrome android:drawable="@mipmap/ic_launcher_foreground" />\n'
                '</adaptive-icon>\n')
    with open(os.path.join(res, 'values', 'colors.xml'), 'w') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
                '    <color name="ic_launcher_background">#1B6B5A</color>\n</resources>\n')

    ios = os.path.join(ROOT, 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
    with open(os.path.join(ios, 'Contents.json')) as f:
        images = json.load(f)['images']
    for im in images:
        pts = float(im['size'].split('x')[0])
        px = round(pts * int(im['scale'].rstrip('x')))
        resize(full, os.path.join(ios, im['filename']), px)
    print('Icons written for Android (legacy + adaptive) and iOS.')


if __name__ == '__main__':
    main()
