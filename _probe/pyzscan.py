import io, os, re, struct, sys, zlib, marshal

EXE = r"D:\DSH插件\dsh-pet-indesktop\dsh-pet-standalone-webm-chat.exe"
data = open(EXE, "rb").read()
print("exe size", len(data))

MAGIC = b"MEI\014\013\012\013\016"
pos = data.rfind(MAGIC)
print("cookie at", pos)
if pos < 0:
    sys.exit("no cookie")
cook = data[pos:pos + 88]
magic = cook[:8]
pkglen, tocoff, toclen, pyvers = struct.unpack("!iiii", cook[8:24])
print("pkg", pkglen, "toc", tocoff, "toclen", toclen, "pyvers", pyvers)

tocdata = data[pos - tocoff: pos - tocoff + toclen]
entries = []
i = 0
while i < len(tocdata):
    (elen, dpos, dlen, ulen, cflag, typecd) = struct.unpack("!iIIIBc", tocdata[i:i + 18])
    name = tocdata[i + 18:i + elen].rstrip(b"\0").decode("utf8", "replace")
    entries.append((name, dpos, dlen, cflag, typecd))
    i += elen
print("entries", len(entries))
for e in entries[:40]:
    print("  ", e[0], e[4], e[2])

# CArchive data area starts at pos - tocoff - pkglen
base = pos - tocoff - pkglen
pyz = None
for name, dpos, dlen, cflag, typecd in entries:
    if typecd in (b"z", b"Z") or name.startswith("PYZ"):
        raw = data[base + dpos: base + dpos + dlen]
        if cflag:
            raw = zlib.decompress(raw)
        pyz = raw
        print("PYZ", name, "->", len(raw))
        break
if pyz is None:
    sys.exit("no PYZ")

# PYZ layout: b'PYZ\0' + pyc magic(4) + toc offset(4 BE)
assert pyz[:4] == b"PYZ\0", pyz[:8]
toc_off = struct.unpack("!i", pyz[8:12])[0]
toc = marshal.loads(pyz[toc_off:])
print("pyz modules", len(toc))

needles = [b"npm add", b"pnpm add", b"dsh-pet-bridge", b"bridge", b"instances", b"\xe6\xa1\xa5\xe6\x8e\xa5"]
hits = []
for name, meta in toc.items():
    ispkg, off, ln = meta
    blob = pyz[off:off + ln]
    try:
        blob = zlib.decompress(blob)
    except Exception:
        pass
    found = [n for n in needles if n in blob]
    if found:
        hits.append((name, found, blob))

print("modules with hits:", len(hits))
for name, found, blob in hits:
    print("==", name, found)
    strs = re.findall(rb"[\x20-\x7e\x80-\xff]{6,}", blob)
    for s in strs:
        t = s.decode("utf8", "replace")
        if any(k in t for k in ("npm", "pnpm", "bridge", "install", "add ", "instance", "profile", "dsh")):
            print("    ", t[:160])
