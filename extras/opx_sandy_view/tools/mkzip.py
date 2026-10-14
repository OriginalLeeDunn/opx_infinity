"""Rebuilds dist/opx_sandy_view.zip -- the preload every player's launcher puts in
the game -- from src/, the same way every time.

The zip holds exactly the files under src/ (r6/scripts/... and archive/pc/mod/...),
deflated, Unix attributes, no extra fields. An entry whose bytes did not change
keeps its place and its date from the current zip, so rebuilding an unchanged
src/ gives the same zip, byte for byte (the sha256 the server prints at start,
`preloads 'dist/opx_sandy_view.zip' ... sha256=...`). A changed entry takes the
date given (default: today, UTC midnight); a new one is added after the others,
in path order; a removed one is dropped.

usage (from extras/opx_sandy_view):
  python3 tools/mkzip.py            rebuild dist/opx_sandy_view.zip, print its sha256
  python3 tools/mkzip.py --check    rebuild nothing; fail if the zip is not src/
  python3 tools/mkzip.py --date 2026-10-06
After a rebuild, bump `version` in open77.lua: the preload changed, so every
player boots the game through the launcher once.
"""
import argparse
import datetime
import hashlib
import os
import sys
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, 'src')
ZIP = os.path.join(ROOT, 'dist', 'opx_sandy_view.zip')


def sources():
    out = {}
    for d, _, files in os.walk(SRC):
        for f in files:
            p = os.path.join(d, f)
            out[os.path.relpath(p, SRC).replace(os.sep, '/')] = p
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--date', default=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d'))
    a = ap.parse_args()
    date = tuple(int(x) for x in a.date.split('-')) + (0, 0, 0)
    src = sources()
    old = []
    if os.path.exists(ZIP):
        with zipfile.ZipFile(ZIP) as z:
            old = z.infolist()
    if a.check:
        names = [i.filename for i in old]
        problems = sorted(set(src) ^ set(names))
        for i in old:
            if i.filename in src and zlib.crc32(open(src[i.filename], 'rb').read()) & 0xffffffff != i.CRC:
                problems.append(i.filename)
        if problems:
            print('dist/opx_sandy_view.zip is not src/: ' + ', '.join(problems))
            return 1
        print('dist/opx_sandy_view.zip is src/ (%d files), sha256 %s' % (len(names), hashlib.sha256(open(ZIP, 'rb').read()).hexdigest()))
        return 0
    order = [i for i in old if i.filename in src]
    kept = {i.filename for i in order}
    tmp = ZIP + '.tmp'
    os.makedirs(os.path.dirname(ZIP), exist_ok=True)
    with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as z:
        entries = [(i.filename, i) for i in order] + [(n, None) for n in sorted(set(src) - kept)]
        for name, info in entries:
            data = open(src[name], 'rb').read()
            same = info is not None and zlib.crc32(data) & 0xffffffff == info.CRC
            zi = zipfile.ZipInfo(name, date_time=info.date_time if same else date)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.create_system = 3
            zi.external_attr = info.external_attr if info is not None else (0o100644 << 16)
            z.writestr(zi, data)
    os.replace(tmp, ZIP)
    with zipfile.ZipFile(ZIP) as z:
        assert z.testzip() is None
        for name in src:
            assert z.read(name) == open(src[name], 'rb').read(), name
    print('dist/opx_sandy_view.zip: %d files, %d bytes, sha256 %s' % (
        len(src), os.path.getsize(ZIP), hashlib.sha256(open(ZIP, 'rb').read()).hexdigest()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
