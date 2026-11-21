#!/usr/bin/env python3
"""Run syntax checks and all current regression tests from the plugin root."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--epubcheck', type=Path, help='Optional EPUBCheck jar for reference validation')
    args = parser.parse_args()
    failures = []
    commands = []
    with tempfile.TemporaryDirectory(prefix='ao3-syntax-') as temp:
        for path in sorted([ROOT / '_meta.lua', ROOT / 'main.lua', *(ROOT / 'ao3lib').rglob('*.lua')]):
            result = subprocess.run(['luajit', '-b', str(path), str(Path(temp) / 'check.luac')],
                                    cwd=ROOT, text=True, capture_output=True)
            if result.returncode:
                failures.append(str(path.relative_to(ROOT)))
                print(result.stdout + result.stderr)
    commands += [(['luajit', str(path.relative_to(ROOT))], path.name)
                 for path in sorted((ROOT / 'tests').glob('test_*.lua'))]
    for path in sorted((ROOT / 'tests').glob('test_*.py')):
        command = [sys.executable, str(path.relative_to(ROOT))]
        if path.name in ('test_html_epub_reference.py', 'test_html_epub_validation.py') and args.epubcheck:
            command += ['--epubcheck', str(args.epubcheck.resolve())]
        commands.append((command, path.name))
    for command, name in commands:
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
        print(('PASS ' if result.returncode == 0 else 'FAIL ') + name, flush=True)
        if result.returncode:
            failures.append(name)
            print(result.stdout + result.stderr, flush=True)
    print(f'{len(commands)} test files; {len(failures)} failures', flush=True)
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
