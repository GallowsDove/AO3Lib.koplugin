"""Validate the offline symbol packs used by both renderers (requires Pillow)."""
from pathlib import Path
import hashlib
import json
from PIL import Image

assets = Path(__file__).resolve().parents[1] / 'assets'
expected = {path.name for path in (assets / 'ao3-icons').glob('*.png')}
assert len(expected) == 18
for style in ('ao3-icons-zerafina', 'ao3-icons-zerafina-eink'):
    folder = assets / style
    assert {path.name for path in folder.glob('*.png')} == expected
    for name in expected:
        with Image.open(folder / name) as image:
            assert image.size == (75, 75)
            if style.endswith('-eink'):
                assert image.mode == 'L'
                image = image.convert('RGB')
                r, g, b = image.split()
                assert r.tobytes() == g.tobytes() == b.tobytes(), name
    # Empty metadata stays blank; Multi stays visually distinguishable.
    assert (folder / 'category-multi.png').read_bytes() != (folder / 'category-none.png').read_bytes()
    assert (folder / 'rating-general-audience.png').read_bytes() != (folder / 'rating-teen.png').read_bytes()
source = assets / 'ao3-icons-zerafina' / 'source'
for entry in json.loads((source / 'manifest.json').read_text()):
    data = (source / ('zerafina-' + entry['name'])).read_bytes()
    git_sha = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
    assert git_sha == entry['sha'], entry['name']
assert 'Copyright (c) 2025 Zerafina' in (source.parent / 'LICENSE').read_text()
print('PASS: both complete offline packs; E-reader grayscale; distinct symbols; upstream mask integrity and license')

eink = assets / 'ao3-icons-zerafina-eink'
ratings = ['general-audience', 'teen', 'mature', 'explicit']
assert [Image.open(eink / f'rating-{rating}.png').getpixel((5, 5)) for rating in ratings] == [153, 119, 85, 51]
multi = Image.open(eink / 'category-multi.png')
assert [multi.getpixel(point) for point in ((10, 10), (60, 10), (10, 60), (60, 60))] == [160, 64, 96, 32]
empty = Image.open(eink / 'warning-no.png')
assert empty.getpixel((0, 0)) == 192 and empty.getpixel((5, 5)) == 255
print('PASS: E-reader rating tones, four-tone Multi and empty frames match ao3-icons-eink')
