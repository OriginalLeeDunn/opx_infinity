"""Typed CR2W (v195) reader/writer for quest resources and scenes (cyn_q305).

Chunks whose native serialisation adds bytes after the property list
(scnAnimName ...) keep them verbatim (`tail`). New names may be added
(appended to the name table, so every existing index stays).

read_doc(bytes) -> doc ; write_doc(doc) -> bytes.  A doc is
  {'header': {...}, 'names': [...] or None, 'imports': [(path, clsIndexName, flags)],
   'exports': [{'cls', 'flags', 'parent', 'template', 'crc', 'props': [(name, type, value)]}]}
Values are tagged tuples so that writing reproduces the bytes exactly:
  primitives -> ('p', python value)      CName -> ('n', str)
  String/NodeRef -> ('s', str, 'utf8'|'utf16')
  handle -> ('h', int)  (1-based chunk index, 0 = null)   raRef/rRef -> ('r', importIndex)
  array/static -> ('a', [values])        enum -> ('e', str)
  bitfield -> ('b', [str,...])           struct -> ('c', [(name, type, value)])
  TweakDBID -> ('t', int)  CRUID -> ('u', int)
"""
import struct, zlib

MAGIC = 0x57325243
DEADBEEF = 0xDEADBEEF
PRIMS = {"Bool": "<B", "Uint8": "<B", "Int8": "<b", "Uint16": "<H", "Int16": "<h", "Uint32": "<I",
         "Int32": "<i", "Float": "<f", "Uint64": "<Q", "Int64": "<q", "Double": "<d"}

def fnv1a64(b):
    h = 0xCBF29CE484222325
    for x in b:
        h ^= x
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h

def name_hash(s):
    """The CR2W name-table hash: FNV-1a 64 folded to 32 bits (0 for the empty name)."""
    if s == "":
        return 0
    h = fnv1a64(s.encode("utf-8"))
    return (h & 0xFFFFFFFF) ^ (h >> 32)

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

def write_vlq(n):
    neg = n < 0
    v = -n if neg else n
    first = (v & 0x3F) | (0x80 if neg else 0)
    v >>= 6
    out = bytearray()
    if v:
        first |= 0x40
    out.append(first)
    while v:
        b = v & 0x7F
        v >>= 7
        if v:
            b |= 0x80
        out.append(b)
    return bytes(out)

# type-kind knowledge learned from sizes (enum vs struct vs bitfield)
KINDS = {}

class Reader:
    def __init__(self, data):
        self.d = data
        (magic, ver, flags, ts, build, objEnd, bufEnd, crc, nch) = struct.unpack_from("<IIIQIIIII", data, 0)
        assert magic == MAGIC
        self.header = dict(version=ver, flags=flags, timestamp=ts, build=build, objectsEnd=objEnd,
                           buffersEnd=bufEnd, crc=crc, numChunks=nch)
        self.tables = [struct.unpack_from("<III", data, 40 + 12 * i) for i in range(10)]
        soff, ssize, _ = self.tables[0]
        self.pool = data[soff:soff + ssize]
        noff, ncount, _ = self.tables[1]
        self.names = []
        for i in range(ncount):
            so, hh = struct.unpack_from("<II", data, noff + 8 * i)
            self.names.append(self.cstr(so))
        ioff, icount, _ = self.tables[2]
        self.imports = []
        for i in range(icount):
            so, cls, fl = struct.unpack_from("<IHH", data, ioff + 8 * i)
            self.imports.append((self.cstr(so), cls, fl))
        eoff, ecount, _ = self.tables[4]
        self.exports = []
        for i in range(ecount):
            cls, ofl, parent, size, off, tmpl, ccrc = struct.unpack_from("<HHIIIII", data, eoff + 24 * i)
            self.exports.append(dict(clsIndex=cls, cls=self.names[cls], flags=ofl, parent=parent, size=size,
                                     off=off, template=tmpl, crc=ccrc))
        bcount = self.tables[5][1]
        assert bcount == 0, "buffers not supported"
        assert self.tables[6][1] == 0, "embedded files not supported"

    def cstr(self, so):
        e = self.pool.index(b"\0", so)
        return self.pool[so:e].decode("utf-8")

    def value(self, t, o, end):
        d = self.d
        if t in PRIMS:
            fmt = PRIMS[t]
            return ("p", struct.unpack_from(fmt, d, o)[0]), o + struct.calcsize(fmt)
        if t == "CName":
            return ("n", self.names[struct.unpack_from("<H", d, o)[0]]), o + 2
        if t in ("String", "NodeRef"):
            n, o = read_vlq(d, o)
            if n < 0:
                return ("s", d[o:o - n].decode("utf-8"), "utf8"), o - n
            return ("s", d[o:o + 2 * n].decode("utf-16-le"), "utf16"), o + 2 * n
        if t.startswith("handle:") or t.startswith("whandle:"):
            return ("h", struct.unpack_from("<i", d, o)[0]), o + 4
        if t.startswith("raRef:") or t.startswith("rRef:"):
            return ("r", struct.unpack_from("<H", d, o)[0]), o + 2
        if t == "TweakDBID":
            return ("t", struct.unpack_from("<Q", d, o)[0]), o + 8
        if t == "LocalizationString":
            unk = struct.unpack_from("<Q", d, o)[0]
            n, o2 = read_vlq(d, o + 8)
            if n < 0:
                return ("l", unk, d[o2:o2 - n].decode("utf-8"), "utf8"), o2 - n
            return ("l", unk, d[o2:o2 + 2 * n].decode("utf-16-le"), "utf16"), o2 + 2 * n
        if t == "Variant":
            ti = struct.unpack_from("<H", d, o)[0]
            size = struct.unpack_from("<I", d, o + 2)[0]
            vt = self.names[ti]
            inner, o2 = self.value(vt, o + 6, o + 2 + size)
            assert o2 == o + 2 + size, ("variant size", vt)
            return ("v", vt, inner), o2
        if t == "CRUID":
            return ("u", struct.unpack_from("<Q", d, o)[0]), o + 8
        if t.startswith("array:"):
            et = t[6:]
            n = struct.unpack_from("<I", d, o)[0]; o += 4
            out = []
            for _ in range(n):
                v, o = self.value(et, o, None)
                out.append(v)
            return ("a", out), o
        if t.startswith("static:") or t.startswith("["):
            if t.startswith("static:"):
                et = t[7:].split(",", 1)[1]
            else:
                et = t[t.index("]") + 1:]
            n = struct.unpack_from("<I", d, o)[0]; o += 4
            out = []
            for _ in range(n):
                v, o = self.value(et, o, None)
                out.append(v)
            return ("a", out), o
        kind = KINDS.get(t)
        if kind is None:
            if end is None:
                kind = "struct" if d[o] == 0 else "enum"
            else:
                size = end - o
                if d[o] == 0 and size >= 3:
                    kind = "struct"
                elif size == 2:
                    kind = "enum" if d[o:o + 2] != b"\0\0" else "bitfield"
                elif size % 2 == 0 and d[end - 2:end] == b"\0\0":
                    kind = "bitfield"
                else:
                    raise ValueError("cannot classify %s (%d bytes)" % (t, size))
            KINDS[t] = kind
        if kind == "enum":
            return ("e", self.names[struct.unpack_from("<H", d, o)[0]]), o + 2
        if kind == "bitfield":
            flags = []
            while True:
                i = struct.unpack_from("<H", d, o)[0]; o += 2
                if i == 0:
                    break
                flags.append(self.names[i])
            return ("b", flags), o
        assert d[o] == 0, (t, d[o])
        props, o = self.props(o + 1)
        return ("c", props), o

    def props(self, o):
        d = self.d
        out = []
        while True:
            ni = struct.unpack_from("<H", d, o)[0]; o += 2
            if ni == 0:
                break
            ti, size = struct.unpack_from("<HI", d, o); o += 6
            name, t = self.names[ni], self.names[ti]
            vend = o + size - 4
            v, o2 = self.value(t, o, vend)
            assert o2 == vend, ("size mismatch", name, t, o2, vend)
            out.append((name, t, v))
            o = vend
        return out, o

def read_doc(data):
    r = Reader(data)
    exports = []
    for e in r.exports:
        o = e["off"]
        assert data[o] == 0
        props, end = r.props(o + 1)
        tail = b""
        if end != o + e["size"]:
            assert end < o + e["size"], ("chunk size", e["cls"], end, o + e["size"])
            tail = data[end:o + e["size"]]
        exports.append(dict(cls=e["cls"], flags=e["flags"], parent=e["parent"], template=e["template"],
                            crc=e["crc"], props=props, tail=tail))
    imports = [(p, r.names[c] if c < len(r.names) else "", fl) for (p, c, fl) in r.imports]
    return dict(header=r.header, names=list(r.names), imports=imports, exports=exports)

class Writer:
    def __init__(self, names=None, allow_new=False):
        self.names = list(names) if names is not None else [""]
        self.index = {n: i for i, n in enumerate(self.names)}
        self.fixed = names is not None and not allow_new

    def name(self, s):
        i = self.index.get(s)
        if i is None:
            assert not self.fixed, "name not in fixed table: " + s
            i = len(self.names)
            self.names.append(s)
            self.index[s] = i
        return i

    def value(self, t, v, out):
        tag = v[0]
        if tag == "p":
            out += struct.pack(PRIMS[t], v[1])
        elif tag == "n":
            out += struct.pack("<H", self.name(v[1]))
        elif tag == "s":
            s = v[1]
            if v[2] == "utf8":
                b = s.encode("utf-8")
                out += write_vlq(-len(b)) if b else write_vlq(0)
                out += b
            else:
                b = s.encode("utf-16-le")
                out += write_vlq(len(b) // 2) + b
        elif tag == "h":
            out += struct.pack("<i", v[1])
        elif tag == "r":
            out += struct.pack("<H", v[1])
        elif tag in ("t", "u"):
            out += struct.pack("<Q", v[1])
        elif tag == "l":
            out += struct.pack("<Q", v[1])
            self.value("String", ("s", v[2], v[3]), out)
        elif tag == "v":
            out += struct.pack("<H", self.name(v[1]))
            sp = len(out)
            out += b"\0\0\0\0"
            self.value(v[1], v[2], out)
            struct.pack_into("<I", out, sp, len(out) - sp)
        elif tag == "a":
            if t.startswith("array:"):
                et = t[6:]
            elif t.startswith("static:"):
                et = t[7:].split(",", 1)[1]
            else:
                et = t[t.index("]") + 1:]
            out += struct.pack("<I", len(v[1]))
            for x in v[1]:
                self.value(et, x, out)
        elif tag == "e":
            out += struct.pack("<H", self.name(v[1]))
        elif tag == "b":
            for f in v[1]:
                out += struct.pack("<H", self.name(f))
            out += struct.pack("<H", 0)
        elif tag == "c":
            out += b"\0"
            self.props(v[1], out)
        else:
            raise ValueError(tag)

    def props(self, props, out):
        for (name, t, v) in props:
            out += struct.pack("<HH", self.name(name), self.name(t))
            sp = len(out)
            out += b"\0\0\0\0"
            self.value(t, v, out)
            struct.pack_into("<I", out, sp, len(out) - sp)
        out += struct.pack("<H", 0)

def write_doc(doc, allow_new_names=False):
    w = Writer(doc.get("names"), allow_new_names)
    exports = doc["exports"]
    chunks = []
    for e in exports:
        ci = w.name(e["cls"])
        body = bytearray(b"\0")
        w.props(e["props"], body)
        body += e.get("tail", b"")
        chunks.append((ci, bytes(body)))
    imports = doc.get("imports", [])
    for (p, c, fl) in imports:
        w.name(c)
    names = w.names
    # string buffer: names then import paths
    pool = bytearray()
    noffs = []
    for n in names:
        noffs.append(len(pool))
        pool += n.encode("utf-8") + b"\0"
    ioffs = []
    for (p, c, fl) in imports:
        ioffs.append(len(pool))
        pool += p.encode("utf-8") + b"\0"
    hdr = doc.get("header", {})
    pos = 160
    tables = [(0, 0, 0)] * 10
    blob = bytearray()
    # strings
    tables[0] = (pos, len(pool), zlib.crc32(bytes(pool)) & 0xFFFFFFFF)
    blob += pool
    pos += len(pool)
    # names
    nt = bytearray()
    for n, off in zip(names, noffs):
        nt += struct.pack("<II", off, name_hash(n))
    tables[1] = (pos, len(names), zlib.crc32(bytes(nt)) & 0xFFFFFFFF)
    blob += nt; pos += len(nt)
    # imports
    if imports:
        it = bytearray()
        for (p, c, fl), off in zip(imports, ioffs):
            it += struct.pack("<IHH", off, w.index[c], fl)
        tables[2] = (pos, len(imports), zlib.crc32(bytes(it)) & 0xFFFFFFFF)
        blob += it; pos += len(it)
    # properties: one empty entry
    pt = bytes(16)
    tables[3] = (pos, 1, zlib.crc32(pt) & 0xFFFFFFFF)
    blob += pt; pos += 16
    # exports
    et = bytearray()
    data_start = pos + 24 * len(chunks)
    off = data_start
    for e, (ci, body) in zip(exports, chunks):
        et += struct.pack("<HHIIIII", ci, e.get("flags", 0), e.get("parent", 0), len(body), off,
                          e.get("template", 0), e.get("crc", 0))
        off += len(body)
    tables[4] = (pos, len(chunks), zlib.crc32(bytes(et)) & 0xFFFFFFFF)
    blob += et; pos += len(et)
    assert pos == data_start
    for (ci, body) in chunks:
        blob += body
    objects_end = 160 + len(blob)
    version = hdr.get("version", 195)
    flags = hdr.get("flags", 0)
    ts = hdr.get("timestamp", 0)
    build = hdr.get("build", 0)
    numChunks = hdr.get("numChunks", 6)
    crcdata = struct.pack("<IIIQIIIII", MAGIC, version, flags, ts, build, objects_end, objects_end, DEADBEEF, numChunks)
    for t in tables:
        crcdata += struct.pack("<III", *t)
    hcrc = zlib.crc32(crcdata) & 0xFFFFFFFF
    head = struct.pack("<IIIQIIIII", MAGIC, version, flags, ts, build, objects_end, objects_end, hcrc, numChunks)
    for t in tables:
        head += struct.pack("<III", *t)
    assert len(head) == 160
    return bytes(head) + bytes(blob)
