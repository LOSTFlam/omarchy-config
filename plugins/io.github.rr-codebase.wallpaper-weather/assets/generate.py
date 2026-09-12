#!/usr/bin/env python3
"""Generate the sprite atlas for the Osaka Jade weather FX layer.

Everything here is deterministic (fixed seed) and dependency-free -- stdlib
zlib writes the PNGs -- so the assets can be regenerated on any machine:

    python3 generate.py

Sprites are pure white with a meaningful alpha channel; the QML layer tints
them per mood, so one atlas serves rain, sun, moon, stars and fireflies.
"""

import math
import random
import struct
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent


def write_png(name, width, height, alpha_fn, rgb=(255, 255, 255)):
    """Write an RGBA PNG whose alpha comes from alpha_fn(x, y) in 0..1."""
    r, g, b = rgb
    rows = []
    for y in range(height):
        row = bytearray()
        row.append(0)  # filter type: none
        for x in range(width):
            a = alpha_fn(x, y)
            a = 0.0 if a < 0.0 else (1.0 if a > 1.0 else a)
            row += bytes((r, g, b, int(round(a * 255))))
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    (HERE / name).write_bytes(png)
    print(f"  {name}  {width}x{height}")


def smoothstep(t):
    t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
    return t * t * (3.0 - 2.0 * t)


# --------------------------------------------------------------------------
# raindrop.png -- a comet streak pointing +x so ImageParticle.autoRotation can
# align it with the fall vector (0 rad = +x in QtQuick.Particles).
#
# MUST be square: ImageParticle stretches its texture to a size x size quad, so
# a 96x10 streak arrives on screen as a fat wedge. The streak is drawn thin
# inside a square canvas instead, and survives the scale intact.
# --------------------------------------------------------------------------
def raindrop():
    size = 128
    cy = (size - 1) / 2.0

    def alpha(x, y):
        t = x / (size - 1)
        head = t ** 2.6                            # bright at the leading edge
        tip = 1.0 - smoothstep((t - 0.94) / 0.06)  # soften the very tip
        thickness = 1.6 + 2.6 * t                  # tapered tail
        falloff = math.exp(-((y - cy) / thickness) ** 2)
        return head * tip * falloff

    write_png("raindrop.png", size, size, alpha)


# --------------------------------------------------------------------------
# glow.png -- soft radial dot. Dust motes, fireflies, splashes, sun/moon disc.
# --------------------------------------------------------------------------
def glow():
    size = 128
    c = (size - 1) / 2.0

    def alpha(x, y):
        r = math.hypot(x - c, y - c) / c
        if r >= 1.0:
            return 0.0
        return (1.0 - r) ** 2.6

    write_png("glow.png", size, size, alpha)


# --------------------------------------------------------------------------
# star.png -- tight core with a faint four-point flare.
# --------------------------------------------------------------------------
def star():
    size = 32
    c = (size - 1) / 2.0

    def alpha(x, y):
        dx, dy = x - c, y - c
        r = math.hypot(dx, dy) / c
        core = (1.0 - r) ** 7 if r < 1.0 else 0.0
        flare_h = math.exp(-(dy / 0.75) ** 2) * max(0.0, 1.0 - abs(dx) / c) ** 3
        flare_v = math.exp(-(dx / 0.75) ** 2) * max(0.0, 1.0 - abs(dy) / c) ** 3
        return core + 0.42 * (flare_h + flare_v)

    write_png("star.png", size, size, alpha)


# --------------------------------------------------------------------------
# ray.png -- one god ray. Widest and brightest at the top, dissolving down.
# --------------------------------------------------------------------------
def ray():
    w, h = 192, 1024
    cx = (w - 1) / 2.0

    def alpha(x, y):
        t = y / (h - 1)
        spread = w * (0.20 + 0.48 * t)
        across = math.exp(-((x - cx) / spread) ** 2)
        down = (1.0 - t) ** 1.7
        top = smoothstep(t / 0.10)  # avoid a hard cut at the emitter
        return across * down * top * 0.7

    write_png("ray.png", w, h, alpha)


# --------------------------------------------------------------------------
# mist.png -- seamless-in-x cloud band. Value noise on a wrapped lattice,
# bilinearly upscaled (the blur is the point), faded out top and bottom.
# --------------------------------------------------------------------------
def mist():
    w, h = 1024, 320
    rng = random.Random(0x5EED)

    def lattice(cols, rows):
        return [[rng.random() for _ in range(cols)] for _ in range(rows)]

    def sample(grid, u, v):
        rows, cols = len(grid), len(grid[0])
        fx, fy = u * cols, v * rows
        x0, y0 = int(math.floor(fx)), int(math.floor(fy))
        tx, ty = smoothstep(fx - x0), smoothstep(fy - y0)
        x0 %= cols
        y0 = max(0, min(rows - 1, y0))
        x1 = (x0 + 1) % cols          # wrap in x -> seamless tile
        y1 = min(rows - 1, y0 + 1)
        a = grid[y0][x0] * (1 - tx) + grid[y0][x1] * tx
        b = grid[y1][x0] * (1 - tx) + grid[y1][x1] * tx
        return a * (1 - ty) + b * ty

    octaves = [(lattice(6, 3), 0.55), (lattice(13, 6), 0.30), (lattice(29, 11), 0.15)]

    def alpha(x, y):
        u, v = x / w, y / h
        n = sum(sample(grid, u, v) * weight for grid, weight in octaves)
        n = smoothstep((n - 0.34) / 0.44)          # lift contrast into wisps
        band = math.sin(math.pi * v) ** 3.0        # dissolve at both edges
        return n * band

    write_png("mist.png", w, h, alpha)


# --------------------------------------------------------------------------
# grain.png -- tileable film grain, kept faint on purpose.
# --------------------------------------------------------------------------
def grain():
    size = 128
    rng = random.Random(0xC0FFEE)
    values = [[rng.random() for _ in range(size)] for _ in range(size)]
    write_png("grain.png", size, size, lambda x, y: values[y][x] ** 2.2)


# --------------------------------------------------------------------------
# vignette.png -- black corners, clear centre. Stretched to any aspect ratio.
# --------------------------------------------------------------------------
def vignette():
    size = 256
    c = (size - 1) / 2.0

    def alpha(x, y):
        r = math.hypot(x - c, y - c) / (c * math.sqrt(2))
        return smoothstep((r - 0.42) / 0.58) ** 1.7

    write_png("vignette.png", size, size, alpha, rgb=(0, 0, 0))


if __name__ == "__main__":
    print("generating osaka jade weather sprites:")
    raindrop()
    glow()
    star()
    ray()
    mist()
    grain()
    vignette()
    print("done.")
