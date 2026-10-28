#!/usr/bin/env python3
"""Lays out the Kikumap disk-image window: Kikumap on the left, the Applications shortcut on the right,
big icons, no toolbar or sidebar, and the picture in .background/background.tiff behind them.

Usage:
  dmg-layout.py <folder>              writes <folder>/.DS_Store
  dmg-layout.py --fix <image> <folder>
      Finder finds the background through an alias, which needs IDs only the finished image has. So the
      first call writes a stand-in alias of the same size; after `hdiutil makehybrid`, this reads the
      real IDs out of the image's HFS+ catalog and swaps the .DS_Store inside the image in place.

The .DS_Store is a "buddy allocator" holding one B-tree leaf of records, sorted by file name
(case-insensitive) and then by record code."""
import plistlib
import struct
import sys

W, H = 560, 380                         # window frame, title bar included
ICON = 128
SPOTS = {"Kikumap.app": (140, 165), "Applications": (420, 165)}
VOLUME = "Kikumap"
BG_DIR, BG_FILE = ".background", "background.tiff"


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


def alias(volume_date, folder_cnid, file_cnid, file_date):
    """A Mac alias (version 2) to /.background/background.tiff on the Kikumap volume."""
    def tag(t, data):
        return struct.pack(">hh", t, len(data)) + data + (b"\0" if len(data) & 1 else b"")
    fixed = struct.pack(">h28pI2shI64pII4s4shhI2s10s",
                        0, VOLUME.encode(), volume_date, b"H+", 5,          # a file · ejectable disk
                        folder_cnid, BG_FILE.encode(), file_cnid, file_date,
                        b"\0" * 4, b"\0" * 4, -1, -1, 0, b"\0\0", b"\0" * 10)
    extras = tag(0, BG_DIR.encode())
    extras += struct.pack(">hhQhhQ", 16, 8, volume_date * 65536, 17, 8, file_date * 65536)
    extras += tag(1, struct.pack(">I", folder_cnid))
    extras += tag(2, f"{VOLUME}:{BG_DIR}:{BG_FILE}".encode())
    for t, text in ((14, BG_FILE), (15, VOLUME)):
        u = text.encode("utf-16-be")
        extras += struct.pack(">hhh", t, len(u) + 2, len(u) // 2) + u
    extras += tag(18, f"/{BG_DIR}/{BG_FILE}".encode())
    extras += tag(19, f"/Volumes/{VOLUME}".encode())
    extras += struct.pack(">hh", -1, 0)
    body = fixed + extras
    return struct.pack(">4shh", b"\0" * 4, 8 + len(body), 2) + body


def ds_store(background):
    window = plist({
        "ContainerShowSidebar": False, "ShowPathbar": False, "ShowSidebar": False,
        "ShowStatusBar": False, "ShowTabView": False, "ShowToolbar": False, "SidebarWidth": 0,
        "WindowBounds": "{{240, 180}, {%d, %d}}" % (W, H),
    })
    view = {
        "arrangeBy": "none", "backgroundType": 0,
        "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0,
        "iconSize": float(ICON), "textSize": 13.0, "labelOnBottom": True,
        "showIconPreview": True, "showItemInfo": False, "viewOptionsVersion": 1,
    }
    if background is not None:
        view["backgroundType"] = 2
        view["backgroundImageAlias"] = background
    records = [
        (".", "bwsp", "blob", window),
        (".", "icvl", "type", "icnv"),
        (".", "icvp", "blob", plist(view)),
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
    return struct.pack(">I", 1) + bytes(space)


def catalog(img):
    """(parent id, name) → (kind, id, creation date) for every file and folder in the image's HFS+ volume."""
    u16 = lambda b, o: struct.unpack_from(">H", b, o)[0]
    u32 = lambda b, o: struct.unpack_from(">I", b, o)[0]
    p = img.find(b"H+\x00\x04")
    assert p >= 1024 and (p - 1024) % 512 == 0, "no HFS+ volume in the image"
    base, vh = p - 1024, img[p:p + 512]
    block = u32(vh, 40)
    fork = vh[272:352]
    cat = b"".join(img[base + u32(fork, 16 + 8 * i) * block:base + (u32(fork, 16 + 8 * i) + u32(fork, 20 + 8 * i)) * block]
                   for i in range(8) if u32(fork, 20 + 8 * i))
    node_size, node = u16(cat, 32), u32(cat, 24)          # header record: node size, first leaf
    out = {}
    while node:
        nd = cat[node * node_size:(node + 1) * node_size]
        for i in range(u16(nd, 10)):
            off = u16(nd, node_size - 2 * (i + 1))
            parent, n = u32(nd, off + 2), u16(nd, off + 6)
            name = nd[off + 8:off + 8 + 2 * n].decode("utf-16-be")
            d = off + 2 + u16(nd, off)
            kind = u16(nd, d)
            if kind in (1, 2):                              # folder, file: id and creation date
                out[(parent, name)] = (kind, u32(nd, d + 8), u32(nd, d + 12))
        node = u32(nd, 0)
    return out


def main(args):
    if args[0] == "--fix":
        image, folder = args[1], args[2].rstrip("/")
        img = bytearray(open(image, "rb").read())
        old = open(folder + "/.DS_Store", "rb").read()
        c = catalog(bytes(img))
        _, _, vol_date = c[(1, VOLUME)]
        _, dir_id, _ = c[(2, BG_DIR)]
        _, file_id, file_date = c[(dir_id, BG_FILE)]
        new = ds_store(alias(vol_date, dir_id, file_id, file_date))
        assert len(new) == len(old), "the .DS_Store changed size"
        n = img.count(old)
        assert n >= 1, "the .DS_Store isn't in the image"
        img = img.replace(old, new)
        open(image, "wb").write(img)
        print(f"background alias: volume date {vol_date}, folder {dir_id}, file {file_id} ({n}×)")
        return
    folder = args[0].rstrip("/")
    import os
    has_bg = os.path.exists(f"{folder}/{BG_DIR}/{BG_FILE}")
    with open(folder + "/.DS_Store", "wb") as f:
        f.write(ds_store(alias(0, 0, 0, 0) if has_bg else None))


main(sys.argv[1:])
