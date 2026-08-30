# Makefile —— odin-work 的统一构建入口
#
#   make help       显示所有目标与可覆盖的变量
#   make / make all 全量构建（dtb + kernel + lk2nd + rootfs + publish）
#   make dtb        只编 4 个设备树
#   make kernel     只编内核与模块
#   make lk2nd      只编二级引导（完整版 lk2nd.img + 精简版 lk2nd-nomarkw.img）
#   make rootfs     组装根文件系统并导出镜像（依赖 kernel 与 dtb）
#   make publish    把全部产物汇总到 out/publish 并生成 SHA256SUMS
#   make clean      清掉 out/
#   make distclean  连内核源码树一起清（下次要重新拉）
#
# 为什么要有 Makefile：
#   原来的入口是 5 个各自为政的 bash 脚本，靠目录约定串联，"谁依赖谁"只写在
#   注释里，跑错顺序要到 rootfs 阶段才报错。Makefile 把依赖关系显式化，并用戳
#   文件做增量 —— 编过的不会白编第二遍。
#
#   **构建逻辑仍然只在 tools/ci/*.sh 里，Makefile 只负责编排。**
#   这样 CI 与本地走同一套实现，不会改出第二份、产生行为分叉。
#
# 常用变量覆盖：
#   make JOBS=16 KDIR=/tmp/linux-msm8953 all
#   make OUT=build rootfs

SHELL := bash

# ---------------------------------------------------------------- 路径
REPO := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
OUT  ?= $(REPO)/out

# 内核源码树：默认落在项目内 tmp/（AGENTS.md §1.6，不用系统 /tmp）。
# CI 想用 /tmp 更快可以显式覆盖：make KDIR=/tmp/linux-msm8953
KDIR ?= $(REPO)/tmp/linux-msm8953

DTB_OUT    := $(OUT)/dtb
KERNEL_OUT := $(OUT)/kernel
LK2ND_OUT  := $(OUT)/lk2nd
ROOTFS_OUT := $(OUT)/rootfs
PUBLISH    := $(OUT)/publish
STAMPS     := $(OUT)/.stamps

# ---------------------------------------------------------------- 钉死的外部输入
# 与 .github/workflows/release-build.yml 的 env 段保持一致，改一处要改两处
KERNEL_REPO  ?= https://github.com/msm8953-mainline/linux.git
KERNEL_SHA   ?= 05f7e89ab9731565d8a62e3b5d1ec206485eeb0b
KERNEL_BRANCH ?= master
KERNEL_SINCE ?= 2026-02-07
LK2ND_VER    ?= 23.1
SUITE        ?= bookworm

# ---------------------------------------------------------------- 工具链
CROSS ?= aarch64-linux-gnu-
JOBS  ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# rootfs 要 debootstrap + mount，必须 root；已经是 root 就别再多套一层 sudo
# （某些最小容器里根本没有 sudo 这个命令）
SUDO := $(shell if [ "$$(id -u)" = 0 ]; then echo ''; else echo 'sudo -E'; fi)

# ---------------------------------------------------------------- 目标
.PHONY: all help fetch-kernel dtb kernel lk2nd rootfs publish clean distclean \
        print-config

.DEFAULT_GOAL := all

all: publish

help:
	@sed -n '2,30p' $(REPO)/Makefile | sed 's/^# \{0,1\}//'

print-config:
	@echo "REPO         = $(REPO)"
	@echo "OUT          = $(OUT)"
	@echo "KDIR         = $(KDIR)"
	@echo "KERNEL_SHA   = $(KERNEL_SHA)"
	@echo "LK2ND_VER    = $(LK2ND_VER)"
	@echo "SUITE        = $(SUITE)"
	@echo "CROSS        = $(CROSS)"
	@echo "JOBS         = $(JOBS)"
	@echo "SUDO         = $(SUDO)"

$(STAMPS):
	@mkdir -p $(STAMPS)

# ---- 内核源码 ------------------------------------------------------------
# 三级回退取内核到钉死的 commit，详见脚本内注释
fetch-kernel: $(STAMPS)/fetch-kernel
$(STAMPS)/fetch-kernel: | $(STAMPS)
	KDIR="$(KDIR)" KERNEL_REPO="$(KERNEL_REPO)" KERNEL_SHA="$(KERNEL_SHA)" \
		KERNEL_BRANCH="$(KERNEL_BRANCH)" KERNEL_SINCE="$(KERNEL_SINCE)" \
		bash $(REPO)/tools/ci/fetch-kernel.sh "$(KDIR)"
	@touch $@

# ---- 设备树（只依赖内核源码，不依赖内核编译）------------------------------
dtb: $(STAMPS)/dtb
$(STAMPS)/dtb: | $(STAMPS) fetch-kernel
	KDIR="$(KDIR)" bash $(REPO)/tools/ci/build-dtb.sh "$(DTB_OUT)"
	@touch $@

# ---- 内核与模块 -----------------------------------------------------------
kernel: $(STAMPS)/kernel
$(STAMPS)/kernel: | $(STAMPS) fetch-kernel
	KDIR="$(KDIR)" CROSS="$(CROSS)" JOBS="$(JOBS)" \
		bash $(REPO)/tools/ci/build-kernel.sh "$(KERNEL_OUT)"
	@touch $@

# ---- 二级引导（独立，不依赖内核源码）--------------------------------------
lk2nd: $(STAMPS)/lk2nd
$(STAMPS)/lk2nd: | $(STAMPS)
	LK2ND_VER="$(LK2ND_VER)" JOBS="$(JOBS)" \
		bash $(REPO)/tools/ci/build-lk2nd.sh "$(LK2ND_OUT)"
	@touch $@

# ---- 根文件系统与镜像 -----------------------------------------------------
# 依赖关系在这里显式化：rootfs 需要 kernel 的 vmlinuz/modules.tar 与 dtb
rootfs: $(STAMPS)/rootfs
$(STAMPS)/rootfs: | $(STAMPS) kernel dtb
	SUITE="$(SUITE)" $(SUDO) bash $(REPO)/tools/ci/build-rootfs.sh \
		"$(ROOTFS_OUT)" "$(KERNEL_OUT)" "$(DTB_OUT)"
	@touch $@

# ---- 汇总产物 + 校验和（对应 CI 的 publish job）---------------------------
publish: $(STAMPS)/publish
$(STAMPS)/publish: | $(STAMPS) rootfs lk2nd
	@mkdir -p $(PUBLISH)
	cp -f $(DTB_OUT)/*.dtb        $(PUBLISH)/
	cp -f $(LK2ND_OUT)/*.img      $(PUBLISH)/
	cp -f $(ROOTFS_OUT)/odin-debian.img        $(PUBLISH)/
	cp -f $(ROOTFS_OUT)/odin-debian-sparse.img $(PUBLISH)/
	cd $(PUBLISH) && sha256sum * | sort -k2 > SHA256SUMS
	@echo "产物已汇总到 $(PUBLISH)："
	@ls -l $(PUBLISH)
	@touch $@

# ---- 清理 -----------------------------------------------------------------
# 注意：只清 out/。内核源码树默认留在 $(KDIR)，避免下次重拉（几十分钟）；
# 确实要连它一起清用 distclean。
clean:
	rm -rf $(OUT)

distclean: clean
	rm -rf $(KDIR)
