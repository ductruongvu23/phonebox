#!/usr/bin/env python3
"""make-apt-repo.py <dir-with-debs> <out-dir>: writes a flat APT repo (Packages, Packages.gz, Packages.bz2, Release)
that Sileo/Zebra can add, without dpkg-scanpackages. The .debs are copied next to the index."""
import bz2, gzip, hashlib, io, os, shutil, sys, tarfile

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)

def control_of(deb):
    data = open(deb, "rb").read()
    pos = 8
    while pos < len(data):
        name = data[pos:pos + 16].decode().strip().rstrip("/")
        size = int(data[pos + 48:pos + 58])
        body = data[pos + 60:pos + 60 + size]
        pos += 60 + size + (size % 2)
        if name.startswith("control.tar"):
            with tarfile.open(fileobj=io.BytesIO(body)) as t:
                for m in t.getmembers():
                    if m.name.lstrip("./") == "control":
                        return t.extractfile(m).read().decode().strip()
    raise SystemExit("no control in " + deb)

entries = []
for f in sorted(os.listdir(src)):
    if not f.endswith(".deb"): continue
    shutil.copy(os.path.join(src, f), os.path.join(out, f))
    p = os.path.join(out, f)
    raw = open(p, "rb").read()
    entries.append(control_of(p) + f"\nFilename: ./{f}\nSize: {len(raw)}\nMD5sum: {hashlib.md5(raw).hexdigest()}\n"
                   f"SHA1: {hashlib.sha1(raw).hexdigest()}\nSHA256: {hashlib.sha256(raw).hexdigest()}\n")
packages = "\n".join(entries).encode()
files = {"Packages": packages, "Packages.gz": gzip.compress(packages, mtime=0), "Packages.bz2": bz2.compress(packages)}
for n, d in files.items(): open(os.path.join(out, n), "wb").write(d)
rel = ["Origin: PhoneBox", "Label: PhoneBox", "Suite: stable", "Version: 1.0", "Codename: ios", "Architectures: iphoneos-arm64",
       "Components: main", "Description: PhoneBox for jailbroken iPhones (rootless)", "SHA256:"]
for n, d in files.items(): rel.append(f" {hashlib.sha256(d).hexdigest()} {len(d)} {n}")
open(os.path.join(out, "Release"), "w").write("\n".join(rel) + "\n")
print("apt repo:", out, [e.split("\n")[0] for e in entries])
