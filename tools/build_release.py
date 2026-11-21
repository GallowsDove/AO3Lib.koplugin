#!/usr/bin/env python3
"""Build the install ZIP and checksum; never include development files or README."""
import argparse
import hashlib
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = 'AO3Lib.koplugin'
ASSET = 'AO3Lib.koplugin.zip'
VERSION = re.compile(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?')


def version(root=ROOT):
    match = re.search(r'^\s*version\s*=\s*"([^"]+)"\s*,', (root / '_meta.lua').read_text(), re.M)
    if not match or not VERSION.fullmatch(match[1]):
        raise ValueError('_meta.lua must contain a semantic version such as 0.1.0 or 0.2.0-rc.1')
    return match[1]


def runtime_files(root=ROOT):
    files = [root / '_meta.lua', root / 'main.lua']
    files += sorted((root / 'ao3lib').rglob('*.lua'))
    files += sorted(path for path in (root / 'assets').rglob('*')
                    if path.is_file() and 'source' not in path.relative_to(root / 'assets').parts
                    and not any(part.startswith('.') for part in path.relative_to(root).parts))
    for path in files:
        if path.is_symlink() or not path.is_file():
            raise ValueError(f'Invalid runtime file: {path}')
    return sorted(set(files))


def build(output, tag=None, root=ROOT):
    release_version = version(root)
    if tag is not None and tag != 'v' + release_version:
        raise ValueError(f'Tag {tag!r} must match _meta.lua version v{release_version}')
    output.mkdir(parents=True, exist_ok=True)
    target = output / ASSET
    # Fixed timestamps and permissions give identical ZIPs for identical files.
    with zipfile.ZipFile(target, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in runtime_files(root):
            name = PLUGIN + '/' + path.relative_to(root).as_posix()
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    (output / 'SHA256SUMS').write_text(f'{digest}  {ASSET}\n')
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist')
    parser.add_argument('--tag', help='Require this tag to match _meta.lua')
    args = parser.parse_args()
    try:
        target = build(args.output, args.tag)
    except ValueError as error:
        parser.error(str(error))
    print(f'Built {target} (v{version()})')


if __name__ == '__main__':
    main()
