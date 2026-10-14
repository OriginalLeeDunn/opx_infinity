"""Packs opx_minimap.archive with every segment STORED (no compression) -- the
writer of tools/ghost/pack.py, unchanged but for one line: every file's buffers
are inline, as the base game's own .xbm (1) and .inkwidget (2) entries are.

(From tools/ghost/pack.py:)

WolvenKit on Linux compresses with its own Kraken build, and two of its streams
(the re-rigged arms' and head's render buffers) cannot be read back by an
independent Kraken decoder -- a stream the game's Oodle might refuse too. The
game reads stored segments as they are (1,073 of basegame_1_engine's are), so
nothing here is compressed at all:

  * each CR2W file WolvenKit wrote is split into its main part and its buffers,
    the buffers decompressed (WolvenKit's own decoder reads its own streams) and
    written back raw: buffer table offset/diskSize/crc32, table 5's crc32 and
    the header crc (crc32 of the 160-byte header with the crc field set to
    0xDEADBEEF) all recomputed;
  * a mesh's buffers must equal the base game's own, byte for byte (the
    re-rig only touches the main part): checked against the original file;
  * RDAR v12: 40-byte header, data from offset 172 like CDPR's archives,
    entries sorted by hash, index CRC-64/XZ over the index from its counts,
    index and file end 4 KiB aligned;
  * each file's DEPENDENCIES are its CR2W hard imports (flags 0), hashed and
    sorted, exactly as the base game's archives list them (the game's own
    minimap.inkwidget: its 15 hard imports; prototype_hud.inkhud: its 71). The
    first 1.4.18 build wrote none.
"""
import ctypes
import hashlib
import os
import struct
import sys
import zlib

KRAKEN = ctypes.CDLL('/opt/wk/pkg/tools/net10.0/any/libkraken.so')
KRAKEN.Kraken_Decompress.restype = ctypes.c_int
KRAKEN.Kraken_Decompress.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]


def kark(blob):
    if blob[:4] != b'KARK':
        return blob
    size = struct.unpack_from('<I', blob, 4)[0]
    out = ctypes.create_string_buffer(size + 64)
    got = KRAKEN.Kraken_Decompress(blob[8:], len(blob) - 8, out, size)
    if got != size:
        raise ValueError('kraken: %d of %d' % (got, size))
    return out.raw[:size]


def split(raw):
    """(main part, [decompressed buffers], [buffer table entries])"""
    assert raw[:4] == b'CR2W'
    version, flags, ts, build, objects_end, buffers_end, crc, nchunks = struct.unpack_from('<IIQIIIII', raw, 4)
    b_off, b_cnt, b_crc = struct.unpack_from('<III', raw, 40 + 12 * 5)
    buffers, entries = [], []
    for i in range(b_cnt):
        e = list(struct.unpack_from('<IIIIII', raw, b_off + 24 * i))
        fl, idx, off, disk, mem, bcrc = e
        data = kark(raw[off:off + disk])
        assert len(data) == mem, (i, len(data), mem)
        buffers.append(data)
        entries.append(e)
    return bytearray(raw[:objects_end]), buffers, entries


def split_main(raw):
    """(main part, buffer table entries) without touching the buffers."""
    assert raw[:4] == b'CR2W'
    objects_end = struct.unpack_from('<I', raw, 4 + 20)[0]
    b_off, b_cnt, b_crc = struct.unpack_from('<III', raw, 40 + 12 * 5)
    entries = [list(struct.unpack_from('<IIIIII', raw, b_off + 24 * i)) for i in range(b_cnt)]
    return bytearray(raw[:objects_end]), entries


def stored(raw, reference=None):
    """The same CR2W file with every buffer stored raw. With `reference` (the
    base game's own buffers, decompressed), those are used instead of
    WolvenKit's: its Linux Kraken encoder writes large streams that no decoder
    reads back, its own included."""
    if reference is None:
        main, buffers, entries = split(raw)
    else:
        main, entries = split_main(raw)
        assert len(entries) == len(reference)
        for e, data in zip(entries, reference):
            assert e[4] == len(data), 'buffer size differs from the base game'
        buffers = list(reference)
    objects_end = len(main)
    b_off, b_cnt, b_crc = struct.unpack_from('<III', main, 40 + 12 * 5)
    offset = objects_end
    for i, data in enumerate(buffers):
        fl, idx, off, disk, mem, bcrc = entries[i]
        struct.pack_into('<IIIIII', main, b_off + 24 * i, fl, idx, offset, len(data), len(data), zlib.crc32(data))
        offset += len(data)
    struct.pack_into('<I', main, 40 + 12 * 5 + 8, zlib.crc32(bytes(main[b_off:b_off + 24 * b_cnt])))
    struct.pack_into('<I', main, 4 + 24, offset)  # buffersEnd
    struct.pack_into('<I', main, 32, 0xDEADBEEF)
    struct.pack_into('<I', main, 32, zlib.crc32(bytes(main[:160])))
    return bytes(main), buffers


def fnv1a64(text):
    h = 0xcbf29ce484222325
    for b in text.lower().encode('utf-8'):
        h ^= b
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


def crc64_xz(data):
    poly = 0xC96C5795D7870F42
    table = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = (c >> 1) ^ poly if c & 1 else c >> 1
        table.append(c)
    c = 0xFFFFFFFFFFFFFFFF
    for b in data:
        c = table[(c ^ b) & 0xFF] ^ (c >> 8)
    return c ^ 0xFFFFFFFFFFFFFFFF


def hard_imports(raw):
    """The depot paths a CR2W file imports with no flag (Default) -- the ones an
    archive lists as the file's dependencies. Soft (4) imports are not listed."""
    assert raw[:4] == b'CR2W'
    soff, ssize, _ = struct.unpack_from('<III', raw, 40)
    ioff, icount, _ = struct.unpack_from('<III', raw, 40 + 12 * 2)
    out = []
    for i in range(icount):
        so, cls, fl = struct.unpack_from('<IHH', raw, ioff + i * 8)
        start = soff + so
        end = raw.index(b'\0', start)
        if fl == 0:
            out.append(raw[start:end].decode('utf-8'))
    return out


def write_archive(path, files, timestamp):
    """files: [(depot path, main bytes, [buffers], numInlineBufferSegments)]"""
    files = sorted(files, key=lambda f: fnv1a64(f[0]))
    body = bytearray()
    base = 172
    entries, segments, deps = [], [], []
    for depot, main, buffers, inline in files:
        first = len(segments)
        for blob in [main] + list(buffers):
            segments.append((base + len(body), len(blob), len(blob)))
            body += blob
        d0 = len(deps)
        deps.extend(sorted({fnv1a64(p) for p in hard_imports(main)}))
        entries.append((fnv1a64(depot), timestamp, inline, first, len(segments), d0, len(deps),
                        hashlib.sha1(b'').digest()))
    index_pos = base + len(body)
    pad = (-index_pos) % 4096
    index_pos += pad
    tail = bytearray()
    tail += struct.pack('<III', len(entries), len(segments), len(deps))
    for h, ts, inline, s0, s1, d0, d1, sha in entries:
        tail += struct.pack('<QqIIIII', h, ts, inline, s0, s1, d0, d1) + sha
    for off, z, s in segments:
        tail += struct.pack('<QII', off, z, s)
    for d in deps:
        tail += struct.pack('<Q', d)
    crc = crc64_xz(bytes(tail))
    index = struct.pack('<IIQ', 8, 8 + len(tail), crc) + bytes(tail)
    total = index_pos + len(index)
    total += (-total) % 4096
    header = struct.pack('<4sIQIQIQ', b'RDAR', 12, index_pos, len(index), 0, 0, total)
    out = bytearray(header) + bytearray(base - len(header)) + body + bytearray(pad) + index
    out += bytearray(total - len(out))
    with open(path, 'wb') as f:
        f.write(out)
    return len(out), len(entries), len(segments)


if __name__ == '__main__':
    root, out_path = sys.argv[1], sys.argv[2]
    originals = dict(arg.split('=', 1) for arg in sys.argv[3:])  # depot=original raw file
    files = []
    for dirpath, dirs, names in os.walk(root):
        for name in sorted(names):
            full = os.path.join(dirpath, name)
            depot = os.path.relpath(full, root).replace('/', '\\')
            raw = open(full, 'rb').read()
            reference = None
            if depot in originals:
                _, reference, _ = split(open(originals[depot], 'rb').read())
                # Where WolvenKit's stream CAN be read, it must equal the base
                # game's buffer byte for byte (the re-rig only edits the main part).
                _, wk_entries = split_main(raw)
                compared = 0
                for i, e in enumerate(wk_entries):
                    try:
                        mine = kark(raw[e[2]:e[2] + e[3]])
                    except ValueError:
                        continue
                    assert mine == reference[i], '%s buffer %d differs from the base game' % (depot, i)
                    compared += 1
                print('%s: base game buffers used (%d of %d also read back from WolvenKit and equal)'
                      % (depot, compared, len(reference)))
            main, buffers = stored(raw, reference)
            inline = len(buffers)
            files.append((depot, main, buffers, inline))
            # the rewritten file must read back as the same content
            main2, buffers2, entries2 = split(main + b''.join(buffers))
            assert buffers2 == buffers
            print('%-44s main %7d  buffers %s' % (depot, len(main), [len(b) for b in buffers][:4]))
    size, n_files, n_segments = write_archive(out_path, files, 134349600000000000)
    print('archive %s: %d bytes, %d files, %d segments, all stored' % (out_path, size, n_files, n_segments))
