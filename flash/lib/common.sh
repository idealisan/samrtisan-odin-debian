#!/bin/bash
# flash/lib/common.sh — ODIN 刷机/构建脚本的公共函数库。
#
# 用法：各阶段脚本开头 source "$(dirname "$0")/../lib/common.sh"
#
# 这里的每一条默认值都来自实机实测，改之前先看 reports/018：
#   * USB NCM 网卡在 PC 侧的地址由手机上的 dnsmasq 分配，池子只有 172.16.42.2 一个地址
#   * SSH 必须先关掉 pubkey（否则 ssh 先试 publickey，sshpass 的密码永远轮不上）
#   * 真机上没有 adbd，也进不了 fastboot（/sys/kernel/reboot/mode 只收 cold/warm/hard），
#     所以「重启到 fastboot」只能靠按键或"启动失败自动停在 fastboot"
set -u

ODIN_REPO=${ODIN_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)}
FLASH_DIR="$ODIN_REPO/flash"
DIST_DIR="$ODIN_REPO/dist"
EVIDENCE_DIR="$ODIN_REPO/evidence"

# ---------------------------------------------------------------- 网络常量
DEVICE_IP=${ODIN_DEVICE_IP:-172.16.42.1}
PC_IP=${ODIN_PC_IP:-172.16.42.2}
SSH_USER=${ODIN_SSH_USER:-user}
SSH_PASS=${ODIN_SSH_PASS:-user}
SSH_PORT=${ODIN_SSH_PORT:-22}

# ---------------------------------------------------------------- 计时常量
# 用户在 8/29 明确要求：单次命令的等待不要动辄好几分钟。这里的默认值全部按
# "足够但不啰嗦" 取值，个别确实需要长等待的阶段在脚本里显式传入。
T_FASTBOOT=${T_FASTBOOT:-180}   # 等用户按键进 fastboot（要真人操作，给足）
T_USBNET=${T_USBNET:-90}        # 重启后等 PC 上出现 USB 网卡
T_SSH=${T_SSH:-150}             # 等 SSH 端口（首启含 resize2fs，慢）
T_BOOT=${T_BOOT:-60}            # 等 fastboot reboot 后设备从 USB 总线消失

# ---------------------------------------------------------------- 日志
_ts() { date '+[%F %T]'; }
log()  { printf '%s %s\n' "$(_ts)" "$*"; }
info() { printf '%s \033[36minfo\033[0m  %s\n' "$(_ts)" "$*"; }
ok()   { printf '%s \033[32m ok \033[0m  %s\n' "$(_ts)" "$*"; }
warn() { printf '%s \033[33mwarn\033[0m  %s\n' "$(_ts)" "$*" >&2; }
err()  { printf '%s \033[31mFAIL\033[0m  %s\n' "$(_ts)" "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '\n%s \033[1m== %s ==\033[0m\n' "$(_ts)" "$*"; }

# ---------------------------------------------------------------- 通用等待
# wait_until <描述> <总超时秒> <轮询间隔秒> <命令...>
wait_until() {
  local desc=$1 timeout=$2 interval=$3; shift 3
  local waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if "$@" >/dev/null 2>&1; then
      ok "$desc (${waited}s)"
      return 0
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done
  err "$desc 超时 (${timeout}s)"
  return 1
}

# retry <次数> <描述> <命令...>
retry() {
  local n=$1 desc=$2; shift 2
  local i rc
  for i in $(seq 1 "$n"); do
    if "$@"; then return 0; fi
    rc=$?
    warn "$desc 第 $i/$n 次失败 (rc=$rc)，2 秒后重试"
    sleep 2
  done
  err "$desc 连续 $n 次失败"
  return 1
}

# ---------------------------------------------------------------- SSH 封装
# 注意：scp 的端口选项是 -P（大写），ssh 的是 -p（小写）。两者不能共用一套选项，
# 否则 scp 会把 `-p 22` 里的 -p 当成"保留时间戳"、把 22 当成文件名。
_ssh_common() {
  printf '%s ' \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=8 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o LogLevel=ERROR
}

_ssh_opts() { _ssh_common; printf '%s ' -p "$SSH_PORT"; }
_scp_opts() { _ssh_common; printf '%s ' -P "$SSH_PORT"; }

# odin_ssh <命令...>  —— 在真机上跑一条命令（非交互）
odin_ssh() { sshpass -p "$SSH_PASS" ssh $(_ssh_opts) "$SSH_USER@$DEVICE_IP" "$@"; }

# odin_sudo_raw —— 从 stdin 读脚本，在真机上以 root 执行，stdout 原样透出。
#   取二进制数据（如 cat 一个 tar）时用这个，不要走 odin_sudo（那个会过 grep）。
# odin_sudo —— 同上，但把 sudo 的密码回显过滤掉，用于读日志/看输出。
# 注意：/root 是 0700，用 odin_ssh（user 身份）读 /root 下的文件只会得到空结果，
#   曾因此把一份完好的备份误判成"截断"。涉及 /root 一律用 odin_sudo*。
odin_sudo_raw() {
  { echo "$SSH_PASS"; cat; } | sshpass -p "$SSH_PASS" \
    ssh $(_ssh_opts) "$SSH_USER@$DEVICE_IP" "sudo -S -p '' sh -s"
}
odin_sudo() {
  odin_sudo_raw 2>&1 | grep -v '^\[sudo\] password for '
}

# 传文件时失败要看得见原因：原先把 stderr 也吞了，出问题时屏幕上只有一句
# "失败"，却不知道是超时、认证还是路径错（实测踩过一次）。
_scp() { # _scp <方向: get|put> <参数...>
  local dir=$1; shift
  local out rc
  out=$(sshpass -p "$SSH_PASS" scp $(_scp_opts) -r "$@" 2>&1); rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/    scp: /'
  return $rc
}

# odin_scp_get <远端路径> <本地路径>
odin_scp_get() { _scp get "$SSH_USER@$DEVICE_IP:$1" "$2"; }

# odin_scp_put <本地路径> <远端路径>
odin_scp_put() { _scp put "$1" "$SSH_USER@$DEVICE_IP:$2"; }

# device_alive —— SSH 可登录即认为设备在运行 Debian
device_alive() {
  odin_ssh 'exit 0' >/dev/null 2>&1
}

# ---------------------------------------------------------------- fastboot 封装
# fastboot 在 macOS 上是单设备也走 USB，多设备时用 -s 指定
FB=${ODIN_FASTBOOT:-fastboot}
fb() { "$FB" "$@"; }

# in_fastboot —— 有 fastboot 设备且能读到 product
in_fastboot() {
  [ -n "$(fb devices 2>/dev/null | awk 'NR>1 && $2=="fastboot" {print $1; exit}')" ]
}

fb_getvar() { fb getvar "$1" 2>&1 | head -1 | tr -d '\r'; }

# ---------------------------------------------------------------- 主机侧 USB 网卡发现
# macOS 上 USB NCM 网卡表现为新的 enX；这里枚举所有"有链路、非 Wi-Fi"的以太网口
list_usb_nics() {
  local iface
  for iface in $(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -E '^en[0-9]+$'); do
    ifconfig "$iface" 2>/dev/null | grep -q 'status: active' || continue
    echo "$iface"
  done
}

# usb_nic_up —— 是否存在已拿到 172.16.42.x 网段的网卡（说明 PC 与设备已通）
usb_nic_up() {
  local iface
  for iface in $(list_usb_nics); do
    ifconfig "$iface" 2>/dev/null | grep -q "inet ${PC_IP} " && return 0
  done
  return 1
}

# ---------------------------------------------------------------- 依赖检查
need() { command -v "$1" >/dev/null 2>&1 || die "缺少依赖: $1"; }
