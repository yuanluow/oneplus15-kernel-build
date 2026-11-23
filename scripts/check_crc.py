#!/usr/bin/env python3
"""Check that our KMI symbol CRCs match the stock kernel.

Vendor modules (vendor_boot / vendor_dlkm) were built against the stock GKI and
carry its symbol CRCs. If ours differ, every such module is rejected
("disagrees about version of symbol") and the phone reboots at the first logo.

usage: check_crc.py <out/vmlinux.symvers> <gki/aarch64/symbols dir> <stock boot.img or Image>

Only KMI symbols (the lists in gki/aarch64/symbols) are checked, because the stock
kernel is built with TRIM_UNUSED_KSYMS and has no CRC for anything else. A CRC is
counted as present when its 4 little-endian bytes appear 4-byte aligned in the
stock kernel image (the __kcrctab array); a random 32-bit value matches by chance
with probability well under 1%.
"""
import os
import random
import struct
import sys

symvers, symdir, stock = sys.argv[1:4]
MIN_RATIO = float(os.environ.get("CRC_MIN_RATIO", "0.97"))
SAMPLE = 400

data = open(stock, "rb").read()
if data[:8] == b"ANDROID!":  # boot image header v3/v4: kernel starts at page 4096
    ksz = struct.unpack_from("<I", data, 8)[0]
    data = data[4096:4096 + ksz]

kmi = set()
for name in os.listdir(symdir):
    path = os.path.join(symdir, name)
    if not os.path.isfile(path):
        continue
    for line in open(path, encoding="utf-8", errors="ignore"):
        s = line.strip()
        if s and not s.startswith(("[", "#")):
            kmi.add(s.split()[0])

ours = {}
for line in open(symvers, encoding="utf-8", errors="ignore"):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 2 and p[0].startswith("0x") and p[1] in kmi:
        ours[p[1]] = int(p[0], 16)

if len(ours) < 100:
    print(f"::error::check_crc: only {len(ours)} KMI symbols found in {symvers}")
    sys.exit(1)

names = sorted(ours)
random.seed(1)
sample = random.sample(names, min(SAMPLE, len(names)))


def present(crc):
    needle = struct.pack("<I", crc)
    i = data.find(needle)
    while i >= 0:
        if i % 4 == 0:
            return True
        i = data.find(needle, i + 1)
    return False


missing = [n for n in sample if not present(ours[n])]
ratio = 1 - len(missing) / len(sample)
print(f"CRC check: {len(sample) - len(missing)}/{len(sample)} sampled KMI symbol CRCs "
      f"match the stock kernel ({ratio:.1%}, need >= {MIN_RATIO:.0%})")
if missing:
    print("  not found in stock kernel (first 20): " + ", ".join(missing[:20]))
if ratio < MIN_RATIO:
    print("::error::Symbol CRCs do not match the stock kernel - vendor modules would fail "
          "to load and the phone would not boot.")
    sys.exit(1)
