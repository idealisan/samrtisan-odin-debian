// shim.c —— lk 基础设施在宿主机上的最小实现
//
// bcache 这里刻意实现成「直接读、不缓存」：仿真台关心的是**正确性**
// （能不能把文件读对），不是性能。少了缓存逻辑也少一处可能出错的地方。
#include "shim.h"

#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <errno.h>

void lk_dprintf(int level, const char *fmt, ...)
{
	if (level > DEBUGLEVEL)
		return;
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

bdev_t *shim_bdev_open(const char *path)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0) {
		perror(path);
		return NULL;
	}
	bdev_t *dev = calloc(1, sizeof(*dev));
	dev->name = path;
	dev->fd = fd;
	dev->size = lseek(fd, 0, SEEK_END);
	if (dev->size < 0)
		dev->size = 0;
	return dev;
}

void shim_bdev_close(bdev_t *dev)
{
	if (!dev)
		return;
	if (dev->fd >= 0)
		close(dev->fd);
	free(dev);
}

ssize_t bio_read(bdev_t *dev, void *buf, off_t offset, size_t len)
{
	if (!dev || dev->fd < 0)
		return -1;
	ssize_t ret = pread(dev->fd, buf, len, offset);
	if (ret < 0)
		return -1;
	return ret;
}

ssize_t bio_write(bdev_t *dev, const void *buf, off_t offset, size_t len)
{
	/* 仿真台只读，写一律拒绝 —— 引导器本来就只需要读 */
	(void)dev; (void)buf; (void)offset; (void)len;
	return -1;
}

/* ------------------------------------------------------------------ bcache */

typedef struct {
	bdev_t *dev;
	size_t block_size;
	int block_count;
	int refs;   /* get/put 配对用，仿真台不真做 LRU */
} shim_cache_t;

bcache_t bcache_create(bdev_t *dev, size_t block_size, int block_count)
{
	shim_cache_t *c = calloc(1, sizeof(*c));
	if (!c)
		return NULL;
	c->dev = dev;
	c->block_size = block_size ? block_size : 4096;
	c->block_count = block_count;
	return (bcache_t)c;
}

void bcache_destroy(bcache_t cache)
{
	free(cache);
}

int bcache_read_block(bcache_t cache, void *buf, uint block)
{
	shim_cache_t *c = (shim_cache_t *)cache;
	if (!c)
		return -1;
	off_t off = (off_t)block * c->block_size;
	ssize_t ret = bio_read(c->dev, buf, off, c->block_size);
	if (ret < 0 || (size_t)ret != c->block_size)
		return -1;
	return 0;
}

int bcache_get_block(bcache_t cache, void **ptr, uint block)
{
	shim_cache_t *c = (shim_cache_t *)cache;
	if (!c || !ptr)
		return -1;
	void *buf = malloc(c->block_size);
	if (!buf)
		return -1;
	if (bcache_read_block(cache, buf, block) < 0) {
		free(buf);
		return -1;
	}
	c->refs++;
	*ptr = buf;
	return 0;
}

int bcache_put_block(bcache_t cache, uint block)
{
	shim_cache_t *c = (shim_cache_t *)cache;
	(void)block;
	if (!c)
		return -1;
	if (c->refs > 0)
		c->refs--;
	return 0;
}

/* fs_register_type: 仿真台不需要 lk 的 fs 注册表 */
status_t fs_register_type(const char *name, const struct fs_api *api)
{
	(void)name; (void)api;
	return NO_ERROR;
}
