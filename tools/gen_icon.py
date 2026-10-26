#!/usr/bin/env python3
"""生成 App 图标（纯标准库，SDF 抗锯齿）"""
import os
import struct
import sys
import zlib


def clamp(v, a=0.0, b=1.0):
    return a if v < a else (b if v > b else v)


def rounded_rect_sdf(px, py, x0, y0, x1, y1, r):
    """返回点到圆角矩形的有符号距离（负=内部）"""
    cx = (x0 + x1) / 2.0
    cy = (y0 + y1) / 2.0
    hx = (x1 - x0) / 2.0 - r
    hy = (y1 - y0) / 2.0 - r
    dx = abs(px - cx) - hx
    dy = abs(py - cy) - hy
    ax = dx if dx > 0 else 0.0
    ay = dy if dy > 0 else 0.0
    outside = (ax * ax + ay * ay) ** 0.5
    inside = min(max(dx, dy), 0.0)
    return outside + inside - r


def render(size):
    s = float(size)
    inset = 0.055 * s
    radius = 0.225 * s
    x0, y0 = inset, inset
    x1, y1 = s - inset, s - inset

    bar_w = 0.105 * s
    gap = 0.055 * s
    base = 0.265 * s
    heights = [0.185, 0.275, 0.375]
    alphas = [0.42, 0.72, 1.0]
    total_w = bar_w * 3 + gap * 2
    start_x = (s - total_w) / 2.0

    bars = []
    for i, h in enumerate(heights):
        bx = start_x + i * (bar_w + gap)
        bars.append((bx, base, bx + bar_w, base + h * s, bar_w / 2.0, alphas[i], i == 2))

    # 背景渐变端点
    top = (0.106, 0.176, 0.310)
    bottom = (0.020, 0.043, 0.078)
    glow = (0.30, 0.45, 0.85)

    rows = []
    for y in range(size):
        row = bytearray()
        yb = s - (y + 0.5)
        for x in range(size):
            px = x + 0.5

            # 背景：左上偏亮 → 右下深色
            t = clamp((px / s) * 0.42 + (1.0 - yb / s) * 0.58)
            r = top[0] + (bottom[0] - top[0]) * t
            g = top[1] + (bottom[1] - top[1]) * t
            b = top[2] + (bottom[2] - top[2]) * t

            # 左上柔光
            gx = px - (x0 + (x1 - x0) * 0.26)
            gy = yb - (y1 - (y1 - y0) * 0.12)
            gd = (gx * gx + gy * gy) ** 0.5
            ga = clamp(1.0 - gd / (0.85 * s)) ** 2 * 0.55
            r += (glow[0] - r) * ga
            g += (glow[1] - g) * ga
            b += (glow[2] - b) * ga

            # 柱状条
            for (bx0, by0, bx1, by1, br, ba, is_accent) in bars:
                d = rounded_rect_sdf(px, yb, bx0, by0, bx1, by1, br)
                a = clamp(0.5 - d) * ba
                if a > 0.0:
                    if is_accent:
                        cr, cg, cb = 0.357, 0.576, 1.0
                    else:
                        cr = cg = cb = 1.0
                    r += (cr - r) * a
                    g += (cg - g) * a
                    b += (cb - b) * a

            # 外轮廓遮罩
            mask = clamp(0.5 - rounded_rect_sdf(px, yb, x0, y0, x1, y1, radius))
            if mask <= 0.0:
                row += b'\x00\x00\x00\x00'
            else:
                row += bytes((
                    int(clamp(r) * 255 + 0.5),
                    int(clamp(g) * 255 + 0.5),
                    int(clamp(b) * 255 + 0.5),
                    int(mask * 255 + 0.5),
                ))
        rows.append(bytes(row))
    return rows


def write_png(path, size, rows):
    raw = b''.join(b'\x00' + r for r in rows)

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 9))
    png += chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'AppIcon.iconset'
    os.makedirs(out, exist_ok=True)
    variants = [
        ('icon_16x16', 16), ('icon_16x16@2x', 32),
        ('icon_32x32', 32), ('icon_32x32@2x', 64),
        ('icon_128x128', 128), ('icon_128x128@2x', 256),
        ('icon_256x256', 256), ('icon_256x256@2x', 512),
        ('icon_512x512', 512), ('icon_512x512@2x', 1024),
    ]
    cache = {}
    for name, size in variants:
        if size not in cache:
            cache[size] = render(size)
        write_png(os.path.join(out, name + '.png'), size, cache[size])
    print('iconset ->', out)


if __name__ == '__main__':
    main()
