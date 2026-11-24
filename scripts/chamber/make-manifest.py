#!/usr/bin/env python3
"""Builds the light chamber's pinned manifest: every file `macx chamber setup` downloads, with its SHA-256.

It verifies everything the way apk-tools does, once, here:
- the minirootfs against Alpine's latest-releases.yaml (HTTPS);
- the APKINDEX RSA signature against the keys inside that minirootfs;
- each package's control and data hashes against the signed index.

At setup time macx then only has to match SHA-256s against this reviewed list. Re-run it to move to a newer
Alpine release, and review the diff.

Usage: python3 -I scripts/chamber/make-manifest.py ARCH CACHE_DIR    (ARCH: aarch64 or x86_64)
Writes data/chamber/manifest-ARCH.json and refreshes Sources/MacxCore/ChamberManifestData.swift.
"""
import hashlib, json, os, subprocess, sys, tarfile, urllib.request

ALPINE = "3.24"
PACKAGES = ["linux-virt", "bash", "zsh", "strace"]
CDN = "https://dl-cdn.alpinelinux.org/alpine"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

def fetch(url, dest):
    if not os.path.exists(dest):
        with urllib.request.urlopen(url, timeout=120) as r, open(dest + ".part", "wb") as f:
            f.write(r.read())
        os.rename(dest + ".part", dest)
    return dest

def sha256(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()

def entries(text):
    cur, out = {}, []
    for line in text.splitlines():
        if not line:
            if cur: out.append(cur); cur = {}
            continue
        if len(line) > 2 and line[1] == ":": cur[line[0]] = line[2:]
    if cur: out.append(cur)
    return out

def main():
    arch, cache = sys.argv[1], sys.argv[2]
    os.makedirs(cache, exist_ok=True)
    rel = urllib.request.urlopen(f"{CDN}/v{ALPINE}/releases/{arch}/latest-releases.yaml", timeout=60).read().decode()
    blocks = [b for b in rel.split("\n-\n") if "alpine-minirootfs" in b] or [rel]
    def field(block, key): return next(l.split(":", 1)[1].strip() for l in block.splitlines() if l.strip().startswith(key + ":"))
    mini = next(b for b in rel.split("-\n") if "flavor: alpine-minirootfs" in b)
    version, mfile, msha = field(mini, "version"), field(mini, "file"), field(mini, "sha256")
    mpath = fetch(f"{CDN}/v{ALPINE}/releases/{arch}/{mfile}", os.path.join(cache, mfile))
    assert sha256(mpath) == msha, "minirootfs hash mismatch"
    root = os.path.join(cache, f"rootfs-{arch}")
    os.makedirs(root, exist_ok=True)
    with tarfile.open(mpath) as t:
        t.extractall(root, members=[m for m in t.getmembers() if m.name.startswith(("./etc/apk", "./lib/apk", "etc/apk", "lib/apk"))])
    keys = os.path.join(root, "etc/apk/keys")
    idx_tgz = fetch(f"{CDN}/v{ALPINE}/main/{arch}/APKINDEX.tar.gz", os.path.join(cache, f"APKINDEX-{arch}.tar.gz"))
    idx_path = os.path.join(cache, f"APKINDEX-{arch}")
    subprocess.run([sys.executable, "-I", os.path.join(HERE, "apkverify.py"), "index", idx_tgz, keys, idx_path], check=True)
    idx = entries(open(idx_path, encoding="utf-8", errors="replace").read())
    installed = {e["P"] for e in entries(open(os.path.join(root, "lib/apk/db/installed"), encoding="utf-8").read())}
    byname = {e["P"]: e for e in idx}
    provider = {}
    for e in idx:
        for p in e.get("p", "").split(): provider.setdefault(p.split("=")[0], e["P"])
    need, todo = [], list(PACKAGES)
    while todo:
        n = todo.pop(0)
        if n in installed or n in need or n not in byname: continue
        need.append(n)
        if n == "linux-virt": continue  # only the kernel image is used; its boot-image tooling isn't
        for d in byname[n].get("D", "").split():
            if d.startswith("!"): continue
            d = d.split(">")[0].split("<")[0].split("=")[0]
            todo.append(provider.get(d, d))
    files = [{"role": "rootfs", "name": "alpine-minirootfs", "version": version, "url": f"{CDN}/v{ALPINE}/releases/{arch}/{mfile}",
              "sha256": msha, "bytes": os.path.getsize(mpath)}]
    for n in need:
        e = byname[n]; f = f"{n}-{e['V']}.apk"
        p = fetch(f"{CDN}/v{ALPINE}/main/{arch}/{f}", os.path.join(cache, f))
        subprocess.run([sys.executable, "-I", os.path.join(HERE, "apkverify.py"), "pkg", p, keys, e["C"]], check=True)
        files.append({"role": "kernel" if n == "linux-virt" else "package", "name": n, "version": e["V"],
                      "url": f"{CDN}/v{ALPINE}/main/{arch}/{f}", "sha256": sha256(p), "bytes": os.path.getsize(p)})
    manifest = {"schema": 1, "alpine": version, "arch": arch, "files": files}
    out = os.path.join(ROOT, "data/chamber", f"manifest-{arch}.json")
    json.dump(manifest, open(out, "w"), indent=2); open(out, "a").write("\n")
    print(f"{arch}: Alpine {version}, {len(files)} files, {sum(f['bytes'] for f in files)/1e6:.1f} MB -> {os.path.relpath(out, ROOT)}")
    # Swift copy, so the installed macx carries the pins without a resource bundle.
    parts = []
    for name in sorted(os.listdir(os.path.join(ROOT, "data/chamber"))):
        if name.startswith("manifest-") and name.endswith(".json"):
            a = name[len("manifest-"):-len(".json")]
            parts.append(f'        "{a}": #"""\n{open(os.path.join(ROOT, "data/chamber", name)).read().rstrip()}\n"""#,')
    swift = ("// Generated by scripts/chamber/make-manifest.py from data/chamber/manifest-*.json. Don't edit by hand.\n\n"
             "enum ChamberManifestData {\n    static let json: [String: String] = [\n" + "\n".join(parts) + "\n    ]\n}\n")
    open(os.path.join(ROOT, "Sources/MacxCore/ChamberManifestData.swift"), "w").write(swift)

main()
