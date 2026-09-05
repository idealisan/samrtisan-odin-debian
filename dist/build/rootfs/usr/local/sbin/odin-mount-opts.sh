#!/bin/sh
# 按文件系统类型给出 USB 外置存储的挂载选项。
#
# 输出：单行、纯选项字符串（如 noatime,uid=1000,gid=1000,fmask=0133,dmask=0022）
#       不含 KEY= 前缀 —— 由 odin-automount.sh 取用后传给 systemd-mount --options=
#
# 各文件系统能接受的选项（实测差异，写错会直接挂载失败）：
#   vfat   : uid= gid= fmask= dmask= utf8= iocharset=（iocharset 别给 utf8，见下）
#   msdos  : 同上但没有长文件名，utf8= 无意义
#   exfat  : uid= gid= fmask= dmask= iocharset=（默认已是 utf8，不用给）
#   ntfs3  : uid= gid= umask= iocharset=
#   ntfs   : 同上（走 mount.ntfs → ntfs-3g，FUSE）
#   ext4/btrfs/xfs/f2fs : 只有 POSIX 权限，给 uid= 会被拒绝 → 仅 noatime
#
# 历史教训（参见 WORKLOG 12:26）：systemd 252 的 systemd-mount **不读**
# SYSTEMD_MOUNT_OPTIONS 环境变量（实测挂出来是默认选项），必须用 --options= 传。
# 所以这里输出纯字符串，由调用方拼进 --options=。
#
# 关于中文文件名（FAT32 这条已修好，2026-09-06）：
#   FAT32 上 **不能用 iocharset=utf8** —— fs/fat/inode.c 会警告
#   "utf8 is not a recommended IO charset"，而且在 vfat 上仍要走
#   load_nls(iocharset)，缺 nls_utf8 就挂载失败（"IO charset utf8 not found"）。
#   正确的写法是 **utf8=1**：它把 opts->utf8 置 1，名字转换改走
#   utf16s_to_utf8s() / utf8s_to_utf16s()（fs/nls/nls_base.c，**只要 CONFIG_NLS=y
#   就编进去**，与 CONFIG_NLS_UTF8 无关），iocharset 仍用默认值 iso8859-1。
#   本镜像 CONFIG_NLS=y、CONFIG_NLS_ISO8859_1=y、CONFIG_NLS_CODEPAGE_437=y
#   且 CONFIG_FAT_DEFAULT_IOCHARSET="iso8859-1" ⇒ utf8=1 **不需要重编内核**，
#   load_nls("cp437") 与 load_nls("iso8859-1") 都能拿到。
#   副作用只有一个：大小写比较仍走 nls_strnicmp(nls_io=iso8859-1)，
#   即 **ASCII 仍不区分大小写、非 ASCII 不折叠** —— 对中文名无影响。
#   exFAT / NTFS3 走内核内建 UTF-16 转换，不依赖 nls_utf8，中文一直正常。

fstype="${1:-}"
uid="${ODIN_MOUNT_UID:-1000}"

case "$fstype" in
	vfat)
		echo "noatime,uid=$uid,gid=$uid,fmask=0133,dmask=0022,utf8=1"
		;;
	msdos)
		# msdos 没有长文件名，utf8 对它没意义，别给
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
