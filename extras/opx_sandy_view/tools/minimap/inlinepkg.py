import sys, os, struct, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cr2wx
from cr2w import CR2W, Parser

def walk_props(d, names, o, end):
    out = []
    while o + 2 <= end:
        ni = struct.unpack_from("<H", d, o)[0]; o += 2
        if ni == 0: break
        ti, size = struct.unpack_from("<HI", d, o); o += 6
        out.append((names[ni], names[ti], o, size - 4)); o += size - 4
    return out

def inline_packages(data):
    c = CR2W(data)
    e = c.exports[0]
    top = walk_props(data, c.names, e["off"] + 1, e["off"] + e["size"])
    li = [x for x in top if x[0] == "libraryItems"][0]
    cnt = struct.unpack_from("<I", data, li[2])[0]; q = li[2] + 4
    res = {}
    for i in range(cnt):
        props = walk_props(data, c.names, q + 1, li[2] + li[3])
        nm = None; blob = None
        for n, t, po, ps in props:
            if n == "name": nm = c.names[struct.unpack_from('<H', data, po)[0]]
            if n == "package":
                size = struct.unpack_from("<I", data, po)[0]
                blob = data[po + 4: po + 4 + size]
        res[nm] = blob
        last = props[-1]; q = last[2] + last[3]
        if struct.unpack_from("<H", data, q)[0] == 0: q += 2
    return c, res

def chunks(blob):
    c = CR2W(blob); p = Parser(c)
    return c, [p.chunk(i) for i in range(len(c.exports))]
