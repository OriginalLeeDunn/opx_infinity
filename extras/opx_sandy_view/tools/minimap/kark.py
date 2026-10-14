"""Kraken (KARK) decompression for rdar.py, through the libkraken.so WolvenKit ships."""
import ctypes, os, struct
_LIB = os.environ.get('OPX_KRAKEN', '/opt/wk/pkg/tools/net10.0/any/libkraken.so')
_K = None


def kark(blob):
    global _K
    if blob[:4] != b'KARK':
        return blob
    if _K is None:
        _K = ctypes.CDLL(_LIB)
        _K.Kraken_Decompress.restype = ctypes.c_int
        _K.Kraken_Decompress.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]
    size = struct.unpack_from('<I', blob, 4)[0]
    out = ctypes.create_string_buffer(size + 64)
    got = _K.Kraken_Decompress(blob[8:], len(blob) - 8, out, size)
    if got != size:
        raise ValueError('kraken: %d of %d' % (got, size))
    return out.raw[:size]
