"""Fast, exact fixed-width text helpers shared by the readers and writers.

Integers are formatted with numpy digit arithmetic (exactly C's "%<w>d" for values that fit the width; wider
values fall back to Python's own % formatting, which is also exactly C's). Floats are formatted with Python's
% operator, whose 'e' and 'g' conversions are correctly rounded like glibc's printf.
"""
import io

import numpy as np

CHUNK_ROWS = 500_000


def int_fields(cols, width):
    """(n, k) integers -> (n, k*width) uint8 array holding k right-aligned "%<width>d" fields per row."""
    a = np.asarray(cols)
    if a.ndim == 1:
        a = a[:, None]
    a = a.astype(np.int64, copy=False)
    n, k = a.shape
    neg = a < 0
    v = np.abs(a)
    nd = np.ones(v.shape, dtype=np.int64)
    p = 10
    for _ in range(1, min(width, 18) + 1):
        nd += v >= p
        p *= 10
    if (nd + neg > width).any():          # a value wider than the field: C prints it in full
        return None
    out = np.full((n, k, width), 32, dtype=np.uint8)
    t = v.copy()
    for j in range(width):
        d = (t % 10).astype(np.uint8)
        t //= 10
        pos = width - 1 - j
        out[:, :, pos] = np.where(j < nd, 48 + d, 32)
    r, c = np.nonzero(neg)
    if r.size:
        out[r, c, width - 1 - nd[r, c]] = 45
    return out.reshape(n, k * width)


def py_fields(values, fmt):
    """Format each value with fmt (Python %); returns list of str."""
    return [fmt % v for v in values]


def float_fields(x, fmt, width):
    """1-D floats -> (n, width) uint8 via fmt (e.g. '%20.9e'), or None if any field is not exactly width wide."""
    x = np.asarray(x, dtype=np.float64)
    s = "".join([fmt % v for v in x.tolist()]).encode("ascii")
    arr = np.frombuffer(s, dtype=np.uint8)
    if arr.size != x.size * width:
        return None
    return arr.reshape(x.size, width)


def write_rows(fh, parts, newline=b"\n"):
    """Write rows built from column blocks: parts is a list of (n, w_i) uint8 arrays; each row ends in newline."""
    n = parts[0].shape[0]
    nl = np.frombuffer(newline, dtype=np.uint8)
    nlb = np.broadcast_to(nl, (n, nl.size))
    fh.write(np.ascontiguousarray(np.hstack(list(parts) + [nlb])).tobytes())


def write_int_table(fh, cols, width, newline=b"\n", fallback_fmt=None):
    """Write an (n, k) integer table as rows of "%<width>d" * k, in chunks."""
    cols = np.asarray(cols)
    if cols.ndim == 1:
        cols = cols[:, None]
    n, k = cols.shape
    for a in range(0, n, CHUNK_ROWS):
        blk = cols[a:a + CHUNK_ROWS]
        f = int_fields(blk, width)
        if f is None:
            row = ("%" + str(width) + "d") * k + newline.decode()
            fh.write("".join(row % tuple(r) for r in blk.tolist()).encode("ascii"))
        else:
            write_rows(fh, [f], newline)


def line_ends(raw):
    """Byte offsets of the newline characters in raw (bytes); an unterminated last line ends at len(raw)."""
    buf = np.frombuffer(raw, dtype=np.uint8)
    step = 64 * 1024 * 1024
    idx = [np.flatnonzero(buf[i:i + step] == 10) + i for i in range(0, buf.size, step)]
    nl = np.concatenate(idx) if idx else np.zeros(0, dtype=np.int64)
    if buf.size and buf[-1] != 10:
        nl = np.append(nl, buf.size)
    return nl


def line_span(nl, i):
    """(start, end) byte offsets of line i (end excludes the newline)."""
    return (0 if i == 0 else int(nl[i - 1]) + 1), int(nl[i])


def read_table(raw, nl, first, nrows, ncols, dtype, what, comments=None):
    """Parse lines first .. first+nrows-1 of raw as a whitespace table of ncols columns (exact: np.loadtxt)."""
    if nrows == 0:
        return np.zeros((0, ncols), dtype=dtype)
    if first + nrows > nl.size:
        raise ValueError(f"{what}: file ends after {nl.size} lines, need {first + nrows}")
    out = np.empty((nrows, ncols), dtype=dtype)
    for a in range(0, nrows, CHUNK_ROWS * 2):
        b = min(nrows, a + CHUNK_ROWS * 2)
        s = line_span(nl, first + a)[0]
        e = int(nl[first + b - 1]) + 1
        t = np.loadtxt(io.BytesIO(raw[s:e]), dtype=dtype, ndmin=2, comments=comments)
        if t.shape != (b - a, ncols):
            raise ValueError(f"{what}: expected {b - a} rows x {ncols} columns, got {t.shape}")
        out[a:b] = t
    return out


def read_int_line(raw, nl, i, n, what):
    """Line i as exactly n integers."""
    s, e = line_span(nl, i)
    tok = raw[s:e].split()
    if len(tok) != n:
        raise ValueError(f"{what}: line {i + 1} should hold {n} integer(s), got {tok!r}")
    return [int(t) for t in tok]
