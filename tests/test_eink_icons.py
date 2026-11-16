import importlib.util
from pathlib import Path
import unittest
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('eink_icons', ROOT / 'tools/build_eink_icons.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class EinkIconsTest(unittest.TestCase):
    def test_complete_set_and_original_geometry(self):
        originals = sorted(builder.SOURCE.glob('*.png'))
        self.assertEqual({p.name for p in originals}, {p.name for p in builder.DEST.glob('*.png')})
        self.assertFalse(list(builder.DEST.glob('*.svg')), 'Rejected redraws must not be shipped')
        for source in originals:
            with self.subTest(icon=source.name), Image.open(source) as original, Image.open(builder.DEST / source.name) as actual:
                self.assertEqual(actual.size, original.size)
                self.assertEqual(actual.mode, 'L')
                expected = builder.convert(original, source.stem)
                self.assertEqual(actual.tobytes(), expected.tobytes(), 'Shipped PNG must come directly from original pixels')
                # Every fully white original symbol pixel remains white at
                # exactly the same coordinate; no font or symbol replacement.
                rgb = original.convert('RGB')
                for y in range(rgb.height):
                    for x in range(rgb.width):
                        if min(rgb.getpixel((x, y))) >= 245:
                            self.assertGreaterEqual(actual.getpixel((x, y)), 240)

    def test_flat_background_and_four_original_regions(self):
        for source in builder.SOURCE.glob('*.png'):
            if source.stem in builder.EMPTY or source.stem == 'category-multi':
                continue
            with self.subTest(icon=source.name), Image.open(builder.DEST / source.name) as image:
                # Far-left interior pixels are clear of all original glyphs.
                for y in range(1, image.height-1):
                    self.assertLessEqual(abs(image.getpixel((2, y)) - builder.BACKGROUNDS[source.stem]), 2)
        with Image.open(builder.DEST / 'category-multi.png') as image:
            self.assertEqual(len(image.getcolors()), 4)
            self.assertEqual([image.getpixel(p) for p in [(2, 2), (40, 2), (2, 40), (40, 40)]], [160, 64, 96, 32])

    def test_rating_backgrounds_get_progressively_darker(self):
        levels = []
        for rating in ['general-audience', 'teen', 'mature', 'explicit']:
            with Image.open(builder.DEST / f'rating-{rating}.png') as image:
                levels.append(image.getpixel((2, 25)))
        self.assertTrue(all(a-b >= 32 for a, b in zip(levels, levels[1:])))
        for family in [('complete-yes', 'complete-no'), ('warning-choosenotto', 'warning-yes')]:
            self.assertGreater(builder.BACKGROUNDS[family[0]], builder.BACKGROUNDS[family[1]])
        warning_levels = []
        for name in ['warning-no', 'warning-choosenotto', 'warning-yes']:
            with Image.open(builder.DEST / f'{name}.png') as image:
                warning_levels.append(image.getpixel((2, 25)))
        self.assertTrue(all(a > b for a, b in zip(warning_levels, warning_levels[1:])))

    def test_original_foreground_compositing(self):
        # Algebraic recovery of the original foreground preserves thin edges,
        # partial coverage, and shadows; there is no threshold or boldening.
        for background in [(230, 115, 0), (153, 0, 0), (0, 67, 167), (120, 167, 0)]:
            for foreground in [0, 100, 255]:
                for alpha in [0, .1, .25, .5, .75, 1]:
                    pixel = tuple(alpha*foreground + (1-alpha)*b for b in background)
                    expected = alpha*foreground + (1-alpha)*builder.BACKGROUND
                    self.assertLessEqual(abs(builder.flatten_pixel(pixel, background)-expected), 1)


if __name__ == '__main__':
    unittest.main()
