#!/usr/bin/env python3
"""src/wallpaper_codec.c against independent references: every PNG, JPEG and
WebP variant a wallpaper can be, checked pixel for pixel against Pillow, or
against the exact values a hand-written PNG encodes (Pillow cannot write
interlaced or 16-bit colour PNGs). The codec is built as a shared object and
driven through ctypes, so no compositor runs. `--sanitize` builds it with
ASan and UBSan and preloads libasan into Python.

    python3 tests/wallpaper_codec.py [--sanitize]

When zig-out/bin/rediwm exists it also checks that the compositor no longer
calls GdkPixbuf (which starts a sandboxed glycin loader process per decode).
"""
import ctypes
import io
import os
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
WC_OK, WC_UNSUPPORTED, WC_TOO_LARGE, WC_CORRUPT = 0, 1, 2, 3


class Info(ctypes.Structure):
    _fields_ = [('w', ctypes.c_int), ('h', ctypes.c_int)]


def build(directory, sanitize):
    flags = ['-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'] if sanitize else []
    library = directory / 'wallpaper_codec.so'
    subprocess.run(['cc', '-shared', '-fPIC', '-g', '-O1', '-std=c11', '-Wall', '-Wextra', '-Werror', *flags,
                    '-o', str(library), str(ROOT / 'src/wallpaper_codec.c'), '-ljpeg', '-lpng16', '-lwebp'], check=True)
    lib = ctypes.CDLL(str(library))
    lib.wc_probe.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(Info)]
    lib.wc_decode.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_uint32), ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
    return lib


def probe(lib, data):
    info = Info()
    status = lib.wc_probe(data, len(data), ctypes.byref(info))
    return status, (info.w, info.h)


def decode(lib, data):
    """(status, (w, h, premultiplied words, has_alpha))."""
    status, (w, h) = probe(lib, data)
    if status != WC_OK:
        return status, None
    pixels = (ctypes.c_uint32 * (w * h))()
    alpha = ctypes.c_int()
    status = lib.wc_decode(data, len(data), pixels, w, h, ctypes.byref(alpha))
    return status, (w, h, list(pixels), bool(alpha.value))


def premultiplied(rgba):
    """Straight (r, g, b, a) tuples to the codec's premultiplied 0xAARRGGBB."""
    out = []
    for r, g, b, a in rgba:
        if a == 255:
            out.append(0xff000000 | r << 16 | g << 8 | b)
        elif a == 0:
            out.append(0)
        else:
            out.append(a << 24 | ((r * a + 127) // 255) << 16 | ((g * a + 127) // 255) << 8 | (b * a + 127) // 255)
    return out


def check(lib, data, expected, size, tolerance, label):
    status, result = decode(lib, data)
    assert status == WC_OK, f'{label}: status {status}'
    w, h, pixels, has_alpha = result
    assert (w, h) == size, f'{label}: size {(w, h)} != {size}'
    assert len(pixels) == len(expected)
    worst = max((abs(((x >> s) & 255) - ((y >> s) & 255)) for x, y in zip(pixels, expected) for s in (24, 16, 8, 0)), default=0)
    assert worst <= tolerance, f'{label}: worst channel difference {worst} > {tolerance}'
    translucent = any(p >> 24 != 255 for p in expected)
    assert has_alpha == translucent, f'{label}: has_alpha {has_alpha}, expected {translucent}'


# ---- hand-written PNGs -------------------------------------------------------

CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]


def chunk(kind, body):
    return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))


def pack_row(values, depth):
    if depth == 16:
        return b''.join(struct.pack('>H', v) for v in values)
    if depth == 8:
        return bytes(values)
    bits = ''.join(format(v, f'0{depth}b') for v in values)
    bits += '0' * (-len(bits) % 8)
    return bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8))


def sample(x, y, channel, depth):
    return (x * 31 + y * 17 + channel * 101) % (1 << depth)


def png_bytes(w, h, depth, color, interlace, plte=None, trns=None):
    passes = ADAM7 if interlace else [(0, 0, 1, 1)]
    raw = b''
    for x0, y0, dx, dy in passes:
        xs = list(range(x0, w, dx))
        if not xs:
            continue
        for y in range(y0, h, dy):
            values = [sample(x, y, c, depth) for x in xs for c in range(CHANNELS[color])]
            if color == 3:
                values = [v % len(plte) for v in values]
            raw += b'\0' + pack_row(values, depth)
    out = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, depth, color, 0, 0, int(interlace)))
    if plte:
        out += chunk(b'PLTE', bytes(v for entry in plte for v in entry))
    if trns is not None:
        out += chunk(b'tRNS', trns)
    return out + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')


def scale(value, depth):
    return value * 255 // ((1 << depth) - 1) if depth < 16 else round(value * 255 / 65535)


def expected_png(w, h, depth, color, plte, trns_value, trns_alpha):
    out = []
    for y in range(h):
        for x in range(w):
            s = [sample(x, y, c, depth) for c in range(CHANNELS[color])]
            if color == 3:
                index = s[0] % len(plte)
                r, g, b = plte[index]
                a = trns_alpha[index] if index < len(trns_alpha) else 255
            elif color in (0, 4):
                r = g = b = scale(s[0], depth)
                a = scale(s[1], depth) if color == 4 else 255
                if trns_value is not None and s[0] == trns_value[0]:
                    a = 0
            else:
                r, g, b = (scale(v, depth) for v in s[:3])
                a = scale(s[3], depth) if color == 6 else 255
                if trns_value is not None and tuple(s) == trns_value:
                    a = 0
            out.append((r, g, b, a))
    return premultiplied(out)


def png_cases(lib):
    w, h = 19, 13  # Odd sizes: partial Adam7 passes and bit-packed row padding.
    cases = 0
    palette = [(i * 16, 255 - i * 16, (i * 77) % 256) for i in range(16)]
    for interlace in (False, True):
        for color, depths in ((0, (1, 2, 4, 8, 16)), (2, (8, 16)), (3, (1, 2, 4, 8)), (4, (8, 16)), (6, (8, 16))):
            for depth in depths:
                plte = palette[:min(16, 1 << depth)] if color == 3 else None
                data = png_bytes(w, h, depth, color, interlace, plte=plte)
                label = f'png color={color} depth={depth} interlace={interlace}'
                check(lib, data, expected_png(w, h, depth, color, plte, None, []), (w, h), 1 if depth == 16 else 0, label)
                cases += 1
        # tRNS: a colour key (gray, truecolour) and per-index alpha (palette).
        for color, depth in ((0, 8), (0, 16), (0, 2), (2, 8), (2, 16)):
            key = tuple(sample(0, 0, c, depth) for c in range(CHANNELS[color]))
            body = b''.join(struct.pack('>H', v) for v in key)
            data = png_bytes(w, h, depth, color, interlace, trns=body)
            label = f'png tRNS color={color} depth={depth} interlace={interlace}'
            check(lib, data, expected_png(w, h, depth, color, None, key, []), (w, h), 1 if depth == 16 else 0, label)
            cases += 1
        for depth in (4, 8):
            plte = palette[:min(16, 1 << depth)]
            alphas = [255 - 17 * i for i in range(0, len(plte) - 3)]  # The last three entries stay opaque.
            data = png_bytes(w, h, depth, 3, interlace, plte=plte, trns=bytes(alphas))
            check(lib, data, expected_png(w, h, depth, 3, plte, None, alphas), (w, h), 0, f'png tRNS palette depth={depth} interlace={interlace}')
            cases += 1
    return cases


# ---- Pillow-written files, read back by Pillow ---------------------------------

def pattern(w, h, mode='RGBA'):
    image = Image.new('RGBA', (w, h))
    image.putdata([(x * 255 // max(w - 1, 1), y * 255 // max(h - 1, 1), (x * 7 + y * 13) % 256, (x * y * 5) % 256 if mode == 'RGBA' else 255)
                   for y in range(h) for x in range(w)])
    return image if mode == 'RGBA' else image.convert('RGB')


def save(image, fmt, **options):
    out = io.BytesIO()
    image.save(out, fmt, **options)
    return out.getvalue()


def reference(data):
    with Image.open(io.BytesIO(data)) as image:
        raw = image.convert('RGBA').tobytes()
        return premultiplied([tuple(raw[i:i + 4]) for i in range(0, len(raw), 4)]), image.size


def pillow_cases(lib):
    cases = 0
    for w, h in ((64, 48), (37, 29), (1, 1)):
        rgba, rgb = pattern(w, h), pattern(w, h, 'RGB')
        for label, data, tolerance in (
            ('png rgb', save(rgb, 'PNG'), 0),
            ('png rgba', save(rgba, 'PNG'), 0),
            ('png palette', save(rgb.convert('P', palette=Image.Palette.ADAPTIVE, colors=40), 'PNG'), 0),
            ('png palette+transparency', save(rgba.convert('P', palette=Image.Palette.ADAPTIVE, colors=40), 'PNG', transparency=3), 0),
            ('png gray', save(rgb.convert('L'), 'PNG'), 0),
            ('png gray+alpha', save(rgba.convert('LA'), 'PNG'), 0),
            ('png 1-bit', save(rgb.convert('1'), 'PNG'), 0),
            ('jpeg 4:2:0', save(rgb, 'JPEG', quality=90), 1),
            ('jpeg 4:4:4', save(rgb, 'JPEG', quality=95, subsampling=0), 1),
            ('jpeg 4:2:2', save(rgb, 'JPEG', quality=85, subsampling=1), 1),
            ('jpeg progressive', save(rgb, 'JPEG', quality=90, progressive=True), 1),
            ('jpeg optimized', save(rgb, 'JPEG', quality=90, optimize=True), 1),
            ('jpeg gray', save(rgb.convert('L'), 'JPEG', quality=90), 1),
            ('jpeg cmyk', save(rgb.convert('CMYK'), 'JPEG', quality=95), 2),
            ('webp lossless', save(rgb, 'WEBP', lossless=True), 0),
            ('webp lossless alpha', save(rgba, 'WEBP', lossless=True), 1),
            ('webp lossy', save(rgb, 'WEBP', quality=80), 0),
            ('webp lossy alpha', save(rgba, 'WEBP', quality=80), 1),
        ):
            expected, size = reference(data)
            check(lib, data, expected, size, tolerance, f'{label} {w}x{h}')
            cases += 1
    # EXIF orientation is not applied (a wallpaper never was): the stored size stays.
    exif = Image.Exif()
    exif[0x0112] = 6
    data = save(pattern(40, 24, 'RGB'), 'JPEG', exif=exif)
    expected, size = reference(data)
    check(lib, data, expected, size, 1, 'jpeg with EXIF orientation')
    assert probe(lib, data) == (WC_OK, (40, 24))
    return cases + 1


def failure_cases(lib):
    rgb = pattern(32, 24, 'RGB')
    png = save(rgb, 'PNG')
    webp = save(rgb, 'WEBP', lossless=True)
    jpeg = save(rgb, 'JPEG')
    for label, data in (('empty', b''), ('text', b'not an image at all'), ('svg', b"<svg xmlns='http://www.w3.org/2000/svg'/>"),
                        ('gif', save(rgb.convert('P'), 'GIF')), ('bmp', save(rgb, 'BMP')), ('tiff', save(rgb, 'TIFF'))):
        assert probe(lib, data)[0] == WC_UNSUPPORTED, label
    # Animated WebP: a still frame is all a wallpaper can be.
    try:
        animated = save(rgb, 'WEBP', save_all=True, append_images=[pattern(32, 24, 'RGB').transpose(Image.Transpose.FLIP_LEFT_RIGHT)], duration=100, lossless=True)
    except Exception as err:  # Pillow built without animated WebP.
        print('skipping animated WebP:', err)
    else:
        if b'ANIM' in animated:
            assert probe(lib, animated)[0] == WC_UNSUPPORTED, 'animated webp'
    # Truncated and damaged files fail cleanly.
    for label, data in (('png', png), ('webp', webp)):
        for cut in (len(data) // 2, len(data) - 40):
            assert decode(lib, data[:cut])[0] == WC_CORRUPT, f'truncated {label} at {cut}'
    for label, data in (('png', png[:8]), ('jpeg', jpeg[:4]), ('webp', webp[:12])):
        assert decode(lib, data)[0] == WC_CORRUPT, f'{label} signature only'
    damaged = bytearray(png)
    damaged[len(damaged) // 2] ^= 0xff
    assert decode(lib, bytes(damaged))[0] in (WC_CORRUPT, WC_OK)  # Never a crash; a flipped IDAT bit usually fails the checksum.
    # A header that claims a huge image is reported, not allocated: the caller
    # bounds it. libpng reads up to the first IDAT before it reports a size.
    def claiming(w, h):
        return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', b'')
    assert probe(lib, claiming(70000, 70000)) == (WC_OK, (70000, 70000))
    assert probe(lib, claiming(0x7fffffff, 1))[0] in (WC_TOO_LARGE, WC_CORRUPT)
    assert probe(lib, claiming(0, 1))[0] == WC_CORRUPT
    # A buffer that does not match the file's own size is refused before any write.
    pixels = (ctypes.c_uint32 * (64 * 64))()
    alpha = ctypes.c_int()
    for w, h in ((31, 24), (33, 24), (32, 23), (32, 25), (64, 64)):
        assert lib.wc_decode(png, len(png), pixels, w, h, ctypes.byref(alpha)) == WC_CORRUPT, (w, h)
        assert lib.wc_decode(webp, len(webp), pixels, w, h, ctypes.byref(alpha)) == WC_CORRUPT, (w, h)
        assert lib.wc_decode(jpeg, len(jpeg), pixels, w, h, ctypes.byref(alpha)) == WC_CORRUPT, (w, h)
    assert lib.wc_decode(png, len(png), None, 32, 24, ctypes.byref(alpha)) == WC_CORRUPT
    return 8


def compositor_does_not_call_pixbuf():
    binary = ROOT / 'zig-out/bin/rediwm'
    if not binary.exists():
        print('zig-out/bin/rediwm not built: skipping the GdkPixbuf symbol check')
        return
    undefined = subprocess.run(['nm', '-D', '--undefined-only', str(binary)], capture_output=True, text=True, check=True).stdout
    calls = [line.split()[-1] for line in undefined.splitlines() if 'gdk_pixbuf' in line or 'glycin' in line]
    assert not calls, f'the compositor must not call GdkPixbuf or glycin: {calls}'
    print('The compositor calls no GdkPixbuf or glycin function')


def main():
    sanitize = '--sanitize' in sys.argv
    if sanitize and 'libasan' not in os.environ.get('LD_PRELOAD', ''):
        asan = subprocess.run(['cc', '-print-file-name=libasan.so'], capture_output=True, text=True, check=True).stdout.strip()
        os.execvpe(sys.executable, [sys.executable, *sys.argv], {**os.environ, 'LD_PRELOAD': asan, 'ASAN_OPTIONS': 'detect_leaks=0'})
    with tempfile.TemporaryDirectory(prefix='rediwm-wallpaper-codec-') as directory:
        lib = build(Path(directory), sanitize)
        total = png_cases(lib) + pillow_cases(lib) + failure_cases(lib)
    print(f'Wallpaper codec: {total} cases passed' + (' under ASan and UBSan' if sanitize else ''))
    compositor_does_not_call_pixbuf()


if __name__ == '__main__':
    main()
