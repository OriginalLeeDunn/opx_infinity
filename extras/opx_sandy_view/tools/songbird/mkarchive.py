"""Writes an RDAR v12 .archive (WolvenKit's layout) with Kraken-compressed CR2W files."""
import sys, os, struct, ctypes, hashlib, time
sys.path.insert(0, os.path.expanduser('~'))
from rdar import fnv1a64

_lib = ctypes.CDLL(os.path.expanduser('~/ooz/libooz.so'))
_compress = getattr(_lib, '_Z13CompressBlockiPhS_iiPK15CompressOptionsS_P10LRMCascade')
_compress.restype = ctypes.c_int
_compress.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_int,
                      ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
_dec = _lib.Ooz_Decompress
_dec.restype = ctypes.c_int
_dec.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int,
                 ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                 ctypes.c_size_t, ctypes.c_int]
KRAKEN, LEVEL = 8, 4

def kraken(data):
    src = ctypes.create_string_buffer(data, len(data))
    dst = ctypes.create_string_buffer(len(data) + 65536)
    n = _compress(KRAKEN, src, dst, len(data), LEVEL, None, None, None)
    if n <= 0:
        raise RuntimeError('compress failed')
    comp = dst.raw[:n]
    back = ctypes.create_string_buffer(len(data) + 64)
    m = _dec(comp, len(comp), back, len(data), 0, 0, 0, None, 0, None, None, None, 0, 0)
    assert m == len(data) and back.raw[:len(data)] == data, 'kraken round trip failed'
    return b'KARK' + struct.pack('<I', len(data)) + comp

POLY = 0xC96C5795D7870F42
_T = []
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ (POLY if c & 1 else 0)
    _T.append(c)
def crc64(b):
    c = 0xFFFFFFFFFFFFFFFF
    for x in b:
        c = (c >> 8) ^ _T[(c ^ x) & 0xFF]
    return c ^ 0xFFFFFFFFFFFFFFFF

def pad_page(buf):
    r = len(buf) % 4096
    if r:
        buf += b'\0' * (4096 - r)

def build(files):
    """files: {depot path: bytes} (CR2W files without buffers)."""
    entries = sorted(((fnv1a64(p.lower()), p, d) for p, d in files.items()), key=lambda x: x[0])
    out = bytearray(b'\0' * (40 + 132))
    fe, segs = [], []
    filetime = int((time.time() + 11644473600) * 10**7)
    for h, p, d in entries:
        start = len(segs)
        off = len(out)
        blob = kraken(d) if len(d) >= 256 else d
        out += blob
        segs.append((off, len(blob), len(d)))
        fe.append((h, filetime, 0, start, len(segs), 0, 0, hashlib.sha1(d).digest()))
    pad_page(out)
    table = bytearray(struct.pack('<III', len(fe), len(segs), 0))
    for e in fe:
        table += struct.pack('<QqIIIII', *e[:7]) + e[7]
    for s in segs:
        table += struct.pack('<QII', *s)
    ipos = len(out)
    out += struct.pack('<IIQ', 8, len(table) + 8, crc64(bytes(table))) + table
    isize = len(out) - ipos
    pad_page(out)
    struct.pack_into('<IIQIQIQ', out, 0, 0x52414452, 12, ipos, isize, 0, 0, len(out))
    struct.pack_into('<Q', out, 40, 0)
    return bytes(out)

if __name__ == '__main__':
    src, depot, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    data = build({depot: open(src, 'rb').read()})
    open(dst, 'wb').write(data)
    print('wrote', dst, len(data))
