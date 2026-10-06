import json,urllib.request,re,collections
for pkg in ["gmsh","tetgen","meshpy","pygimli","pgcore","discretize"]:
    d=json.load(urllib.request.urlopen(f"https://pypi.org/pypi/{pkg}/json"))
    v=d["info"]["version"]; files=d["urls"]
    plats=collections.Counter()
    for f in files:
        fn=f["filename"]
        if fn.endswith(".tar.gz"): plats["sdist"]+=1; continue
        tag=fn[:-4].split("-")[-1]
        plat="win" if "win" in tag else "mac" if "macosx" in tag else "linux" if "linux" in tag else tag
        plats[plat]+=1
    rel=sorted(d["releases"].keys(), key=lambda s:[int(x) if x.isdigit() else 0 for x in re.split(r'[.]',s)])
    up=[f["upload_time"][:10] for f in files][:1]
    print(f"{pkg:10s} {v:10s} uploaded {up} files {dict(plats)} license={d['info'].get('license_expression') or (d['info'].get('license') or '')[:30]} n_releases={len(rel)}")
    if pkg in("tetgen","meshpy","pgcore"):
        print("   ", sorted(set(f['filename'].split('-')[2] for f in files if f['filename'].endswith('.whl'))))
