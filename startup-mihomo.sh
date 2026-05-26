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

# 只靠 is_mihomo_core_running 会认为「已在跑」而跳过拉起，若误判（ps 撞到其它命令行含同一路径片段）则会「有图标/无端口」。
api_panel_reachable() {
  curl -sS -m 2 -o /dev/null "${API_ROOT}/" >/dev/null 2>&1
}

CONFIG_NAME=$(cfg_active)
CONFIG="${DATA_DIR}/${CONFIG_NAME}"

if [[ "${1:-}" == "restart" ]]; then
  "${SCRIPT_DIR}/shutdown-mihomo.sh" || true
  for ((i = 0; i < 25; i++)); do
    is_mihomo_core_running || break
    sleep "${POLL}"
  done
fi

if is_mihomo_core_running; then
  # 等新进程留出监听窗口；总等待约 15s，避免慢机/大配置误判为僵尸
  for ((w = 0; w < 100; w++)); do
    if api_panel_reachable; then
      echo "mihomo 已在运行"
      exit 0
    fi
    sleep 0.15
  done
  echo "检测到占位进程但面板不可达 (${API_ROOT})，尝试关闭后重启…" >&2
  "${SCRIPT_DIR}/shutdown-mihomo.sh" || true
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

for ((i = 0; i < 25; i++)); do
  if is_mihomo_core_running; then
    echo "mihomo 已启动"
    echo "配置: ${CONFIG_NAME}"
    echo "面板: http://127.0.0.1:9090/ui/"
    exit 0
  fi
  sleep "${POLL}"
done

echo "启动失败，查看 ${LOG}" >&2
exit 1
