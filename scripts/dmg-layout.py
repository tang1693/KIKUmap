#!/usr/bin/env python3
"""Writes the .DS_Store that lays out the Kikumap disk-image window: Kikumap on the left,
the Applications shortcut on the right, big icons, no toolbar or sidebar.

Usage: dmg-layout.py <folder>   (writes <folder>/.DS_Store)

The file is a "buddy allocator" holding one B-tree leaf of records, sorted by file
name (case-insensitive) and then by record code."""
import plistlib
import struct
import sys

W, H = 560, 380                         # window frame, title bar included
ICON = 128
SPOTS = {"Kikumap.app": (140, 165), "Applications": (420, 165)}


def record(name, code, kind, value):
    n = name.encode("utf-16-be")
    out = struct.pack(">I", len(n) // 2) + n + code.encode() + kind.encode()
    if kind == "blob":
        return out + struct.pack(">I", len(value)) + value
    if kind == "long":
        return out + struct.pack(">I", value)
    return out + value.encode()          # "type": a four-letter code


def plist(d):
    return plistlib.dumps(d, fmt=plistlib.FMT_BINARY)


window = plist({
    "ContainerShowSidebar": False, "ShowPathbar": False, "ShowSidebar": False,
    "ShowStatusBar": False, "ShowTabView": False, "ShowToolbar": False, "SidebarWidth": 0,
    "WindowBounds": "{{240, 180}, {%d, %d}}" % (W, H),
})
icons = plist({
    "arrangeBy": "none", "backgroundType": 0,
    "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
    "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0,
    "iconSize": float(ICON), "textSize": 13.0, "labelOnBottom": True,
    "showIconPreview": True, "showItemInfo": False, "viewOptionsVersion": 1,
})

records = [
    (".", "bwsp", "blob", window),
    (".", "icvl", "type", "icnv"),
    (".", "icvp", "blob", icons),
    (".", "vSrn", "long", 1),
] + [(name, "Iloc", "blob", struct.pack(">IIII", x, y, 0xFFFFFFFF, 0xFFFF0000))
     for name, (x, y) in SPOTS.items()]
records.sort(key=lambda r: (r[0].lower(), r[1].encode()))

# Blocks in an 8 KB space (offsets count from file byte 4; each block aligned to its size):
# 0 header (32)  ·  32 DSDB (32)  ·  2048 block list (2048)  ·  4096 the leaf (4096)
LEAF, DSDB, INFO = (4096, 12), (32, 5), (2048, 11)

leaf = struct.pack(">II", 0, len(records)) + b"".join(record(*r) for r in records)
assert len(leaf) <= 4096, "too many records for one leaf"
dsdb = struct.pack(">IIIII", 2, 0, len(records), 1, 0x1000)   # root block, levels, records, nodes, page size

info = struct.pack(">II", 3, 0)
info += b"".join(struct.pack(">I", off | log) for off, log in (INFO, DSDB, LEAF))
info += b"\0" * 4 * (256 - 3)
info += struct.pack(">I", 1) + bytes([4]) + b"DSDB" + struct.pack(">I", 1)
# what the blocks leave free, up to the allocator's 2 GB space (as Finder writes it)
free = {6: [64], 7: [128], 8: [256], 9: [512], 10: [1024]} | {n: [1 << n] for n in range(13, 31)}
for size in range(32):
    offs = free.get(size, [])
    info += struct.pack(">I", len(offs)) + b"".join(struct.pack(">I", o) for o in offs)

space = bytearray(8192)
space[0:32] = b"Bud1" + struct.pack(">III", INFO[0], 1 << INFO[1], INFO[0]) + bytes.fromhex("00000209") + b"\0" * 12
space[DSDB[0]:DSDB[0] + len(dsdb)] = dsdb
space[INFO[0]:INFO[0] + len(info)] = info
space[LEAF[0]:LEAF[0] + len(leaf)] = leaf

with open(sys.argv[1].rstrip("/") + "/.DS_Store", "wb") as f:
    f.write(struct.pack(">I", 1) + bytes(space))
