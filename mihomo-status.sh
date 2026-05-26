#!/usr/bin/env bash
# 输出: off | tun | tun:ss-s | proxy:ss-s | tun:cfg-a ...
set -euo pipefail

SCRIPT_DIR="${HOME}/Desktop/mihomo"
DATA_DIR="${HOME}/.config/mihomo"
MIHOMO_BIN="${DATA_DIR}/mihomo"
STATE_FILE="${DATA_DIR}/.switch-on"

# shellcheck source=mihomo-configs.sh
source "${SCRIPT_DIR}/mihomo-configs.sh"

state_line() {
  local mode="$1"
  local stem
  stem=$(cfg_stem "$(cfg_active)")
  echo "${mode}:${stem}"
}

if [[ -f "${STATE_FILE}" ]]; then
  raw=""
  IFS= read -r raw < "${STATE_FILE}" || raw=""
  raw="${raw//$'\r'/}"
  raw="${raw//$'\n'/}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  if [[ "${raw}" == "off" ]]; then
    # 文件曾被纠成 off，但实际核心仍在（例如装脚本自动 on、或手工起核）→ 勿报 off，否则菜单永远灰且与 TUN 矛盾
    if is_mihomo_core_running; then
      state_line "tun"
      exit 0
    fi
    echo "off"
    exit 0
  fi
  # 状态文件仍为开启，但内核已退出 → 输出 off，避免菜单/Hammerspoon 与 pgrep 不一致
  if ! is_mihomo_core_running; then
    echo "off"
    exit 0
  fi
  if [[ "${raw}" == *:* ]]; then
    echo "${raw}"
    exit 0
  fi
  if [[ "${raw}" == "tun" || "${raw}" == "proxy" ]]; then
    state_line "${raw}"
    exit 0
  fi
fi

if ! is_mihomo_core_running; then
  echo "off"
  exit 0
fi

state_line "tun"
