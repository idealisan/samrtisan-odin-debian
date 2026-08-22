#!/usr/bin/env python3
"""Parse an Android boot image (v0 header) and extract kernel/ramdisk/second.

Also scans for embedded FDT blobs (magic d00dfeed) and carves them out.
Usage: parse_bootimg.py <boot.img> <outdir>
"""
import re
import struct
import sys
from pathlib import Path


def main(img_path: str, outdir: str) -> None:
    d = Path(img_path).read_bytes()
    out = Path(outdir)
    out.mkdir(parents=True, exist_ok=True)

    (magic, kernel_size, kernel_addr, ramdisk_size, ramdisk_addr,
     second_size, second_addr, tags_addr, page_size, dt_size) = struct.unpack('<8s9I', d[:44])
    assert magic == b'ANDROID!', 'not an android boot image'
    cmdline = d[64:64 + 512].split(b'\0')[0].decode(errors='replace')

    print(f'kernel={kernel_size}@{kernel_addr:#x} ramdisk={ramdisk_size}@{ramdisk_addr:#x}')
    print(f'second={second_size}@{second_addr:#x} tags={tags_addr:#x} page={page_size} dt={dt_size}')
    print('cmdline:', repr(cmdline))

    ps = page_size

    def off(n):
        return ((n + ps - 1) // ps) * ps

    o = ps
    ks = o; o += off(kernel_size)
    (out / 'kernel.bin').write_bytes(d[ks:ks + kernel_size])
    if ramdisk_size:
        (out / 'ramdisk.bin').write_bytes(d[o:o + ramdisk_size]); o += off(ramdisk_size)
    if second_size:
        (out / 'second.bin').write_bytes(d[o:o + second_size]); o += off(second_size)
    print(f'sections: kernel@{ks:#x} ramdisk@{ks+off(kernel_size):#x} second@{o:#x}')

    # carve embedded FDTs from the whole image (lk2nd embeds device DTBs in its binary)
    n = 0
    for m in re.finditer(b'\xd0\x0d\xfe\xed', d):
        tot = struct.unpack('>I', d[m.start() + 4:m.start() + 8])[0]
        if 0 < tot <= len(d) - m.start():
            (out / f'fdt_{n:02d}_{m.start():x}.dtb').write_bytes(d[m.start():m.start() + tot])
            n += 1
    print(f'carved {n} embedded FDTs into {out}')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
