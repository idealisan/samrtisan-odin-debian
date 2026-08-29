#!/bin/sh
# 按文件系统类型给出 USB 外置存储的挂载选项。
#
# 输出：单行、纯选项字符串（如 noatime,uid=1000,gid=1000,fmask=0133,dmask=0022）
#       不含 KEY= 前缀 —— 由 odin-automount.sh 取用后传给 systemd-mount --options=
#
# 各文件系统能接受的选项（实测差异，写错会直接挂载失败）：
#   vfat   : uid= gid= fmask= dmask= iocharset=
#   exfat  : uid= gid= fmask= dmask=         ← **不支持 iocharset**，给了会报错
#   ntfs3  : uid= gid= umask= iocharset=
#   ntfs   : 同上（走 mount.ntfs → ntfs-3g，FUSE）
#   ext4/btrfs/xfs/f2fs : 只有 POSIX 权限，给 uid= 会被拒绝 → 仅 noatime
#
# 历史教训（参见 WORKLOG 12:26）：systemd 252 的 systemd-mount **不读**
# SYSTEMD_MOUNT_OPTIONS 环境变量（实测挂出来是默认选项），必须用 --options= 传。
# 所以这里输出纯字符串，由调用方拼进 --options=。
#
# 关于 iocharset：本镜像内核 CONFIG_NLS_UTF8 未编译（用户决策：不为 FAT32
# 中文重编内核模块），vfat 默认按 iso8859-1 解释文件名 ⇒ 中文名会乱码。
# exFAT / NTFS3 走内核内建 UTF-16 转换（fs/exfat/super.c:691-697 不调用
# load_nls），不依赖 nls_utf8，中文正常。需要中文名的盘请用这两种格式。

fstype="${1:-}"
uid="${ODIN_MOUNT_UID:-1000}"

case "$fstype" in
	vfat|msdos)
		echo "noatime,uid=$uid,gid=$uid,fmask=0133,dmask=0022"
		;;
	exfat)
		echo "noatime,uid=$uid,gid=$uid,fmask=0133,dmask=0022"
		;;
	ntfs3|ntfs)
		echo "noatime,uid=$uid,gid=$uid,umask=0022"
		;;
	*)
		# POSIX 文件系统：根目录属主是格式化时的用户（多为 root），
		# 需要写入请 sudo chown 一次（会写进文件系统本身，持久生效）
		echo "noatime"
		;;
esac
exit 0
