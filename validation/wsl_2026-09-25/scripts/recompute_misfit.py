import csv, glob, math, os, sys
d = sys.argv[1]
cnv = {}
with open(os.path.join(os.path.dirname(d), 'femtic.cnv')) as f:
    next(f)
    for line in f:
        p = line.split()
        cnv[(int(p[0]), int(p[1]))] = (float(p[5]), float(p[6]))
print(f"{'iter':>4} {'N':>5} {'misfit_recomp':>14} {'misfit_cnv':>12} {'relerr':>9} {'RMS_recomp':>10} {'RMS_cnv':>9} {'freqs(rank0|rank1)':>s}")
for it in range(0, 50):
    files = sorted(glob.glob(os.path.join(d, f'result_*_iter{it}.csv')))
    if not files: break
    mis = 0.0; n = 0; freqs = []
    for fn in files:
        fr = set()
        with open(fn) as f:
            rows = list(csv.reader(f))
        hdr = [h.strip() for h in rows[1]]
        ic = [hdr.index(f'{ri}(Z{c})_Cal') for c in ('xx','xy','yx','yy') for ri in ('Re','Im')]
        io = [hdr.index(f'{ri}(Z{c})_Obs') for c in ('xx','xy','yx','yy') for ri in ('Re','Im')]
        isd = [hdr.index(f'{ri}(Z{c})_SD') for c in ('xx','xy','yx','yy') for ri in ('Re','Im')]
        for r in rows[2:]:
            r = [x.strip() for x in r]
            if len(r) < len(hdr) or not r[0]: continue
            fr.add(r[1])
            for a, b, s in zip(ic, io, isd):
                cal, obs, sd = float(r[a]), float(r[b]), float(r[s])
                mis += ((obs - cal) / sd) ** 2; n += 1
        freqs.append(','.join(sorted(fr, key=float)))
    rms = math.sqrt(mis / n)
    mc, rc = cnv.get((it, 0), (float('nan'), float('nan')))
    print(f"{it:>4} {n:>5} {mis:>14.6e} {mc:>12.6e} {abs(mis-mc)/mc:>9.2e} {rms:>10.6f} {rc:>9.6f} {' | '.join(freqs)}")
