#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="${HOME}/Desktop/mihomo"
HS_INIT="${HOME}/.hammerspoon/init.lua"

ln -sf "${SCRIPT_DIR}/hammerspoon-init.lua" "${HS_INIT}"
chmod +x "${SCRIPT_DIR}/mihomo-control.sh"
chmod +x "${SCRIPT_DIR}/startup-mihomo.sh"
chmod +x "${SCRIPT_DIR}/shutdown-mihomo.sh"
chmod +x "${SCRIPT_DIR}/mihomo-configs.sh"
chmod +x "${SCRIPT_DIR}/mihomo-status.sh"

# shellcheck source=mihomo-configs.sh
source "${SCRIPT_DIR}/mihomo-configs.sh"

killall Hammerspoon 2>/dev/null || true
sleep 1
open -a Hammerspoon
sleep 2

# 核心启停交给 ⌃⌥⌘M / 菜单 / mihomo-control.sh；此处默认不拉起进程。
# 若仍希望「装完即启动」（旧行为）：MIHOMO_AUTO_START=1 ./install-hotkeys.sh
echo ""
if [[ "${MIHOMO_AUTO_START:-}" == 1 ]]; then
  echo "MIHOMO_AUTO_START=1：正在启动 mihomo 核心（等同 mihomo-control.sh on）…"
  if MIHOMO_SILENT=1 "${SCRIPT_DIR}/mihomo-control.sh" on; then
    :
  else
    echo "WARN: mihomo 启动失败，请查看 ~/.config/mihomo/mihomo.log" >&2
  fi
  sleep 0.8
  if is_mihomo_core_running; then
    echo "校验：已发现 ~/.config/mihomo/mihomo 进程。"
  else
    echo "WARN: 未发现 mihomo 核心进程（请按 ⌃⌥⌘M 或手动：${SCRIPT_DIR}/mihomo-control.sh on）" >&2
  fi
else
  echo "未自动启动核心（默认）。请按 ⌃⌥⌘ M 显示图标并开 TUN，或执行： ${SCRIPT_DIR}/mihomo-control.sh on"
  if [[ "${MIHOMO_SKIP_START:-}" == 1 ]]; then
    echo "（MIHOMO_SKIP_START=1 已无需再设：默认即不启动；仅提示兼容旧说明）"
  fi
fi

echo ""
echo "Hammerspoon 已配置；⌃⌥⌘ M：**开核心 + 显示图标** / **关核心 + 隐藏图标**。"
echo ""
echo "  Ctrl+Opt+Cmd+M  global: show icon + start TUN / stop + hide icon"
echo "  Ctrl+Opt+Cmd+L  global: switch cfg (only while mihomo running)"
echo "  click icon      menu: TUN / 关闭 / 退出"
echo ""
