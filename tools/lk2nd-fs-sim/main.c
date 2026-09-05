// ext2sim —— 在宿主机上直接跑 lk2nd 的 ext2 驱动，用来验证
//            "lk2nd 能不能从这个镜像里读出某个文件"
//
//   用法： ext2sim <image> <path-in-image> [期望的文件大小]
//
// 退出码：
//   0  读出来了，且（给了期望大小时）大小对得上
//   1  挂载失败 / 打开失败 / 读失败 / 内容对不上
//   2  用法错误
//
// 打印内容：文件大小、前几行、以及整份内容的校验和 —— 校验和用来做
//           "改驱动前后读到的东西是否逐字节一致"的回归比对。
#include "shim.h"

/* ext2 驱动的内部接口（直接调驱动，不走 lk 的 fs 抽象层） */
typedef void fscookie;
typedef void filecookie;

status_t ext2_mount(bdev_t *dev, fscookie **cookie);
status_t ext2_open_file(fscookie *cookie, const char *path, filecookie **fcookie);
ssize_t ext2_read_file(filecookie *fcookie, void *buf, off_t offset, size_t len);
status_t ext2_stat_file(filecookie *fcookie, struct file_stat *stat);
status_t ext2_close_file(filecookie *fcookie);

/* 简单的 FNV-1a，够用来比对内容是否一致 */
static unsigned long fnv1a(const unsigned char *p, size_t n)
{
	unsigned long h = 1469598103934665603UL;
	for (size_t i = 0; i < n; i++) {
		h ^= p[i];
		h *= 1099511628211UL;
	}
	return h;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "用法: %s <image> <path-in-image> [期望大小]\n", argv[0]);
		return 2;
	}
	const char *img = argv[1];
	const char *path = argv[2];
	long want = (argc > 3) ? strtol(argv[3], NULL, 10) : -1;

	bdev_t *dev = shim_bdev_open(img);
	if (!dev)
		return 1;

	fscookie *cookie = NULL;
	status_t st = ext2_mount(dev, &cookie);
	if (st != NO_ERROR || !cookie) {
		printf("MOUNT: FAIL (status=%d)\n", st);
		shim_bdev_close(dev);
		return 1;
	}
	printf("MOUNT: OK\n");

	filecookie *fc = NULL;
	st = ext2_open_file(cookie, path, &fc);
	if (st != NO_ERROR || !fc) {
		printf("OPEN %s: FAIL (status=%d)\n", path, st);
		shim_bdev_close(dev);
		return 1;
	}

	struct file_stat fs;
	if (ext2_stat_file(fc, &fs) != NO_ERROR) {
		printf("STAT: FAIL\n");
		shim_bdev_close(dev);
		return 1;
	}
	printf("OPEN %s: OK  size=%lld is_dir=%d\n", path, (long long)fs.size, fs.is_dir);

	int rc = 0;
	if (want >= 0 && fs.size != (off_t)want) {
		printf("SIZE: MISMATCH got=%lld want=%ld\n", (long long)fs.size, want);
		rc = 1;
	} else if (want >= 0) {
		printf("SIZE: OK (%lld)\n", (long long)fs.size);
	}

	if (fs.size > 0) {
		size_t len = (size_t)fs.size;
		unsigned char *buf = malloc(len);
		if (!buf) {
			printf("READ: OOM\n");
			shim_bdev_close(dev);
			return 1;
		}
		ssize_t got = ext2_read_file(fc, buf, 0, len);
		if (got < 0 || (size_t)got != len) {
			printf("READ: FAIL got=%zd want=%zu\n", got, len);
			free(buf);
			shim_bdev_close(dev);
			return 1;
		}
		printf("READ: OK %zd bytes, fnv1a=%016lx\n", got, fnv1a(buf, len));

		/* 文本文件就打前几行，方便肉眼确认 */
		int printable = 1;
		size_t show = len > 200 ? 200 : len;
		for (size_t i = 0; i < show; i++) {
			unsigned char c = buf[i];
			if (c == '\n' || c == '\t' || (c >= 32 && c < 127))
				continue;
			printable = 0;
			break;
		}
		if (printable) {
			printf("CONTENT:\n");
			fwrite(buf, 1, show, stdout);
			if (len > show)
				printf("... (%zu bytes total)\n", len);
		}
		free(buf);
	}

	ext2_close_file(fc);
	shim_bdev_close(dev);
	return rc;
}
