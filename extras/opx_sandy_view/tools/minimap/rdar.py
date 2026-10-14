import struct, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kark import kark

def fnv1a64(s):
    h = 0xcbf29ce484222325
    for b in s.encode("utf-8"):
        h ^= b
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h

class Archive:
    def __init__(self, path):
        self.path = path
        self.f = open(path, "rb")
        hdr = self.f.read(40)
        magic, ver, ipos, isize, dpos, dsize, fsize = struct.unpack("<IIQIQIQ", hdr)
        assert magic == 0x52414452, hex(magic)
        self.version = ver
        self.f.seek(ipos)
        idx = self.f.read(isize)
        ftoff, ftsize, crc, nfiles, nsegs, ndeps = struct.unpack_from("<IIQIII", idx, 0)
        o = 28
        self.files = {}
        for i in range(nfiles):
            h, ts, ninl, s0, s1, d0, d1 = struct.unpack_from("<QqIIIII", idx, o)
            self.files[h] = (ninl, s0, s1, d0, d1)
            o += 56
        self.segs = []
        for i in range(nsegs):
            self.segs.append(struct.unpack_from("<QII", idx, o))
            o += 16
        self.deps = struct.unpack_from("<%dQ" % ndeps, idx, o)

    def read_segment(self, i):
        off, z, size = self.segs[i]
        self.f.seek(off)
        blob = self.f.read(z)
        if z == size:
            return blob
        return kark(blob)

    def read(self, path_or_hash, main_only=False):
        h = path_or_hash if isinstance(path_or_hash, int) else fnv1a64(path_or_hash.lower())
        e = self.files.get(h)
        if e is None:
            return None
        ninl, s0, s1, d0, d1 = e
        parts = [self.read_segment(s0)]
        if not main_only:
            for i in range(s0 + 1, s1):
                parts.append(self.read_segment(i))
        return b"".join(parts)

def read_parts(self, path_or_hash):
    h = path_or_hash if isinstance(path_or_hash, int) else fnv1a64(path_or_hash.lower())
    e = self.files.get(h)
    if e is None:
        return None
    ninl, s0, s1, d0, d1 = e
    return [self.read_segment(i) for i in range(s0, s1)]
Archive.read_parts = read_parts
