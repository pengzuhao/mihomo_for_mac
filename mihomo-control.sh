#!/usr/bin/env bash
# Mihomo 统一控制（脚本在 Desktop，数据在 ~/.config/mihomo）
set -euo pipefail

SCRIPT_DIR="${HOME}/Desktop/mihomo"
DATA_DIR="${HOME}/.config/mihomo"
MIHOMO_BIN="${DATA_DIR}/mihomo"
API="http://127.0.0.1:9090"
PROXY_HOST="127.0.0.1"
PROXY_PORT="7890"
STATE_FILE="${DATA_DIR}/.switch-on"

# shellcheck source=mihomo-configs.sh
source "${SCRIPT_DIR}/mihomo-configs.sh"

network_service() {
  local iface svc
  iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  svc=$(networksetup -listallhardwareports 2>/dev/null | awk -v iface="$iface" '
    /Hardware Port:/ { port=$0; sub(/^Hardware Port: /, "", port) }
    /^Device:/ && $2==iface { print port; exit }
  ')
  if [[ -n "${svc}" ]]; then
    echo "${svc}"
    return
  fi
  if networksetup -listallnetworkservices 2>/dev/null | grep -qx "Wi-Fi"; then
    echo "Wi-Fi"
    return
  fi
  networksetup -listallnetworkservices 2>/dev/null | grep -v '^\*' | head -1
}

proxy_on() {
  local svc
  svc=$(network_service)
  networksetup -setwebproxy "${svc}" "${PROXY_HOST}" "${PROXY_PORT}"
  networksetup -setsecurewebproxy "${svc}" "${PROXY_HOST}" "${PROXY_PORT}"
  networksetup -setsocksfirewallproxy "${svc}" "${PROXY_HOST}" "${PROXY_PORT}"
  networksetup -setwebproxystate "${svc}" on
  networksetup -setsecurewebproxystate "${svc}" on
  networksetup -setsocksfirewallproxystate "${svc}" on
}

proxy_off() {
  local svc
  svc=$(network_service)
  networksetup -setwebproxystate "${svc}" off
  networksetup -setsecurewebproxystate "${svc}" off
  networksetup -setsocksfirewallproxystate "${svc}" off
}

is_running() {
  is_mihomo_core_running
}

wait_running() {
  local i
  for ((i = 0; i < 40; i++)); do
    is_running && return 0
    sleep 0.15
  done
  return 1
}

# 仅当 yaml 中 `secret` 非空时附带 Bearer；绑定 127.0.0.1 且空 secret 时核心通常不校验。
_curl_with_api_auth() {
  local sec="$1"
  shift
  local -a auth=()
  [[ -n "${sec}" ]] && auth=( -H "Authorization: Bearer ${sec}" )
  curl -sS "${auth[@]}" "$@"
}

secret_for() {
  cfg_read_secret "${1}"
}

state_mode() {
  local mode="$1"
  echo "${mode}:$(cfg_stem "$(cfg_active)")"
}

write_state() {
  echo "$1" >"${STATE_FILE}"
}

read_state_mode() {
  if [[ ! -f "${STATE_FILE}" ]]; then
    echo ""
    return
  fi
  local raw
  raw=$(<"${STATE_FILE}")
  raw="${raw//$'\r'/}"
  raw="${raw//$'\n'/}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  if [[ "${raw}" == *:* ]]; then
    echo "${raw%%:*}"
  else
    echo "${raw}"
  fi
}

tun_label() {
  echo "TUN-$(cfg_stem "$(cfg_active)")"
}

# load：先用运行中进程 secret 鉴权 PUT；tun：先用目标配置 secret（热切换后内存已是新配置）
api_secrets_collect() {
  local mode="$1"
  local cfg="$2"
  local running_cfg="${3:-}"
  local sec_cfg sec_run seen=""
  sec_cfg=$(secret_for "${cfg}")
  sec_run=""
  if [[ -n "${running_cfg}" ]]; then
    sec_run=$(secret_for "${running_cfg}")
  fi
  if [[ "${mode}" == "load" ]]; then
    if [[ -n "${running_cfg}" ]]; then
      [[ "${sec_run}" != "${seen}" ]] && echo "${sec_run}" && seen="${sec_run}"
    fi
    [[ "${sec_cfg}" != "${seen}" ]] && echo "${sec_cfg}"
  else
    [[ "${sec_cfg}" != "${seen}" ]] && echo "${sec_cfg}" && seen="${sec_cfg}"
    if [[ -n "${running_cfg}" && "${running_cfg}" != "${cfg}" ]]; then
      [[ "${sec_run}" != "${seen}" ]] && echo "${sec_run}"
    fi
  fi
}

api_tun_is_enabled() {
  local cfg="$1"
  local running_cfg="${2:-}"
  local secret body
  while IFS= read -r secret || [[ -n "${secret:-}" ]]; do
    [[ -z "${secret}" ]] && continue
    body=$(_curl_with_api_auth "${secret}" -m 2 "${API}/configs" 2>/dev/null) || continue
    if echo "${body}" | grep -qE '"tun"[[:space:]]*:[[:space:]]*\{[^}]*"enable"[[:space:]]*:[[:space:]]*true'; then
      return 0
    fi
  done < <(api_secrets_collect tun "${cfg}" "${running_cfg}")
  return 1
}

api_tun_enable() {
  local cfg="${1:-$(cfg_active)}"
  local running_cfg="${2:-}"
  if api_tun_is_enabled "${cfg}" "${running_cfg}"; then
    return 0
  fi
  local secret code
  while IFS= read -r secret || [[ -n "${secret:-}" ]]; do
    [[ -z "${secret}" ]] && continue
    code=$(_curl_with_api_auth "${secret}" -m 3 -o /dev/null -w '%{http_code}' -X PATCH \
      -H "Content-Type: application/json" \
      -d '{"tun":{"enable":true,"stack":"gvisor","auto-route":true,"auto-detect-interface":true,"dns-hijack":["any:53"]}}' \
      "${API}/configs" 2>/dev/null) || continue
    if [[ "${code}" == "200" || "${code}" == "204" ]]; then
      return 0
    fi
  done < <(api_secrets_collect tun "${cfg}" "${running_cfg}")
  return 1
}

load_config_api() {
  local cfg="$1"
  local running_cfg="${2:-}"
  local path="${DATA_DIR}/${cfg}"
  local secret code
  local timeout="${MIHOMO_LOAD_CFG_TIMEOUT:-30}"
  while IFS= read -r secret || [[ -n "${secret:-}" ]]; do
    [[ -z "${secret}" ]] && continue
    code=$(_curl_with_api_auth "${secret}" -m "${timeout}" -o /dev/null -w '%{http_code}' -X PUT \
      -H "Content-Type: application/json" \
      -d "{\"path\":\"${path}\"}" \
      "${API}/configs?force=true" 2>/dev/null) || continue
    if [[ "${code}" == "200" || "${code}" == "204" ]]; then
      cfg_set_active "${cfg}"
      return 0
    fi
  done < <(api_secrets_collect load "${cfg}" "${running_cfg}")
  return 1
}

reload_config_restart() {
  local cfg="$1"
  cfg_set_active "${cfg}"
  "${SCRIPT_DIR}/startup-mihomo.sh" restart
  wait_running || return 1
}

force_stop() {
  # 先关系统代理再写状态：此前若先 write_state off，force_stop 读到 mode 已不是 proxy → 不关代理 → 指向 7890 断网
  proxy_off || true
  write_state "off"
  if ! is_running; then
    return 0
  fi
  "${SCRIPT_DIR}/shutdown-mihomo.sh" || true
  if is_running; then
    echo "停止失败（请用活动监视器核对 ${MIHOMO_BIN}）" >&2
    return 1
  fi
  write_state "off"
}

cmd_on() {
  "${SCRIPT_DIR}/startup-mihomo.sh"
  wait_running || {
    echo "启动失败" >&2
    exit 1
  }

  if [[ -f "${STATE_FILE}" ]] && [[ "$(read_state_mode)" == "proxy" ]]; then
    proxy_off || true
  fi

  local cfg_on
  cfg_on=$(cfg_active)

  # 配置已写 tun.enable: true 时，核心启动即挂 TUN；勿在 9090 未就绪时 PATCH/误关 TUN
  if cfg_tun_enabled_in_file "${cfg_on}"; then
    write_state "$(state_mode tun)"
    echo "已开启 $(tun_label)"
    return 0
  fi

  if api_tun_enable "${cfg_on}"; then
    write_state "$(state_mode tun)"
    echo "已开启 $(tun_label)"
    return 0
  fi

  if api_tun_is_enabled "${cfg_on}"; then
    write_state "$(state_mode tun)"
    echo "已开启 $(tun_label)"
    return 0
  fi

  local secret
  secret=$(secret_for "$(cfg_active)")
  _curl_with_api_auth "${secret}" -m 2 -X PATCH \
    -H "Content-Type: application/json" \
    -d '{"tun":{"enable":false}}' \
    "${API}/configs" >/dev/null 2>&1 || true
  proxy_on || true
  write_state "$(state_mode proxy)"
  echo "TUN 不可用，已改用系统代理"
}

cmd_off() {
  if ! is_running; then
    write_state "off"
    proxy_off || true
    echo "mihomo 已关闭"
    return 0
  fi
  force_stop
  echo "mihomo 已关闭"
}

cmd_clear_proxy() {
  proxy_off || true
  echo "已关闭系统 Web/HTTPS/SOCKS 代理（仍上不了网时请检查 系统设置→网络）"
}

cmd_switch() {
  if is_running; then
    cmd_off
  else
    cmd_on
  fi
}

cmd_switch_config() {
  if ! is_running; then
    echo "请先开启 mihomo" >&2
    exit 1
  fi
  if ! cfg_switchable; then
    echo "仅一个配置，无需切换" >&2
    exit 1
  fi

  local current next stem
  current=$(cfg_active)
  next=$(cfg_next "${current}")
  stem=$(cfg_stem "${next}")

  if ! load_config_api "${next}" "$(cfg_running)"; then
    reload_config_restart "${next}" || {
      echo "切换配置失败" >&2
      exit 1
    }
  fi

  if ! api_tun_enable "${next}"; then
    echo "配置已切换，但 TUN 开启失败" >&2
    write_state "$(state_mode tun)"
    exit 1
  fi

  write_state "$(state_mode tun)"
  echo "已切换至 ${stem}"
}

cmd_set_config() {
  local name="${1:-}"
  if [[ -z "${name}" ]]; then
    echo "用法: $(basename "$0") set-config <文件名.yaml>" >&2
    exit 1
  fi
  name="${name//[$'\t\r\n']/}"
  if [[ "${name}" != *.yaml ]]; then
    name="${name}.yaml"
  fi
  if [[ ! -f "${DATA_DIR}/${name}" ]]; then
    echo "配置不存在: ${name}" >&2
    exit 1
  fi

  if ! is_running; then
    cfg_set_active "${name}"
    echo "已设为当前配置: $(cfg_stem "${name}") （核心未运行时可再点 TUN 或 ⌃⌥⌘ M）"
    return 0
  fi

  local running_cfg
  running_cfg=$(cfg_running)

  if ! load_config_api "${name}" "${running_cfg}"; then
    reload_config_restart "${name}" || {
      echo "切换配置失败" >&2
      exit 1
    }
  fi

  if ! api_tun_enable "${name}" "${running_cfg}"; then
    if api_tun_is_enabled "${name}" "${running_cfg}"; then
      write_state "$(state_mode tun)"
      echo "已切换至 $(cfg_stem "${name}")"
      return 0
    fi
    local secret
    secret=$(secret_for "${name}")
    _curl_with_api_auth "${secret}" -m 2 -X PATCH \
      -H "Content-Type: application/json" \
      -d '{"tun":{"enable":false}}' \
      "${API}/configs" >/dev/null 2>&1 || true
    proxy_on || true
    write_state "$(state_mode proxy)"
    echo "已切至 $(cfg_stem "${name}")（TUN 不可用，系统代理 7890）"
    return 0
  fi

  write_state "$(state_mode tun)"
  echo "已切换至 $(cfg_stem "${name}")"
}

usage() {
  cat <<EOF
用法: $(basename "$0") <命令>

  switch          ⌃⌥⌘ M 开关
  on              开启 TUN
  off             关闭
  switch-config   ⌃⌥⌘ L 循环切换（运行中且 ≥2 个 *.yaml）
  set-config FILE 设为当前 *.yaml（未运行仅写 .active-config；运行中热切）
  clear-proxy     仅关闭本机系统代理（救急：已关 mihomo 仍断网时执行）

无 .active-config 时默认配置须为唯一的「default-*.yaml」（0 或多个均报错）。
EOF
}

main() {
  case "${1:-}" in
    switch) cmd_switch ;;
    on) cmd_on ;;
    off) cmd_off ;;
    switch-config) cmd_switch_config ;;
    set-config) cmd_set_config "${2:-}" ;;
    clear-proxy) cmd_clear_proxy ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
