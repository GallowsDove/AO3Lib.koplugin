#!/usr/bin/env python3
"""Build offline Zerafina symbols from the bundled upstream PNG masks (Pillow)."""
from pathlib import Path
from PIL import Image, ImageDraw
from build_eink_icons import convert as convert_eink

ASSETS = Path(__file__).resolve().parents[1] / 'assets'
COLOR = ASSETS / 'ao3-icons-zerafina'
EINK = ASSETS / 'ao3-icons-zerafina-eink'
# Upstream code-default.css supplies the colors. The original Multi design
# uses four colored quadrants, retained as four tones in the E-reader variant.
ICONS = {
    'rating-general-audience': ('rating-gen', '#8bc101'),
    'rating-teen': ('rating-teen', '#f5ce00'),
    'rating-mature': ('rating-mature', '#ef851c'),
    'rating-explicit': ('rating-explicit', '#b0021f'),
    'category-femslash': ('category-ff', '#b0021f'),
    'category-het': ('category-mf', '#910679'),
    'category-gen': ('category-gen', '#8bc101'),
    'category-slash': ('category-mm', '#0054d4'),
    'category-multi': ('category-multi', None),
    'category-other': ('category-other', '#000000'),
    'warning-choosenotto': ('warning-choosenotto', '#ef851c'),
    'warning-yes': ('warning-yes', '#b0021f'),
    'warning-external-work': ('warning-external-work', '#107cb9'),
    'complete-no': ('complete-no', '#b0021f'),
    'complete-yes': ('complete-yes', '#8bc101'),
    'rating-notrated': (None, '#ffffff'),
    'category-none': (None, '#ffffff'),
    'warning-no': (None, '#ffffff'),
}


def build():
    COLOR.mkdir(exist_ok=True)
    EINK.mkdir(exist_ok=True)
    for name, (source, color) in ICONS.items():
        image = Image.new('RGBA', (75, 75), color or 'white')
        draw = ImageDraw.Draw(image)
        if name == 'category-multi':
            for box, fill in (((0, 0, 37, 37), '#8bc101'), ((38, 0, 74, 37), '#910679'),
                              ((38, 38, 74, 74), '#0054d4'), ((0, 38, 37, 74), '#b0021f')):
                draw.rectangle(box, fill=fill)
        elif source:
            with Image.open(COLOR / 'source' / f'zerafina-{source}-01.png') as mask:
                image.alpha_composite(mask.convert('RGBA'))
        # Match the skin's one-pixel border on the color version.
        pixel = image.getpixel((0, 0))
        alpha = .1 if source else .25
        border = tuple(round(c * (1 - alpha)) for c in pixel[:3]) + (255,)
        ImageDraw.Draw(image).rectangle((0, 0, 74, 74), outline=border, width=1)
        rgb = image.convert('RGB')
        rgb.save(COLOR / f'{name}.png', optimize=True)
        # Use exactly the same flat backgrounds, rating tones, empty frames,
        # quadrant tones and foreground reconstruction as ao3-icons-eink.
        convert_eink(rgb, name).save(EINK / f'{name}.png', optimize=True)


if __name__ == '__main__':
    build()
