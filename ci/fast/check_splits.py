"""Fail when the parts of a split campaign do not load exactly the spec files of the original campaign.

Usage: check_splits.py <tests/UI dir> <campaigns.json>

What runs is what `npm run test:specific` loads, not what the glob means:
  ts-mocha ... campaigns/$TEST_PATH      ($TEST_PATH unquoted, run by npm with /bin/sh)
1. /bin/sh (dash on Ubuntu) applies POSIX pathname expansion to the word: no brace expansion and
   no globstar (`**` is `*`). A pattern matching nothing stays as is.
2. mocha takes every resulting word: an existing file is loaded, an existing directory is loaded
   recursively (.mocharc recursive), anything else with glob magic goes through its own glob
   (minimatch: braces, real `**`), else the word + a spec extension.
Each part must load the files of the original campaign it matches with real glob semantics, and
the parts together exactly the files of the original campaign, none twice.
"""
import fnmatch
import json
import re
import sys
from pathlib import Path

# Mocha's default extensions are combined with the .mocharc ones (yargs combine-arrays).
EXTENSIONS = ('.js', '.cjs', '.mjs', '.ts')


def sh_magic(segment):
    return any(c in segment for c in '*?[')


def sh_expand(cwd, word):
    """Dash pathname expansion of an unquoted word (relative paths only)."""
    if not sh_magic(word):
        return [word]
    matches = ['']
    segments = word.split('/')
    for i, seg in enumerate(segments):
        nxt = []
        for prefix in matches:
            base = cwd / prefix if prefix else cwd
            if not sh_magic(seg):
                nxt.append(prefix + seg)
                continue
            if not base.is_dir():
                continue
            for entry in sorted(e.name for e in base.iterdir()):
                if entry.startswith('.') and not seg.startswith('.'):
                    continue
                if fnmatch.fnmatchcase(entry, seg):
                    nxt.append(prefix + entry)
        matches = [m + '/' if i < len(segments) - 1 else m for m in nxt]
    found = sorted(m for m in matches if (cwd / m).exists())
    return found or [word]


def braces(pattern):
    """Minimatch brace expansion (comma lists, nested), innermost first."""
    for m in re.finditer(r'\{([^{}]*)\}', pattern):
        if ',' in m.group(1):
            out = []
            for alt in m.group(1).split(','):
                out += braces(pattern[:m.start()] + alt + pattern[m.end():])
            return out
    return [pattern]


def glob_magic(word):
    return len(braces(word)) > 1 or sh_magic(word)


def segments_match(pats, parts):
    if not pats:
        return not parts
    if pats[0] == '**':
        for k in range(len(parts) + 1):
            if k and parts[k - 1].startswith('.'):
                break
            if segments_match(pats[1:], parts[k:]):
                return True
        return False
    if not parts:
        return False
    if parts[0].startswith('.') and not pats[0].startswith('.'):
        return False
    return fnmatch.fnmatchcase(parts[0], pats[0]) and segments_match(pats[1:], parts[1:])


def all_files(cwd, top):
    root = cwd / top
    return [p.relative_to(cwd).as_posix() for p in root.rglob('*') if p.is_file()] if root.is_dir() else []


def glob_files(pattern, universe):
    """Mocha's glob (glob@10 + minimatch, nodir, no dot files): every matching file, any extension."""
    alternatives = [p.split('/') for p in braces(pattern)]
    return {f for f in universe if any(segments_match(a, f.split('/')) for a in alternatives)}


def dir_files(cwd, rel):
    out = set()
    for p in (cwd / rel).rglob('*'):
        if p.is_file() and p.suffix in EXTENSIONS and not p.name.startswith('.'):
            out.add(p.relative_to(cwd).as_posix())
    return out


def mocha_files(cwd, word, universe):
    path = cwd / word
    if path.is_file():
        return {Path(word).as_posix()}
    if path.is_dir():
        return dir_files(cwd, word)
    if glob_magic(word):
        return glob_files(word, universe)
    return {word + e for e in EXTENSIONS if (cwd / (word + e)).is_file()}


def loaded(cwd, test_path, universe):
    """Spec files that `TEST_PATH=<test_path> npm run test:specific` loads, and the sh words."""
    words = sh_expand(cwd, 'campaigns/' + test_path)
    files = set()
    for w in words:
        files |= mocha_files(cwd, w, universe)
    return files, words


def script_glob(package, campaign):
    script = package['scripts'].get('test:' + campaign, '')
    m = re.fullmatch(r"TEST_PATH='([^']+)' npm run test:specific", script.strip())
    return m.group(1) if m else None


def main():
    cwd = Path(sys.argv[1])
    conf = json.load(open(sys.argv[2], encoding='utf-8'))
    package = json.load(open(cwd / 'package.json', encoding='utf-8'))
    specific = package['scripts'].get('test:specific', '')
    if specific != 'ts-mocha $EXTRA_TEST_PARAMS --file utils/setup.ts campaigns/$TEST_PATH':
        print(f'::error::unexpected test:specific script, cannot check the splits: {specific}')
        sys.exit(1)
    universe = all_files(cwd, 'campaigns')
    ok = True
    for original, parts in conf['splits'].items():
        glob = script_glob(package, original)
        if glob is None:
            if 'test:' + original in package['scripts']:
                print(f'{original}: unexpected script form, cannot check: {package["scripts"]["test:" + original]}')
                ok = False
            else:
                print(f'{original}: no test script on this version, split unused')
            continue
        expected, _ = loaded(cwd, glob, universe)
        got, notes = {}, []
        for name, part in parts.items():
            got[name], words = loaded(cwd, part, universe)
            intended = glob_files('campaigns/' + part, universe)
            if got[name] != intended:
                ok = False
                shown = words if len(words) <= 5 else words[:5] + [f'... {len(words) - 5} more']
                notes.append(f'  {name}: /bin/sh expands its glob to {len(words)} word(s) {shown}: loads '
                             f'{len(got[name])} files instead of the {len(intended)} the glob matches')
                notes += [f'    DROPPED {f}' for f in sorted(intended - got[name])]
                notes += [f'    ADDED   {f}' for f in sorted(got[name] - intended)]
        union = set().union(*got.values())
        overlap = sorted({f for f in union if sum(f in v for v in got.values()) > 1})
        missing = expected - union
        extra = union - expected
        sizes = ', '.join(f'{k}={len(v)}' for k, v in got.items())
        print(f'{original}: {len(expected)} files -> {sizes}')
        for n in notes:
            print(n)
        if missing or extra or overlap:
            ok = False
            for f in sorted(missing):
                print(f'  MISSING   {f}')
            for f in sorted(extra):
                print(f'  EXTRA     {f}')
            for f in overlap:
                print(f'  DUPLICATE {f}')
    if not ok:
        print('::error::campaign splits do not load the files of the original campaigns, see above')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
