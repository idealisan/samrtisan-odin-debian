#!/bin/bash
# flash/flash-all.sh —— 从设备自带的原生 fastboot 开始，一路刷到 SSH 可用
#
#   flash/flash-all.sh                 # 从头跑（00 → 90）
#   flash/flash-all.sh --from 40       # 从某个阶段继续（失败后重跑用）
#   flash/flash-all.sh --dry-run       # 只打印将执行的动作，不真刷
#
# 阶段：
#   00 precheck    本机依赖、镜像存在性与校验和、设备当前状态
#   10 backup      经 SSH 全量备份真机根文件系统（手机本地打包 + HTTP 拉回）
#   20 fastboot    进入原生 fastboot（远程：改名 extlinux.conf 让 lk2nd 停在 fastboot）
#   30 boot        刷 lk2nd → boot 分区
#   40 data        刷 Debian 镜像 → userdata 分区
#   50 reboot      fastboot reboot，等 PC 上出现 USB NCM 网卡
#   60 usbnet      等 PC 拿到 172.16.42.2（DHCP 优先，超时静态兜底）
#   70 ssh         等 22 端口可达
#   80 verify      跑验收项（内核 / 面板 / 背光 / DRM / usb0 / WiFi / 扩容）
#   90 handoff     收尾提示
#
# 为什么 20 能远程完成（整条流程的关键）：
#   真机上没有 adbd，/sys/kernel/reboot/mode 又只收 cold/warm/hard，
#   从系统内部没法直接进 fastboot。但实测证实：**lk2nd 找不到
#   /extlinux/extlinux.conf 时会自动停在 fastboot**。所以把配置改名再重启，
#   就能无人值守地落到 fastboot；刷完之后新系统自带 /extlinux/extlinux.conf，
#   lk2nd 正常引导。
#   若这条不通（比如 lk2nd 本身坏了），脚本会提示人工按【音量减 + 电源】。
#
# 任何阶段失败都可直接 `--from <该阶段>` 重跑，不用从头再来。
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/common.sh"

FROM=00
DRY=0
BOOT_IMG=${BOOT_IMG:-$DIST_DIR/lk2nd-nomarkw.img}
DATA_IMG=${DATA_IMG:-$DIST_DIR/odin-debian-sparse.img}
DATA_IMG_RAW=${DATA_IMG_RAW:-$DIST_DIR/odin-debian.img}
STATE=$EVIDENCE_DIR/flash-state.env

usage() { sed -n '2,26p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --from)     FROM=$2; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# 阶段门控：FROM <= 该阶段编号 时才执行
run() { [ "${FROM:-0}" -le "$1" ] 2>/dev/null; }

# 一次 ping 成功即算通
ping_one() { ping -c 1 -W 1500 "$DEVICE_IP" >/dev/null 2>&1; }

# 真执行 or 只打印
act() { # act <命令...>
  if [ "$DRY" = 1 ]; then info "[dry-run] $*"; return 0; fi
  "$@"
}

# 要求设备处于 fastboot；dry-run 下假定成立，好让全流程能预览一遍
require_fastboot() {
  if [ "$DRY" = 1 ]; then info "[dry-run] 假定已在 fastboot"; return 0; fi
  in_fastboot || die "$1"
}

save_state() {
  mkdir -p "$(dirname "$STATE")"; [ -f "$STATE" ] || : > "$STATE"
  grep -v "^$1=" "$STATE" 2>/dev/null > "$STATE.tmp" || true
  echo "$1=$2" >> "$STATE.tmp"; mv "$STATE.tmp" "$STATE"
}
load_state() { [ -f "$STATE" ] && grep -s "^$1=" "$STATE" | cut -d= -f2- || true; }

fsize() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }

# ---------------------------------------------------------------- 00 precheck
if run 0; then
  step "00 precheck"
  for t in fastboot sshpass curl; do need "$t"; done
  for f in "$BOOT_IMG" "$DATA_IMG"; do
    [ -f "$f" ] || die "缺镜像: $f（到 GitHub Release 下载，或用 BOOT_IMG / DATA_IMG 指定）"
    ok "  镜像就绪 $(basename "$f")  $(fsize "$f") 字节"
  done
  if [ -f "$DIST_DIR/MANIFEST.sha256" ]; then
    log "按 Release 清单校验校验和..."
    ( cd "$DIST_DIR" && shasum -a 256 -c MANIFEST.sha256 ) >/dev/null 2>&1 \
      && ok "  校验和全部匹配" || warn "  校验和有出入，确认是否下错版本"
  fi
  if device_alive; then ok "  设备状态：Debian 运行中（SSH 可达）"
  elif in_fastboot; then ok "  设备状态：fastboot"
  else warn "  设备状态：既不在 SSH 也不在 fastboot（可能需要按键）"; fi
fi

# ---------------------------------------------------------------- 10 backup
if run 10; then
  step "10 backup"
  if device_alive; then
    act bash "$FLASH_DIR/stages/10-backup.sh"
    act bash "$FLASH_DIR/stages/10-backup.sh" --fetch
  else
    warn "设备不可达，跳过备份。若已备份过，用 --from 20 继续"
  fi
fi

# ---------------------------------------------------------------- 20 fastboot
if run 20; then
  step "20 fastboot"
  if in_fastboot; then
    ok "已在 fastboot"
  elif device_alive; then
    info "设备在 Debian 里。远程进 fastboot：改名 extlinux.conf，lk2nd 找不到配置会停在 fastboot"
    act odin_sudo <<'R'
      mv /extlinux/extlinux.conf /extlinux/extlinux.conf.disabled
      sync
R
    save_state extlinux_disabled 1
    act odin_sudo <<'R'
      nohup sh -c "sleep 2; reboot" >/dev/null 2>&1 &
R
    if [ "$DRY" = 1 ]; then
      info "[dry-run] 跳过等待（dry-run 不会真的重启，等也等不到）"
    else
    log "等设备落到 fastboot（最多 ${T_FASTBOOT}s，10s 一查）"
    if wait_until "设备进入 fastboot" "$T_FASTBOOT" 10 in_fastboot; then
      ok "已进入 fastboot"
    else
      err "没能自动进 fastboot"
      cat <<'TIP'
  请人工操作：关机后按住【音量减 + 电源键】进入原厂 fastboot，然后重跑
      flash/flash-all.sh --from 30
TIP
      exit 1
    fi
    fi
  else
    die "设备既不在 SSH 也不在 fastboot，无法继续"
  fi
fi

# ---------------------------------------------------------------- 30 boot
if run 30; then
  step "30 boot（刷 lk2nd → lk2nd 分区）"
  require_fastboot "不在 fastboot，先跑 --from 20"

  # ★★ 关键：lk2nd 装在自己那个叫 lk2nd 的分区里，不是 boot。
  #
  # 实测（这次刷机踩出来的）：boot 分区的真实布局是
  #    偏移 0      … 512 KB   ← lk2nd 本体，设备就从这里启动
  #    偏移 512 KB …          ← fastboot 的 "boot" 分区，给内核用的
  # 证据：boot 分区里有 4 个 ANDROID! 魔数（0 / 266840 / 524288 / 795132），
  # 而 `fastboot getvar all` 报 `partition-size:lk2nd: 0x80000`（正好 512 KB）、
  # `partition-size:boot: 0x3f80000`。
  #
  # 所以 `fastboot flash boot <lk2nd.img>` 会把镜像写到偏移 512 KB 处，
  # 偏移 0 那个旧的 lk2nd 毫发无损，重启后照样是旧版在跑 —— 而命令返回 OKAY，
  # 看上去一切正常。要换掉 lk2nd，必须刷 lk2nd 分区。
  LK2ND_PART=${LK2ND_PART:-lk2nd}
  log "刷入 $(basename "$BOOT_IMG") → ${LK2ND_PART} 分区"
  if [ "$DRY" = 1 ]; then
    info "[dry-run] fastboot flash ${LK2ND_PART} $BOOT_IMG"
  else
    if ! fb flash "$LK2ND_PART" "$BOOT_IMG"; then
      warn "刷 ${LK2ND_PART} 分区失败，回退刷 boot（有些环境不会导出 lk2nd 分区名）"
      fb flash boot "$BOOT_IMG" || die "刷 boot 失败"
    fi
    ok "${LK2ND_PART} 分区刷写完成"
  fi
fi

# ---------------------------------------------------------------- 40 data
if run 40; then
  step "40 data（刷 Debian → userdata 分区）"
  require_fastboot "不在 fastboot，先跑 --from 20"
  log "刷入 $(basename "$DATA_IMG")（sparse 版，fastboot 自动分块传输）"
  if [ "$DRY" = 1 ]; then
    info "[dry-run] fastboot flash userdata $DATA_IMG"
  else
    if ! fb flash userdata "$DATA_IMG"; then
      warn "sparse 版失败，回退 raw 版（一次下载，可能超过 max-download-size）"
      [ -f "$DATA_IMG_RAW" ] || die "raw 版也不存在: $DATA_IMG_RAW"
      fb flash userdata "$DATA_IMG_RAW" || die "刷 userdata 失败"
    fi
    ok "userdata 分区刷写完成"
  fi
fi

# ---------------------------------------------------------------- 50 reboot
if run 50; then
  step "50 reboot"
  if [ "$DRY" = 1 ]; then
    info "[dry-run] fastboot reboot"
  else
    fb reboot || warn "fastboot reboot 返回非 0（多数情况无妨，继续等）"
    log "等 USB 网卡出现（最多 ${T_USBNET}s）"
    wait_until "PC 上出现 USB 网卡" "$T_USBNET" 5 usb_nic_up \
      && ok "USB 网络已通" || warn "未自动拿到地址，进 60 阶段用静态兜底"
  fi
fi

# ---------------------------------------------------------------- 60 usbnet
if run 60 && [ "$DRY" = 0 ]; then
  step "60 usbnet（等 PC 拿到 ${PC_IP}）"
  if usb_nic_up; then
    ok "PC 已持有 ${PC_IP}"
  else
    log "DHCP 未生效，静态兜底"
    nic=""
    for i in $(seq 1 12); do
      nic=$(list_usb_nics | head -1)
      [ -n "$nic" ] && break
      sleep 5
    done
    [ -n "$nic" ] || die "找不到 USB 网卡，检查连线"
    log "给 $nic 配 ${PC_IP}/24"
    sudo ifconfig "$nic" inet "${PC_IP}/24" up 2>/dev/null \
      || sudo ifconfig "$nic" "${PC_IP}" netmask 255.255.255.0 up \
      || die "配地址失败"
    wait_until "PC 与设备互通" 30 3 ping_one || die "配了地址仍不通"
    ok "静态地址已通"
  fi
fi

# ---------------------------------------------------------------- 70 ssh
if run 70 && [ "$DRY" = 0 ]; then
  step "70 ssh（等 22 端口；首启含文件系统扩容，会比较慢）"
  wait_until "SSH 可达" "$T_SSH" 10 device_alive \
    || die "SSH 一直不可达。救援通道（initramfs telnet / IPv6 / UART）见 reports/018"
  ok "SSH 已通"
fi

# ---------------------------------------------------------------- 80 verify
if run 80 && [ "$DRY" = 0 ]; then
  step "80 verify"
  pass=0; fail=0
  chk() { if [ "$2" = "$3" ]; then ok "  ✅ $1: $3"; pass=$((pass+1));
          else err "  ❌ $1: 期望 [$2]，实际 [$3]"; fail=$((fail+1)); fi; }
  has() { case "$3" in *"$2"*) ok "  ✅ $1"; pass=$((pass+1));;
          *) err "  ❌ $1（实际: $3）"; fail=$((fail+1));; esac; }
  r() { odin_ssh "$1" 2>/dev/null | tr -d '\r\n' | head -1; }
  # 精确判断某个内核模块是否已加载。两个坑都实测踩过：
  #   1. 不能写 lsmod | grep -c <名字>：lsmod 的 "used by" 列里也会出现该名字，
  #      grep -c 数的是行数，会多算（查 ft8716 得 2、查 wcn 得 4）。
  #   2. 也别用 lsmod | awk '{print $1}'：$1 要经过 本地shell → ssh → 远端shell
  #      三层，转义极易出错（实测拿到 "unbound variable"）。
  # 直接查 /proc/modules 的行首最干净，一行搞定、无需任何转义。
  mod_loaded() { r "grep -q '^$1 ' /proc/modules && echo 1 || echo 0"; }

  chk "hostname"        "odin"         "$(r 'cat /etc/hostname')"
  has "内核版本"         "6.19"         "$(r 'uname -r')"

  # --- 显示链路：必须"先证明驱动加载了"，再查有没有报错 ---
  # 反面教训：只查 dmesg 里错误串的条数，是"无错即通过"——驱动压根没加载时
  # dmesg 里自然 0 条错误，一样通过。所以先做正向检查。
  chk "面板驱动已加载(ft8716)" "1" "$(mod_loaded panel_ft8716)"
  chk "DSI 已连接"       "connected"    "$(r 'cat /sys/class/drm/card0-DSI-1/status')"
  # status 只是连接器的探测结果，enabled 才表示真的做了一次 modeset。两者都看，
  # 与仓库 docs/04-排障.md 的显示类排障流程保持一致
  chk "DSI 已使能"       "enabled"      "$(r 'cat /sys/class/drm/card0-DSI-1/enabled')"
  has "DRM 设备节点"     "card0"        "$(odin_ssh 'ls /dev/dri/ | tr "\n" " "' 2>/dev/null)"
  chk "面板初始化失败数"  "0"            "$(r 'dmesg | grep -c "Failed to initialize panel"')"
  # 用 actual_brightness（硬件回读）而不是 brightness（只是请求值），后者非零
  # 也可能屏幕是黑的
  bl=$(r 'cat /sys/class/backlight/*/actual_brightness')
  if [ -n "$bl" ] && [ "$bl" -gt 0 ] 2>/dev/null; then ok "  ✅ 背光(回读): $bl"; pass=$((pass+1))
  else err "  ❌ 背光(回读): [$bl]"; fail=$((fail+1)); fi

  # --- 网络 ---
  has "usb0 地址"        "172.16.42.1"  "$(r 'ip -4 -o addr show usb0 | awk "{print \$4}"')"
  # wlan0 存在只说明 net device 建出来了；固件没起来时它也可能在。所以顺带看
  # 驱动有没有真的加载
  has "wlan0 存在"       "wlan0"        "$(odin_ssh 'ls /sys/class/net/ | tr "\n" " "' 2>/dev/null)"
  chk "WiFi 驱动已加载(wcn36xx)" "1" "$(mod_loaded wcn36xx)"
  chk "sshd"            "active"       "$(r 'systemctl is-active ssh')"

  # --- 首启扩容 ---
  # 不能拿 df 的第 2 列含不含 "G" 来判断：镜像本身就是 2 GiB，扩没扩都是 "xG"，
  # 那条判据恒真。直接读 resize 服务自己写的日志，那才是最直接的证据。
  # grep -c 给的是"匹配行数"：日志里有一行 rc=0 才是成功，所以期望值是 1 不是 0
  chk "resize2fs 成功(日志行)" "1"    "$(r 'grep -c "resize2fs rc=0" /var/log/odin-resize.log')"
  chk "扩容标记已落"      "1"            "$(r 'test -f /var/lib/odin-resize-done && echo 1 || echo 0')"
  # 兜底再判一次容量：镜像是 2 GiB，所以"明显大于 2G"才说明真的扩容了
  sz=$(r 'df -h / | tail -1 | awk "{print \$2}"' | tr -d 'G')
  if [ -n "$sz" ] && [ "${sz%.*}" -gt 10 ] 2>/dev/null; then
    ok "  ✅ 根分区容量: ${sz}G（镜像本身 2G，说明已扩容）"; pass=$((pass+1))
  else err "  ❌ 根分区容量: [${sz}G]（镜像本身 2G，未扩容）"; fail=$((fail+1)); fi

  # --- modprobe 是否可用 ---
  # 项目里多处依赖它（重载 wcn36xx、加载 configfs、modules-load.d），缺了不会报错
  # 只会静默失效。真机实测确认过缺 kmod 包，这条就是为了防止它悄悄回来。
  # 注意 /usr/sbin 不在普通用户 PATH 里，直接 command -v modprobe 会漏报。
  # 我们真正在意的是"以 root 运行时能不能调到"，所以带上 sbin 再查。
  has "modprobe 可用"    "modprobe"     "$(r 'PATH=$PATH:/usr/sbin:/sbin command -v modprobe || echo 无')"

  echo
  ok "验收通过 $pass 项，失败 $fail 项"
  [ "$fail" -eq 0 ] || { err "有验收项未通过，救援通道见 reports/018"; exit 1; }
fi

# ---------------------------------------------------------------- 90 handoff
if run 90 && [ "$DRY" = 0 ]; then
  step "90 handoff"
  if [ "$(load_state extlinux_disabled)" = "1" ]; then
    ok "20 阶段为进 fastboot 改过名，新系统自带 /extlinux/extlinux.conf，无需还原"
    save_state extlinux_disabled 0
  fi
  info "登录：ssh ${SSH_USER}@${DEVICE_IP}（密码 ${SSH_PASS}）"
  info "切完整版（带 OTG）：sudo sed -i 's/^default .*/default l0/' /extlinux/extlinux.conf && sudo reboot"
fi

step "完成"
