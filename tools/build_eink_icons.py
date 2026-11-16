#!/usr/bin/env python3
"""Flatten the original AO3 PNG backgrounds and convert them to grayscale.

No drawing, fonts, tracing, resizing or geometry changes. Pillow is required
only to rebuild the shipped PNGs, never to deploy or run the plugin.
Derived assets retain the originals' GPL-2.0-or-later license (see
assets/ao3-icons/COPYING and SOURCES.txt).
"""
from pathlib import Path
from statistics import median
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'assets' / 'ao3-icons'
DEST = ROOT / 'assets' / 'ao3-icons-eink'
BACKGROUND = 96
EMPTY = {'rating-notrated', 'category-none', 'warning-no'}
# Keep color families recognizable as tones, with ratings deliberately ordered
# light to dark. Multiples of 17 give well-separated steps on a 16-gray palette.
BACKGROUNDS = {
    'rating-general-audience': 153,
    'rating-teen': 119,
    'rating-mature': 85,
    'rating-explicit': 51,
    'category-gen': 153,
    'category-het': 102,
    'category-slash': 68,
    'category-femslash': 51,
    'category-other': 0,
    'warning-choosenotto': 85,
    'warning-yes': 51,
    'warning-external-work': 68,
    'complete-yes': 153,
    'complete-no': 51,
}


def flatten_pixel(pixel, background, target=BACKGROUND):
    """Recompose the original foreground over a constant gray background.

The original glyphs, anti-aliasing and shadows are neutral/white, composited
onto a colored background. Chrominance separates that background contribution
from the original foreground, without thresholding or redrawing its outline.
"""
    mean_p = sum(pixel) / 3
    mean_b = sum(background) / 3
    chroma_b = [channel - mean_b for channel in background]
    variance = sum(channel * channel for channel in chroma_b)
    if variance < 1:
        # The sole neutral, non-empty original is white-on-black category-other.
        return round(target + (255 - target) * mean_p / 255)
    beta = sum((p - mean_p) * b for p, b in zip(pixel, chroma_b)) / variance
    beta = min(1, max(0, beta))
    return round(min(255, max(0, mean_p + beta * (target - mean_b))))


def convert(source, name):
    rgb = source.convert('RGB')
    width, height = rgb.size
    out = Image.new('L', rgb.size)
    if name in EMPTY:
        # These originals have no glyph: retain the existing one-pixel frame,
        # flattening its gradient and the cream-colored empty interior.
        for y in range(height):
            for x in range(width):
                out.putpixel((x, y), 192 if x in (0, width-1) or y in (0, height-1) else 255)
        return out
    if name == 'category-multi':
        # Preserve the exact original four regions, using four flat gray tones.
        tones = ((160, 64), (96, 32))
        for y in range(height):
            for x in range(width):
                out.putpixel((x, y), tones[y >= height//2][x >= width//2])
        return out
    for y in range(height):
        # Both edges are clear of the original glyphs. Use the interior edges
        # rather than the original bevel's outermost column.
        samples = [rgb.getpixel((x, y)) for x in (2, 3, width-4, width-3)]
        background = tuple(median(pixel[channel] for pixel in samples) for channel in range(3))
        for x in range(width):
            out.putpixel((x, y), flatten_pixel(rgb.getpixel((x, y)), background, BACKGROUNDS[name]))
    return out


def main():
    DEST.mkdir(exist_ok=True)
    for path in sorted(SOURCE.glob('*.png')):
        with Image.open(path) as original:
            convert(original, path.stem).save(DEST / path.name, optimize=True)


if __name__ == '__main__':
    main()
