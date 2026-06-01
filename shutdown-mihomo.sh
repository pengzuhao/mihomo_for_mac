#!/usr/bin/env bash
# Mihomo 停止：按 pid 精确杀核心（不用 killall，避免误伤 / 阻塞弹窗）
set -euo pipefail

SCRIPT_DIR="${HOME}/Desktop/mihomo"
DATA_DIR="${HOME}/.config/mihomo"
# shellcheck source=mihomo-configs.sh
source "${SCRIPT_DIR}/mihomo-configs.sh"
API="http://127.0.0.1:9090"

tun_off_bg() {
  local cfg sec
  local -a auth=()
  cfg=$(cfg_active 2>/dev/null) || true
  sec=""
  if [[ -n "${cfg}" ]]; then
    sec="$(cfg_read_secret "${cfg}")"
  fi
  [[ -n "${sec}" ]] && auth=( -H "Authorization: Bearer ${sec}" )
  curl -sS -m 1 -X PATCH "${auth[@]}" \
    -H "Content-Type: application/json" \
    -d '{"tun":{"enable":false}}' \
    "${API}/configs" >/dev/null 2>&1 &
}

stop_pids() {
  local pid
  local -a pids=()
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] && pids+=("${pid}")
  done < <(mihomo_core_pids)
  [[ ${#pids[@]} -eq 0 ]] && return 0
  kill "${pids[@]}" 2>/dev/null || true
}

if is_mihomo_core_running; then
  tun_off_bg
  stop_pids
  for _ in {1..20}; do
    is_mihomo_core_running || break
    sleep 0.08
  done
fi

if is_mihomo_core_running; then
  sudo -n /usr/bin/killall mihomo 2>/dev/null || true
  for _ in {1..20}; do
    is_mihomo_core_running || break
    sleep 0.08
  done
fi

if is_mihomo_core_running; then
  echo "停止失败。请运行: ~/Desktop/mihomo/install-sudoers.sh 后重试，或在活动监视器结束 mihomo 核心进程" >&2
  exit 1
fi

if [[ -z "${MIHOMO_SILENT_SHUTDOWN:-}" ]]; then
  echo "mihomo 已停止"
fi
