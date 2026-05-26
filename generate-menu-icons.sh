#!/usr/bin/env bash
# 从 ico-openup.png / ico-closed.png 生成菜单栏图标（18px + @2x）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPEN="${SCRIPT_DIR}/ico-openup.png"
CLOSED="${SCRIPT_DIR}/ico-closed.png"

for f in "${OPEN}" "${CLOSED}"; do
  [[ -f "${f}" ]] || { echo "缺少: ${f}" >&2; exit 1; }
done

VENV="/tmp/mihomo-icon-venv"
if [[ ! -x "${VENV}/bin/python" ]]; then
  python3 -m venv "${VENV}"
  "${VENV}/bin/pip" install pillow -q
fi

export MIHOMO_DIR="${SCRIPT_DIR}"
"${VENV}/bin/python" << 'PY'
import os
from pathlib import Path
from PIL import Image

base = Path(os.environ["MIHOMO_DIR"])
OUT = 18


def bg_color(img):
    w, h = img.size
    pts = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1), (w // 2, 0), (0, h // 2)]
    rs, gs, bs = [], [], []
    for x, y in pts:
        r, g, b, a = img.getpixel((x, y))
        rs.append(r)
        gs.append(g)
        bs.append(b)
    n = len(rs)
    return sum(rs) // n, sum(gs) // n, sum(bs) // n


def save_icon(canvas, out):
    path = Path(out)
    canvas.resize((OUT, OUT), Image.Resampling.LANCZOS).save(path)
    canvas.resize((OUT * 2, OUT * 2), Image.Resampling.LANCZOS).save(
        path.with_name(path.stem + "@2x" + path.suffix)
    )


def crop_pad(img):
    bbox = img.getbbox()
    if not bbox:
        raise SystemExit("无法提取图标")
    img = img.crop(bbox)
    side = max(img.size)
    pad = max(2, side // 12)
    c = Image.new("RGBA", (side + pad * 2, side + pad * 2), (0, 0, 0, 0))
    c.paste(img, ((c.size[0] - img.size[0]) // 2, (c.size[1] - img.size[1]) // 2))
    return c


def process_on(src, out):
    img = Image.open(src).convert("RGBA")
    br, bg, bb = bg_color(img)
    px = img.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            diff = abs(r - br) + abs(g - bg) + abs(b - bb)
            if diff < 35:
                px[x, y] = (0, 0, 0, 0)
            else:
                lum = int(0.299 * r + 0.587 * g + 0.114 * b)
                px[x, y] = (255, 255, 255, min(255, max(80, (lum - 30) * 4)))
    save_icon(crop_pad(img), out)


def process_off(src, out):
    """关闭态：中灰 template，保留 ico-closed 的压暗质感，不过亮"""
    img = Image.open(src).convert("RGBA")
    br, bg, bb = bg_color(img)
    px = img.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            diff = abs(r - br) + abs(g - bg) + abs(b - bb)
            if diff < 28:
                px[x, y] = (0, 0, 0, 0)
                continue
            lum = int(0.299 * r + 0.587 * g + 0.114 * b)
            # 相对背景更深 → 更低灰度；整体限制在 70~150，避免白亮
            tone = max(70, min(150, 55 + diff // 3))
            alpha = max(100, min(220, diff * 2))
            px[x, y] = (tone, tone, tone, alpha)
    save_icon(crop_pad(img), out)


process_on(base / "ico-openup.png", base / "menu-icon-on.png")
process_off(base / "ico-closed.png", base / "menu-icon-off.png")
for size, name in ((18, "menu-icon-hidden.png"), (36, "menu-icon-hidden@2x.png")):
    Image.new("RGBA", (size, size), (0, 0, 0, 0)).save(base / name)
print("已生成 menu-icon-on/off/hidden.png (+ @2x)")
PY
