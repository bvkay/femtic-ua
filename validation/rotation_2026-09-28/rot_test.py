import numpy as np, math
rng = np.random.default_rng(1)
def R(t):  # rows = new axes expressed in old (north, east) coords; new x axis at azimuth t clockwise from old x
    c, s = math.cos(math.radians(t)), math.sin(math.radians(t)); return np.array([[c, s], [-s, c]])
rot = lambda Z, t: R(t) @ Z @ R(t).T
alpha = 7.42                       # magnetic north azimuth, clockwise from grid north
Zte, Ztm = 1.3 - 0.9j, -0.4 + 0.25j
Zmag = np.array([[0, Zte], [Ztm, 0]])           # strike along magnetic north (x_mag)
# independent construction in the grid frame: strike unit s at azimuth +alpha, normal n
a = math.radians(alpha); s = np.array([math.cos(a), math.sin(a)]); n = np.array([-math.sin(a), math.cos(a)])
Zgrid_true = Zte * np.outer(s, n) + Ztm * np.outer(n, s)   # E = Zte s (n.H) + Ztm n (s.H)
for th in (-alpha, +alpha):
    print("T1 theta=%+.2f: max|R Zmag R^T - Zgrid_true| = %.2e" % (th, np.abs(rot(Zmag, th) - Zgrid_true).max()))
Zg = rot(Zmag, -alpha)
phis = np.arange(-45, 45, 0.01)
diag = [abs(rot(Zg, p)[0, 0])**2 + abs(rot(Zg, p)[1, 1])**2 for p in phis]
print("T2 strike recovered from grid-frame tensor: %.2f deg clockwise from grid north (expect %.2f)" % (phis[int(np.argmin(diag))], alpha))
# variance propagation: vec order xx, xy, yx, yy ; Z' = M vec(Z) with M = kron(R, R)
M = np.kron(R(-alpha), R(-alpha)); W = M**2
print("T3 M = kron(R,R); W = M**2 rows sum:", np.round(W.sum(1), 12), " cols sum:", np.round(W.sum(0), 12))
V = np.array([0.02, 0.5, 0.8, 0.03])            # complex variances E|dZ|^2 of xx, xy, yx, yy
ns = 400000
dz = (rng.standard_normal((ns, 4)) + 1j * rng.standard_normal((ns, 4))) * np.sqrt(V / 2)
emp = np.mean(np.abs(dz @ M.T)**2, axis=0); pred = W @ V
print("T3 Monte Carlo var' :", np.round(emp, 5), " predicted (M**2) V :", np.round(pred, 5), " max rel diff %.3f" % np.max(np.abs(emp/pred - 1)))
c2, s2 = math.cos(a)**2, math.sin(a)**2
print("   weights for Var'_xx: c^4=%.4f c^2s^2=%.4f s^4=%.5f ; bound Var' <= max(V) holds: %s" % (c2**2, c2*s2, s2**2, bool(np.all(pred <= V.max() + 1e-15))))
