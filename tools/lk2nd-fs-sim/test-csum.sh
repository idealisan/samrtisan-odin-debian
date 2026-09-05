#!/bin/bash
# metadata_csum 专项测试
#
# metadata_csum 是 **ro_compat** 特性。lk2nd 挂载时只校验 ro_compat（白名单 SPARSE_SUPER|LARGE_FILE）
# ⇒ 开了它会被拒。所以要做两件事：
#   1. 把 metadata_csum 加进 lk2nd 的 ro_compat 白名单（只读路径不需要真的校验）
#   2. 确认它不改变只读解析所需的布局 —— 重点怀疑：目录块尾部会多一个 12 字节的
#      fake dirent (ext4_dir_entry_tail: inode=0, rec_len=12, name_len=0, file_type=0xDE)
#
# 本脚本先在「改白名单之前」跑一遍，看失败形态；改完再跑一遍，看是否全过。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

STAGE=stage-csum
IMG_C=csum.img      # 带 metadata_csum
IMG_N=nocsum.img    # 不带（对照）
FEAT_C="resize_inode,extents,metadata_csum,^64bit,^huge_file,^dir_nlink,^extra_isize"
FEAT_N="resize_inode,extents,^64bit,^metadata_csum,^huge_file,^dir_nlink,^extra_isize"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 准备内容
say "准备测试内容"
rm -rf "$STAGE"; mkdir -p "$STAGE/extlinux" "$STAGE/boot"
cat > "$STAGE/extlinux/extlinux.conf" <<'CONF'
label l0
	kernel /boot/vmlinuz-test
	initramfs /boot/initramfs-test
	append console=ttyMSM0,115200n8 root=/dev/disk/by-label/pmOS_root rootwait rw
CONF
printf 'INITRAMFS-TEST-CONTENT\n' > "$STAGE/boot/initramfs-test"
python3 - <<'PY'
import struct
with open("stage-csum/boot/vmlinuz-test", "wb") as f:
    for i in range(20 * 1024 * 1024 // 8):
        f.write(struct.pack("<Q", i))
PY
nfiles=$(find "$STAGE" | wc -l)
ninodes=$(( nfiles * 12 / 10 + 2000 ))
echo "  -N $ninodes"

rm -f "$IMG_C" "$IMG_N"
mke2fs -q -F -t ext4 -L pmOS_root -O "$FEAT_C" -I 256 -b 4096 -N "$ninodes" -d "$STAGE" "$IMG_C" 128M
mke2fs -q -F -t ext4 -L pmOS_root -O "$FEAT_N" -I 256 -b 4096 -N "$ninodes" -d "$STAGE" "$IMG_N" 128M

# ------------------------------------------------- 用 python 读超级块（本机没有 dumpe2fs）
feat() {
	python3 - "$1" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
sb = d[1024:2048]
compat, incompat, ro = struct.unpack_from("<III", sb, 0x5C)
# 三组特性的位值会重复（compat 的 0x8=ext_attr、ro_compat 的 0x8=huge_file），所以必须分表查，不能合成一个 dict。
C = {0x4:'has_journal', 0x8:'ext_attr', 0x10:'resize_inode', 0x20:'dir_index'}
I = {0x2:'filetype', 0x10:'meta_bg', 0x40:'extents', 0x80:'64bit', 0x200:'flex_bg'}
R = {0x1:'sparse_super', 0x2:'large_file', 0x8:'huge_file', 0x20:'dir_nlink',
     0x40:'extra_isize', 0x400:'metadata_csum'}
def dec(v, t): return [n for b, n in sorted(t.items()) if v & b]
print(" ".join(dec(compat, C) + dec(incompat, I) + dec(ro, R)))
PY
}

say "两个镜像的特性"
printf '  带 csum   : %s\n' "$(feat "$IMG_C")"
printf '  不带 csum : %s\n' "$(feat "$IMG_N")"

# ---------------------------------------------------------------- 跑测试
say "ext2sim 读取"
for pair in "$IMG_C 带 metadata_csum" "$IMG_N 不带 metadata_csum（对照）"; do
	set -- $pair
	img=$1; label=$2
	printf '\n  --- %s ---\n' "$label"
	./ext2sim "$img" /extlinux/extlinux.conf 2>&1 | sed 's/^/    /'
done

say "汇总（下面两行都该是 ✅）"
printf '  不带 csum: %s\n' "$(./ext2sim "$IMG_N" /extlinux/extlinux.conf >/dev/null 2>&1 && echo ✅ || echo ❌)"
printf '  带 csum  : %s\n' "$(./ext2sim "$IMG_C" /extlinux/extlinux.conf >/dev/null 2>&1 && echo ✅ || echo ❌)"
