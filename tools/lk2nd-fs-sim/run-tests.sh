#!/bin/bash
# 在宿主机上跑 lk2nd ext2 驱动的回归矩阵。
#
# 两组文件系统配置：
#   A = 当前 tools/build-image.sh 用的（无 extents）—— 必须**一直**能读（回归基线）
#   B = 我们想要的（开 extents）—— 改驱动前应当失败/读错，改驱动后应当能读对
#
# 每种配置读两个文件：
#   小文件 /extlinux/extlinux.conf   （几百字节，ext4 下可能 inline 或单个 extent）
#   大文件 /boot/vmlinuz-test        （30 MiB，必然跨多个 extent，能逼出 extent tree）
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

STAGE=stage
IMG_A=noext.img
IMG_B=ext.img

# 当前 tools/build-image.sh 的特性集；B 只把 ^extents 换成 extents
FEAT_A="resize_inode,^extents,^64bit,^metadata_csum,^huge_file,^dir_nlink,^extra_isize"
FEAT_B="resize_inode,extents,^64bit,^metadata_csum,^huge_file,^dir_nlink,^extra_isize"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 准备内容
say "准备测试内容"
rm -rf "$STAGE"; mkdir -p "$STAGE/extlinux" "$STAGE/boot"
cat > "$STAGE/extlinux/extlinux.conf" <<'CONF'
label l0
	kernel /boot/vmlinuz-test
	initramfs /boot/initramfs-test
	dtb /boot/dtb-test
	append console=ttyMSM0,115200n8 root=/dev/disk/by-label/pmOS_root rootwait rw
CONF
printf 'INITRAMFS-TEST-CONTENT\n' > "$STAGE/boot/initramfs-test"
printf 'DTB-TEST-CONTENT\n' > "$STAGE/boot/dtb-test"
# 30 MiB、内容随位置变化 —— 用常量填充的话，读错位也看不出来
python3 - <<PY
import struct
with open("$STAGE/boot/vmlinuz-test","wb") as f:
    for i in range(30*1024*1024 // 8):
        f.write(struct.pack("<Q", i))
PY
ls -la "$STAGE/boot/" | sed 's/^/  /'
echo "  vmlinuz md5 = $(md5 -q "$STAGE/boot/vmlinuz-test")"

# ---------------------------------------------------------------- 建镜像
nfiles=$(find "$STAGE" | wc -l)
ninodes=$(( nfiles * 12 / 10 + 2000 ))
echo "  inode 数: -N $ninodes"

say "建镜像 A（无 extents，当前配置）"
rm -f "$IMG_A"
mke2fs -q -F -t ext4 -L pmOS_root -O "$FEAT_A" -I 256 -b 4096 -N "$ninodes" \
	-d "$STAGE" "$IMG_A" 128M 2>&1 | sed 's/^/  /'
echo "  $(ls -la $IMG_A | awk '{print $5}') 字节"

say "建镜像 B（开 extents，目标配置）"
rm -f "$IMG_B"
mke2fs -q -F -t ext4 -L pmOS_root -O "$FEAT_B" -I 256 -b 4096 -N "$ninodes" \
	-d "$STAGE" "$IMG_B" 128M 2>&1 | sed 's/^/  /'
echo "  $(ls -la $IMG_B | awk '{print $5}') 字节"

# ---------------------------------------------------------------- 跑测试
run_case() {   # run_case <镜像> <配置名>
	local img=$1 name=$2
	say "$name :: $img"

	local rc_all=0
	for f in /extlinux/extlinux.conf /boot/initramfs-test /boot/vmlinuz-test; do
		printf '  --- %s ---\n' "$f"
		./ext2sim "$img" "$f" 2>&1 | sed 's/^/    /'
		local rc=${PIPESTATUS[0]}
		[ "$rc" != 0 ] && { echo "    ✗ 退出码 $rc"; rc_all=1; }
	done
	return $rc_all
}

run_case "$IMG_A" "A 无 extents（回归基线：必须全过）"; A=$?
run_case "$IMG_B" "B 开 extents（目标）"; B=$?

# ---------------------------------------------------------------- 内容比对
say "内容比对（把镜像里的文件 dump 出来跟原文件比）"
dump_and_cmp() {  # dump_and_cmp <镜像> <路径> <本地原文件>
	local img=$1 path=$2 orig=$3
	local out="$HERE/.dump.tmp"
	./ext2sim "$img" "$path" > /dev/null 2>&1 || { echo "  $path: 读失败"; return 1; }
	# ext2sim 只打印前 200 字节，这里用 debugfs 不可得，改用 python 直接比大小+前部
	python3 - "$img" "$path" "$orig" <<'PY'
import sys, hashlib, subprocess
img, path, orig = sys.argv[1], sys.argv[2], sys.argv[3]
r = subprocess.run(["./ext2sim", img, path], capture_output=True, text=True)
line = [l for l in r.stdout.splitlines() if l.startswith("READ: OK")]
if not line:
    print(f"  {path}: 没读到内容")
    sys.exit(1)
# 校验和来自 READ 行；原文件算同一算法对比
want = open(orig, "rb").read()
# 用 ext2sim 的 fnv1a 口径复算（与 main.c 一致）
def fnv1a(p):
    h = 1469598103934665603
    for b in p:
        h ^= b
        h = (h * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return h
got_hex = line[0].split("fnv1a=")[1].strip()
if f"{fnv1a(want):016x}" == got_hex:
    print(f"  {path}: ✅ 内容一致 ({len(want)} 字节)")
    sys.exit(0)
else:
    print(f"  {path}: ❌ 内容不一致")
    sys.exit(1)
PY
}

for pair in "$IMG_A A" "$IMG_B B"; do
	set -- $pair
	echo "--- $2 ---"
	dump_and_cmp "$1" /extlinux/extlinux.conf "$STAGE/extlinux/extlinux.conf" || true
	dump_and_cmp "$1" /boot/vmlinuz-test "$STAGE/boot/vmlinuz-test" || true
done

say "汇总"
[ "$A" = 0 ] && echo "  A（无 extents）：✅ 全过" || echo "  A（无 extents）：❌ 有失败（回归破了吗？）"
[ "$B" = 0 ] && echo "  B（开 extents）：✅ 全过" || echo "  B（开 extents）：❌ 有失败"
exit 0
