#!/usr/bin/env python3
"""Unsparse an Android sparse image and compare against a raw reference.

Verifies that odin-debian-sparse.img and odin-debian.img contain identical
data. Exit code 0 = identical.

Usage: check_sparse.py <sparse.img> <raw.img>

为什么是流式比对：早先版本把两个文件整体读进内存再比（bytes 拼起来）。
core 变体（约 800 MiB）没问题，gui 变体（约 4.6 GiB）就直接把内存吃光 ——
两个文件各一份就是 9 GB 多，进程被 OOM 杀掉，表现为校验失败却没有任何输出
（退出码非 0、stdout 空），报错离真因很远。
现在按 4 MiB 一片边读边比，内存占用恒定。
"""
import struct
import sys

CHUNK_RAW = 0xCAC1
CHUNK_FILL = 0xCAC2
CHUNK_DONT_CARE = 0xCAC3

# 单次读写的上限：4 MiB。再大省不了多少时间，却把内存占用线性抬上去。
SLICE = 4 << 20


def fail(msg: str) -> None:
    print(msg)
    sys.exit(1)


def main(sparse_path: str, raw_path: str) -> None:
    diffs = []
    raw_pos = 0
    with open(sparse_path, 'rb') as sf, open(raw_path, 'rb') as rf:
        hdr = sf.read(28)
        if len(hdr) != 28:
            fail('sparse 文件头都读不全（img2simg 失败了？）')
        magic, mm, hdrs, blk_sz, total_blks, total_chunks, _crc = \
            struct.unpack('<7I', hdr)
        if magic != 0xED26FF3A or mm != 1:
            fail(f'不是 sparse v1 镜像: magic={magic:#x} major={mm}')
        if hdrs != ((12 << 16) | 28):
            fail(f'文件头尺寸异常 {hdrs:#x}')

        for i in range(total_chunks):
            ch = sf.read(12)
            if len(ch) != 12:
                fail(f'第 {i} 个 chunk 头读不全（文件被截断）')
            ct, chunk_sz, totsz = struct.unpack('<3I', ch)
            nbytes = chunk_sz * blk_sz
            body = sf.read(totsz - 12)
            if len(body) != totsz - 12:
                fail(f'第 {i} 个 chunk 数据读不全（文件被截断）')

            if ct == CHUNK_RAW:
                for off in range(0, nbytes, SLICE):
                    piece = body[off:off + SLICE]
                    if rf.read(len(piece)) != piece:
                        diffs.append(raw_pos + off)
                    raw_pos += len(piece)
            elif ct == CHUNK_FILL:
                fill = body[:4]
                left = nbytes
                while left > 0:
                    n = min(SLICE, left)
                    if rf.read(n) != fill * (n // 4):
                        diffs.append(raw_pos)
                    raw_pos += n
                    left -= n
            elif ct == CHUNK_DONT_CARE:
                # 与旧版一致：dont-care 段不参与比对，但 raw 侧要跳过同样长度
                rf.seek(nbytes, 1)
                raw_pos += nbytes
            else:
                fail(f'unknown chunk type {ct:#x} at #{i}')

        # 比对完所有 chunk 后，raw 应当正好读完
        tail = rf.read(1)
        if tail:
            fail(f'sparse 比 raw 短：raw 还剩内容（已比对 {raw_pos} 字节）')
        if raw_pos != total_blks * blk_sz:
            fail(f'长度不一致: sparse {total_blks * blk_sz} vs raw {raw_pos}')

    if diffs:
        print(f'DIFFERENT: {len(diffs)} differing {blk_sz}-byte blocks')
        print('first offsets:', [hex(o) for o in diffs[:10]])
        sys.exit(1)
    print('IDENTICAL')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
