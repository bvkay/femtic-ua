"""Surface-only gmsh run -> triangle PLC (.poly + npz) for the tetgen front-ends."""
NL = "\n"


def run(gmsh, np, sites, topo, st, sb, sa, se):
    gmsh.model.mesh.generate(2)
    ntag, xyz, _ = gmsh.model.mesh.getNodes()
    xyz = xyz.reshape(-1, 3)
    idx = np.full(int(ntag.max()) + 1, -1)
    idx[ntag] = np.arange(len(ntag))
    T, M = [], []
    for s in [1, st, sb] + sa + se:
        _, ft = gmsh.model.mesh.getElementsByType(2, s)
        ft = idx[ft.reshape(-1, 3)]
        T.append(ft)
        M.append(np.full(len(ft), 100 if s == 1 else s))
    T = np.vstack(T)
    M = np.concatenate(M)
    used = np.unique(T)
    remap = np.full(len(xyz), -1)
    remap[used] = np.arange(len(used))
    xyz = xyz[used]
    T = remap[T]
    np.savez("out/toy_plc.npz", xyz=xyz, tri=T, mark=M, sites=sites,
             sites_z=topo(sites[:, 0], sites[:, 1]))
    with open("out/toy.poly", "w", newline=NL) as f:
        f.write(f"{len(xyz)} 3 0 0" + NL)
        for i, p in enumerate(xyz):
            f.write(f"{i+1} {float(p[0])!r} {float(p[1])!r} {float(p[2])!r}" + NL)
        f.write(f"{len(T)} 1" + NL)
        for t, m in zip(T, M):
            f.write(f"1 0 {m}" + NL + f"3 {t[0]+1} {t[1]+1} {t[2]+1}" + NL)
        f.write("0" + NL + "2" + NL)
        f.write("1 0.0 0.0 250.0 10 -1" + NL + "2 0.0 0.0 -250.0 20 -1" + NL)
    print("PLC", len(xyz), "nodes", len(T), "triangles")
    gmsh.finalize()
