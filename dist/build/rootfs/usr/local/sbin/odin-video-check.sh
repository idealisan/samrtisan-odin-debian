#!/bin/bash
# odin-video-check.sh —— 体检 ODIN 的 venus 硬件视频编解码是否真的可用
#
#   sudo odin-video-check.sh            # 完整体检（含一次真实编解码）
#   sudo odin-video-check.sh --quick    # 只看固件/设备/格式，不跑编解码
#
# 判据：venus 是 V4L2 M2M 设备，不是 VA-API。可用 = firmware 在 +
# 出现 qcom-venus-decoder 与 qcom-venus-encoder 两个设备 + 能真的编出一帧、
# 再解回来。
# 只看 lsmod 有 venus_core 不算数 —— 它 probe 失败时模块照样在；
# 只看 /dev/video* 也不算数 —— 摄像头 msm_vfe* 占着 video0~video5。
set -u

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

VENUS_LIB=/usr/local/lib/odin/venus-devs.sh
if [ -r "$VENUS_LIB" ]; then
	# shellcheck source=/dev/null
	. "$VENUS_LIB"
else
	odin_venus_devs() { :; }
	odin_venus_dev() { return 1; }
	echo "  ❌ 缺 $VENUS_LIB，无法判定 venus 设备（镜像不完整？）"
fi

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
# /proc/modules 里是下划线（venus_core/venus_dec/venus_enc），模块文件是
# venus-core.ko —— kmod 把 - 与 _ 当同一个，所以两种写法都能 modprobe。
if grep -qE '^venus[-_]' /proc/modules 2>/dev/null; then
	pass "venus 模块已加载：$(grep -oE '^venus[-_][a-z]+' /proc/modules | tr '\n' ' ')"
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
# 按驱动写死在 sysfs 里的设备名认设备（qcom-venus-decoder / qcom-venus-encoder），
# 不靠"发现顺序"也不靠"有 /dev/video*"—— 本机摄像头 msm_vfe* 占着 video0~video5，
# 后两种判据都不成立。
DEC=$(odin_venus_dev dec)
ENC=$(odin_venus_dev enc)

# 把全部 video 设备列出来做上下文，venus 的那两个单独标注
for v in /dev/video*; do
	[ -e "$v" ] || continue
	n=$(cat "/sys/class/video4linux/${v#/dev/}/name" 2>/dev/null)
	case "$v" in
		"$DEC"|"$ENC") info "$v  name=$n   ← venus" ;;
		*)             info "$v  name=$n" ;;
	esac
done

if [ -n "$DEC" ]; then pass "解码器 $DEC"; else fail "没有 qcom-venus-decoder 设备"; fi
if [ -n "$ENC" ]; then pass "编码器 $ENC"; else fail "没有 qcom-venus-encoder 设备"; fi

# 两端格式都列：解码器吃压缩格式、吐原始帧；编码器反过来。
# 哪一侧是压缩格式取决于 v4l2-ctl 对 M2M 设备的映射，所以这里不猜，
# 两边都打出来并注明是哪条命令的结果。
for d in "$DEC" "$ENC"; do
	[ -n "$d" ] || continue
	info "$d --list-formats："
	v4l2-ctl -d "$d" --list-formats 2>/dev/null | sed 's/^/     /'
	info "$d --list-formats-out："
	v4l2-ctl -d "$d" --list-formats-out 2>/dev/null | sed 's/^/     /'
done

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
# 分辨率**不能随便挑**：venus 的编码器在若干档位上会让 ffmpeg 段错误，
# 1920x1080 一带必崩，640x360 也崩（但 640x480、1280x720、854x480、
# 1920x1440 都正常）。实测档位表见 reports/030 §4，改这里之前先去查表。
# 另外必须显式 -pix_fmt nv12：源不是 nv12 时 ffmpeg 不一定会自动转，
# 不转会直接报 "Encoder requires nv12 pixel format"（reports/030 §1.2）。
if ffmpeg -y -loglevel error -f lavfi -i testsrc2=size=640x480:rate=30:duration=2 \
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
