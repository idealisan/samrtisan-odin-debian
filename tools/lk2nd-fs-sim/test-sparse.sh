#!/bin/bash
# 稀疏 / 碎片场景测试
#
# 稀疏文件：64 MiB 里每隔 8 MiB 写 1 MiB，其余是"洞"。验证两件事：
#   ① 空洞读到的是 0 而不是脏数据（extent 未覆盖 / 间接块为 0 都要返回 0）
#   ② 文件被切成多段时 extent 数量增多；inode 内只能放 (60-12)/12 = 4 个 extent，
#      超过就会长出索引层（eh_depth > 0），能逼出 extent 树的下钻路径
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

STAGE=stage-sparse
IMG_A=sparse-noext.img
IMG_B=sparse-ext.img
FEAT_A="resize_inode,^extents,^64bit,^metadata_csum,^huge_file,^dir_nlink,^extra_isize"
FEAT_B="resize_inode,extents,^64bit,^metadata_csum,^huge_file,^dir_nlink,^extra_isize"

echo "=== 造稀疏文件 ==="
rm -rf "$STAGE"; mkdir -p "$STAGE/boot"
python3 - <<'EOF'
f = open("stage-sparse/boot/sparse.bin", "wb")
f.truncate(64 * 1024 * 1024)
for base in range(0, 64, 8):
    f.seek(base * 1024 * 1024)
    f.write(bytes([base]) * (1024 * 1024))
f.close()
EOF
ls -la "$STAGE/boot/" | sed 's/^/  /'
echo "  逻辑 64 MiB，实际占用 $(du -h "$STAGE/boot/sparse.bin" | cut -f1)"

nfiles=$(find "$STAGE" | wc -l)
ninodes=$(( nfiles * 12 / 10 + 2000 ))

echo
echo "=== 建镜像 ==="
rm -f "$IMG_A" "$IMG_B"
mke2fs -q -F -t ext4 -L pmOS_root -O "$FEAT_A" -I 256 -b 4096 -N "$ninodes" -d "$STAGE" "$IMG_A" 160M
mke2fs -q -F -t ext4 -L pmOS_root -O "$FEAT_B" -I 256 -b 4096 -N "$ninodes" -d "$STAGE" "$IMG_B" 160M
ls -la "$IMG_A" "$IMG_B" | sed 's/^/  /'

echo
echo "=== 读出来跟原文件比 ==="
check() {   # check <镜像> <标签>
	local img=$1 tag=$2
	printf '  --- %s ---\n' "$tag"
	./ext2sim "$img" /boot/sparse.bin 2>&1 | grep -E "MOUNT|OPEN|READ: OK" | sed 's/^/    /'
	local rc=${PIPESTATUS[0]}
	[ "$rc" != 0 ] && { echo "    ✗ 退出码 $rc"; return 1; }

	# 内容比对：ext2sim 的 READ 行带 fnv1a，跟原文件复算的结果比
	python3 - "$img" <<'EOF'
import sys, subprocess
img = sys.argv[1]
r = subprocess.run(["./ext2sim", img, "/boot/sparse.bin"], capture_output=True, text=True)
line = [l for l in r.stdout.splitlines() if l.startswith("READ: OK")]
if not line:
    print("    没有 READ 行"); sys.exit(1)
def fnv1a(p):
    h = 1469598103934665603
    for b in p:
        h ^= b
        h = (h * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return h
got = line[0].split("fnv1a=")[1].strip()
want = f"{fnv1a(open('stage-sparse/boot/sparse.bin','rb').read()):016x}"
if got == want:
    print("    ✅ 内容逐字节一致（含空洞读成 0）")
    sys.exit(0)
print(f"    ❌ 内容不一致 got={got} want={want}")
sys.exit(1)
EOF
}

check "$IMG_A" "A 无 extents"; A=$?
check "$IMG_B" "B 开 extents"; B=$?

echo
echo "=== 看 B 组有没有走到 extent 索引层（depth>0）==="
if [ -x ./ext2sim-dbg ]; then
	./ext2sim-dbg "$IMG_B" /boot/sparse.bin 2>&1 | grep -cE "\(extent\)" | sed 's/^/  走 extent 路径的块翻译次数: /'
else
	echo "  （没有 ext2sim-dbg，跳过）"
fi

echo
echo "=== 汇总 ==="
[ "$A" = 0 ] && echo "  A（无 extents）：✅" || echo "  A（无 extents）：❌"
[ "$B" = 0 ] && echo "  B（开 extents）：✅" || echo "  B（开 extents）：❌"
exit 0
