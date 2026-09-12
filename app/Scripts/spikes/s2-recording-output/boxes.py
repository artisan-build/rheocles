#!/usr/bin/env python3
"""List the top-level boxes of a MOV/MP4 so `moof` fragments are visible
without trusting anyone's summary. A fragmented movie is `ftyp moov
[moof mdat]+ ...`; a conventional one is `ftyp mdat moov` or `ftyp moov mdat`
with the `moov` written only at finalisation — which is exactly what a
kill -9 never gets to."""
import struct, sys, collections

path = sys.argv[1]
counts = collections.Counter()
rows = []
with open(path, "rb") as f:
    f.seek(0, 2); end = f.tell(); f.seek(0)
    off = 0
    while off < end:
        f.seek(off)
        hdr = f.read(8)
        if len(hdr) < 8:
            rows.append((off, "<truncated header>", end - off)); break
        size, typ = struct.unpack(">I4s", hdr)
        typ = typ.decode("latin1")
        if size == 1:
            size = struct.unpack(">Q", f.read(8))[0]
        elif size == 0:
            size = end - off
        rows.append((off, typ, size))
        counts[typ] += 1
        if size < 8: rows.append((off, "<bad size>", size)); break
        off += size
    if off > end:
        rows.append((end, "<last box runs past EOF by %d bytes>" % (off - end), 0))

for off, typ, size in rows[:12]:
    print("%12d  %-6s %12d" % (off, typ, size))
if len(rows) > 12:
    print("         ...  (%d boxes total)" % len(rows))
    for off, typ, size in rows[-3:]:
        print("%12d  %-6s %12d" % (off, typ, size))
print("counts:", dict(counts))
print("fragmented:", "yes" if counts["moof"] > 0 else "no", "| has moov:", "yes" if counts["moov"] > 0 else "no")
