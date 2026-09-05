#!/usr/bin/env python3
"""核对 odin-debian.img 的 ext4 特性位与超级块校验和（metadata_csum 专项）。

用法：
    python3 sbcheck.py <image> [另一个 image ...]

为什么需要它：
  开了 metadata_csum 之后，内核挂载时会验超级块校验和。校验和不对 => 直接拒绝挂载，
  表现就是"起不来"。这个脚本在**宿主机**上把内核那套算法重算一遍，和镜像里存的值
  对比，不用刷机就能判断镜像会不会被内核接受。

算法（与 fs/ext4/super.c 的 ext4_superblock_csum 对齐）：
    csum = crc32c(~0, superblock[0 : offsetof(s_checksum)])
  即：整段超级块（s_checksum 字段先置 0）做一次标准 CRC-32C。

踩过的坑（别重蹈）：
  * crc32c 的"前后取反"约定极易搞错。第一版脚本用错了约定，算出"校验和不一致"，
    差点误报镜像有问题。所以这里**先跑自检向量**再算：
        crc32c("123456789") == 0xE3069283
    通不过就是脚本错了，不是镜像错了。
  * s_checksum 在超级块内的偏移是 0x3FC（超级块本身在分区偏移 1024 处）。
  * 字段偏移可用 s_volume_name 反查：0x78 处应读出 b'pmOS_root'。
"""
import struct
import sys

POLY = 0x82F63B78
_TAB = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = (_c >> 1) ^ (POLY if _c & 1 else 0)
    _TAB.append(_c)


def crc32c(crc, data):
    """与内核 crc32c(crc, data, len) 同义：不做前后取反，由调用方决定。"""
    c = crc
    for b in data:
        c = _TAB[(c ^ b) & 0xFF] ^ (c >> 8)
    return c


assert (crc32c(0xFFFFFFFF, b"123456789") ^ 0xFFFFFFFF) == 0xE3069283, "crc32c 实现有误"

INCOMPAT = {
    0x1: "compression", 0x2: "filetype", 0x4: "recover", 0x8: "journal_dev",
    0x10: "meta_bg", 0x40: "extents", 0x80: "64bit", 0x200: "flex_bg",
    0x400: "ea_inode", 0x8000: "inline_data", 0x10000: "encrypt", 0x20000: "casefold",
}
RO_COMPAT = {
    0x1: "sparse_super", 0x2: "large_file", 0x8: "huge_file", 0x10: "gdt_csum",
    0x20: "dir_nlink", 0x40: "extra_isize", 0x100: "quota", 0x200: "bigalloc",
    0x400: "metadata_csum",
}
COMPAT = {
    0x1: "dir_prealloc", 0x4: "has_journal", 0x8: "ext_attr",
    0x10: "resize_inode", 0x20: "dir_index", 0x200: "sparse_super2", 0x400: "fast_commit",
}
LK2ND_RO_ALLOWED = 0x1 | 0x2 | 0x400  # lk2nd 补丁 0006 之后的白名单


def bits(v, tbl):
    return [n for b, n in sorted(tbl.items()) if v & b] or ["(无)"]


def check(path):
    with open(path, "rb") as f:
        f.seek(1024)
        sb = bytearray(f.read(1024))
    magic, = struct.unpack_from("<H", sb, 0x38)
    compat, = struct.unpack_from("<I", sb, 0x5C)
    incompat, = struct.unpack_from("<I", sb, 0x60)
    ro, = struct.unpack_from("<I", sb, 0x64)
    label = bytes(sb[0x78:0x88]).split(b"\0")[0].decode("ascii", "replace")
    stored, = struct.unpack_from("<I", sb, 0x3FC)

    print("=== %s ===" % path)
    print("  magic 0x%x (%s)  卷标 %r" % (magic, "OK" if magic == 0xEF53 else "坏", label))
    print("  compat    0x%-6x %s" % (compat, " ".join(bits(compat, COMPAT))))
    print("  incompat  0x%-6x %s" % (incompat, " ".join(bits(incompat, INCOMPAT))))
    print("  ro_compat 0x%-6x %s" % (ro, " ".join(bits(ro, RO_COMPAT))))

    masked = ro & ~LK2ND_RO_ALLOWED
    print("  lk2nd 挂载门禁：ro_compat & ~0x%x = 0x%x -> %s"
          % (LK2ND_RO_ALLOWED, masked, "放行" if masked == 0 else "拒绝（lk2nd 挂不上）"))

    if not (ro & 0x400):
        print("  超级块校验和：metadata_csum 未开，内核不校验（存储值 0x%08x）" % stored)
        return
    body = bytes(sb[:0x3FC])  # s_checksum 字段被排除在外（内核是先把它置 0 再算）
    calc = crc32c(0xFFFFFFFF, body)
    print("  超级块校验和：存储 0x%08x  重算 0x%08x  -> %s"
          % (stored, calc, "一致，内核会接受" if calc == stored else "★不一致，内核会拒绝挂载"))
    print()


if __name__ == "__main__":
    for p in sys.argv[1:] or ["dist/odin-debian.img"]:
        check(p)
