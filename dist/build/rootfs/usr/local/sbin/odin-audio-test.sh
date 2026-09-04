#!/bin/bash
# odin-audio-test.sh —— ODIN（U2 Pro）音频通路人工验收
#
#   用法：  bash /usr/local/sbin/odin-audio-test.sh          # 交互菜单
#           bash /usr/local/sbin/odin-audio-test.sh speaker  # 只跑一项
#           （speaker / music / earpiece / emic / mic / vol / status）
#           也可以直接敲 odin-audio-test.sh（在 /usr/local/sbin 里，PATH 上有）
#
# 为什么要人工跑：脚本/内核只能证明"电路打通了"（DAPM 全 On、功放使能脚拉高），
# 证明不了"扬声器真的响了"。这一步只能靠耳朵。
#
# 控件名一律用 **cset 认的原始名**（不是 amixer scontrols 显示的简化名）：
#     SPK DAC Switch / RX3 Digital Volume / Ext Spk Switch / Earpiece Switch / EAR_S
# 详见 /usr/share/alsa/ucm2/Qualcomm/msm8953-odin/HiFi.conf 的文件头。
#
# ⚠️ 需要 root（/dev/snd/* 是 root:audio 660，当前镜像里 user 还没进 audio 组）。
#    脚本会自己检测并用 sudo 重跑。
#
# 关于测试音乐 $WAV：
#     **不随镜像分发**（有版权，也不该进版本库）。重刷之后 /home/user/music/
#     会被清空，放音乐会退化成 3 秒提示音。想听真音乐就自己放一个进去：
#         scp 某首歌.mp3 user@手机:/tmp/
#         ssh user@手机 "ffmpeg -i /tmp/某首歌.mp3 -t 30 -ar 48000 -ac 2 \
#                        -c:a pcm_s16le /home/user/music/warm-30s.wav"
#     或者在本机转好再传（手机里没有 ffmpeg）。必须是 48k / S16_LE，
#     因为后端把格式钉死在 48000 Hz / 2 声道 / S16_LE。
set -u

C=0                       # 声卡号
WAV=/home/user/music/warm-30s.wav     # 《暖暖》前 30 秒，48k/立体声/S16
#
# ⚠️ RXn Digital Volume 的刻度是 **min=0 max=124，84 = 0 dB，1 dB/档**。
#    它不是百分比！填 30 不是"30%"，是 **−54 dB** —— 扬声器还能勉强听见，
#    听筒直接就没声了（听筒贴耳朵听、响度本就低得多，需要比扬声器**更大**的
#    数字增益）。所以扬声器与听筒**必须各自独立保存音量**，不能共用一个值。
VOL=${VOL:-100}           # 扬声器：100 = +16 dB
EVOL=${EVOL:-100}         # 听筒：同样 +16 dB（实测可用）
LOG=/home/user/audio-test.log

db() { printf '%+d dB' $(( $1 - 84 )); }   # 数字音量 → dB，显示用

# ---------------------------------------------------------------- root 检查
if [ "$(id -u)" -ne 0 ]; then
	exec sudo VOL="$VOL" bash "$0" "$@"
fi

say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

log()  { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }

cset() { amixer -c "$C" cset name="$1" "$2" >/dev/null 2>&1 \
         || warn "cset $1 = $2 失败"; }

ask() { # ask <问题>  → 回答进 REPLY
	printf '\n\033[1m%s\033[0m [y/N] ' "$1"
	read -r REPLY || REPLY=n
	log "问：$1  答：${REPLY:-n}"
}

# ---------------------------------------------------------------- 通路开关
spk_on() {
	cset 'PRI_MI2S_RX Audio Mixer MultiMedia1' 1
	cset 'RX3 MIX1 INP1' RX1
	cset 'RX3 Digital Volume' "$VOL"
	## 扬声器（大喇叭）走 LINEOUT，不是 SPK_OUT：
	##   PDM_RX3 → LINEOUT DAC → LINEOUT(mux) → LINEOUT PA → LINEOUT_OUT → AW 功放
	## 外置功放是 AW87318 一类，MODE 脚要打 6 个脉冲才开机（DTS 里 awinic,aw8738
	## + awinic,mode = <6>），这个脚本不用管，驱动在 POST_PMU 自己会打。
	cset 'LINEOUT' Switch
	cset 'Ext Spk Switch' on
	cset 'Earpiece Switch' off
	cset 'EAR_S' ZERO
	cset 'RX1 MIX1 INP1' ZERO
}
ear_on() {
	cset 'PRI_MI2S_RX Audio Mixer MultiMedia1' 1
	cset 'RX1 MIX1 INP1' RX1
	cset 'RX1 Digital Volume' "$EVOL"
	cset 'EAR_S' Switch
	cset 'Earpiece Switch' on
	cset 'Ext Spk Switch' off
	cset 'LINEOUT' ZERO
	cset 'RX3 MIX1 INP1' ZERO
}
tone() {   # tone <秒数描述>
	speaker-test -D hw:0,"$C" -c 2 -r 48000 -F S16_LE -t sine -f 1000 -l 1 >/dev/null 2>&1
}
playwav() {
	if [ -f "$WAV" ]; then
		aplay -D hw:0,0 "$WAV" >/dev/null 2>&1
	else
		warn "找不到 $WAV（重刷后 /home/user/music 会被清空，音乐不随镜像分发）"
		warn "改播 3 秒 1 kHz 提示音。想听真音乐请看脚本头部的说明补一个 WAV。"
		tone
	fi
}

# ---------------------------------------------------------------- 各项测试
t_speaker() {
	hdr "扬声器：3 秒 1 kHz 提示音（数字音量 $VOL = $(db "$VOL")）"
	spk_on
	say "  放音中……"
	tone
	ask "扬声器听到蜂鸣了吗？"
}
t_music() {
	hdr "扬声器：播放《暖暖》前 30 秒（数字音量 $VOL = $(db "$VOL")）"
	spk_on
	say "  播放中（30 秒，Ctrl-C 可中断）……"
	playwav
	ask "扬声器播出音乐了吗？"
}
t_earpiece() {
	hdr "听筒：3 秒 1 kHz 提示音（数字音量 $EVOL = $(db "$EVOL")，请把耳朵贴到听筒上）"
	ear_on
	say "  放音中……"
	tone
	ask "听筒听到蜂鸣了吗？"
}
t_emusic() {
	hdr "听筒：播放《暖暖》前 30 秒（数字音量 $EVOL = $(db "$EVOL")，请贴耳朵）"
	ear_on
	say "  播放中（30 秒，Ctrl-C 可中断）……"
	playwav
	ask "听筒播出音乐了吗？"
}
t_mic() {
	hdr "麦克风：录 6 秒后从扬声器回放"
	# 采集链：AMIC1 → ADC1 → DEC1 → Tertiary MI2S → MultiMedia2
	cset 'MultiMedia2 Mixer TERT_MI2S_TX' 1
	cset 'DEC1 MUX' ADC1
	cset 'CIC1 MUX' AMIC
	cset 'ADC1 Volume' 8
	local f=/tmp/mic-test.wav
	rm -f "$f"
	say "  请对着手机下方（麦克风孔）说话，录 6 秒……"
	arecord -D hw:0,1 -f S16_LE -r 48000 -c 1 -d 6 "$f" >/dev/null 2>&1
	if [ ! -s "$f" ]; then
		warn "没录到文件，采集失败"
		return
	fi
	local rms
	rms=$(od -An -td2 -v "$f" | tr -s ' ' '\n' | grep -v '^$' \
	      | awk '{ s += $1*$1; n++ } END { if (n) printf "%.0f", sqrt(s/n) }')
	say "  录音 $(( $(stat -c%s "$f") / 96000 )) 秒，RMS ≈ $rms（本底约 1~2）"
	if [ "${rms:-0}" -le 5 ]; then
		warn "能量接近本底，可能没收到声音"
	fi
	say "  现在从扬声器回放……"
	spk_on
	aplay -D hw:0,0 "$f" >/dev/null 2>&1
	ask "听到自己的录音了吗？"
}
t_vol() {
	hdr "调数字音量（84 = 0 dB，1 dB/档，0~124）"
	say "  注意：这不是百分比。低于 84 就是负增益，"
	say "  听筒会比扬声器先听不见（听筒本来响度就低得多）。"
	printf '\n  1) 扬声器  当前 %s（%s）\n' "$VOL" "$(db "$VOL")"
	printf '  2) 听筒    当前 %s（%s）\n' "$EVOL" "$(db "$EVOL")"
	printf '  选 1/2（直接回车返回）：'
	read -r which || which=
	case "$which" in
		1) prompt='扬声器'; cur=$VOL ;;
		2) prompt='听筒';   cur=$EVOL ;;
		*) return ;;
	esac
	printf '  %s 新音量（当前 %s = %s，直接回车不改）：' "$prompt" "$cur" "$(db "$cur")"
	read -r v || v=
	if [ -n "${v:-}" ]; then
		case "$v" in
			*[!0-9]*) warn "不是数字，忽略" ;;
			*)
				if [ "$v" -gt 124 ]; then v=124; fi
				if [ "$which" = 1 ]; then VOL=$v; else EVOL=$v; fi
				ok "$prompt 已设为 $v（$(db "$v")）"
				log "调音量：$prompt = $v（$(db "$v")）"
				;;
		esac
	fi
}

t_status() {
	hdr "当前状态"
	say "--- 声卡 ---"; cat /proc/asound/cards
	say "--- 播放 PCM ---"; aplay -l 2>&1 | grep device
	say "--- 采集 PCM ---"; arecord -l 2>&1 | grep device
	say "--- 关键控件 ---"
	# 注意：这里必须用 `cget name=`，不能用 `sget`。两者认的名字不一样 ——
	# cset/cget name= 用原始元素名（SPK DAC Switch），sget/sset 用 simple 层
	# 剥过后缀的名字（SPK DAC）。混用会显示成空白，看着像控件不存在。
	#
	# 但 cget 对枚举只给下标（values=3），所以再把下标翻成项名（values=3 → RX1）。
	for n in 'PRI_MI2S_RX Audio Mixer MultiMedia1' 'RX3 MIX1 INP1' \
	         'RX3 Digital Volume' 'LINEOUT' 'Ext Spk Switch' \
	         'RX1 MIX1 INP1' 'RX1 Digital Volume' 'EAR_S' 'Earpiece Switch' \
	         'MultiMedia2 Mixer TERT_MI2S_TX' 'DEC1 MUX' 'CIC1 MUX' 'ADC1 Volume'; do
		info=$(amixer -c "$C" cget name="$n" 2>/dev/null)
		v=$(printf '%s\n' "$info" | grep -E '^  : values' | head -1 | sed 's/^  : //')
		idx=${v#values=}
		it=$(printf '%s\n' "$info" | grep -E "^  ; Item #$idx " | head -1 \
		     | sed "s/.*'\(.*\)'.*/\1/")
		[ -n "$it" ] && v="$v ($it)"
		## RXn Digital Volume 是整数，单看数字看不出大小，附上 dB
		case "$n" in
			'RX3 Digital Volume') v="$v  [$(db "${v#values=}")]" ;;
			'RX1 Digital Volume') v="$v  [$(db "${v#values=}")]" ;;
		esac
		printf '  %-40s %s\n' "$n" "$v"
	done
	say "--- 功放使能脚 GPIO 132 ---"
	grep 'gpio132' /sys/kernel/debug/gpio 2>/dev/null || say "  (读不到 debugfs)"
	say "--- ADSP ---"
	for d in /sys/class/remoteproc/remoteproc*; do
		echo "  $d: $(cat "$d/name" 2>/dev/null) = $(cat "$d/state" 2>/dev/null)"
	done
}

# ---------------------------------------------------------------- 主流程
log "==== 开始一轮音频验收 ===="

case "${1:-}" in
	speaker)  t_speaker;  exit 0 ;;
	music)    t_music;    exit 0 ;;
	earpiece) t_earpiece; exit 0 ;;
	emic)     t_emusic;   exit 0 ;;
	mic)      t_mic;      exit 0 ;;
	vol)      t_vol;      exit 0 ;;
	status)   t_status;   exit 0 ;;
esac

cat <<'BANNER'
╔══════════════════════════════════════════════════════════╗
║  ODIN 音频通路人工验收                                    ║
║  每一项放完音后回答 y/N，回答会记进 ~/audio-test.log      ║
╚══════════════════════════════════════════════════════════╝
BANNER
t_status

while true; do
	printf '\n\033[1m选择\033[0m  1)扬声器提示音  2)扬声器放音乐  3)听筒提示音  4)听筒放音乐\n'
	printf '      5)麦克风录放  6)调音量(扬声器 %s / 听筒 %s)  7)看状态  0)退出\n' \
		"$VOL" "$EVOL"
	printf '> '
	read -r sel || sel=0
	log "选择：$sel"
	case "$sel" in
		1) t_speaker  ;;
		2) t_music    ;;
		3) t_earpiece ;;
		4) t_emusic   ;;
		5) t_mic      ;;
		6) t_vol      ;;
		7) t_status   ;;
		0|q|Q) break  ;;
		*) warn "不认识的选项" ;;
	esac
done

hdr "收工"
say "  回答记录：$LOG"
log "==== 本轮结束 ===="
