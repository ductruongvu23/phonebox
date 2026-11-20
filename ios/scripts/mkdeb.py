#!/usr/bin/env python3
"""mkdeb.py <stage-dir> <out.deb>: packs a staged tree (with DEBIAN/ inside) into a .deb without dpkg.
A .deb is an ar archive: debian-binary, control.tar.gz, data.tar.gz (xz is not needed; gzip is read everywhere)."""
import gzip, io, os, sys, tarfile, time

def tar_gz(root, members, root_owned=True):
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as t:
            for arc, path in members:
                ti = t.gettarinfo(path, arcname=arc)
                ti.uid = ti.gid = 0; ti.uname = ti.gname = "root"; ti.mtime = 0
                if ti.isdir(): ti.mode = 0o755
                if ti.isreg():
                    with open(path, "rb") as f: t.addfile(ti, f)
                else: t.addfile(ti)
    return buf.getvalue()

def walk(top, prefix="./"):
    out = [(prefix.rstrip("/") or ".", top)]
    for dp, dns, fns in os.walk(top):
        dns.sort()
        for n in dns + sorted(fns):
            p = os.path.join(dp, n)
            out.append((prefix + os.path.relpath(p, top), p))
    return out

def ar(members):
    out = b"!<arch>\n"
    for name, data in members:
        hdr = f"{name:<16}{int(time.time()) if False else 0:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n"
        out += hdr.encode() + data + (b"\n" if len(data) % 2 else b"")
    return out

def main(stage, dest):
    control_dir = os.path.join(stage, "DEBIAN")
    ctl = [(a, p) for a, p in walk(control_dir)]
    data = [(a, p) for a, p in walk(stage) if not (a == "./DEBIAN" or a.startswith("./DEBIAN/"))]
    deb = ar([("debian-binary", b"2.0\n"),
              ("control.tar.gz", tar_gz(control_dir, ctl)),
              ("data.tar.gz", tar_gz(stage, data))])
    with open(dest, "wb") as f: f.write(deb)

main(sys.argv[1], sys.argv[2])
