import sys, os, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cr2w
_orig = cr2w.Parser.value
def value(self, t, o, end):
    if t.startswith("[") and "]" in t:
        et = t[t.index("]") + 1:]
        n = struct.unpack_from("<I", self.d, o)[0]; o += 4
        out = []
        for _ in range(n):
            v, o = self.value(et, o, None)
            out.append(v)
        return out, o
    return _orig(self, t, o, end)
cr2w.Parser.value = value
