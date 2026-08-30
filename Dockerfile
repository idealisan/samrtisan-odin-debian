# ODIN 编译专用镜像 —— 构建环境的唯一权威定义
#
#   docker build -t odin-build:latest .
#   （起容器的命令见 docs/05-构建与发布.md 第一节）
#
# 为什么需要它：
#   构建要同时在两种体系结构上干活 —— 交叉编 arm64 内核、编 ARM32 裸机的 lk2nd、
#   debootstrap 一个 arm64 根再 chroot 进去装包、最后造 ext4 镜像。依赖散在
#   CI workflow 的四个 job 里，靠人肉 apt-get 装一次就退化成"某台机器上能编"。
#   把依赖钉进镜像，本地与 CI 才是同一套输入。
#
# 依赖清单不是我拍脑袋列的：逐条来自 .github/workflows/release-build.yml 里
# dtb / lk2nd / kernel / rootfs 四个 job 各自的 apt-get install 行，再补上
# make 内部要用到的几个（git/curl/patch/python3/xz-utils）。
#
# 基础镜像钉到 digest 而不是 tag：tag 会随上游滚动，digest 保证今天和三年后
# 拉到的是同一层。本地已有这一层时不会走网络。
FROM debian:bookworm@sha256:813017f3d62be4b5891a7acca6a01bdcd4b8513daa81b1ab99d3a50385b26931

ENV DEBIAN_FRONTEND=noninteractive

# ccache 落点固定成绝对路径：它默认位置的判定规则在 4.x 里改过
# （XDG_CACHE_HOME → ~/.cache/ccache → ~/.ccache），不写死就会出现"缓存在 A 处、
# 挂载卷挂到 B 处"这种查半天的事故。挂卷就挂这里。
ENV CCACHE_DIR=/var/cache/odin-ccache

# 全部依赖一条 RUN 装完：只有一层，且中途失败不会留下半装状态的中间层。
# 注释分组与 CI 的 job 一一对应，方便两边对照着改。
RUN apt-get update && apt-get install -y --no-install-recommends \
      # ---- 公共：make 内部会用到的
      ca-certificates curl git patch make python3 xz-utils file \
      # ---- dtb job
      device-tree-compiler \
      # ---- lk2nd job（ARM32 裸机工具链）
      gcc-arm-none-eabi libfdt-dev \
      # ---- kernel job
      gcc-aarch64-linux-gnu bc bison flex libssl-dev libelf-dev \
      kmod cpio rsync ccache \
      # ---- rootfs job
      debootstrap qemu-user-static binfmt-support \
      e2fsprogs android-sdk-libsparse-utils parted \
    && rm -rf /var/lib/apt/lists/*

# ccache 的两条关键配置 —— 默认值在这个项目上必然全量未命中，已实测确认：
#
#   compiler_check 默认 mtime：把编译器二进制的 mtime 计入哈希。
#     CI 每个 job 都全新 apt-get install 交叉编译器，mtime 每次都变
#     ⇒ 4399 个编译单元全部未命中，实测命中率 2.02%，内核编 29 分钟。
#     实测：只 touch 编译器二进制，命中率就从 100% 掉到 0%。
#
#   hash_dir 默认 true：编译带 -g 时把当前工作目录计入哈希。
#     本内核 CONFIG_DEBUG_INFO=y，而源码树位置一旦变动（旧脚本用 /tmp/linux-msm8953，
#     迁进 Makefile 后变成仓库内 tmp/），旧缓存整体作废。
#
# 两条都改掉之后实测：换目录、touch 编译器，命中率都是 100%。
# 代价：改配置会让**旧缓存条目全部失效一次**（哈希规则变了），只此一次。
RUN mkdir -p "$CCACHE_DIR" \
    && ccache --set-config max_size=10G \
    && ccache --set-config compression=true \
    && ccache --set-config compiler_check=content \
    && ccache --set-config hash_dir=false

WORKDIR /work/odin-work

# 容器里默认就是 root：debootstrap / chroot / mke2fs / mount 全都要特权，
# 没必要造一个非 root 用户再 sudo 回去（Makefile 的 SUDO 变量对 root 自动置空）。
CMD ["sleep", "infinity"]
