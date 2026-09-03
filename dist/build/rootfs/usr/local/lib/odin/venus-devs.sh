# venus-devs.sh —— venus 视频设备的**唯一**判据（供 odin-venus-fw.sh 与
#                    odin-video-check.sh 共同 source）
#
# ⚠️ 不要用 `ls /dev/video*`、`compgen -G '/dev/video*'` 之类"有设备就算成功"
#    的判据。本机摄像头（CAMSS / msm_vfe）已经占了 video0~video5：
#      evidence/device-probe/05-hardware-full.txt:149-154
#        video0 msm_vfe0_video0 ... video5 msm_vfe1_video2
#    所以这类判据**恒为真** —— venus 完全没起来也会判定成功。这正是
#    odin-venus-fw.sh 的模块重载分支一直是死代码、日志还谎报"venus 已就绪"
#    的原因（2026-09-03 修正）。
#
# 正确判据是驱动写死在 sysfs 里的设备名，主线源码实锤：
#   drivers/media/platform/qcom/venus/vdec.c  strscpy(vdev->name, "qcom-venus-decoder", ...)
#   drivers/media/platform/qcom/venus/venc.c  strscpy(vdev->name, "qcom-venus-encoder", ...)
# 摄像头设备的 name 是 msm_vfe*_video*，与上面两个不会撞。
#
# 用法：
#   . /usr/local/lib/odin/venus-devs.sh
#   odin_venus_devs                       # 列出 "<dec|enc> /dev/videoX"
#   odin_venus_dev | grep -c .            # 有几个 venus 设备（0 = 没起来）
#   odin_venus_dev dec                    # 解码器设备路径（没有则空）
#   odin_venus_dev enc                    # 编码器设备路径

# 打印 "<dec|enc> /dev/videoX"，一行一个；没有 venus 设备时无输出
odin_venus_devs() {
	for d in /sys/class/video4linux/*; do
		[ -r "$d/name" ] || continue
		case "$(cat "$d/name" 2>/dev/null)" in
			qcom-venus-decoder) echo "dec /dev/${d##*/}" ;;
			qcom-venus-encoder) echo "enc /dev/${d##*/}" ;;
		esac
	done
}

# 取指定角色的设备路径：odin_venus_dev dec|enc（没有则无输出、返回 1）
odin_venus_dev() {
	want=${1:-}
	[ -n "$want" ] || return 1
	node=$(odin_venus_devs | awk -v w="$want" '$1==w{print $2; exit}')
	[ -n "$node" ] || return 1
	echo "$node"
}
