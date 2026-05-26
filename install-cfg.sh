#!/usr/bin/env bash
# 将新拷入的订阅 yaml 与本机约定对齐：混合代理 7890、面板 API 9090、MetaCubeXD（external-ui: ui）
# 用法：先复制 *.yaml → ~/.config/mihomo ，再运行本脚本
set -euo pipefail

DATA_DIR="${1:-${HOME}/.config/mihomo}"

if [[ ! -d "${DATA_DIR}" ]]; then
  echo "目录不存在: ${DATA_DIR}" >&2
  exit 1
fi

export DATA_DIR_FOR_PY="${DATA_DIR}"
python3 <<'PY'
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

DATA = Path(os.environ["DATA_DIR_FOR_PY"]).expanduser()

# 仅顶层（行首非空白）的这几项会与「混合口 + API + UI」冲突，先删掉再统一注入。
TOP_PREFIXES = (
    "mixed-port:",
    "external-controller:",
    "external-ui:",
    "socks-port:",
    "redir-port:",
)
PORT_LINE = re.compile(r"^port:\s*\S")


MARKER = "# --- normalized by install-cfg.sh"


def remove_previous_inject(lines: list[str]) -> list[str]:
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.strip().startswith(MARKER):
            i += 1
            while i < len(lines):
                s = lines[i].strip()
                if s.startswith("external-ui:"):
                    i += 1
                    while i < len(lines) and lines[i].strip() == "":
                        i += 1
                    break
                i += 1
            continue
        out.append(line)
        i += 1
    return out


def strip_top_conflict(lines: list[str]) -> list[str]:
    out: list[str] = []
    for line in lines:
        if line.startswith(" ") or line.startswith("\t"):
            out.append(line)
            continue
        s = line.lstrip()
        low = s.lower()
        if any(low.startswith(p) for p in TOP_PREFIXES):
            continue
        if PORT_LINE.match(s):
            continue
        out.append(line)
    return out


def first_content_line_index(lines: list[str]) -> int:
    for i, line in enumerate(lines):
        st = line.strip()
        if st == "":
            continue
        if st.startswith("#"):
            continue
        return i
    return len(lines)


HEADER = """# --- normalized by install-cfg.sh: mixed-port 7890 / API :9090 / external-ui ---
mixed-port: 7890
external-controller: '127.0.0.1:9090'
external-ui: ui"""

patched = 0
skipped = 0

for path in sorted(DATA.glob("*.yaml")):
    if not path.is_file():
        skipped += 1
        continue
    raw = path.read_text(encoding="utf-8", errors="surrogateescape")
    ends_nl = raw.endswith("\n")
    lines = raw.splitlines()
    merged = strip_top_conflict(remove_previous_inject(lines))
    idx = first_content_line_index(merged)
    inject = [*HEADER.splitlines(), ""]
    new_lines = merged[:idx] + inject + merged[idx:]
    new_text = "\n".join(new_lines)
    if ends_nl:
        new_text += "\n"
    if new_text == raw:
        print(f"[skip/same] {path.name}")
        continue
    path.write_text(new_text, encoding="utf-8")
    patched += 1
    print(f"[patched]   {path.name}")

print(f"\nDone. patched={patched}, skipped(non-file?)={skipped}, dir={DATA}")
print("Restart or: mihomo-control.sh ... set-config（或 off → on）后打开 http://127.0.0.1:9090/ui/")
PY
