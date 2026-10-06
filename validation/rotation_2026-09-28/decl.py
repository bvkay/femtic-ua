"""IGRF-14 declination and UTM 53S grid convergence at every Vulcan site, at the real acquisition epochs.

    conda run -n base python validation/rotation_2026-09-28/decl.py      (needs ppigrf, pyproj, scipy)

Writes alpha_per_site.csv next to this file: one row per site (site_id, group, epoch, lat, lon, elev_m,
D_igrf14_deg, conv_pyproj_deg, alpha_deg) with alpha = D - gamma, the azimuth of magnetic north clockwise
from UTM grid north. prep_vulcan.py reads it with data.rotation angle_deg 'auto'.
Epochs (Ben, 2026-09-28; the EDIs carry only the dummy ACQDATE 01/01/01): 2022 grid A1-J10 Oct-Nov 2022
= 2022.83, Vul24-* April 2024 = 2024.29, Vul25_* March 2025 = 2025.21.
The corner table cross-checks ppigrf against an independent spherical-harmonic synthesis of the same
IGRF-14 coefficients (scout version, 2026-09-28) and against IGRF-13.
"""
import csv, math, os, datetime as dt, warnings
import numpy as np
warnings.filterwarnings("ignore")
import ppigrf, pyproj
from scipy.special import lpmv, factorial
HERE = os.path.dirname(os.path.abspath(__file__))
CSV = os.path.join(HERE, "..", "..", "Vulcan", "site_coords_utm53.csv")
EPOCH = {"grid": 2022.83, "Vul24": 2024.29, "Vul25": 2025.21}
group = lambda i: "Vul24" if i.startswith("Vul24") else ("Vul25" if i.startswith("Vul25") else "grid")
rows = list(csv.DictReader(open(CSV)))
ids = [r["id"] for r in rows]
lat = np.array([float(r["lat"]) for r in rows]); lon = np.array([float(r["lon"]) for r in rows])
h = np.array([float(r["elev_m"]) for r in rows]) / 1000.0
grp = [group(i) for i in ids]
yr = np.array([EPOCH[k] for k in grp])
print("n sites", len(rows), {k: grp.count(k) for k in EPOCH}, "lat %.4f..%.4f lon %.4f..%.4f" %
      (lat.min(), lat.max(), lon.min(), lon.max()))
clat, clon = (lat.min() + lat.max()) / 2, (lon.min() + lon.max()) / 2
corners = {"centre": (clat, clon), "SW": (lat.min(), lon.min()), "SE": (lat.min(), lon.max()),
           "NW": (lat.max(), lon.min()), "NE": (lat.max(), lon.max())}
def date(y):
    yi = int(y); d0, d1 = dt.datetime(yi, 1, 1), dt.datetime(yi + 1, 1, 1)
    return d0 + (d1 - d0) * (y - yi)
def D_ppigrf(la, lo, hh, y, fn=ppigrf.ppigrf.shc_fn_igrf14):
    Be, Bn, Bu = ppigrf.igrf(lo, la, hh, date(y), coeff_fn=fn)
    return float(np.degrees(np.arctan2(np.squeeze(Be), np.squeeze(Bn))))
def read_shc(fn):
    L = [l for l in open(fn) if not l.startswith("#")]
    years, g = np.array(L[1].split(), float), {}
    for l in L[2:]:
        p = l.split()
        if len(p) >= 3:
            g[(int(p[0]), int(p[1]))] = np.array(p[2:], float)
    return years, g
YRS, CO = read_shc(ppigrf.ppigrf.shc_fn_igrf14)
def coeffs(y):
    i = np.searchsorted(YRS, y) - 1; w = (y - YRS[i]) / (YRS[i + 1] - YRS[i])
    return {k: v[i] + w * (v[i + 1] - v[i]) for k, v in CO.items()}
A_REF = 6371.2
def V(r, th, ph, c):
    x, s = np.cos(th), 0.0
    for n in range(1, 14):
        for m in range(0, n + 1):
            P = lpmv(m, n, x) * (-1) ** m                   # remove the Condon-Shortley phase
            if m > 0:
                P *= math.sqrt(2.0 * factorial(n - m) / factorial(n + m))
            s += (A_REF / r) ** (n + 1) * (c[(n, m)] * math.cos(m * ph) + c.get((n, -m), 0.0) * math.sin(m * ph)) * P
    return A_REF * s
def D_own(la, lo, hh, y):
    c = coeffs(y); A, B = 6378.137, 6356.752314245
    phi, lam = math.radians(la), math.radians(lo)
    N_ = A ** 2 / math.sqrt(A ** 2 * math.cos(phi) ** 2 + B ** 2 * math.sin(phi) ** 2)
    X, Z = (N_ + hh) * math.cos(phi), (N_ * B ** 2 / A ** 2 + hh) * math.sin(phi)
    r, th = math.hypot(X, Z), math.pi / 2 - math.atan2(Z, X)
    dr, dth, dph = 1e-3, 1e-6, 1e-6
    Br = -(V(r + dr, th, lam, c) - V(r - dr, th, lam, c)) / (2 * dr)
    Bth = -(V(r, th + dth, lam, c) - V(r, th - dth, lam, c)) / (2 * dth) / r
    Bph = -(V(r, th, lam + dph, c) - V(r, th, lam - dph, c)) / (2 * dph) / (r * math.sin(th))
    Xn, Ye, Zd = -Bth, Bph, -Br
    psi = (math.pi / 2 - th) - phi
    return math.degrees(math.atan2(Ye, Xn * math.cos(psi) - Zd * math.sin(psi)))
hc = float(np.median(h))
print("\nDeclination (deg E) at the corners: IGRF-14 ppigrf | own synthesis | IGRF-13 ppigrf")
worst = 0.0
for k, y in EPOCH.items():
    for name, (la, lo) in corners.items():
        d14, do = D_ppigrf(la, lo, hc, y), D_own(la, lo, hc, y)
        worst = max(worst, abs(d14 - do))
        print("  %-5s %.2f %-6s %8.4f | %8.4f | %8.4f" % (k, y, name, d14, do,
                                                         D_ppigrf(la, lo, hc, y, ppigrf.ppigrf.shc_fn_igrf13)))
print("  max |ppigrf - own synthesis| = %.1e deg" % worst)
p = pyproj.Proj("EPSG:32753")
D = np.array([D_ppigrf(la, lo, hh, y) for la, lo, hh, y in zip(lat, lon, h, yr)])
gam = np.array([p.get_factors(lo, la).meridian_convergence for la, lo in zip(lat, lon)])
e0, n0 = p(clon, clat); e1, n1 = p(clon, clat + 0.01)
print("\nconvergence at the centre %.4f deg; grid bearing of true north %.4f deg (finite difference)" %
      (p.get_factors(clon, clat).meridian_convergence, math.degrees(math.atan2(e1 - e0, n1 - n0))))
alpha = D - gam
for k in EPOCH:
    m = np.array([g_ == k for g_ in grp])
    print("alpha %-5s epoch %.2f (%3d sites): D %.3f..%.3f, gamma %.3f..%.3f, alpha %.3f..%.3f mean %.3f" %
          (k, EPOCH[k], m.sum(), D[m].min(), D[m].max(), gam[m].min(), gam[m].max(), alpha[m].min(),
           alpha[m].max(), alpha[m].mean()))
print("alpha all 120: %.3f..%.3f mean %.3f; max |alpha - 7.42| = %.3f deg" %
      (alpha.min(), alpha.max(), alpha.mean(), np.abs(alpha - 7.42).max()))
out = os.path.join(HERE, "alpha_per_site.csv")
with open(out, "w", newline="\n") as fh:
    fh.write("site_id,group,epoch,lat,lon,elev_m,D_igrf14_deg,conv_pyproj_deg,alpha_deg\n")
    for r, k, y, d, gm, a in sorted(zip(rows, grp, yr, D, gam, alpha), key=lambda t: t[0]["id"]):
        fh.write("%s,%s,%.2f,%s,%s,%s,%.5f,%.5f,%.5f\n" % (r["id"], k, y, r["lat"], r["lon"], r["elev_m"], d, gm, a))
print("wrote", out)
