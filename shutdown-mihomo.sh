#!/usr/bin/env bash
# Mihomo 停止（先杀进程，API 关 TUN 放后台，避免卡住）
set -euo pipefail

SCRIPT_DIR="${HOME}/Desktop/mihomo"
DATA_DIR="${HOME}/.config/mihomo"
MIHOMO_BIN="${DATA_DIR}/mihomo"
# shellcheck source=mihomo-configs.sh
source "${SCRIPT_DIR}/mihomo-configs.sh"
API="http://127.0.0.1:9090"
KILLALL="/usr/bin/killall"

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

if is_mihomo_core_running; then
  tun_off_bg
  killall mihomo 2>/dev/null || true
  for _ in {1..15}; do
    is_mihomo_core_running || break
    sleep 0.08
  done
fi

if is_mihomo_core_running; then
  if sudo -n "${KILLALL}" mihomo 2>/dev/null; then
    for _ in {1..15}; do
      is_mihomo_core_running || break
      sleep 0.08
    done
  fi
fi

if is_mihomo_core_running; then
  osascript -e 'do shell script "killall mihomo 2>/dev/null || true" with administrator privileges' 2>/dev/null || true
  for _ in {1..15}; do
    is_mihomo_core_running || break
    sleep 0.08
  done
fi

if is_mihomo_core_running; then
  echo "停止失败。请运行: ~/Desktop/mihomo/install-sudoers.sh" >&2
  exit 1
fi

if [[ -z "${MIHOMO_SILENT_SHUTDOWN:-}" ]]; then
  echo "mihomo 已停止"
fi
