#!/usr/bin/env python3
"""Unsparse an Android sparse image and compare against a raw reference.

Verifies that odin-debian-sparse.img and odin-debian.img contain identical
data. Exit code 0 = identical.

Usage: check_sparse.py <sparse.img> <raw.img>
"""
import struct
import sys
from pathlib import Path

CHUNK_RAW = 0xCAC1
CHUNK_FILL = 0xCAC2
CHUNK_DONT_CARE = 0xCAC3


def unsparse(sparse_path: str) -> bytes:
    d = Path(sparse_path).read_bytes()
    magic, mm, hdrs, blk_sz, total_blks, total_chunks, _crc = struct.unpack('<7I', d[:28])
    assert magic == 0xED26FF3A and mm == 1, 'not a sparse v1 image'
    assert hdrs == ((12 << 16) | 28), f'unexpected header sizes {hdrs:#x}'
    parts = []
    pos = 28
    for i in range(total_chunks):
        ct, chunk_sz, totsz = struct.unpack('<3I', d[pos:pos + 12])
        if ct == CHUNK_RAW:
            parts.append(d[pos + 12:pos + 12 + chunk_sz * blk_sz])
        elif ct == CHUNK_FILL:
            parts.append(d[pos + 12:pos + 16] * (chunk_sz * blk_sz // 4))
        elif ct == CHUNK_DONT_CARE:
            pass
        else:
            raise SystemExit(f'unknown chunk type {ct:#x} at #{i}')
        pos += totsz
    data = b''.join(parts)
    assert len(data) == total_blks * blk_sz, 'size mismatch after unsparse'
    return data


def main(sparse_path: str, raw_path: str) -> None:
    un = unsparse(sparse_path)
    raw = Path(raw_path).read_bytes()
    if un == raw:
        print('IDENTICAL')
        return
    b = 4096
    diffs = [i for i in range(0, min(len(un), len(raw)), b)
             if un[i:i + b] != raw[i:i + b]]
    print(f'DIFFERENT: {len(diffs)} differing {b}-byte blocks')
    print('first offsets:', [hex(o) for o in diffs[:10]])
    sys.exit(1)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
