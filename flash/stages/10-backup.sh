#!/bin/bash
# 10-backup —— 全量备份真机根文件系统（userdata 已用部分）
#
# ⚠️ 已停用（2026-09-05，用户拍板）：flash-all.sh 不再调用本脚本。
#    停用理由：这是纯测试机，没有要保的数据；而备份本身有害——tar 整个根会把
#    3.5 GiB 内存的页缓存吃满（实测 free 掉到 52 MiB），SSH 直接失联，
#    紧接着的 reboot 命令发不出去，刷机流程卡死在"等 fastboot 超时"。
#    需要备份分区时改用 fastboot 侧的手段，别走正在运行的系统。
#    文件留着是为了保留"为什么不能这么干"的记录，不要照抄它去写新脚本。
#
#   flash/stages/10-backup.sh              在手机上生成备份包（后台跑，只轮询大小）
#   flash/stages/10-backup.sh --status     只看进度，不启动新任务
#   flash/stages/10-backup.sh --fetch      把已生成的备份包拉回主机
#
# 为什么要做：
#   * 刷 userdata 会清空设备全部数据。真机现在跑的是「早期镜像 + 增量部署」的状态，
#     和 dist/ 里的镜像已经 divergent，一旦新镜像有遗漏就回不去了。
#   * 这份 tar 同时是构建新镜像的 staging 基线 —— 真机是唯一「已知能亮屏」的那份，
#     用它能保证新镜像 ≥ 真机状态，而不是拿容器里那份 8/23 的陈旧 /mnt/debian 重建。
#
# 为什么"先在手机上打包、之后再拉回"（2026-08-29 实测）：
#   最初写成 `ssh 设备 tar -cf - / | gzip > 本机`，两次都在 ~14s / ~110MB 处断掉，
#   设备随后 30 秒完全不响应 ping。分离测试后确认不是网络问题——纯流量压测
#   400MB 用 20s 跑完（约 20MB/s）。是设备端 tar 边读边往外吐时 USB NCM 链路会
#   stall。改成 tar 落到设备本地文件后，传输阶段只剩一个顺序大文件拷贝，绕开了
#   这个问题。USB 接在繁忙的 hub 上时尤其要这样走。
#
# 排除的是伪文件系统与运行时挂载点（/proc /sys /dev /run /tmp），
# 它们在 build-image.sh 的干净化阶段也会被清掉，备份没有意义。
set -o pipefail
source "$(dirname "$0")/../lib/common.sh"

# 设备上的备份落点。/root/odin-backup 必须出现在下面的排除表里，
# 否则 tar 会把自己正在写的文件也读进去，无限增长。
RDIR=/root/odin-backup
RFILE="$RDIR/rootfs-full.tar"
RDONE="$RDIR/DONE"
RERR="$RDIR/tar.err"
RPID="$RDIR/tar.pid"

need sshpass
device_alive || die "设备无 SSH 响应（${DEVICE_IP}）——先确认 USB 线连着、PC 已拿到 ${PC_IP}"

mode=${1:-}

case "$mode" in
  --status)
    step "备份进度（设备 ${RFILE}）"
    odin_sudo <<REMOTE 2>&1 | grep -v '^\[sudo\]'
      printf '  文件大小: %s MB\n' \$(( \$(stat -c%s '$RFILE' 2>/dev/null || echo 0) / 1048576 ))
      if [ -f '$RDONE' ]; then echo '  状态: 已完成';
      elif pgrep -f 'tar.*rootfs-full.tar' >/dev/null; then echo '  状态: 进行中';
      else echo '  状态: 未启动/已中断'; fi
      [ -s '$RERR' ] && { echo '  tar stderr:'; tail -5 '$RERR' | sed 's/^/    /'; }
REMOTE
    exit 0
    ;;

  --fetch)
    # 走 HTTP 而不是 ssh cat：
    #   1) HTTP 有正经的流量控制与重试，ssh 把大文件塞进管道时 USB NCM 会 stall
    #      （2026-08-29 实测：ssh 传 900MB 两次都在 ~110MB 处断，设备随即失联 30s）
    #   2) curl -C - 支持断点续传，中途断了不用从头再来
    # 服务只绑 172.16.42.1（usb0 那侧），不会开在 Wi-Fi 上。
    step "把设备上的备份拉回主机（HTTP）"
    OUT=${2:-$EVIDENCE_DIR/live-device-backup/rootfs-full.tar}
    PORT=${ODIN_HTTP_PORT:-8080}
    mkdir -p "$(dirname "$OUT")"
    odin_sudo <<REMOTE 2>/dev/null | grep -q '^READY$' \
      || die "设备上没有就绪的备份（缺 ${RDONE}），先跑一次不带参数的 10-backup.sh"
      [ -f '$RDONE' ] && echo READY
REMOTE

    RSIZE=$(odin_sudo <<REMOTE 2>/dev/null | tail -1
      stat -c%s '$RFILE' 2>/dev/null || echo 0
REMOTE
)
    log "远端备份 ${RSIZE} 字节（$(( RSIZE / 1048576 )) MB）"

    # 先清掉可能残留的实例（上次脚本被打断时会留下），否则新实例起不来、端口被占
    odin_sudo <<REMOTE >/dev/null 2>&1
      pkill -f 'http.server.*$PORT' 2>/dev/null; sleep 1
      cd '$RDIR'
      nohup python3 -m http.server '$PORT' --bind '$DEVICE_IP' >/dev/null 2>&1 &
      echo \$! > '$RDIR/http.pid'
REMOTE
    log "已在设备 ${DEVICE_IP}:${PORT} 起 HTTP 服务"

    t0=$(date +%s)
    # --noproxy '*' 不能省：开发机上普遍设了 http_proxy（本机这个指向 127.0.0.1:3030），
    # curl 会把 172.16.42.1 的请求也发给代理，表现是"TCP 通、curl 却 code=000"。
    curl -C - --noproxy '*' --retry 10 --retry-delay 2 --retry-all-errors \
         -o "$OUT" "http://${DEVICE_IP}:${PORT}/rootfs-full.tar"
    rc=$?

    odin_sudo <<REMOTE >/dev/null 2>&1
      kill \$(cat '$RDIR/http.pid') 2>/dev/null; rm -f '$RDIR/http.pid'
REMOTE
    log "HTTP 服务已关闭"

    if [ "$rc" -eq 0 ]; then
      sz=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")
      [ "$sz" = "$RSIZE" ] \
        && ok "已拉回：${OUT}（$(( sz / 1048576 )) MB，耗时 $(($(date +%s)-t0))s，大小一致）" \
        || warn "拉回完成但大小不符：本地 $sz != 远端 $RSIZE"
    else
      die "下载失败（curl rc=${rc}），已保留部分文件，重跑本命令可断点续传"
    fi
    exit 0
    ;;

  "") : ;;
  *) die "用法: 10-backup.sh [--status|--fetch [本地路径]]" ;;
esac

# ---------------------------------------------------------------- 生成备份（设备本地）
step "在手机上生成全量备份 → 设备 ${RFILE}"
log "采集真机用量快照..."
odin_ssh 'df -h / | tail -1' 2>/dev/null | sed 's/^/  /'

# 用 nohup 起在设备本地，SSH 断掉也不影响；进度靠轮询文件大小看（每次一条 stat，
# 流量可忽略，hub 繁忙时也安全）。不压缩：设备 CPU 慢，且后面拉回时再压也不迟。
odin_sudo <<REMOTE 2>&1 | grep -v '^\[sudo\]'
  mkdir -p '$RDIR'
  rm -f '$RDONE' '$RERR' '$RFILE'
  nohup tar --numeric-owner --xattrs --acls --one-file-system \
      --warning=no-file-changed -C / -cf '$RFILE' \
      --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run \
      --exclude=./tmp --exclude=./var/tmp --exclude=./mnt --exclude=./media \
      --exclude=./lost+found --exclude=./var/lib/misc/dnsmasq.leases \
      --exclude=./root/odin-backup \
      . > '$RDIR/tar.out' 2> '$RERR' &
  echo \$! > '$RPID'
  sleep 1
  echo "  tar 已在后台启动，pid=\$(cat '$RPID')"
REMOTE

log "等待打包完成（每 5s 轮询一次，最多 10 分钟）..."
for i in $(seq 1 120); do
  sleep 5
  # 一次往返同时取回 {是否还在跑} 与 {文件大小}，减少往返次数
  probe=$(odin_sudo <<REMOTE 2>/dev/null | tail -1
      s=\$(stat -c%s '$RFILE' 2>/dev/null || echo 0)
      if pgrep -f 'tar.*rootfs-full.tar' >/dev/null; then r=running; else r=finished; fi
      echo "\$r \$s"
REMOTE
  )
  set -- $probe
  running=${1:-finished}; size=${2:-0}
  printf '  [%s] %5d MB  %s\n' "$(date +%T)" "$(( size / 1048576 ))" "$running"
  [ "$running" = "finished" ] && break
done

# 收尾：回传退出码、落完成标记
odin_sudo <<REMOTE 2>&1 | grep -v '^\[sudo\]' | sed 's/^/  /'
  if pgrep -f 'tar.*rootfs-full.tar' >/dev/null; then
    echo "tar 仍在运行（pid \$(cat '$RPID')），未落完成标记"
  else
    # tar 退出码 1 = "读取期间文件被改动"，对运行中的系统属正常
    if [ -f '$RFILE' ] && tar -tf '$RFILE' >/dev/null 2>&1; then
      touch '$RDONE'
      echo "归档可读，已落完成标记 $RDONE"
    else
      echo "归档校验失败，不落标记"
    fi
    printf 'size = %s bytes\n' \$(stat -c%s '$RFILE' 2>/dev/null || echo 0)
  fi
  [ -s '$RERR' ] && { echo '--- tar stderr ---'; tail -10 '$RERR'; }
REMOTE

# 自校验：在设备上列一遍归档（只在设备内部跑，不传数据回主机）
# 注意路径在 /root 下（0700），必须用 odin_sudo，用 odin_ssh 会静默得到空结果。
log "设备侧自校验关键条目..."
n=$(odin_sudo <<REMOTE 2>/dev/null | tail -1
      tar -tf '$RFILE' 2>/dev/null | wc -l
REMOTE
)
n=$(printf '%s' "$n" | tr -d ' ')
if [ -n "$n" ] && [ "$n" -gt 10000 ]; then
  ok "归档可读，条目数 $n"
else
  warn "归档条目数异常（${n:-空}），可能截断"
fi
MISSING=$(odin_sudo <<REMOTE 2>/dev/null
      for p in ./extlinux/extlinux.conf ./boot/vmlinuz ./boot/initramfs.cpio.gz \
               ./usr/local/sbin/odin-usb-role.sh ./etc/fstab; do
        tar -tf '$RFILE' 2>/dev/null | grep -qx "\$p" || echo "\$p"
      done
REMOTE
)
if [ -z "$MISSING" ]; then
  ok "关键条目齐全"
else
  printf '%s\n' "$MISSING" | sed 's/^/  缺 /' >&2
  warn "归档缺少上述条目"
fi

ok "设备上的备份就绪：$RFILE"
info "稍后 USB 直连时执行：flash/stages/10-backup.sh --fetch"
