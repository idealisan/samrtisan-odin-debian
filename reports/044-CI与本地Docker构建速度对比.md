# 044 — CI 与本地 Docker 构建的速度对比（2026-09-06 实测）

目的：以后要改内核/设备树/根文件系统时，知道该等 CI 还是本机编。

---

## 一、结论先行

| 阶段 | CI（GitHub-hosted） | 本地（Docker / OrbStack） | 快几倍 |
|---|---|---|---|
| lk2nd | 44 s | **8 s** | 5.5× |
| dtb | 198 s | **57 s** | 3.5× |
| kernel（ccache 冷） | 2149 s（35 分 49 秒） | **778 s**（12 分 58 秒） | 2.8× |
| kernel（ccache 温） | — | **350 s**（5 分 50 秒） | 6.1× |
| rootfs-core | 400 s | **149 s**（2 分 29 秒） | 2.7× |
| **合计（到 core 镜像可用）** | **≈2791 s ≈ 46 分** | **≈992 s ≈ 16.5 分** | **2.8×** |

**建议**：
- **改内核配置 / 设备树 / 补丁 → 本机编**。16 分钟出镜像，比等 CI（46 分钟）快近 3 倍，
  而且改完立刻能重编。
- **正式发布 → 必须走 CI**。项目规则：交付物只认 CI 产物，本机产物只用于验证与提速。
- **只改用户态脚本（dist/、flash/）→ 本机编 rootfs 即可**（2.5 分钟）。

---

## 二、两边环境

| | CI | 本地 |
|---|---|---|
| 机器 | GitHub-hosted runner（标准 4 vCPU） | MacBook（Apple Silicon） |
| 架构 | **x86_64**，交叉编译 `aarch64-linux-gnu-` | **原生 aarch64**（OrbStack 跑 ARM64 容器，`uname -m` = aarch64） |
| 核数 | 4 | **8**（`nproc` = 8） |
| 内存 | 16 GB | 8 GB |
| 根文件系统 chroot | **qemu-user-static**（arm64 根跑在 x86_64 上） | **原生**，不需要 qemu |
| 容器 | 无（直接在 runner 上跑） | `odin-build:latest`（1.77 GB，仓库根 Dockerfile） |

### 差距从哪来

1. **原生 vs 交叉 + qemu —— 最大头。**
   本地容器是 aarch64，编译出来的代码直接是目标架构；CI 是 x86_64 交叉编译，
   而且 rootfs 阶段 chroot 进 arm64 根之后要跑 `qemu-aarch64`，
   dpkg / postinst 全在模拟下跑。这是 rootfs 差 2.7 倍的主因。
2. **核数 8 vs 4**（`make -j8` vs CI 的并发）。
3. **CI 每轮固定开销**：`actions/checkout`、子模块初始化、`apt-get install` 一堆工具、
   缓存恢复与写回。看 dtb 就明白了 —— 真正跑 dtc 只要几秒，CI 那条 job 却要 198 秒，
   剩下全是环境准备。

---

## 三、实测明细

### CI —— run 34005822667（commit `604421c`，v0.9.7-fsck-tools）

起 10:11:14，各 job 墙钟：

```
dtb          success   198s
kernel       success  2149s     ← 占大头
lk2nd        success    44s
rootfs-core  success   400s
rootfs-gui   （并发跑，另一条 job）
```

注：这轮的基础根缓存因 `v3 → v4` 键变更而失效，debootstrap 是重跑的，
所以 rootfs 这 400s 属于"缓存冷"的情形；命中缓存时会更短。

### 本地 —— 同一 commit `604421c`

```
fetch-kernel   62s      （复制内核树到 tmp/linux-msm8953）
lk2nd           8s      （make -B 强制）
dtb            57s      （make -B 强制）
kernel        778s      （ccache 冷）
rootfs-core   149s
--------------------------------
合计          1054s  ≈ 17.6 分
```

第一次跑（lk2nd / dtb 命中时间戳，未强制）总 989s ≈ 16.5 分。

### 本地 —— commit `5fb5ea0`（传感器版，ccache 温）

直接进树编内核验证：

```
olddefconfig   rc=0，CONFIG_INPUT_QCOM_SPMI_HAPTICS=y 在
make -j8 Image modules   350s（5 分 50 秒），rc=0
  CC  drivers/input/misc/qcom-spmi-haptics.o     ← 新驱动编进去了
```

ccache 命中后 778s → 350s，**同一棵树再编只要一半时间**。

---

## 四、本机怎么跑（照 docs/05 第一节）

```sh
# 一次性的（镜像已缓存时 0.8 秒就返回）
docker build -t odin-build:latest .

mkdir -p tmp/ccache tmp/linux-dtb tmp/linux-kernel
docker run -d --name odin-dev --privileged \
  -v /Volumes/caseSensitiveBar/odin-work:/work/odin-work \
  -v /Volumes/caseSensitiveBar/odin-work/tmp/ccache:/var/cache/odin-ccache \
  odin-build:latest

docker exec -it odin-dev bash
cd /work/odin-work && make fetch-kernel && make dtb OUT=out \
  && make lk2nd OUT=out && make kernel OUT=out && make rootfs-core OUT=out
```

产物落在仓库的 `out/`（宿主能看到）：`out/rootfs-core/odin-debian-sparse.img` 等。

**OrbStack 不在跑时**先 `open -a OrbStack`，等 `docker version` 通了再编。

---

## 五、这轮顺手修掉的两个"静默失效"（都跟构建速度无关，但一样致命）

### 5.1 CI 基础根缓存键抄了一份包清单

`.github/workflows/release-build.yml` 里原来自己抄了一份 `--include` 来算键：
```sh
inc="busybox-static,udev,ssh,sudo,systemd,iproute2,dnsmasq,parted,e2fsprogs"
```
给 `tools/ci/build-rootfs.sh` 加 `dosfstools,exfatprogs` 后键不变 ⇒ 缓存命中 ⇒
debootstrap 跳过 ⇒ **新包静默没进镜像**（刷上真机才发现 `mkfs.vfat` 不存在）。

已改成按 `tools/ci/build-rootfs.sh` 的 sha256 变化（键 v3 → v4），
并把包清单收成脚本里的唯一来源 `DEB_INCLUDE`。

**修完已验证**：本地编出来的镜像里
```
/sbin/mkfs.vfat   /sbin/fsck.vfat   /sbin/mkfs.exfat   /sbin/fsck.exfat
dosfstools 4.2-1        exfatprogs 1.2.0-1+deb12u1
```

### 5.2 `make kernel` / `make dtb` 漏了配置与补丁依赖

原来只有 order-only 依赖 `| $(STAMPS) fetch-kernel` ⇒ 时间戳一在就跳过。
改了内核配置、改了补丁都不会触发重编，**且不报错**。
已把 `config 文件 + patches/*.patch`（dtb 另加 `dts/build-dtb.sh + dts/*.dts`）
写成真依赖。

---

## 六、两个别踩的坑（这轮实测撞到的）

### 6.1 `make -B kernel` 不能用

`-B` 会强制 make 去"重建" `.config`，撞上内核 Makefile 的 `$(KCONFIG_CONFIG)` 规则：
```
*** Configuration file ".config" not found!
make[2]: *** [Makefile:884: .config] Error 1
```
kernel 与依赖它的 rootfs 都会挂；dtb / lk2nd 不受影响。
要强制重编请 `touch` 输入文件（现在有真依赖了，改了自然会重编）。

### 6.2 本地验证补丁要连 `.git` 一起复制

用 `tar --exclude=.git` 复制内核树来做补丁验证时，`git apply` 会报
```
Skipped patch 'arch/arm64/boot/dts/qcom/msm8953-smartisan-odin.dts'
```
并且**返回 0、什么都不做** —— 静默失败，看着像"补丁已打过"。
CI 的构建树是 `cp -a`（带 `.git`）所以不受影响；本地必须连 `.git` 一起复制。

---

## 七、什么时候还是得等 CI

1. **要发布的产物** —— 项目规则，交付物只认 CI。
2. **gui 变体** —— 本地默认只编 core（gui 是 core 的超集，包多得多，CI 上也要更久）。
3. **想让上游链路持续自证** —— CI 每轮都会重打一遍全部补丁，
   等于持续证明它们仍适用于钉死的内核 commit；本机只在你想起来时才跑。
