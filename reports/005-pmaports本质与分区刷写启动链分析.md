# 分析报告 005 — pmaports 的本质 & 分区识别/刷写/启动链衔接机制

| 项目 | 内容 |
|------|------|
| 报告编号 | ODIN-DOC-005 |
| 日期 | 2026-08-22 |
| 问题 A | pmaports 是不是就是 postmarketOS 移植的那一批软件包？ |
| 问题 B | 全套工具如何确定手机型号与 eMMC 分区状态，把 lk2nd/boot/rootfs 刷到正确位置并互相衔接启动？ |
| 调查方式 | 本地 lk2nd 源码（boot/extlinux/wrapper）+ 原厂 gpt_main0.bin 实际解析 + pmbootstrap 源码 + pmaports initramfs 脚本，全部给出处 |

---

## 一、问题 A：pmaports 的本质

**结论：是的。** pmaports 就是 postmarketOS 的"移植软件包配方仓库"，它是 Alpine
Linux 打包体系（APKBUILD 格式）之上的一个专用包集合：

| 层 | 内容 | 来源 |
|----|------|------|
| Alpine 基础层 | musl、busybox、apk 工具链、gcc 等数千个通用包 | Alpine 官方 aports（分支由 channels.cfg 绑定，如 edge↔master、v24.06↔3.20-stable）|
| **pmaports 层** | postmarketOS 专属包：`device/*`（设备包+内核+固件）、`main/`（mkinitfs、devicepkg-dev、lk2nd、boot-deploy、msm-firmware-loader…）、`cross/`（交叉编译器）、`temp/`（临时 fork 的 Alpine 包）、`modem/`（qrtr/rmtfs 等） | gitlab.postmarketos.org/pmaports |

要点：
1. 每个目录就是一个 APKBUILD 包配方（源码 URL + 补丁 + build/package 函数），
   pmbootstrap 用 Alpine abuild 在 chroot 里按需编译——pmaports 本身不含上游源码；
2. `channels.cfg` 把 pmaports 分支与 Alpine 稳定分支成对绑定（004 文档已引全文）；
3. "移植一个手机 = 往 pmaports 添加 device-xxx / linux-* / firmware-* 几个配方"，
   其余全部复用。

---

## 二、问题 B：设备识别 → 分区 → 刷写 → 启动链

### 2.1 手机型号如何确定

- **pmbootstrap 不做任何自动探测。** 设备型号完全来自 `init` 时用户输入的
  `vendor-codename`（存入 pmbootstrap_v3.cfg），此后一切行为（deviceinfo、内核包、
  boot.img 参数）都由该设备包的 `deviceinfo/APKBUILD` 驱动。
- 刷写阶段 fastboot 只对"当前处于 bootloader 模式的那台设备"操作；pmbootstrap 通过
  `fastboot devices -l` 列设备但不校验型号——**选错 device 包就会刷错内容**，
  这是人为保证的约定。
- 设备侧的"身份"由硬件只读：msm8953 的 PBL/SBL 按 eMMC 中 GPT 找 aboot，
  与软件选择的型号无关。

### 2.2 eMMC 分区状态如何确定 —— 以 ODIN 实测为准

**关键事实：pmOS 从不重分区手机的 eMMC。** 安卓出厂时 GPT 已固化（高通 EDL 烧录
gpt_main0.bin），所有工具都只是**按名字引用既有分区**。实测 ODIN 原厂 GPT
（解析 `Pro_user_V4.2.5/.../gpt_main0.bin`，60 项）关键条目：

| LBA 范围 | 分区名 | 大小 | 在 pmOS 链路中的角色 |
|----------|--------|------|---------------------|
| 52–1075 | sbl1 | 512K | 高通第二引导（不可动） |
| 393216–395263 | **aboot**(+abootbak) | 1M | 原厂 LK 主引导（保留原样） |
| 397312–528383 | **boot** | **64M** | ← `fastboot flash boot` 目标：先刷 lk2nd.img |
| 528384–659455 | recovery | 64M | 可弃用（可刷 recovery zip 场景） |
| 2375680–2572287 | modem | 96M | 基带固件（msm-firmware-loader 只读挂载用） |
| 2621440–3145727 | cache | 256M | 可用作临时 |
| 3145728–9437183 | system | 3G | 弃用 |
| 9568256–… | **userdata** | 余量(32G 机约 27G) | ← `fastboot flash userdata` 目标：整个 rootfs 镜像 |

注：gpt_main0.bin 里 userdata 条目 first=9568256、last=first−1（占位），说明出厂
GPT 模板的 userdata 尺寸在产线烧录时才按实际 eMMC 容量展开——进一步证明
"分区表属于设备、不属于系统"。

fastboot 侧 `flash <name>` 时，**是手机上的 bootloader 自己查 GPT 把名字翻译成
LBA**（ODIN 上即原厂 aboot/lk2nd 的 partition_parser）。pmbootstrap 全程不读手机
分区表，只提供镜像文件和分区名（`$PARTITION_KERNEL` 默认 `"boot"`、
`$PARTITION_ROOTFS` 默认 `"userdata"`，见 pmb/flasher/variables.py）。

### 2.3 三级引导链与各文件的落位

```
┌─ 第0级 SoC ROM → sbl1 → tz/rpm/devcfg …（出厂固件，不动）
├─ 第1级 aboot 分区: 原厂 LK (emmc_appsboot.mbn)
│      └─ 读 "boot" 分区, 按安卓 boot.img 格式加载执行
├─ 第2级 boot 分区(64M): lk2nd.img          ← fastboot flash boot lk2nd.img
│      └─ lk2nd 初始化面板/按键/fastboot; 正常启动路径调 lk2nd_boot():
│           ① wrapper.c: 注册整块 eMMC 为 wrp0, 用 partition_parser 枚举 GPT,
│              每个分区发布为 wrp0pN 且 label=分区名 (boot/userdata/...)
│           ② 对每个分区再调 partition_publish() → 解析"分区里的分区表"
│              ⇒ userdata 里面是我们刷入的 <device>.img, 自带子 GPT:
│                 p1 pmOS_boot(ext4)  p2 pmOS_root(ext4)  ← 被发布成叶子块设备
│           ③ boot.c: lk2nd_scan_devices() 逐叶子设备尝试 ext2 挂载
│              (>16MiB 或名字以 boot 开头), 找 /extlinux/extlinux.conf
├─ 第3级 pmOS_boot 内文件: vmlinuz + initramfs + dtbs + extlinux.conf
│      └─ extlinux.c: kernel/initrd/fdtdir/append; DTB 选择用设备描述里的
│         lk2nd,dtb-files ("msm8953-smartisan-odin") 匹配
│         <fdtdir>/qcom/<name>.dtb → 加载后还会做 DEV_TREE_UPDATE
│         (即报告001的面板 compatible 替换发生在这一步!)
│      └─ 跳转内核; 找不到则回落 "Reverting to android boot"(走原厂 boot.img 流程)
└─ 第4级 Linux initramfs (postmarketos-initramfs):
       find_root_partition(): 先看 cmdline pmos_root_uuid=/pmos_root=,
       否则 blkid --label pmOS_root 全盘扫描
       (init_functions.sh:214-290 注释明说支持"system 分区里套分区表"布局,
        mount_subpartitions 先行解析嵌套 GPT) → 挂载 pmOS_root → switch_root
```

### 2.4 "互相关联"的五个衔接点（为什么恰好能接上）

| # | 衔接 | 依赖的约定/机制 |
|---|------|----------------|
| 1 | aboot → lk2nd | lk2nd.img 是合法安卓 boot.img 包装（kernel=lk2nd），aboot 无感知执行 |
| 2 | lk2nd → pmOS_boot | `<device>.img` 自带 GPT + 分区标签固定为 `pmOS_boot/pmOS_root`；lk2nd 递归枚举 + extlinux 约定路径 `/extlinux/extlinux.conf` |
| 3 | DTB 正确性 | extlinux fdtdir + 设备描述 `lk2nd,dtb-files` 与内核 dtb 文件名（qcom/msm8953-smartisan-odin.dtb）严格同名；运行期再被 lk2nd 改写 panel compatible |
| 4 | initramfs → pmOS_root | 分区标签 `pmOS_root`（blkid 扫描兜底）或 cmdline 显式 UUID；两者都由 install 时 pmbootstrap 写 fstab/boot-deploy 写 extlinux.conf 固化 |
| 5 | rootfs 内容自洽 | device 包 depends 拉齐 内核/lk2nd/firmware/soc 包，apk 触发器在装完瞬间生成 initramfs+extlinux.conf，保证 /boot 内三件套版本一致 |

### 2.5 刷写命令与落点对照（pmbootstrap 实际执行）

```
fastboot flash boot     $BOOT/lk2nd.img        # flash_lk2nd 动作, 必须最先刷
fastboot flash boot     $BOOT/boot.img         # 仅非-lk2nd 直启方案使用;
                                               # lk2nd 方案下不用(会覆盖lk2nd)!
fastboot flash userdata /home/pmos/rootfs/<device>.img   # 含嵌套GPT的完整盘镜像
```
print_flash_info（_install.py:962+）正是按"文件是否存在 + flasher 是否有该动作"
打印以上提示，并对 lk2nd 设备特别输出 *"You should flash it before flashing
anything else"*。mido/daisy 等 lk2nd 设备的 `deviceinfo_generate_extlinux_config="true"`
就是告诉 boot-deploy："我的 boot 分区是 lk2nd 要读的文件系统，生成 extlinux.conf
而非仅 boot.img"。

---

## 三、对我们 ODIN 移植的直接推论

1. ODIN 的 boot 分区 64MB、userdata ~27GB，容量充足；无需任何重分区动作；
2. 我们的自编 lk2nd.img → 手动 `fastboot flash boot lk2nd.img`（或塞进设备包
   depends 让 /boot/lk2nd.img 出现后走 `pmbootstrap flasher flash_lk2nd`）；
3. 缺失 `device-smartisan-odin` 包时 install 无法产出含正确
   `extlinux.conf/dtbs/deviceinfo` 的 pmOS_boot——这是当前打通全链的最后缺口
   （deviceinfo 需含 `generate_extlinux_config="true"`、
   `dtb=qcom/msm8953-smartisan-odin`、fastboot 偏移组同 mido）；
4. 启动链验证顺序建议：串口看 lk2nd 日志的
   "Trying to boot from the file system..."→"Trying to boot '…'" 两行，
   即可确认第2→3级衔接成功。

---

*文档结束 — odin-port 系列 №005*
