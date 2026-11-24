"""Alpine package verification, as apk-tools does it.
APKINDEX.tar.gz and .apk files are concatenated gzip streams. The first stream holds .SIGN.RSA[256].<key>.pub,
an RSA signature over the next stream's compressed bytes. A package's control stream SHA-1 must equal the
index's C: field (Q1 + base64), and .PKGINFO's datahash is the SHA-256 of the data stream."""
import base64, hashlib, io, os, subprocess, sys, tarfile, zlib

def streams(data):
    out, i = [], 0
    while i < len(data):
        d = zlib.decompressobj(31)
        d.decompress(data[i:])
        end = len(data) - len(d.unused_data)
        out.append(data[i:end]); i = end
    return out

def members(stream):
    raw = zlib.decompress(stream, 31)
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as t:
        return {m.name: (t.extractfile(m).read() if m.isfile() else None) for m in t.getmembers()}

def verify_sig(sig_stream, signed, keys):
    for name, sig in members(sig_stream).items():
        if not name.startswith(".SIGN.RSA"): continue
        algo = "-sha256" if name.startswith(".SIGN.RSA256.") else "-sha1"
        key = os.path.join(keys, name.split(".", 3)[3])
        if not os.path.exists(key): raise SystemExit(f"unknown signing key {name}")
        open("/tmp/.macx-sig", "wb").write(sig); open("/tmp/.macx-signed", "wb").write(signed)
        r = subprocess.run(["openssl", "dgst", algo, "-verify", key, "-signature", "/tmp/.macx-sig", "/tmp/.macx-signed"], capture_output=True, text=True)
        os.remove("/tmp/.macx-sig"); os.remove("/tmp/.macx-signed")
        return r.stdout.strip() == "Verified OK", os.path.basename(key)
    raise SystemExit("no signature found")

mode, path, keys = sys.argv[1], sys.argv[2], sys.argv[3]
data = open(path, "rb").read()
s = streams(data)
ok, key = verify_sig(s[0], s[1], keys)
if not ok: raise SystemExit(f"BAD SIGNATURE {path}")
if mode == "index":
    open(sys.argv[4], "wb").write(members(s[1])["APKINDEX"]); print(f"index signature OK ({key})")
else:
    want_c = sys.argv[4]
    got_c = "Q1" + base64.b64encode(hashlib.sha1(s[1]).digest()).decode()
    if got_c != want_c: raise SystemExit(f"control hash mismatch {path}")
    info = members(s[1])[".PKGINFO"].decode()
    datahash = next(l.split(" = ")[1] for l in info.splitlines() if l.startswith("datahash"))
    if hashlib.sha256(s[2]).hexdigest() != datahash: raise SystemExit(f"data hash mismatch {path}")
    print(f"package OK: {os.path.basename(path)} (signature {key}, control + data hashes match)")
