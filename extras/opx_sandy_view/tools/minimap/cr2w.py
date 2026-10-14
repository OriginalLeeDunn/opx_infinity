import struct

class CR2W:
    def __init__(self, data):
        self.d = data
        (magic, ver, flags, ts, build, objEnd, bufEnd, crc, nchunks) = struct.unpack_from("<IIIQIIIII", data, 0)
        assert magic == 0x57325243, "not CR2W"
        self.version = ver
        o = 40
        self.tables = []
        for i in range(10):
            self.tables.append(struct.unpack_from("<III", data, o))
            o += 12
        soff, ssize, _ = self.tables[0]
        self.strpool = data[soff:soff + ssize]
        noff, ncount, _ = self.tables[1]
        self.names = []
        for i in range(ncount):
            so, hh = struct.unpack_from("<II", data, noff + i * 8)
            end = self.strpool.index(b"\0", so)
            self.names.append(self.strpool[so:end].decode("utf-8", "replace"))
        ioff, icount, _ = self.tables[2]
        self.imports = []
        for i in range(icount):
            so, cls, fl = struct.unpack_from("<IHH", data, ioff + i * 8)
            end = self.strpool.index(b"\0", so)
            self.imports.append((self.strpool[so:end].decode("utf-8", "replace"), self.names[cls] if cls < len(self.names) else cls, fl))
        eoff, ecount, _ = self.tables[4]
        self.exports = []
        for i in range(ecount):
            cls, oflags, parent, size, off, tmpl, ccrc = struct.unpack_from("<HHIIIII", data, eoff + i * 24)
            self.exports.append({"cls": self.names[cls], "parent": parent, "size": size, "off": off})
        boff, bcount, _ = self.tables[5]
        self.buffers = []
        for i in range(bcount):
            self.buffers.append(struct.unpack_from("<IIIIII", data, boff + i * 24))

PRIMS = {"Bool": ("<B", 1), "Uint8": ("<B", 1), "Int8": ("<b", 1), "Uint16": ("<H", 2), "Int16": ("<h", 2),
         "Uint32": ("<I", 4), "Int32": ("<i", 4), "Float": ("<f", 4), "Uint64": ("<Q", 8), "Int64": ("<q", 8),
         "Double": ("<d", 8)}

def read_vlq(d, o):
    b = d[o]; o += 1
    neg = b & 0x80
    val = b & 0x3F
    shift = 6
    more = b & 0x40
    while more:
        b = d[o]; o += 1
        val |= (b & 0x7F) << shift
        shift += 7
        more = b & 0x80
    return (-val if neg else val), o

class Parser:
    def __init__(self, c):
        self.c = c
        self.d = c.d
        self.unknown = {}

    def string(self, o):
        n, o = read_vlq(self.d, o)
        if n < 0:
            s = self.d[o:o - n].decode("utf-8", "replace"); o += -n
        else:
            s = self.d[o:o + 2 * n].decode("utf-16-le", "replace"); o += 2 * n
        return s, o

    def value(self, t, o, end):
        d = self.d
        c = self.c
        if t in PRIMS:
            fmt, n = PRIMS[t]
            return struct.unpack_from(fmt, d, o)[0], o + n
        if t == "CName":
            i = struct.unpack_from("<H", d, o)[0]
            return c.names[i] if i < len(c.names) else i, o + 2
        if t in ("String",):
            return self.string(o)
        if t == "NodeRef":
            return self.string(o)
        if t.startswith("handle:") or t.startswith("whandle:"):
            return ("#", struct.unpack_from("<i", d, o)[0]), o + 4
        if t.startswith("raRef:") or t.startswith("rRef:"):
            i = struct.unpack_from("<H", d, o)[0]
            return ("ref", c.imports[i - 1][0] if 0 < i <= len(c.imports) else i), o + 2
        if t.startswith("array:"):
            et = t[6:]
            n = struct.unpack_from("<I", d, o)[0]; o += 4
            out = []
            for _ in range(n):
                v, o = self.value(et, o, None)
                out.append(v)
            return out, o
        if t.startswith("static:"):
            # static:N,T
            rest = t[7:]
            cnt, et = rest.split(",", 1)
            n = struct.unpack_from("<I", d, o)[0]; o += 4
            out = []
            for _ in range(n):
                v, o = self.value(et, o, end)
                out.append(v)
            return out, o
        if t in ("TweakDBID",):
            return ("tdbid", struct.unpack_from("<Q", d, o)[0]), o + 8
        if t in ("CRUID",):
            return ("cruid", struct.unpack_from("<Q", d, o)[0]), o + 8
        if t in ("EntityID",):
            return self.props(o, end)
        kind = self.kinds.get(t)
        if kind is None:
            if end is not None and end - o == 2 and d[o] != 0:
                kind = "enum"
            elif d[o] == 0:
                kind = "struct"
            else:
                kind = "enum"
            self.kinds[t] = kind
        if kind == "enum":
            i = struct.unpack_from("<H", d, o)[0]
            return c.names[i] if i < len(c.names) else i, o + 2
        v, o = self.props(o + 1, end if end is not None else len(d))
        return v, o
        raise ValueError("unknown type " + t)

    kinds = {}

    def props(self, o, end):
        c = self.c
        d = self.d
        out = {}
        while o + 2 <= end:
            ni = struct.unpack_from("<H", d, o)[0]; o += 2
            if ni == 0:
                break
            ti, size = struct.unpack_from("<HI", d, o); o += 6
            name, t = c.names[ni], c.names[ti]
            vend = o + size - 4
            try:
                v, o2 = self.value(t, o, vend)
                if o2 != vend:
                    v = ("SIZE_MISMATCH", t, o2 - vend, v)
            except Exception as ex:
                v = ("ERR", t, str(ex), d[o:vend].hex()[:64])
                self.unknown[t] = self.unknown.get(t, 0) + 1
            out[name] = v
            o = vend
        return out, o

    def chunk(self, i):
        e = self.c.exports[i]
        o = e["off"]
        assert self.d[o] == 0, ("chunk lead byte", self.d[o])
        v, _ = self.props(o + 1, o + e["size"])
        return v
