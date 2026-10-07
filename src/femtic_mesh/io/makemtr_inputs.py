"""makeMtr's input files, read as the C++ reads them (makeMtr @df8e207, main.cpp:170-394, ObservationPoint.cpp:65-103,
ObservationLine.cpp:112-146), with the C++'s stdout log echoed line for line through `out`.

  read_params('makeMtr.param')  ->  the nested ellipsoids (centre, rotation, r, L, oblateness) and the sea regions
  read_sites('obs_site.dat')    ->  the sites (each: xyz and its spheres r, L, f) and the observation lines

Number formats follow the C++ streams: std::cout turns std::scientific (precision 6, '%.6e') after the sphere table
and stays so; numbers printed before it and on std::cerr use the default format ('%g'). Every C++ exit(1) is a
MakeMtrError with the C++ message. Stricter than the C++: a value missing before the end of a file (the C++ would
use garbage) and a count written as a decimal (the C++ would read '4.0' as 4, then '.0') are errors; a count missing
at the very end of a file (the sea attributes, the observation lines) reads as 0, as in the C++ (main.cpp:298, 382).
"""
import numpy as np

PI = 3.14159265359                    # main.cpp:68 (truncated; not math.pi)
DEG2RAD = PI / 180.0                  # main.cpp:71
RAD2DEG = 180.0 / PI


class MakeMtrError(Exception):
    """A C++ exit(1). .stream is 'stderr' (std::cerr) or 'stdout' (the one std::cout message)."""
    def __init__(self, msg, stream="stderr"):
        super().__init__(msg)
        self.stream = stream


class _Tokens:
    """C++ 'ifs >> x' over a whole file. A count at the very end may be missing (read as 0, as the C++'s
    initialised variable stays 0); any other missing value is an error here (the C++ would use garbage)."""
    def __init__(self, path):
        try:
            with open(path, "r", encoding="ascii", errors="replace") as fh:
                self.t = fh.read().split()
        except OSError:
            raise MakeMtrError(f"Cannot open file {path}") from None
        self.i, self.path = 0, path

    def _next(self, what):
        if self.i >= len(self.t):
            raise MakeMtrError(f"{self.path}: file ends before {what}")
        self.i += 1
        return self.t[self.i - 1]

    def f(self, what="a number"):
        tok = self._next(what)
        try:
            return float(tok)
        except ValueError:
            raise MakeMtrError(f"{self.path}: '{tok}' is not a number ({what})") from None

    def n(self, what="a count", optional=False):
        if optional and self.i >= len(self.t):
            return 0
        tok = self._next(what)
        try:
            return int(tok)
        except ValueError:
            raise MakeMtrError(f"{self.path}: '{tok}' is not a whole number ({what})") from None


def _e(x):
    return "%.6e" % x                 # std::cout << std::scientific (precision 6)


def _g(x):
    return "%g" % x                   # default stream format (precision 6), std::cerr and cout before std::scientific


def read_params(path="makeMtr.param", out=print):
    """readParameters (main.cpp:170-359, no _FINE_SURF): dict of the ellipsoids and the sea regions."""
    t = _Tokens(path)
    out(f"Read parameters from {path}")
    out("--- Spheres ---")
    c = (t.f("the centre X"), t.f("the centre Y"), t.f("the centre Z"))
    out(f"Center coorinate of the fine region [km] : (X,Y,Z) = : {_g(c[0])} {_g(c[1])} {_g(c[2])}")
    rot = t.f("the rotation angle") * DEG2RAD
    out(f"Rotation angle of horizontal ellipsoid [deg] : {_g(rot * RAD2DEG)}")
    n = t.n("the number of spheres")
    out(f"Total number of spheres : {n}")
    if n < 1:
        raise MakeMtrError("Total number of spheres must be greater than zero.")
    out("<Radius[km]> <Edge Length[km]> <OblatenessHorizontal> <OblatenessVerticalEarth> <OblatenessVerticalAir>")
    rows = []
    for i in range(n):
        rows.append([t.f(f"sphere {i} value {k}") for k in range(5)])
        out("".join("%15.6e" % v for v in rows[-1]))
    r, L, fh, fe, fa = (np.array(col) for col in zip(*rows))
    for i in range(1, n):                                          # main.cpp:263-296 (sphere 0 is not checked)
        msg = None
        if r[i] < r[i - 1]:
            msg = f"Radius of the region {i} is smaller than that of the previous region."
        elif L[i] < L[i - 1]:
            msg = f"Edge length of the region {i} is smaller than that of the previous region."
        elif fh[i] < 0 or fh[i] > 1:
            msg = "Oblateness of horizontal ellipsoid must be smaller than 1 and larger than 0."
        elif fe[i] < 0 or fe[i] > 1 or fa[i] < 0 or fa[i] > 1:
            msg = "Oblateness must be smaller than 1 and larger than 0."
        elif r[i] * (1.0 - fh[i]) < r[i - 1] * (1.0 - fh[i - 1]):
            msg = f"Length of shorter axis of horizontal ellipsoid {i} is less than that of the previous ellipsoid."
        elif r[i] * (1.0 - fe[i]) < r[i - 1] * (1.0 - fe[i - 1]):
            msg = f"Depth of sphere {i} is shallower than that of the previous sphere in the earth."
        elif r[i] * (1.0 - fa[i]) < r[i - 1] * (1.0 - fa[i - 1]):
            msg = f"Depth of sphere {i} is shallower than that of the previous sphere in the air."
        if msg:
            raise MakeMtrError(msg)
    P = {"c": c, "rot": rot, "r": r, "L": L, "fh": fh, "fe": fe, "fa": fa, "sea_attr": [], "sea": []}
    nsea = t.n("the number of sea attributes", optional=True)
    P["sea_attr"] = [t.n("a sea attribute") for _ in range(max(nsea, 0))]
    if nsea > 0:
        out(f"Number of attributes of the sea : {nsea}")
        for a in P["sea_attr"]:
            out(f"{a}")
        nreg = t.n("the number of sea regions")
        out(f"Number of regions for definig the edge lengths in the sea : {nreg}")
        for _ in range(max(nreg, 0)):
            X, Y = t.f("a sea region X"), t.f("a sea region Y")
            out(f"Center coorinate of the region [km] : (X,Y) = : {_e(X)} {_e(Y)}")
            rdeg = t.f("a sea region rotation")
            out(f"Rotation of the region [deg.] : {_e(rdeg)}")
            m = t.n("the number of sea spheres")
            out(f"Number of spheres definig the edge lengths : {m}")
            out("<Radius[km]> <Edge Length[km]> <Oblateness>")
            rr = []
            for _ in range(max(m, 0)):
                rr.append((t.f("a sea radius"), t.f("a sea edge length"), t.f("a sea oblateness")))
                out(" ".join(_e(v) for v in rr[-1]))
            P["sea"].append((X, Y, rdeg * DEG2RAD, rr))
    return P


def _check_layers(r, L, i):
    if i > 0 and r[i] < r[i - 1]:
        raise MakeMtrError(f"Error : Inner radius ( {_g(r[i - 1])} ) is greater than outer radius ( {_g(r[i])} ) !! ")
    if i > 0 and L[i] < L[i - 1]:
        raise MakeMtrError(f"Error : Inner edge length ( {_g(L[i - 1])} ) is greater than outer edge length "
                           f"( {_g(L[i])} ) !! ")


def read_sites(path="obs_site.dat", out=print):
    """readObsSites (main.cpp:361-394): (sites, lines). A site is (xyz, r, L, f); a line is (end points (2, 3), r,
    L)."""
    t = _Tokens(path)
    out(f"Read data of observed sites from {path}")
    n = t.n("the number of sites")
    out(f"Total number of observed site : {n}")
    sites = []
    for k in range(max(n, 0)):                                     # ObservationPoint.cpp:65-103
        xyz = (t.f(f"site {k} X"), t.f(f"site {k} Y"), t.f(f"site {k} Z"))
        out(f"Coordinate : {_e(xyz[0])} {_e(xyz[1])} {_e(xyz[2])}")
        m = t.n(f"the number of spheres of site {k}")
        if m <= 0:
            raise MakeMtrError(f"Error : Total number of spheres less than 1. : {m}")
        out(f"Number of spheres : {m}")
        r, L, f = [], [], []
        for i in range(m):
            r.append(t.f("a site radius"))
            L.append(t.f("a site edge length"))
            f.append(t.f("a site oblateness"))
            _check_layers(r, L, i)
            if f[i] < 0.0 or f[i] > 1.0:
                raise MakeMtrError("Error : Oblateness must be smaller than 1 and larger than 0.")
        for i in range(m):
            out(f" Radius[km] : {_e(r[i])}, edge length[km] : {_e(L[i])}, oblateness : {_e(f[i])}")
        sites.append((xyz, np.array(r), np.array(L), np.array(f)))
    nl = t.n("the number of lines", optional=True)
    out(f"Total number of lines : {nl}")
    lines = []
    for k in range(max(nl, 0)):                                    # ObservationLine.cpp:112-146
        ends = np.array([[t.f(f"a coordinate of line {k}") for _ in range(3)] for _ in range(2)])
        m = t.n(f"the number of layers of line {k}")
        if m <= 0:
            raise MakeMtrError(f"Error : Total number of layers is less than 1 : {m}")
        r, L = [], []
        for i in range(m):
            r.append(t.f("a line radius"))
            L.append(t.f("a line edge length"))
            _check_layers(r, L, i)
        out(f" First coordinate  : {_e(ends[0, 0])} {_e(ends[0, 1])} {_e(ends[0, 2])}")
        out(f" Second coordinate : {_e(ends[1, 0])} {_e(ends[1, 1])} {_e(ends[1, 2])}")
        out(f" Number of layers  : {m}")
        for i in range(m):
            out(f" Radius [km] : {_e(r[i])}, Edge length [km] : {_e(L[i])}")
        lines.append((ends, np.array(r), np.array(L)))
    return sites, lines
