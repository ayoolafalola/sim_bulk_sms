#!/usr/bin/env python3
"""Messages++ app icon (design C: two bubbles with an amber "++" badge).

The artwork lives as SVG in assets/icon/src/. This script renders each SVG to a 1024x1024 master in
assets/icon/ with headless Google Chrome, then uses macOS `sips` to write every size:

  Android  mipmap-*/ic_launcher.png (legacy), adaptive layers ic_launcher_background / _foreground /
           _monochrome (Android 13+ themed icons), drawable-*/ic_stat_messages.png (notifications)
  iOS      AppIcon.appiconset (opaque, no alpha, as the App Store requires)
  Play     assets/icon/play_store_512.png

    python3 tool/make_icon.py                 # render SVGs, then all sizes
    python3 tool/make_icon.py --resize-only   # only re-cut sizes from the PNG masters
"""
import json
import os
import struct
import subprocess
import sys
import tempfile
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON = os.path.join(ROOT, 'assets', 'icon')
SRC = os.path.join(ICON, 'src')
RES = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
DENSITIES = (('mdpi', 1), ('hdpi', 1.5), ('xhdpi', 2), ('xxhdpi', 3), ('xxxhdpi', 4))
MASTERS = ('icon_full', 'icon_background', 'icon_foreground', 'icon_monochrome', 'notification')


def render(name):
    """SVG -> 1024x1024 PNG (transparent where the SVG draws nothing)."""
    svg = open(os.path.join(SRC, name + '.svg')).read()
    with tempfile.TemporaryDirectory() as tmp:
        page = os.path.join(tmp, 'icon.html')
        with open(page, 'w') as f:
            f.write('<!doctype html><html><head><style>html,body{margin:0;background:transparent}'
                    'svg{display:block}</style></head><body>' + svg + '</body></html>')
        out = os.path.join(ICON, name + '.png')
        subprocess.run([CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
                        '--default-background-color=00000000', '--window-size=1024,1024',
                        '--screenshot=' + out, 'file://' + page], check=True, capture_output=True)


def read_png(path):
    """8-bit RGB/RGBA PNG -> (width, height, channels, rows of bytes)."""
    data = open(path, 'rb').read()
    pos, idat, w, h, ctype = 8, b'', 0, 0, 0
    while pos < len(data):
        n, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b'IHDR':
            w, h, depth, ctype, _, _, interlace = struct.unpack('>IIBBBBB', body)
            assert depth == 8 and interlace == 0 and ctype in (2, 6), 'expected 8-bit RGB(A)'
        elif kind == b'IDAT':
            idat += body
        pos += 12 + n
    ch = 4 if ctype == 6 else 3
    raw, stride, rows, prev = zlib.decompress(idat), w * ch, [], bytearray(w * ch)
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            a = line[x - ch] if x >= ch else 0
            b, c = prev[x], prev[x - ch] if x >= ch else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line))
        prev = line
    return w, h, ch, rows


def write_rgb_png(path, w, h, rows):
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    raw = b''.join(b'\x00' + r for r in rows)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def opaque(src, dst):
    """Drops the alpha channel (the full icon is opaque; the App Store rejects icons with alpha)."""
    w, h, ch, rows = read_png(src)
    if ch == 4:
        rows = [bytes(b for i, b in enumerate(r) if i % 4 != 3) for r in rows]
    write_rgb_png(dst, w, h, rows)


def resize(src, dst, px):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    subprocess.run(['sips', '-z', str(px), str(px), src, '--out', dst], check=True, capture_output=True)


def main():
    if '--resize-only' not in sys.argv:
        for name in MASTERS:
            print('Rendering', name)
            render(name)
        opaque(os.path.join(ICON, 'icon_full.png'), os.path.join(ICON, 'icon_full.png'))
    m = {name: os.path.join(ICON, name + '.png') for name in MASTERS}

    for density, mult in DENSITIES:
        d = lambda kind: os.path.join(RES, f'{kind}-{density}')
        resize(m['icon_full'], os.path.join(d('mipmap'), 'ic_launcher.png'), int(48 * mult))
        for layer in ('background', 'foreground', 'monochrome'):
            resize(m['icon_' + layer], os.path.join(d('mipmap'), f'ic_launcher_{layer}.png'), int(108 * mult))
        resize(m['notification'], os.path.join(d('drawable'), 'ic_stat_messages.png'), int(24 * mult))
    os.makedirs(os.path.join(RES, 'mipmap-anydpi-v26'), exist_ok=True)
    with open(os.path.join(RES, 'mipmap-anydpi-v26', 'ic_launcher.xml'), 'w') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable="@mipmap/ic_launcher_background" />\n'
                '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
                '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />\n'
                '</adaptive-icon>\n')

    ios = os.path.join(ROOT, 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
    with open(os.path.join(ios, 'Contents.json')) as f:
        images = json.load(f)['images']
    for im in images:
        pts = float(im['size'].split('x')[0])
        resize(m['icon_full'], os.path.join(ios, im['filename']), round(pts * int(im['scale'].rstrip('x'))))
    resize(m['icon_full'], os.path.join(ICON, 'play_store_512.png'), 512)
    print('Icons written: Android (legacy, adaptive, themed, notification), iOS, Play Store 512.')


if __name__ == '__main__':
    main()
