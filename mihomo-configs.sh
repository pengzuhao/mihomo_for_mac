#!/usr/bin/env bash
# 配置发现：订阅配置为 DATA_DIR 下任意 *.yaml（名称排序）；
# 默认配置仅限「default-*.yaml」（有且仅能匹配 1 个），否则报错并提示用 .active-config 指定。
set -euo pipefail

DATA_DIR="${HOME}/.config/mihomo"
ACTIVE_CONFIG_FILE="${DATA_DIR}/.active-config"

cfg_list() {
  local f
  shopt -s nullglob
  local files=("${DATA_DIR}"/*.yaml)
  shopt -u nullglob
  if [[ ${#files[@]} -eq 0 ]]; then
    return 0
  fi
  local base
  for f in "${files[@]}"; do
    base=$(basename "${f}")
    echo "${base}"
  done | LC_ALL=C sort
}

cfg_count() {
  local n=0
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] && n=$((n + 1))
  done < <(cfg_list)
  echo "${n}"
}

cfg_stem() {
  local name="${1:-}"
  name="${name%.yaml}"
  echo "${name}"
}

# 状态行 / 菜单文案用「当前激活文件名去 .yaml」（与 state_line / tun_label 同源）

cfg_default_print_usage() {
  cat >&2 <<EOT

如何指定默认/当前配置（任选其一）：
  ① 默认文件：在 ${DATA_DIR}/ 下放且仅放 1 个「default-*.yaml」（例：default-my.yaml）
  ② 手动指向：echo \"配置文件名.yaml\" > ${ACTIVE_CONFIG_FILE}
EOT
}

# 在无有效 .active-config 时调用：须恰好 1 个 default-*.yaml；否则报错退出（stderr 中文说明）。
cfg_default() {
  local -a defs=()
  local f base
  shopt -s nullglob
  for f in "${DATA_DIR}"/default-*.yaml; do
    base=$(basename "${f}")
    defs+=("${base}")
  done
  shopt -u nullglob

  local n=${#defs[@]}
  if [[ "${n}" -eq 1 ]]; then
    echo "${defs[0]}"
    return 0
  fi

  if [[ "${n}" -eq 0 ]]; then
    echo "错误：未找到默认配置文件。" >&2
    echo "规则：文件名须以 「default-」开头、以 「.yaml」结尾，且在 ${DATA_DIR}/ 下有且仅有 1 个该模式文件（例如 default-ss-s.yaml）。" >&2
    cfg_default_print_usage
  else
    echo "错误：找到多个默认配置（符合 default-*.yaml 的共 ${n} 个），只能保留其中一个，或删掉/移走多余的后再试。" >&2
    printf '  - %s\n' "${defs[@]}" >&2
    cfg_default_print_usage
  fi
  exit 1
}

cfg_active() {
  if [[ -f "${ACTIVE_CONFIG_FILE}" ]]; then
    local name
    name=$(<"${ACTIVE_CONFIG_FILE}")
    name="${name//$'\r'/}"
    name="${name//$'\n'/}"
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    if [[ -n "${name}" ]] && [[ -f "${DATA_DIR}/${name}" ]]; then
      echo "${name}"
      return 0
    fi
  fi
  cfg_default
}

cfg_set_active() {
  local name="$1"
  echo "${name}" >"${ACTIVE_CONFIG_FILE}"
}

cfg_next() {
  local current="$1"
  local -a items=()
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] && items+=("${line}")
  done < <(cfg_list)
  local n=${#items[@]}
  if [[ "${n}" -eq 0 ]]; then
    echo "错误：${DATA_DIR} 下无任何 *.yaml 配置" >&2
    exit 1
  fi
  local i
  for ((i = 0; i < n; i++)); do
    if [[ "${items[i]}" == "${current}" ]]; then
      echo "${items[$(((i + 1) % n))]}"
      return 0
    fi
  done
  echo "${items[0]}"
}

cfg_read_secret() {
  local cfg="$1"
  local line=""
  if [[ -z "${cfg}" || ! -f "${DATA_DIR}/${cfg}" ]]; then
    echo ""
    return 0
  fi
  # pipefail 下「无匹配」会令整条管道失败并使调用方脚本退出；必须容忍空
  line=$( { grep -E '^[[:space:]]*secret:' "${DATA_DIR}/${cfg}" 2>/dev/null || true; } | head -1 )
  if [[ -z "${line}" ]]; then
    echo ""
    return 0
  fi
  sed -E 's/^[[:space:]]*secret:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/' <<< "${line}"
}

cfg_switchable() {
  [[ "$(cfg_count)" -ge 2 ]]
}

# yaml 顶层 tun.enable: true（default-ss-s 等）；启动后核心会自行挂 TUN，不必等 9090 再 PATCH
cfg_tun_enabled_in_file() {
  local cfg="$1"
  local f="${DATA_DIR}/${cfg}"
  [[ -f "${f}" ]] || return 1
  awk '
    /^tun:/ { in_tun = 1; next }
    in_tun && /^[^[:space:]#]/ { in_tun = 0 }
    in_tun && /^[[:space:]]+enable:[[:space:]]*true([[:space:]]|$|#)/ { found = 1 }
    END { exit !found }
  ' "${f}"
}

# 真·mihomo 核心：与 startup-mihomo.sh 一致，命令行含「二进制路径 +  -f  +  -d $DATA_DIR」。
# 1) pgrep -f 路径会误匹配 zsh/Cursor 里出现同一路径的进程。
# 2) ps 默认会截断长 args，必须 axww，否则刚 nohup 起的进程常被漏检 → 脚本报启动失败但 UI 仍乐观。
is_mihomo_core_running() {
  local pid
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] && return 0
  done < <(mihomo_core_pids)
  return 1
}

# 真·mihomo 核心 pid 列表（精确匹配 -f / -d，避免 killall 误伤）
mihomo_core_pids() {
  local bin="${DATA_DIR}/mihomo"
  local dd="${DATA_DIR}"
  ps axww -o pid=,args= 2>/dev/null | awk -v b="$bin" -v d="$dd" '
    index($0, b) && index($0, " -f ") && index($0, " -d ") && index($0, d) {
      sub(/^[[:space:]]+/, "", $1)
      print $1
    }
  '
}

# 从 ps 读出当前核心 -f 指向的 yaml 文件名
cfg_running() {
  local bin="${DATA_DIR}/mihomo"
  local dd="${DATA_DIR}"
  ps axww -o args= 2>/dev/null | awk -v b="$bin" -v d="$dd" '
    index($0, b) && index($0, " -f ") && index($0, " -d ") && index($0, d) {
      i = index($0, " -f ")
      rest = substr($0, i + 4)
      split(rest, a, " ")
      n = a[1]
      sub(".*/", "", n)
      print n
      exit
    }
  '
}
