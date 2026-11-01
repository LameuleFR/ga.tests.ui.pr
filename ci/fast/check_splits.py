"""Fail when a split of a long campaign does not cover exactly the files of the original campaign.

Usage: check_splits.py <tests/UI dir> <campaigns.json>
Mocha expands the TEST_PATH globs itself (minimatch, with brace expansion), so the same
expansion is reproduced here with brace expansion + pathlib globbing.
"""
import json
import re
import sys
from pathlib import Path


def braces(pattern):
    m = re.search(r'\{([^{}]*)\}', pattern)
    if not m:
        return [pattern]
    out = []
    for alt in m.group(1).split(','):
        out += braces(pattern[:m.start()] + alt + pattern[m.end():])
    return out


def expand(root, pattern):
    files = set()
    for p in braces(pattern):
        for f in root.glob(p):
            if f.is_file() and f.suffix == '.ts':
                files.add(f.relative_to(root).as_posix())
    return files


def script_glob(package, campaign):
    script = package['scripts'].get('test:' + campaign, '')
    m = re.search(r"TEST_PATH='([^']+)'", script)
    return m.group(1) if m else None


def main():
    tests_dir = Path(sys.argv[1])
    conf = json.load(open(sys.argv[2], encoding='utf-8'))
    package = json.load(open(tests_dir / 'package.json', encoding='utf-8'))
    root = tests_dir / 'campaigns'
    ok = True
    for original, parts in conf['splits'].items():
        glob = script_glob(package, original)
        if glob is None:
            print(f'{original}: no test script on this version, split unused')
            continue
        expected = expand(root, glob)
        got = {}
        for name, part in parts.items():
            got[name] = expand(root, part)
        union = set().union(*got.values())
        overlap = sum(len(v) for v in got.values()) - len(union)
        missing = expected - union
        extra = union - expected
        sizes = ', '.join(f'{k}={len(v)}' for k, v in got.items())
        print(f'{original}: {len(expected)} files -> {sizes}')
        if missing or extra or overlap:
            ok = False
            for f in sorted(missing):
                print(f'  MISSING {f}')
            for f in sorted(extra):
                print(f'  EXTRA   {f}')
            if overlap:
                print(f'  {overlap} file(s) in several parts')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
