# Makefile —— odin-work 的统一构建入口
#
#   make help       显示所有目标与可覆盖的变量
#   make / make all 全量构建（dtb + kernel + lk2nd + rootfs → 产物汇总）
#   make fetch-kernel  取内核源码到钉死的 commit
#   make dtb        只编 4 个设备树
#   make kernel     只编内核与模块
#   make lk2nd      只编二级引导（完整版 + 精简版）
#   make rootfs     组装根文件系统并导出镜像（变体取 ODIN_VARIANT，默认 gui）
#   make rootfs-core / make rootfs-gui      显式指定变体
#   make publish / publish-core / publish-gui   产物汇总到 out/publish + SHA256SUMS
#   make clean      清 out/；make distclean 连内核源码树一起清
#
# 两个变体：core（无 GUI，服务器 / 开发基线）与 gui（带 Plasma Mobile 桌面）
#   dtb / kernel / lk2nd 与变体无关 —— 两个变体共用同一份产物，只编一次。
#   差别只在 rootfs 阶段装什么包，所以变体维度从 rootfs 才引入。
#   core 是 gui 的子集 ⇒ 本地默认只编 gui（ODIN_VARIANT ?= gui）；
#   CI 两个都编，各一条 job，共用上一步的 kernel / dtb artifact。
#
# 设计取向（与用户的共识）：
#   **能写成直线命令的，直接写在这里；有真逻辑的，仍然放脚本。**
#
#   写在这里的：dtb / kernel / lk2nd —— 原本三个脚本共 274 行，
#    mostly 是"打补丁 → 编译 → 拷产物 → 自检"的直线流程，做成具名 target
#    之后步骤一眼可见，还能单独重跑某一步。
#
#   仍然是脚本的：
#     tools/ci/fetch-kernel.sh   三级回退 + 重试（上游只让取 ref 能到达的 commit）
#     tools/ci/build-rootfs.sh   debootstrap 流水线，串起下面两个
#     tools/build-image.sh       保守特性集 + 导出 + 20+ 项回读校验
#   这三个里头是判断、循环、错误处理，写进 Makefile 只会变成一坨 \ 续行。
#
# 变量覆盖：
#   make JOBS=16 KDIR=/tmp/linux-msm8953 all
#   make OUT=build rootfs

SHELL := bash
# 每条 recipe 都跑在 set -euo pipefail 下 —— 这是 Makefile 相对脚本最大的短板，
# 补上之后未定义变量、管道里某一段失败都会立刻暴露，而不是静默继续。
.SHELLFLAGS := -eu -o pipefail -c

# ---------------------------------------------------------------- 路径
REPO := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
OUT  ?= $(REPO)/out
# 立刻转绝对路径：recipe 里会 cd 进内核源码树，届时 "out/kernel" 这种相对路径
# 就指到别处去了（CI 上的表现是 modules_install 把 modstage 建在源码树下，
# 最后 tar 报 No such file or directory）。老脚本里也有这条警告，重构时漏了。
# override 不能省：CI 是命令行传参（make kernel OUT=out），
# 命令行变量会盖掉 Makefile 里的普通赋值，只有 override 才拦得住。
override OUT := $(abspath $(OUT))

# 内核源码树：默认落在项目内 tmp/（AGENTS.md §1.6，不用系统 /tmp）。
# CI 想用 /tmp 更快可覆盖：make KDIR=/tmp/linux-msm8953
KDIR ?= $(REPO)/tmp/linux-msm8953

# lk2nd 源码树（tarball 解开后就地打补丁、就地编译）
LK2ND_SRC ?= $(REPO)/tmp/lk2nd-src

DTB_OUT    := $(OUT)/dtb
KERNEL_OUT := $(OUT)/kernel
LK2ND_OUT  := $(OUT)/lk2nd
PUBLISH    := $(OUT)/publish
STAMPS     := $(OUT)/.stamps
# 变体相关路径用递归展开（= 而不是 :=）：rootfs-core / rootfs-gui 的 recipe
# 运行时才会确定 ODIN_VARIANT，:= 会把解析期那个默认值钉死，两个变体就串了。
ROOTFS_OUT = $(OUT)/rootfs-$(ODIN_VARIANT)

# ---------------------------------------------------------------- 钉死的外部输入
# 与 .github/workflows/release-build.yml 的 env 段一致，改一处要改两处
KERNEL_REPO   ?= https://github.com/msm8953-mainline/linux.git
KERNEL_SHA    ?= 05f7e89ab9731565d8a62e3b5d1ec206485eeb0b
KERNEL_BRANCH ?= master
KERNEL_SINCE  ?= 2026-02-07
LK2ND_VER     ?= 23.1
SUITE         ?= bookworm

# ---------------------------------------------------------------- 变体
# core（无 GUI，服务器 / 开发基线）/ gui（Plasma Mobile 桌面）。
# 本地默认 gui：core 是它的子集，本地没必要为求证子集再花一遍 debootstrap。
# CI 会显式跑两条：make rootfs-core 与 make rootfs-gui。
ODIN_VARIANT  ?= gui
VARIANTS      := core gui

# ---------------------------------------------------------------- 工具链
CROSS ?= aarch64-linux-gnu-
JOBS  ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# rootfs 要 debootstrap + mount，必须 root；已是 root 就别套 sudo
# （某些最小容器里根本没有 sudo 这个命令）
SUDO := $(shell if [ "$$(id -u)" = 0 ]; then echo ''; else echo 'sudo -E'; fi)

# 产物大小：GNU 的 stat -c 与 BSD 的 stat -f
SIZE = stat -c%s "$(1)" 2>/dev/null || stat -f%z "$(1)"

# 四个设备树（完整版 / 安全版 × 自动识别面板 / 面板写死 FT8716）
DTB_NAMES := msm8953-smartisan-odin \
             msm8953-smartisan-odin-norolesw \
             msm8953-smartisan-odin-ft8716 \
             msm8953-smartisan-odin-ft8716-norolesw

# ---------------------------------------------------------------- 目标
# 描述"某棵内核源码树状态"的三个戳（fetch / dtb / kernel）必须按 KDIR 分开。
#
# 戳文件记的是一棵源码树的状态，不是"本项目取过源码"这件事。换一棵树却沿用旧戳，
# make 会认为源码已取过、直接跳过 fetch ⇒ 补丁打进一个不存在的目录，
# 报错是 `cd: /xxx: No such file or directory`，离真因有十万八千里。
#
# CI 上只有一棵树，永远不会遇到；本地必须给 dtb 与 kernel 各用一棵树
# （dtb 只打 0007，kernel 打 0001-0008，共用一棵会撞"0007 已应用"），
# 这个坑是必然踩到的。见 docs/05 第一节。
KDIR_TAG := $(subst /,_,$(abspath $(KDIR)))

.PHONY: all help print-config fetch-kernel dtb kernel lk2nd \
        rootfs rootfs-core rootfs-gui \
        publish publish-core publish-gui \
        clean distclean

.DEFAULT_GOAL := all

all: publish

help:
	@sed -n '2,35p' $(REPO)/Makefile | sed 's/^# \{0,1\}//'

print-config:
	@echo "REPO        = $(REPO)"
	@echo "OUT         = $(OUT)"
	@echo "KDIR        = $(KDIR)"
	@echo "LK2ND_SRC   = $(LK2ND_SRC)"
	@echo "KERNEL_SHA  = $(KERNEL_SHA)"
	@echo "LK2ND_VER   = $(LK2ND_VER)"
	@echo "SUITE       = $(SUITE)"
	@echo "ODIN_VARIANT= $(ODIN_VARIANT)  (可选: $(VARIANTS))"
	@echo "ROOTFS_OUT  = $(ROOTFS_OUT)"
	@echo "CROSS       = $(CROSS)"
	@echo "JOBS        = $(JOBS)"
	@echo "SUDO        = $(SUDO)"

$(STAMPS):
	@mkdir -p $(STAMPS)

# ================================================================ 内核源码
# 保留脚本：三级回退（depth 1 → shallow-since → 整支 master）+ 重试，
# 上游 GitHub 只让取 ref 能到达的 commit，这段是纯逻辑，留在脚本里。
fetch-kernel: $(STAMPS)/fetch-$(KDIR_TAG)
$(STAMPS)/fetch-$(KDIR_TAG): | $(STAMPS)
	KDIR="$(KDIR)" KERNEL_REPO="$(KERNEL_REPO)" KERNEL_SHA="$(KERNEL_SHA)" \
		KERNEL_BRANCH="$(KERNEL_BRANCH)" KERNEL_SINCE="$(KERNEL_SINCE)" \
		bash $(REPO)/tools/ci/fetch-kernel.sh "$(KDIR)"
	@mkdir -p $(STAMPS) && touch $@

# ================================================================ 设备树
# DTB 只依赖 0007（设备树）；0001-0006/0008 是驱动，编 DTB 用不到，
# 少打几个补丁就少几个失配点。
dtb: $(STAMPS)/dtb-$(KDIR_TAG)
$(STAMPS)/dtb-$(KDIR_TAG): | $(STAMPS) fetch-kernel
	@mkdir -p $(DTB_OUT)
	@echo "[dtb] 应用设备树补丁 0007"
	if [ ! -f "$(KDIR)/arch/arm64/boot/dts/qcom/msm8953-smartisan-odin.dts" ]; then \
		cd "$(KDIR)" && patch -p1 --forward --no-backup-if-mismatch \
			< $(firstword $(wildcard $(REPO)/patches/0007-*.patch)); \
	else \
		echo "[dtb]   已打过，跳过"; \
	fi
	@echo "[dtb] 编译四个 DTB"
	KDIR="$(KDIR)" bash $(REPO)/dts/build-dtb.sh
	cp -f $(addprefix $(REPO)/dts/,$(addsuffix .dtb,$(DTB_NAMES))) $(DTB_OUT)/
	@echo "[dtb] 自检"
	@for v in ft8716 ft8716-norolesw; do \
		f="$(DTB_OUT)/msm8953-smartisan-odin-$$v.dtb"; \
		if grep -qa "smartisan,odin-ft8716" "$$f"; then \
			echo "[dtb]   ✅ 面板写死 FT8716 ($$v)  $$($(call SIZE,$$f)) 字节"; \
		else \
			echo "[dtb]   ❌ $$v 里没有 smartisan,odin-ft8716" >&2; exit 1; \
		fi; \
	done
# 自检一律"先把输出落到文件，再 grep -q 读文件"，不要在管道上 grep。
# 两条坑，都是实测踩出来的：
#   · `X | grep -q PAT`：grep -q 一匹配上就退出，把上游撞成 SIGPIPE(141)，
#     pipefail 把整个管道判为失败 ⇒ `if 管道; then` 走进 else。于是
#     "必须搜到"的报缺失、"必须搜不到"的假通过。CI 上时好时坏（竞态）。
#   · `n=$$(X | grep -c PAT)`：grep -c 匹配数为 0 时**退出码是 1**，而
#     `n=$$(...)` 这个赋值的状态就是命令替换的状态 ⇒ 在 set -e 下直接把
#     构建打断（dtb 就是这么挂的）。故自检里不要写带命令替换的赋值。
# 落到文件则两个坑都不存在，且上游命令自身的失败也能单独判出来。
	@dtc -I dtb -O dts "$(DTB_OUT)/msm8953-smartisan-odin-ft8716-norolesw.dtb" \
		> "$(DTB_OUT)/.odin-dtb-check.dts" 2>/dev/null \
		|| { echo "[dtb]   ❌ dtc 反编译失败" >&2; exit 1; }
	@if grep -q "usb-role-switch" "$(DTB_OUT)/.odin-dtb-check.dts"; then \
		echo "[dtb]   ❌ 安全版仍含 usb-role-switch" >&2; exit 1; \
	else \
		echo "[dtb]   ✅ 安全版无 usb-role-switch"; \
	fi
	@rm -f "$(DTB_OUT)/.odin-dtb-check.dts"
	@mkdir -p $(STAMPS) && touch $@

# ================================================================ 内核与模块
# 0001-0008 全打：CI 的价值之一就是持续证明这些补丁仍适用于钉死的 commit。
kernel: $(STAMPS)/kernel-$(KDIR_TAG)
$(STAMPS)/kernel-$(KDIR_TAG): | $(STAMPS) fetch-kernel
	@mkdir -p $(KERNEL_OUT)
	@echo "[kernel] 应用补丁 0001-0008"
	@for p in $(sort $(wildcard $(REPO)/patches/*.patch)); do \
		echo "[kernel]   $$(basename $$p)"; \
		cd "$(KDIR)" && patch -p1 --forward --no-backup-if-mismatch < "$$p"; \
	done
	@echo "[kernel] 配置"
	cp -f $(REPO)/config-postmarketos-qcom-msm8953.aarch64 "$(KDIR)/.config"
	cd "$(KDIR)" && make ARCH=arm64 CROSS_COMPILE="$(CROSS)" olddefconfig >/dev/null
	@echo "[kernel] 编译 Image + modules ($(JOBS) 线程，这步慢)"
	cd "$(KDIR)" && make -j"$(JOBS)" ARCH=arm64 CROSS_COMPILE="$(CROSS)" \
		CC="$(if $(shell command -v ccache 2>/dev/null),ccache ,)$(CROSS)gcc" \
		Image modules 2>&1 | tee /tmp/odin-kernel-build.log
# 打印命中率：全是 0 说明缓存键或 CC 没生效，别当成"缓存做过了"
	@command -v ccache >/dev/null 2>&1 && ccache -s || true
	@echo "[kernel] 取产物"
	cp -f "$(KDIR)/arch/arm64/boot/Image" "$(KERNEL_OUT)/vmlinuz"
	@echo "[kernel]   vmlinuz    $$($(call SIZE,$(KERNEL_OUT)/vmlinuz)) 字节"
	cd "$(KDIR)" && make ARCH=arm64 CROSS_COMPILE="$(CROSS)" \
		INSTALL_MOD_PATH="$(KERNEL_OUT)/modstage" modules_install 2>&1 \
		| tee /tmp/odin-modules-install.log
	tar -cf "$(KERNEL_OUT)/modules.tar" -C "$(KERNEL_OUT)/modstage" .
	rm -rf "$(KERNEL_OUT)/modstage"
	@echo "[kernel]   modules.tar $$($(call SIZE,$(KERNEL_OUT)/modules.tar)) 字节"
	@echo "[kernel] 自检：新增驱动应编出来"
	@for drv in panel-ft8716 panel-r69006 panel-nt36672; do \
		if [ -n "$$(find "$(KDIR)" -name "$$drv.ko" -print -quit)" ]; then \
			echo "[kernel]   ✅ $$drv.ko"; \
		else \
			echo "[kernel]   ❌ $$drv.ko 缺失" >&2; exit 1; \
		fi; \
	done
	@mkdir -p $(STAMPS) && touch $@

# ================================================================ 二级引导
# 补丁顺序 1,2,3 → 4：前三个两个变体都要，0004 只给精简版（去 markw/rosy）
# （它去掉 markw/rosy，强制 lk2nd 命中 odin 条目）。
# 两个变体共用一个源码树，必须串行，所以放在同一个 recipe 里。
lk2nd: $(STAMPS)/lk2nd
$(STAMPS)/lk2nd: | $(STAMPS)
	@mkdir -p $(LK2ND_OUT) $(LK2ND_SRC)
	@echo "[lk2nd] 取源码 $(LK2ND_VER) (msm8916-mainline/lk2nd)"
	rm -rf "$(LK2ND_SRC)"
	mkdir -p "$(LK2ND_SRC)"
	curl -sSL "https://github.com/msm8916-mainline/lk2nd/archive/refs/tags/$(LK2ND_VER).tar.gz" \
		| tar -xz --strip-components=1 -C "$(LK2ND_SRC)"
	test -f "$(LK2ND_SRC)/makefile"
	@echo "[lk2nd] 打补丁 0001 0002 0003"
	@for p in $(foreach n,0001 0002 0003,$(firstword $(wildcard $(REPO)/lk2nd/$(n)-*.patch))); do \
		echo "[lk2nd]   $$(basename $$p)"; \
		patch -p1 --forward --no-backup-if-mismatch -d "$(LK2ND_SRC)" < "$$p"; \
	done
	@echo "[lk2nd] 构建完整版"
	make -j"$(JOBS)" -C "$(LK2ND_SRC)" TOOLCHAIN_PREFIX=arm-none-eabi- \
		LK2ND_VERSION="$(LK2ND_VER)-full-odinport" PROJECT=lk2nd-msm8953 2>&1 \
		| tee /tmp/lk2nd-build-full.log
	cp -f "$(LK2ND_SRC)/build-lk2nd-msm8953/lk2nd.img" "$(LK2ND_OUT)/lk2nd.img"
	@echo "[lk2nd]   lk2nd.img         $$($(call SIZE,$(LK2ND_OUT)/lk2nd.img)) 字节"
	@echo "[lk2nd] 打补丁 0004 → 构建精简版（增量重编即可）"
	@for p in $(wildcard $(REPO)/lk2nd/0004-*.patch); do \
		echo "[lk2nd]   $$(basename $$p)"; \
		patch -p1 --forward --no-backup-if-mismatch -d "$(LK2ND_SRC)" < "$$p"; \
	done
	make -j"$(JOBS)" -C "$(LK2ND_SRC)" TOOLCHAIN_PREFIX=arm-none-eabi- \
		LK2ND_VERSION="$(LK2ND_VER)-nomarkw-odinport" PROJECT=lk2nd-msm8953 2>&1 \
		| tee /tmp/lk2nd-build-nomarkw.log
	cp -f "$(LK2ND_SRC)/build-lk2nd-msm8953/lk2nd.img" "$(LK2ND_OUT)/lk2nd-nomarkw.img"
	@echo "[lk2nd]   lk2nd-nomarkw.img $$($(call SIZE,$(LK2ND_OUT)/lk2nd-nomarkw.img)) 字节"
	@echo "[lk2nd] 自检"
	@strings "$(LK2ND_OUT)/lk2nd-nomarkw.img" > "$(LK2ND_OUT)/.odin-strings.txt" \
		|| { echo "[lk2nd]   ❌ strings 失败" >&2; exit 1; }
	@if grep -q "xiaomi-markw" "$(LK2ND_OUT)/.odin-strings.txt"; then \
		echo "[lk2nd]   ❌ 仍能搜到 xiaomi-markw" >&2; exit 1; \
	else \
		echo "[lk2nd]   ✅ xiaomi-markw: 0 处"; \
	fi
	@if grep -q "smartisan-odin" "$(LK2ND_OUT)/.odin-strings.txt"; then \
		echo "[lk2nd]   ✅ smartisan-odin: 保留"; \
	else \
		echo "[lk2nd]   ❌ odin 条目丢失" >&2; exit 1; \
	fi
	@rm -f "$(LK2ND_OUT)/.odin-strings.txt"
	@mkdir -p $(STAMPS) && touch $@

# ================================================================ 根文件系统
# 仍是脚本：debootstrap + depmod + initramfs + 用户态配置 + 镜像导出，
# 一整条流水线，且有 mount 之类的副作用，不适合拆成 make recipe。
# 变体走模式规则（% = core / gui）：两个变体的步骤完全一样，只有名字不同，
# 用 $* 把变体名传下去即可，没必要把同一段 recipe 抄两遍。
# 戳文件也按变体分开 —— 否则编完 core 再编 gui，make 会认为 rootfs 已最新而跳过。
rootfs: rootfs-$(ODIN_VARIANT)
rootfs-core: $(STAMPS)/rootfs-core
rootfs-gui:  $(STAMPS)/rootfs-gui

$(STAMPS)/rootfs-%: | $(STAMPS) kernel dtb
	@case "$*" in \
		core|gui) ;; \
		*) echo "[rootfs] 未知变体: $*（可选 core 或 gui）" >&2; exit 1 ;; \
	esac
	@mkdir -p $(OUT)/rootfs-$*
	SUITE="$(SUITE)" ODIN_VARIANT="$*" $(SUDO) bash $(REPO)/tools/ci/build-rootfs.sh \
		"$(OUT)/rootfs-$*" "$(KERNEL_OUT)" "$(DTB_OUT)"
	@mkdir -p $(STAMPS) && touch $@

# ================================================================ 产物汇总
publish: publish-$(ODIN_VARIANT)
publish-core: $(STAMPS)/publish-core
publish-gui:  $(STAMPS)/publish-gui

$(STAMPS)/publish-%: | $(STAMPS) rootfs-% lk2nd
	@case "$*" in \
		core|gui) ;; \
		*) echo "[publish] 未知变体: $*（可选 core 或 gui）" >&2; exit 1 ;; \
	esac
	@mkdir -p $(PUBLISH)
	cp -f $(DTB_OUT)/*.dtb       $(PUBLISH)/
	cp -f $(LK2ND_OUT)/*.img     $(PUBLISH)/
	cp -f $(OUT)/rootfs-$*/*.img $(PUBLISH)/
	cd $(PUBLISH) && sha256sum * | sort -k2 > SHA256SUMS
	@echo "[publish] $* 变体产物已汇总到 $(PUBLISH)："
	@ls -l $(PUBLISH)
	@mkdir -p $(STAMPS) && touch $@

# ================================================================ 清理
# 只清 out/。内核源码树默认留着，避免下次重拉（几十分钟）；
# 确实要连它一起清用 distclean。
clean:
	rm -rf $(OUT)

distclean: clean
	rm -rf $(KDIR) $(LK2ND_SRC)
