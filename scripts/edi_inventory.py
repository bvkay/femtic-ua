"""
EDI inventory and coordinate table for the Vulcan FEMTIC project.

Reads every .edi in an input folder and takes site coordinates from the HEAD block
(LAT/LONG in D:M:S, ELEV in m) interpreted with the Geotools "floor" convention:
"-30:8:45" means -30 + 8/60 + 45/3600 = -29.854 (the sign applies to the degrees only).
The INFO block decimal LATITUDE/LONGITUDE is used only as a cross-check: for the
Vulcan 2022 export three files (C5, D2, E1) carry INFO coordinates copied from other
sites, while their HEAD coordinates sit on the 1 km grid (verified by an affine grid fit).
Converts to UTM (WGS84) and writes:
  <out>/site_coords_utm<zone>.csv      id, lat, lon, elev_m, east_m, north_m
  <out>/site_coords_femticpy.txt       id  east_km  north_km  elev_km   (femticPy coord file format)
  <out>/edi_inventory.md               QC summary: extent, spacing, NFREQ, masked counts, header mismatches
  <out>/frequency_table.csv            union of frequencies with site counts

Usage: python edi_inventory.py <edi_dir> <out_dir> [--zone 53] [--north]
"""
import sys, re, glob, os, argparse
import numpy as np
import pandas as pd
from pyproj import Proj


def dms_to_deg_naive(s):
    """Interpret 'D:M:S' as D + M/60 + S/3600 with the sign applied to D only.
    This reproduces what Geotools intended when it wrote negative latitudes."""
    d, m, sec = s.split(':')
    return float(d) + float(m) / 60.0 + float(sec) / 3600.0


def dms_to_deg_standard(s):
    """Standard EDI interpretation: the sign applies to the whole value."""
    d, m, sec = s.split(':')
    sign = -1.0 if d.strip().startswith('-') else 1.0
    return sign * (abs(float(d)) + float(m) / 60.0 + float(sec) / 3600.0)


def parse_edi(path):
    txt = open(path, errors='replace').read()
    site = os.path.splitext(os.path.basename(path))[0]
    g = lambda pat, flags=0: re.search(pat, txt, flags)
    m = g(r'LATITUDE\s*:\s*([-\d.]+)');  lat = float(m.group(1)) if m else np.nan
    m = g(r'LONGITUDE\s*:\s*([-\d.]+)'); lon = float(m.group(1)) if m else np.nan
    m = g(r'ELEVATION\s*:\s*([-\d.]+)'); elev = float(m.group(1)) if m else np.nan
    m = g(r'^LAT=([-+\d:.]+)', re.M);    head_lat = m.group(1) if m else None
    m = g(r'^LONG=([-+\d:.]+)', re.M);   head_lon = m.group(1) if m else None
    m = g(r'^NFREQ=(\d+)', re.M);        nfreq = int(m.group(1)) if m else -1
    m = g(r'>FREQ\s*//\s*\d+\s*\n(.*?)(?=\n>)', re.S)
    freqs = np.array([float(x) for x in m.group(1).split()]) if m else np.array([])
    has_tipper = bool(g(r'^>TXR', re.M))
    zmask = 0
    for blk in re.finditer(r'^>(Z[XY][XY](R|I|\.VAR))\s*//\s*\d+\s*\n(.*?)(?=\n>)', txt, re.S | re.M):
        zmask += len(re.findall(r'1\.0+[eE]\+0*32', blk.group(3)))
    m = g(r'^ELEV=([-\d.]+)', re.M);     head_elev = float(m.group(1)) if m else np.nan
    hlat = dms_to_deg_naive(head_lat) if head_lat else np.nan
    hlon = dms_to_deg_naive(head_lon) if head_lon else np.nan
    return dict(id=site, lat=hlat, lon=hlon, elev_m=head_elev,
                info_lat=lat, info_lon=lon, info_elev=elev,
                head_lat_dms=head_lat, head_lon_dms=head_lon,
                head_lat_naive=hlat,
                head_lat_standard=dms_to_deg_standard(head_lat) if head_lat else np.nan,
                nfreq=nfreq,
                fmax=freqs.max() if freqs.size else np.nan,
                fmin=freqs.min() if freqs.size else np.nan,
                z_masked=zmask, has_tipper=has_tipper, freqs=freqs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('edi_dir')
    ap.add_argument('out_dir')
    ap.add_argument('--zone', type=int, default=53)
    ap.add_argument('--north', action='store_true', help='northern hemisphere (default south)')
    a = ap.parse_args()
    os.makedirs(a.out_dir, exist_ok=True)
    files = sorted(glob.glob(os.path.join(a.edi_dir, '*.edi')))
    rows = [parse_edi(f) for f in files]
    df = pd.DataFrame(rows)
    p = Proj(proj='utm', zone=a.zone, ellps='WGS84', south=not a.north)
    east, north = p(df['lon'].values, df['lat'].values)
    df['east_m'] = east
    df['north_m'] = north

    cols = ['id', 'lat', 'lon', 'elev_m', 'east_m', 'north_m']
    df[cols].to_csv(os.path.join(a.out_dir, f'site_coords_utm{a.zone}.csv'), index=False, float_format='%.3f')
    with open(os.path.join(a.out_dir, 'site_coords_femticpy.txt'), 'w', newline='\n') as fh:
        for _, r in df.iterrows():
            fh.write(f"{r['id']}\t{r['east_m']/1000:.4f}\t{r['north_m']/1000:.4f}\t{r['elev_m']/1000:.5f}\n")

    # union of frequencies, merging bands closer than 0.01 log10 units (femticPy's rule)
    allf = np.sort(np.unique(np.concatenate([r['freqs'] for r in rows])))[::-1]
    bands = []
    for f in allf:
        if bands and abs(np.log10(f) - np.log10(bands[-1])) < 0.01:
            continue
        bands.append(f)
    ftab = pd.DataFrame({'freq_hz': bands, 'n_sites': 0})
    for r in rows:
        seen = set()
        for f in r['freqs']:
            idx = int(np.argmin(np.abs(np.log10(ftab['freq_hz'].values) - np.log10(f))))
            if idx not in seen:
                ftab.loc[idx, 'n_sites'] += 1
                seen.add(idx)
    ftab['period_s'] = 1.0 / ftab['freq_hz']
    ftab.to_csv(os.path.join(a.out_dir, 'frequency_table.csv'), index=False, float_format='%.6g')

    xy = df[['east_m', 'north_m']].values
    d = np.sqrt(((xy[:, None, :] - xy[None, :, :]) ** 2).sum(-1))
    np.fill_diagonal(d, np.inf)
    nn = d.min(1)
    mism = int((np.abs(df['head_lat_standard'] - df['info_lat']) > 0.001).sum())
    naive_ok = int((np.abs(df['head_lat_naive'] - df['info_lat']) < 0.001).sum())
    # sites whose INFO block disagrees with the HEAD block by more than ~100 m
    dlat = np.abs(df['info_lat'] - df['lat']) * 111000.0
    dlon = np.abs(df['info_lon'] - df['lon']) * 111000.0 * np.cos(np.deg2rad(df['lat']))
    df['info_head_offset_m'] = np.hypot(dlat, dlon)
    suspect = df[df['info_head_offset_m'] > 100]

    md = []
    md.append(f"# EDI inventory: {a.edi_dir}\n")
    md.append(f"Files: {len(df)}   UTM zone {a.zone}{'N' if a.north else 'S'} (WGS84)\n")
    md.append("| quantity | min | max |\n|---|---|---|")
    md.append(f"| latitude | {df['lat'].min():.4f} | {df['lat'].max():.4f} |")
    md.append(f"| longitude | {df['lon'].min():.4f} | {df['lon'].max():.4f} |")
    md.append(f"| easting m | {df['east_m'].min():.0f} | {df['east_m'].max():.0f} |")
    md.append(f"| northing m | {df['north_m'].min():.0f} | {df['north_m'].max():.0f} |")
    md.append(f"| elevation m | {df['elev_m'].min():.1f} | {df['elev_m'].max():.1f} |")
    md.append(f"| NFREQ | {df['nfreq'].min()} | {df['nfreq'].max()} |")
    md.append(f"| fmax Hz | {df['fmax'].min():.4g} | {df['fmax'].max():.4g} |")
    md.append(f"| fmin Hz | {df['fmin'].min():.3g} | {df['fmin'].max():.3g} |")
    md.append(f"| nearest-neighbour spacing m | {nn.min():.0f} | {nn.max():.0f} |")
    md.append(f"\nExtent E-W {(df['east_m'].max()-df['east_m'].min())/1000:.1f} km, "
              f"N-S {(df['north_m'].max()-df['north_m'].min())/1000:.1f} km. Median NN spacing {np.median(nn):.0f} m.\n")
    md.append(f"Coordinates come from the HEAD block using the Geotools floor reading (D + M/60 + S/3600). "
              f"Under the standard DMS reading {mism} of {len(df)} headers would disagree with INFO; "
              f"under the floor reading {naive_ok} agree.\n")
    if len(suspect):
        md.append(f"INFO block disagrees with HEAD by more than 100 m in {len(suspect)} file(s) "
                  "(INFO judged wrong; HEAD used):\n")
        md.append("| id | HEAD lat | HEAD lon | INFO lat | INFO lon | offset m |\n|---|---|---|---|---|---|")
        for _, r in suspect.iterrows():
            md.append(f"| {r['id']} | {r['lat']:.4f} | {r['lon']:.4f} | {r['info_lat']:.4f} | {r['info_lon']:.4f} | {r['info_head_offset_m']:.0f} |")
        md.append("")
    md.append(f"Tipper blocks present: {int(df['has_tipper'].sum())} files. "
              f"Masked values inside Z blocks: {int(df['z_masked'].sum())} total.\n")
    md.append(f"Union of frequencies: {len(ftab)} bands from {ftab['freq_hz'].max():.4g} Hz to {ftab['freq_hz'].min():.3g} Hz "
              f"({ftab['period_s'].min():.4g} s to {ftab['period_s'].max():.0f} s). "
              f"Bands held by all sites: {int((ftab['n_sites'] == len(df)).sum())}.\n")
    md.append("\n## Per-site table\n")
    md.append(df[['id', 'lat', 'lon', 'elev_m', 'east_m', 'north_m', 'nfreq', 'fmax', 'fmin', 'z_masked', 'info_head_offset_m']]
              .to_markdown(index=False, floatfmt='.4f'))
    open(os.path.join(a.out_dir, 'edi_inventory.md'), 'w', newline='\n').write('\n'.join(md) + '\n')
    print('\n'.join(md[:16]))


if __name__ == '__main__':
    main()
