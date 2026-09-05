# 036 — 让根分区用上完整 ext4：给 lk2nd 加只读 extents 支持

日期：2026-09-05
相关：`reports/035`（内存与 swap 两个问题的成因）

---

## 0. 背景与目标

`reports/035` 查清了两件事：可用内存只有 3.46 GiB，而 swap 一直是 0。
swap 建不起来的直接原因是**根分区的 ext4 关着 extents**：

```
swapfile 走 iomap，需要 extents
根分区 ext4 为了迁就 lk2nd，用 mke2fs -O ^extents 建的
⇒ swapon: Invalid argument（且内核不打任何日志）
```

关 extents 的理由是：lk2nd 要读根分区里的 `/extlinux/extlinux.conf`
（kernel / initramfs / dtb 也都在那），而它只有 ext2 驱动，不认识 extents。

所以目标是：**给 lk2nd 补上只读 extents 支持**，把根分区的特性枷锁摘掉，
进而用上基于文件的 swap。

---

## 1. 调研结论（决定了工作量与做法）

| # | 发现 | 影响 |
|---|---|---|
| 1 | `tools/build-image.sh` 的 `-O` **已经关掉了** `64bit / metadata_csum / huge_file / dir_nlink / extra_isize`，只差 `extents` 一个 | 不需要处理 64bit 带来的 group descriptor 布局变化、不需要校验和 —— 工作量比预想小很多 |
| 2 | lk2nd 的 ext2 驱动挂载时**只校验 `s_feature_ro_compat`**（白名单 `SPARSE_SUPER\|LARGE_FILE`），**完全不检查 `s_feature_incompat`** | 开 extents 不会在挂载时被拒，而是读文件时用间接块方式解析 extent 树，读出**错误块号**而不是报错 —— 比拒绝更难查。所以补丁必须补上 incompat 门禁 |
| 3 | lk2nd 会扫**所有 ≥16 MiB 的 leaf 分区**（label 含 "boot" 的不受此限），逐个 `fs_mount(..., "ext2", ...)` 找 extlinux.conf | 只要有任何一个大分区是"lk2nd 读不了"的文件系统，也只是跳过它；但我们只有一个大分区（根），所以它必须可读 |
| 4 | ext2 驱动对外只依赖 6 个函数（`bio_read` + 5 个 `bcache_*`）和 `dprintf` | 依赖面小到能整个搬到宿主机编译 —— 这才有 §3 的仿真台 |

---

## 2. 补丁 `lk2nd/0005`（3 文件，+194/−2）

### 2.1 `ext2_fs.h`：ext4 常量与结构体

数值逐条按内核 `fs/ext4/ext4.h`、`fs/ext4/ext4_extents.h` 核对：

- incompat 特性位：`EXTENTS=0x40`、`64BIT=0x80`、`MMP=0x100`、
  `FLEX_BG=0x200`、`INLINE_DATA=0x8000`、`ENCRYPT=0x10000`、`CASEFOLD=0x20000`
- inode 标志：`EXT4_HUGE_FILE_FL=0x40000`、`EXT4_EXTENTS_FL=0x80000`、
  `EXT4_INLINE_DATA_FL=0x10000000`
- `struct ext4_extent_header / ext4_extent / ext4_extent_idx`，`EXT4_EXT_MAGIC=0xf30a`
- 白名单 `EXT2_FEATURE_INCOMPAT_SUPP_RO_EXT4`：
  放行 `FILETYPE | META_BG | FLEX_BG | EXTENTS`，
  拒绝 `64BIT / INLINE_DATA / ENCRYPT / CASEFOLD / MMP`

### 2.2 `ext2.c`：补 incompat 门禁

原来完全不检查 `s_feature_incompat`。现在：

```c
if (ext2->sb.s_feature_incompat & ~EXT2_FEATURE_INCOMPAT_SUPP_RO_EXT4) {
        LTRACEF("unsupported incompat features 0x%x (allowed 0x%x)\n", ...);
        err = -5;
        return err;
}
```

**拒绝比静默读错好**：不检查的话，遇到不支持的特性会一路读到"错但看起来合理"
的块号，最终表现为"文件打不开"或"读到乱码"，根本想不到是文件系统特性不兼容。

### 2.3 `io.c`：extent 查找 + 顺手修一个 UB

新增 `ext2_extent_lookup()`，`file_block_to_fs_block()` 对带
`EXT4_EXTENTS_FL` 的 inode 分流：

- 按 `eh_depth` 逐层下钻。第一层嵌在 `inode->i_block`（60 字节）里，
  更深层各占一个物理块，最多 `EXT4_MAX_EXTENT_DEPTH`(5) 层
- 叶子命中返回 `phys + (fileblock - ee_block)`
- 未覆盖、或"未初始化"(`ee_len > 32768`) 都返回 0，由调用方按"读到全 0"处理
- 字节序：`i_block` 区域**没有**经过 `endian_swap_inode`（那里刻意跳过块指针），
  所以每个字段自己套 `LE16/LE32`；`i_flags` 经过了 `LE32SWAP`，是主机序，直接比较

顺带修的 UB（这是仿真台能稳定工作的前提，也是 lk2nd 自身的真 bug）：

```c
uint32_t pos[4];                                    /* 未初始化 */
uint32_t level = 0;
ext2_calculate_block_pointer_pos(ext2, fileblock, &level, pos);
LTRACEF("level %d, pos 0x%x 0x%x 0x%x 0x%x\n", level, pos[0], pos[1], pos[2], pos[3]);
```

`level==0` 时只填了 `pos[0]`，`LTRACEF` 却读 `pos[1..3]`。读未初始化栈是未定义
行为：**clang `-O1` 下会把 `level` 一起弄成垃圾**（本该 0，实测打印出 3），
导致原本能读的文件读不出来。`-O0` 和 `-O1 + sanitizer` 都正常 —— 只在特定编译
配置下现形的 bug。改为 `uint32_t pos[4] = { 0, 0, 0, 0 };`，并补上
`ext2_calculate_block_pointer_pos()` 返回值的检查（原来返回值被直接丢弃）。

---

## 3. 验证手段：宿主机仿真台 `tools/lk2nd-fs-sim`（新，已入库）

lk2nd 是引导器，直接改它意味着每次验证都要「编译 → 刷 boot 分区 → 重启」。
有了 §1 发现 4（依赖面只有 6 个函数），可以把它搬到宿主机：

```sh
cd tools/lk2nd-fs-sim
./build.sh                    # 复制驱动源码 → 打 lk2nd/0005 → 编译 ext2sim
./run-tests.sh                # 主矩阵
./test-sparse.sh              # 稀疏文件
NOPATCH=1 ./build.sh          # 不打补丁，复现"改前"的失败（对照）
DEBUGLEVEL=SPEW ./build.sh    # 打开驱动逐块 trace
```

要点：

- `ext/` 下的 lk2nd 源码**一个字都不用改**，靠 `-I` 让 `#include <debug.h>`
  之类命中 shim
- `build.sh` 先把补丁打进源码副本再编译 —— **测的就是真正会编进 lk2nd.img 的那份代码**
  （子模块平时是干净的，改动都在 `lk2nd/*.patch` 里）
- bcache 在 shim 里实现成"直接读、不缓存"：仿真台关心的是正确性，不是性能

### 3.1 结果

| 场景 | 无 extents（回归） | 开 extents（目标） |
|---|---|---|
| 小文件 167 B（extlinux.conf） | ✅ | ✅ |
| 大文件 30 MiB 连续（kernel） | ✅ | ✅ |
| 稀疏文件 64 MiB 含洞 | ✅ | ✅ |

三种文件在两种配置下读出的 **fnv1a 校验和完全相同** —— extents 路径与原来的
间接块路径产出逐字节一致。

稀疏文件的 extent 树实测 `depth=1`（8 个 extent，超过 inode 内可容纳的 4 个就长出
索引层），索引层下钻路径被真实走到 **16392 次**；大文件和小文件都是 `depth=0`。

对照：`NOPATCH=1 ./build.sh` 下开 extents 读不出来（复现原故障）。

> 附注：`NOPATCH=1` 时**无 extents 那组也会失败**，就是 §2.3 那个 UB 被 `-O1` 触发。
> 真机上 lk2nd 的编译没触发（否则现在根本引导不起来），但那是运气不是正确 —— 顺手修掉。

---

## 4. 配套改动

| 文件 | 改动 |
|---|---|
| `Makefile` | 0005 加进**第一组**补丁（0001 0002 0003 **0005**）。0005 改的是驱动，完整版和精简版都要，必须在编完整版之前打上；0004 是精简版专用（去掉 markw / rosy），等完整版编完再打做增量重编 |
| `tools/build-image.sh` | `extents` 由「关」改「开」；自检里 `extent` 从"禁止特性"清单拿出，改成**正向断言"extents 必须开启"**，其余 5 个仍必须关闭 |
| `odin-swap.sh` | 重写：swapfile 4 GiB（优先级 10）撑峰值 + zram 512 MiB（优先级 100）打底；`ODIN_ZRAM_SIZE=0` 可只要 swapfile |
| `odin-swap.service` | 从 `WantedBy=swap.target` 改 `WantedBy=multi-user.target` |
| `99-odin-swap.conf` | 更新注释（内容不变，仍是 `swappiness=80`） |

服务挂载点为什么改：建 4 GiB swapfile 依赖 resize2fs（历史上 dd 写出 231 MB 就
ENOSPC、留下半截文件），所以必须 `After` 一个属于 multi-user.target 的单元；
而挂在 multi-user.target 上、不再 `Before=sysinit.target`，就不会重演
`reports/035` §2.1 那个 systemd 依赖环（unit 被静默丢弃、journal 0 条记录）。

---

## 5. 开 extents 之后，根分区跟普通 ext4 还差什么

用设备上的 e2fsprogs **1.47.0** 实测（`/etc/mke2fs.conf` 的 `[fs_types] ext4`
是 `has_journal,extent,huge_file,flex_bg,metadata_csum,64bit,dir_nlink,extra_isize`，
`[defaults] base_features` 是
`sparse_super,large_file,filetype,resize_inode,dir_index,ext_attr`）：

```
默认 ext4:  has_journal ext_attr resize_inode dir_index filetype extent 64bit flex_bg
            sparse_super large_file huge_file dir_nlink extra_isize metadata_csum

我们的:     has_journal ext_attr resize_inode dir_index filetype extent flex_bg
            sparse_super large_file
```

### 5.1 还差 5 个特性

| 特性 | 为什么关 | 实际影响 |
|---|---|---|
| `64bit` | 开了 group descriptor 从 32 字节变 64 字节，lk2nd 按 32 字节读会错位 | **无**。上限 16 TiB（4K 块），根分区 112 GiB |
| `metadata_csum` | 它是 **ro_compat**，lk2nd 挂载白名单只允许 `sparse_super\|large_file`，会被拒 | **有**：元数据没有校验和，eMMC 位翻转导致的静默损坏检测不到 |
| `huge_file` | 允许 >2 TiB 的单个文件 | **无** |
| `dir_nlink` | 允许目录 link count >65000 | **无** |
| `extra_isize` | inode 里给扩展属性预留的空间 | **实测无**：都关了 `extra_isize`，但两边 `stat -c %w` 都能拿到文件创建时间 |

### 5.2 非特性层面

全部**一致**：blocksize 4096、inode_size 256、保留块 5%（Reserved blocks uid/gid
都是 root）、默认挂载选项 `user_xattr acl`、日志（has_journal，journal inode 8）。

唯一的人为差异是 inode 数量：我们按实际文件数 `-N`（留 20% + 2000 富余），
为的是 `resize2fs -M` 能把镜像缩下去（`tools/build-image.sh` 里有详细注释）。
扩容到 112 GiB 之后 resize2fs 会按默认比例补齐 inode 表 —— 实测根分区
`Inode count 2121728`，`df -i` 用了 **1%**，不紧张。

### 5.3 还想再摘的话（按性价比排）

1. **`metadata_csum`** —— 唯一有实际收益的。lk2nd 只读，不需要真的校验；
   只要在它的 ro_compat 白名单里加上 `metadata_csum`（以及确认它不影响
   只读路径的布局解析）即可。收益：能检测出元数据损坏。
2. `64bit`、`huge_file`、`dir_nlink`、`extra_isize` —— 收益基本为零，
   除非将来真的需要 >16 TiB 的分区或 >2 TiB 的文件。

---

## 6. 证据

- `tools/lk2nd-fs-sim/` —— 宿主机仿真台（代码 + 测试 + README）
- `lk2nd/0005-lib-fs-ext2-add-readonly-ext4-extent-support.patch`
- `evidence/mem-swap-audit-20260905.txt`、`evidence/swap-why-20260905.txt`
