import csv, glob, math, sys, os
d = sys.argv[1]; mu0 = 4e-7*math.pi
tol_rho, tol_ph = 0.10, 3.0
stats = {}; fails = 0; n = 0; diag_ratio_max = 0.0
for fn in sorted(glob.glob(os.path.join(d, 'result_*_iter0.csv'))):
    rows = list(csv.reader(open(fn))); hdr = [h.strip() for h in rows[1]]
    g = lambda r, k: float(r[hdr.index(k)].strip())
    for r in rows[2:]:
        if len(r) < len(hdr) or not r[0].strip(): continue
        f = g(r, 'Freq[Hz]'); w = 2*math.pi*f
        zxy = complex(g(r,'Re(Zxy)_Cal'), g(r,'Im(Zxy)_Cal')); zyx = complex(g(r,'Re(Zyx)_Cal'), g(r,'Im(Zyx)_Cal'))
        zxx = complex(g(r,'Re(Zxx)_Cal'), g(r,'Im(Zxx)_Cal')); zyy = complex(g(r,'Re(Zyy)_Cal'), g(r,'Im(Zyy)_Cal'))
        diag_ratio_max = max(diag_ratio_max, max(abs(zxx), abs(zyy))/min(abs(zxy), abs(zyx)))
        for name, z in (('xy', zxy), ('yx', zyx)):
            rho = abs(z)**2/(w*mu0); ph = math.degrees(math.atan2(abs(z.imag), abs(z.real)))
            n += 1
            bad = abs(rho-100)/100 > tol_rho or abs(ph-45) > tol_ph
            fails += bad
            s = stats.setdefault((f, name), [1e9, -1e9, 1e9, -1e9]); s[0]=min(s[0],rho); s[1]=max(s[1],rho); s[2]=min(s[2],ph); s[3]=max(s[3],ph)
print(f"{'freq_Hz':>8} {'comp':>4} {'rho_a min':>9} {'rho_a max':>9} {'phase min':>9} {'phase max':>9}")
for (f, c), s in sorted(stats.items()):
    print(f"{f:>8.0e} {c:>4} {s[0]:>9.2f} {s[1]:>9.2f} {s[2]:>9.2f} {s[3]:>9.2f}")
print(f"station-freq-components checked: {n}; outside tolerance (rho +-10%, phase +-3 deg): {fails}")
print(f"max |Zdiag|/|Zoffdiag| = {diag_ratio_max:.3e}")
print("HALFSPACE CHECK:", "PASS" if fails == 0 else "FAIL")
