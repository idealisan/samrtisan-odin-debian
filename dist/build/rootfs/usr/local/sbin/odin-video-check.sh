#!/bin/bash
# odin-video-check.sh —— 体检 ODIN 的 venus 硬件视频编解码是否真的可用
#
#   sudo odin-video-check.sh            # 完整体检（含一次真实编解码）
#   sudo odin-video-check.sh --quick    # 只看固件/设备/格式，不跑编解码
#
# 判据：venus 是 V4L2 M2M 设备，不是 VA-API。可用 = firmware 在 + /dev/videoX
# 里有 venus 的 decoder/encoder + 能真的编出一帧、再解回来。
# 只看 lsmod 有 venus_core 不算数 —— 它 probe 失败时模块照样在。
set -u

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

ok=0; bad=0
pass() { echo "  ✅ $*"; ok=$((ok + 1)); }
fail() { echo "  ❌ $*"; bad=$((bad + 1)); }
info() { echo "  · $*"; }
head2() { echo; echo "=== $* ==="; }

echo "ODIN venus 硬件编解码体检 $(date -Is)"

# ---------------------------------------------------------------- 1. 固件
head2 "1. venus 固件（/lib/firmware）"
if [ -s /lib/firmware/venus.mdt ]; then
	pass "venus.mdt 在位（$(stat -c%s /lib/firmware/venus.mdt) 字节）"
	ls -1 /lib/firmware/venus.mdt /lib/firmware/venus.b* 2>/dev/null | sed 's/^/     /'
else
	fail "缺 /lib/firmware/venus.mdt —— 跑 sudo /usr/local/sbin/odin-venus-fw.sh 从原厂 modem 分区取"
fi

# ---------------------------------------------------------------- 2. 内核
head2 "2. 内核驱动"
if grep -q "venus" /proc/modules 2>/dev/null; then
	pass "venus 模块已加载：$(grep -o '^venus_[a-z]*' /proc/modules | tr '\n' ' ')"
else
	fail "venus 模块未加载"
fi
if dmesg 2>/dev/null | grep -q "venus.*probe with driver"; then
	fail "venus probe 失败过：$(dmesg | grep 'venus.*probe with driver' | tail -1)"
else
	pass "dmesg 里没有 venus probe 失败记录"
fi

# ---------------------------------------------------------------- 3. v4l2 设备
head2 "3. V4L2 M2M 设备"
DEC=""; ENC=""
# 靠"它到底支持哪些压缩格式"来认设备，比认名字可靠：
# venus 的 decoder / encoder 各占一个 /dev/videoX，名字随内核版本变过。
for v in /dev/video*; do
	[ -e "$v" ] || continue
	info "$v  name=$(cat /sys/class/video4linux/${v#/dev/}/name 2>/dev/null)"
	fmts=$(v4l2-ctl -d "$v" --list-formats 2>/dev/null | tr '\n' ' ')
	case "$fmts" in
		*H264*|*HEVC*|*VP8*|*VP9*|*MPEG4*)
			if [ -z "$DEC" ]; then DEC="$v"; else ENC="$v"; fi ;;
	esac
done
if [ -n "$DEC" ]; then
	pass "找到编解码设备：dec=$DEC enc=${ENC:-（未识别，可能同一个）}"
else
	fail "没有任何 /dev/video* 支持压缩格式 —— venus 没起来"
fi
[ -n "$DEC" ] && v4l2-ctl -d "$DEC" --list-formats 2>/dev/null | sed 's/^/     /'

[ "$QUICK" = 1 ] && {
	echo
	echo "结论：通过 $ok 项，失败 $bad 项（--quick 模式，未跑编解码）"
	exit $((bad > 0))
}

# ---------------------------------------------------------------- 4. 真实编解码
command -v ffmpeg >/dev/null || { echo; fail "没有 ffmpeg"; exit 1; }
W=/tmp/odin-video-check
mkdir -p "$W"

head2 "4. 硬件编码（h264_v4l2m2m）"
if ffmpeg -y -loglevel error -f lavfi -i testsrc2=size=640x360:rate=30:duration=2 \
	-pix_fmt nv12 -c:v h264_v4l2m2m -b:v 2M "$W/enc.h264" 2>"$W/enc.err"; then
	pass "编码成功：$(stat -c%s "$W/enc.h264") 字节"
else
	fail "编码失败"; sed 's/^/     /' "$W/enc.err" | head -10
fi

head2 "5. 硬件解码（h264_v4l2m2m）"
if [ -s "$W/enc.h264" ]; then
	if ffmpeg -y -loglevel error -c:v h264_v4l2m2m -i "$W/enc.h264" \
		-f rawvideo -pix_fmt nv12 "$W/dec.raw" 2>"$W/dec.err"; then
		pass "解码成功：$(stat -c%s "$W/dec.raw") 字节原始帧"
	else
		fail "解码失败"; sed 's/^/     /' "$W/dec.err" | head -10
	fi
else
	info "跳过（上一步没有产物）"
fi

echo
echo "结论：通过 $ok 项，失败 $bad 项"
echo "（临时文件在 $W，可自行清理）"
exit $((bad > 0))
