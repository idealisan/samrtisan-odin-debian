# lk2nd 文件系统仿真台

在**宿主机**上跑 lk2nd 的 `lib/fs/ext2` 驱动，用来回答一个问题：

> lk2nd 能不能从这个镜像里读出这个文件？

## 为什么需要它

lk2nd 是引导器。直接改它意味着每次验证都要「编译 → 刷 boot 分区 → 重启」，
一来几分钟，二来改错就变砖（虽然能靠 fastboot 救回来）。

而 lk2nd 的 ext2 驱动对外只依赖 6 个函数（`bio_read` + 5 个 `bcache_*`）和
`dprintf`，依赖面小到可以整个搬到宿主机编译。于是迭代成本从「刷机 5 分钟」
变成「本地秒级」，还能做**回归测试**和**矩阵测试**。

## 用法

```sh
git submodule update --init ext/lk2nd     # 第一次需要

cd tools/lk2nd-fs-sim
./build.sh                    # 打上 lk2nd/0005 补丁后编译
./run-tests.sh                # 主矩阵：无 extents / 开 extents × 三种文件
./test-sparse.sh              # 稀疏文件（含空洞）

NOPATCH=1 ./build.sh          # 不打补丁，用来复现"改前"的失败（对照用）
DEBUGLEVEL=SPEW ./build.sh    # 打开驱动逐块 trace
```

也可以拿它直接看任意镜像：

```sh
./ext2sim <镜像> <镜像内路径> [期望大小]
```

## 文件构成

| 文件 | 作用 |
|---|---|
| `shim.h` / `shim.c` | lk 基础设施在宿主机上的最小实现；bcache 故意不做缓存（只关心正确性） |
| `debug.h` `err.h` `endian.h` `list.h` `lib/*.h` | 同名桩头文件，让 `#include <debug.h>` 之类命中 shim |
| `main.c` | 命令行入口：挂载 → 打开 → 读 → 打印大小、前几行、fnv1a 校验和 |
| `build.sh` | 复制驱动源码 → 应用补丁 → 编译 |
| `run-tests.sh` / `test-sparse.sh` | 测试矩阵 |

`ext/` 下的 lk2nd 源码**一个字都不用改** —— 靠 `-I` 把 shim 顶到搜索路径最前面。

## 当前测试覆盖

| 场景 | 无 extents | 开 extents |
|---|---|---|
| 小文件（167 B，extlinux.conf） | ✅ | ✅ |
| 大文件（30 MiB 连续，kernel） | ✅ | ✅ |
| 稀疏文件（64 MiB 含洞） | ✅ | ✅ |

三种文件在两种配置下读出的内容**fnv1a 校验和相同** —— 说明 extents 路径与
原来的间接块路径产出逐字节一致。稀疏文件的 extent 树 `depth=1`，索引层下钻
路径被真实走到 16000+ 次。

## 已知的坑

- 驱动里 `file_block_to_fs_block()` 原来 `uint32_t pos[4];` 不初始化就传参，
  `LTRACEF` 又去读 `pos[1..3]`。读未初始化栈是 UB：clang `-O1` 下会把 `level`
  一起弄成垃圾（本该 0，实测打印出 3），导致本来能读的文件读不出来。
  `-O0` 和 `-O1 + sanitizer` 都正常，所以这是个只在特定编译配置下才现形的 bug。
  补丁 0005 已修（初始化 + 检查返回值）。

- 解析 `/proc/device-tree/**/reg` 时别用 `od -tx8`：它在 ARM64 上按**小端**解释，
  会把 `0x0000000010000000` 显示成 `0000001000000000`。用 `-tx1` 逐字节看。
