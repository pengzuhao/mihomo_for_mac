#!/usr/bin/env bash
# Mihomo 启动（配置见 mihomo-configs.sh / .active-config）
set -euo pipefail

SCRIPT_DIR="${HOME}/Desktop/mihomo"
DATA_DIR="${HOME}/.config/mihomo"
MIHOMO_BIN="${DATA_DIR}/mihomo"
LOG="${DATA_DIR}/mihomo.log"
API_ROOT="http://127.0.0.1:9090"
POLL=0.12

# shellcheck source=mihomo-configs.sh
source "${SCRIPT_DIR}/mihomo-configs.sh"

if [[ ! -x "${MIHOMO_BIN}" ]]; then
  echo "mihomo 不存在: ${MIHOMO_BIN}" >&2
  exit 1
fi

api_panel_reachable() {
  local sec code
  local -a auth=()
  sec=$(cfg_read_secret "$(cfg_active)")
  [[ -n "${sec}" ]] && auth=( -H "Authorization: Bearer ${sec}" )
  code=$(curl -sS -m 1 "${auth[@]}" -o /dev/null -w '%{http_code}' "${API_ROOT}/" 2>/dev/null) || code=000
  [[ "${code}" != "000" ]]
}

startup_ok() {
  is_mihomo_core_running && api_panel_reachable
}

CONFIG_NAME=$(cfg_active)
CONFIG="${DATA_DIR}/${CONFIG_NAME}"

if [[ "${1:-}" == "restart" ]]; then
  MIHOMO_SILENT_SHUTDOWN=1 "${SCRIPT_DIR}/shutdown-mihomo.sh" || true
  for ((i = 0; i < 25; i++)); do
    is_mihomo_core_running || break
    sleep "${POLL}"
  done
fi

if is_mihomo_core_running; then
  if startup_ok; then
    echo "mihomo 已在运行"
    exit 0
  fi
  echo "检测到占位进程但面板不可达 (${API_ROOT})，尝试关闭后重启…" >&2
  MIHOMO_SILENT_SHUTDOWN=1 "${SCRIPT_DIR}/shutdown-mihomo.sh" || true
  for ((i = 0; i < 25; i++)); do
    is_mihomo_core_running || break
    sleep "${POLL}"
  done
  if is_mihomo_core_running; then
    echo "清理旧进程失败，请检查活动监视器或 install-sudoers" >&2
    exit 1
  fi
fi

cfg_set_active "${CONFIG_NAME}"
nohup "${MIHOMO_BIN}" -f "${CONFIG}" -d "${DATA_DIR}" >>"${LOG}" 2>&1 &

for ((i = 0; i < 50; i++)); do
  if startup_ok; then
    echo "mihomo 已启动"
    echo "配置: ${CONFIG_NAME}"
    echo "面板: http://127.0.0.1:9090/ui/"
    exit 0
  fi
  sleep "${POLL}"
done

echo "启动失败，查看 ${LOG}" >&2
MIHOMO_SILENT_SHUTDOWN=1 "${SCRIPT_DIR}/shutdown-mihomo.sh" || true
exit 1
