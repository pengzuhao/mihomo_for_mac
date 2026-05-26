#!/usr/bin/env bash
# 一次性安装：关闭 mihomo 时免密 sudo killall（方案 2）
set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/mihomo"
USER_NAME="$(whoami)"
KILLALL="/usr/bin/killall"

if [[ ! -x "${KILLALL}" ]]; then
  echo "未找到 ${KILLALL}" >&2
  exit 1
fi

CONTENT="${USER_NAME} ALL=(root) NOPASSWD: ${KILLALL} mihomo"

echo "将写入 ${SUDOERS_FILE}："
echo "  ${CONTENT}"
echo ""
echo "（需要输入一次本机管理员密码）"

TMP="$(mktemp)"
echo "${CONTENT}" >"${TMP}"
chmod 440 "${TMP}"

sudo cp "${TMP}" "${SUDOERS_FILE}"
rm -f "${TMP}"
sudo chmod 440 "${SUDOERS_FILE}"

if sudo visudo -cf "${SUDOERS_FILE}" 2>/dev/null; then
  echo ""
  echo "安装成功。关闭 mihomo 将不再弹管理员密码。"
  echo "验证: sudo -n ${KILLALL} mihomo  # 无进程时应无输出"
else
  echo "sudoers 校验失败，已删除" >&2
  sudo rm -f "${SUDOERS_FILE}"
  exit 1
fi
