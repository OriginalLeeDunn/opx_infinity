"""A small, exact-enough BC3 (DXT5) encoder: the alpha half searched per block
(both interpolation modes, endpoints refined), the colour half fitted along the
block's principal axis. Pillow's encoder left alpha errors of 50/255 on the
anti-aliased rims; this one keeps them within the format's own step."""
import numpy as np


def _alpha_palettes(a0, a1):
    a0 = a0.astype(np.int32); a1 = a1.astype(np.int32)
    m1 = np.stack([a0, a1] + [((7 - i) * a0 + i * a1) // 7 for i in range(1, 7)], axis=-1)
    m2 = np.stack([a0, a1] + [((5 - i) * a0 + i * a1) // 5 for i in range(1, 5)] + [np.zeros_like(a0), np.full_like(a0, 255)], axis=-1)
    return m1, m2


def encode_alpha(blocks):
    """blocks: (N,16) uint8 -> (N,8) uint8"""
    n = blocks.shape[0]
    b = blocks.astype(np.int32)
    best_err = np.full(n, 1 << 30)
    best = np.zeros((n, 8), np.uint8)
    lo = b.min(axis=1); hi = b.max(axis=1)
    inner = np.where((b > 0) & (b < 255), b, 1000)
    lo2 = inner.min(axis=1); hi2 = np.where((b > 0) & (b < 255), b, -1).max(axis=1)
    lo2 = np.where(lo2 == 1000, 0, lo2); hi2 = np.where(hi2 < 0, 255, hi2)
    cands = []
    for d0 in (-6, -3, 0, 3, 6):
        for d1 in (-6, -3, 0, 3, 6):
            # mode 1: a0 > a1 (a0 = max)
            a0 = np.clip(hi + d0, 0, 255); a1 = np.clip(lo + d1, 0, 255)
            a0, a1 = np.maximum(a0, a1), np.minimum(a0, a1)
            same = a0 == a1
            a0 = np.where(same & (a0 < 255), a0 + 1, a0); a1 = np.where(same & (a0 == 255) & (a1 == 255), 254, a1)
            cands.append((a0, a1, 1))
            # mode 2: a0 <= a1 over the inner values, 0 and 255 explicit
            b0 = np.clip(lo2 + d1, 0, 255); b1 = np.clip(hi2 + d0, 0, 255)
            b0, b1 = np.minimum(b0, b1), np.maximum(b0, b1)
            cands.append((b0, b1, 2))
    for a0, a1, mode in cands:
        m1, m2 = _alpha_palettes(a0, a1)
        pal = m1 if mode == 1 else m2
        diff = np.abs(b[:, :, None] - pal[:, None, :])
        idx = diff.argmin(axis=2)
        err = (diff.min(axis=2) ** 2).sum(axis=1)
        better = err < best_err
        if not better.any():
            continue
        best_err = np.where(better, err, best_err)
        bits = np.zeros(n, np.uint64)
        for i in range(16):
            bits |= (idx[:, i].astype(np.uint64) & 7) << np.uint64(3 * i)
        out = np.zeros((n, 8), np.uint8)
        out[:, 0] = a0; out[:, 1] = a1
        for k in range(6):
            out[:, 2 + k] = ((bits >> np.uint64(8 * k)) & np.uint64(0xFF)).astype(np.uint8)
        best[better] = out[better]
    return best


def _to565(c):
    c = np.clip(np.round(c), 0, 255).astype(np.int32)
    return ((c[..., 0] * 31 + 127) // 255 << 11) | ((c[..., 1] * 63 + 127) // 255 << 5) | ((c[..., 2] * 31 + 127) // 255)


def _from565(v):
    r = (v >> 11) & 31; g = (v >> 5) & 63; bl = v & 31
    return np.stack([(r * 255 + 15) // 31, (g * 255 + 31) // 63, (bl * 255 + 15) // 31], axis=-1)


def encode_color(blocks):
    """blocks: (N,16,3) uint8 -> (N,8) uint8, 4-colour mode (BC3 always interpolates 4)."""
    n = blocks.shape[0]
    c = blocks.astype(np.float64)
    mean = c.mean(axis=1, keepdims=True)
    cen = c - mean
    cov = np.einsum('nki,nkj->nij', cen, cen)
    # principal axis by power iteration
    v = np.ones((n, 3)) / np.sqrt(3)
    for _ in range(8):
        v = np.einsum('nij,nj->ni', cov, v)
        norm = np.linalg.norm(v, axis=1, keepdims=True)
        v = np.where(norm > 1e-9, v / np.maximum(norm, 1e-9), np.ones((n, 3)) / np.sqrt(3))
    t = np.einsum('nki,ni->nk', cen, v)
    e0 = mean[:, 0, :] + v * t.max(axis=1, keepdims=True)
    e1 = mean[:, 0, :] + v * t.min(axis=1, keepdims=True)
    c0 = _to565(e0); c1 = _to565(e1)
    # keep c0 >= c1 (4-colour ordering is irrelevant for BC3 but tidy)
    swap = c0 < c1
    c0, c1 = np.where(swap, c1, c0), np.where(swap, c0, c1)
    p0 = _from565(c0).astype(np.float64); p1 = _from565(c1).astype(np.float64)
    pal = np.stack([p0, p1, (2 * p0 + p1) / 3, (p0 + 2 * p1) / 3], axis=1)
    d = ((c[:, :, None, :] - pal[:, None, :, :]) ** 2).sum(axis=-1)
    idx = d.argmin(axis=2)
    bits = np.zeros(n, np.uint64)
    for i in range(16):
        bits |= (idx[:, i].astype(np.uint64) & 3) << np.uint64(2 * i)
    out = np.zeros((n, 8), np.uint8)
    out[:, 0] = c0 & 0xFF; out[:, 1] = c0 >> 8
    out[:, 2] = c1 & 0xFF; out[:, 3] = c1 >> 8
    for k in range(4):
        out[:, 4 + k] = ((bits >> np.uint64(8 * k)) & np.uint64(0xFF)).astype(np.uint8)
    return out


def encode(rgba):
    h, w, _ = rgba.shape
    assert h % 4 == 0 and w % 4 == 0
    blocks = rgba.reshape(h // 4, 4, w // 4, 4, 4).transpose(0, 2, 1, 3, 4).reshape(-1, 16, 4)
    alpha = encode_alpha(blocks[:, :, 3])
    color = encode_color(blocks[:, :, :3])
    return np.concatenate([alpha, color], axis=1).tobytes()
