// shim.h —— 把 lk2nd ext2 驱动跑到宿主机上所需的最小环境
//
// 目的：lk2nd 的 lib/fs/ext2 只依赖 6 个外部函数（bio_read + 5 个 bcache_*）
// 加上 dprintf/LTRACEF，依赖面小到可以整个搬到宿主机编译。
// 于是"改 lk2nd 引导器"这件事，迭代成本从「刷机 5 分钟 + 变砖风险」
// 变成「本地秒级」，还能做回归测试（保证不破坏现状）。
//
// 这里刻意**不改** ext/ 下 lk2nd 的任何源文件，只提供同名头文件，
// 编译时用 -I 指到本目录即可。
#ifndef LK_SHIM_H
#define LK_SHIM_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

/* ---------------------------------------------------------------- err.h */
/* 错误码照抄 ext/lk2nd/include/err.h，不自己编号 —— 数值不一致会误导调试 */
typedef int status_t;
#define NO_ERROR 0
#define ERR_NOT_FOUND -2
#define ERR_NOT_READY -3
#define ERR_NO_MSG -4
#define ERR_NO_MEMORY -5
#define ERR_ALREADY_STARTED -6
#define ERR_NOT_VALID -7
#define ERR_INVALID_ARGS -8
#define ERR_NOT_ENOUGH_BUFFER -9
#define ERR_NOT_SUSPENDED -10
#define ERR_OBJECT_DESTROYED -11
#define ERR_NOT_BLOCKED -12
#define ERR_TIMED_OUT -13
#define ERR_ALREADY_EXISTS -14
#define ERR_CHANNEL_CLOSED -15
#define ERR_OFFLINE -16
#define ERR_NOT_ALLOWED -17
#define ERR_BAD_PATH -18
#define ERR_ALREADY_MOUNTED -19
#define ERR_IO -20
#define ERR_NOT_DIR -21
#define ERR_NOT_FILE -22
#define ERR_RECURSE_TOO_DEEP -23
#define ERR_NOT_SUPPORTED -24
#define ERR_TOO_BIG -25

/* --------------------------------------------------------------- endian.h */
/* 宿主机（x86 / ARM64）与 ext4 磁盘格式同为小端，所以这些转换是恒等的。
   宏名与 lk 保持一致，避免改驱动源码。 */
#define LE64(val) (val)
#define LE32(val) (val)
#define LE16(val) (val)
#define LE64SWAP(var) (var) = LE64(var);
#define LE32SWAP(var) (var) = LE32(var);
#define LE16SWAP(var) (var) = LE16(var);

/* --------------------------------------------------------------- stdlib.h */
#define ROUNDUP(a, b) (((a) + ((b)-1)) & ~((b)-1))

/* ------------------------------------------------------------- debug.h */
/* dprintf 在 POSIX 里也是个函数，所以先重命名再包一层，避免和 stdio 撞 */
void lk_dprintf(int level, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

#define dprintf lk_dprintf

#define CRITICAL 0
#define ALWAYS   0
#define INFO     1
#define SPEW     2
#ifndef DEBUGLEVEL
#define DEBUGLEVEL INFO
#endif

#define LTRACEF(fmt, ...) lk_dprintf(SPEW, "LTRACE %s:%d: " fmt, __FILE__, __LINE__, ##__VA_ARGS__)
#define TRACEF(...)       LTRACEF(__VA_ARGS__)
#define TRACE             LTRACEF("\n")

/* --------------------------------------------------------------- bio.h */
typedef uint32_t bnum_t;
typedef struct bdev {
	const char *name;
	off_t size;
	/* 宿主机侧：就是一个打开的镜像 fd */
	int fd;
} bdev_t;

struct list_node {
	struct list_node *prev, *next;
};

struct bdev_struct {
	struct list_node list;
};

ssize_t bio_read(bdev_t *dev, void *buf, off_t offset, size_t len);
ssize_t bio_write(bdev_t *dev, const void *buf, off_t offset, size_t len);

/* ------------------------------------------------------------ bcache.h */
typedef void *bcache_t;

bcache_t bcache_create(bdev_t *dev, size_t block_size, int block_count);
void bcache_destroy(bcache_t);
int bcache_read_block(bcache_t, void *, uint block);
int bcache_get_block(bcache_t, void **, uint block);
int bcache_put_block(bcache_t, uint block);

/* --------------------------------------------------------------- fs.h */
#define FS_MAX_FILE_LEN 128

typedef void fscookie;
typedef void filecookie;
typedef void dircookie;

struct file_stat {
	bool is_dir;
	off_t size;
};

struct dirent {
	char name[FS_MAX_FILE_LEN];
};

typedef struct filehandle filehandle;
typedef struct dirhandle dirhandle;

/* 驱动注册用（ext2.c 底部有 static const struct fs_api ext2_api）。
   仿真台不走 lk 的 fs 抽象层，所以只要结构对得上、注册函数是个空壳即可。 */
struct fs_api {
	status_t (*mount)(struct bdev *, fscookie **);
	status_t (*unmount)(fscookie *);
	status_t (*open)(fscookie *, const char *, filecookie **);
	status_t (*create)(fscookie *, const char *, filecookie **, uint64_t);
	status_t (*stat)(filecookie *, struct file_stat *);
	ssize_t (*read)(filecookie *, void *, off_t, size_t);
	ssize_t (*write)(filecookie *, const void *, off_t, size_t);
	status_t (*close)(filecookie *);

	status_t (*mkdir)(fscookie *, const char *);
	status_t (*opendir)(fscookie *, const char *, dircookie **);
	status_t (*readdir)(dircookie *, struct dirent *);
	status_t (*closedir)(dircookie *);
};

status_t fs_register_type(const char *name, const struct fs_api *api);

/* --------------------------------------------------------------- stdlib.h */
#define MIN(a, b) (((a) < (b)) ? (a) : (b))
#define MAX(a, b) (((a) > (b)) ? (a) : (b))

/* ------------------------------------------------------------------ arch */
typedef uintptr_t addr_t;
#ifndef CACHE_LINE
#define CACHE_LINE 64
#endif

/* ------------------------------------------------- 宿主机侧的辅助接口 */
/* 打开一个镜像文件，返回一个假的 bdev */
bdev_t *shim_bdev_open(const char *path);
void shim_bdev_close(bdev_t *dev);

#endif
