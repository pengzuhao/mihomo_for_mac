# Mihomo（macOS / Apple Silicon）

## 目录布局

| 位置 | 内容 |
|------|------|
| **`~/Desktop/mihomo/`** | 脚本、文档（本 README） |
| **`~/.config/mihomo/`** | 二进制、配置、UI、GeoIP、日志、缓存 |

```
~/Desktop/mihomo/              ~/.config/mihomo/
├── README.md                  ├── mihomo               # 核心（setuid）
├── 代理与节点选择.md           ├── default-*.yaml       # 默认仅认此模式（须恰好 1 个）+ 任意 *.yaml
├── 快捷键.md                  ├── ui/                  # Web 面板
├── startup-mihomo.sh          ├── geoip.metadb
├── shutdown-mihomo.sh         ├── cache.db
├── mihomo-control.sh          ├── mihomo.log
├── install-hotkeys.sh         ├── hotkey.log
├── install-cfg.sh             └── launchd.*.log（若有）
└── hammerspoon-init.lua
```

## 1. 安装过程

### 1.1 下载核心

```bash
export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890

mkdir -p ~/.config/mihomo
curl -sL -o /tmp/mihomo.gz \
  "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.25/mihomo-darwin-arm64-v1.19.25.gz"
gunzip -c /tmp/mihomo.gz > ~/.config/mihomo/mihomo
chmod +x ~/.config/mihomo/mihomo
```

### 1.2 TUN 权限（setuid）

```bash
osascript -e 'do shell script "chown root:admin $HOME/.config/mihomo/mihomo && chmod 4755 $HOME/.config/mihomo/mihomo" with administrator privileges'
```

### 1.3 Web 面板

```bash
export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890
rm -rf ~/.config/mihomo/ui && mkdir -p ~/.config/mihomo/ui
curl -sL -o /tmp/metacubexd.tgz \
  "https://github.com/MetaCubeX/metacubexd/releases/download/v1.248.4/compressed-dist.tgz"
tar -xzf /tmp/metacubexd.tgz -C ~/.config/mihomo/ui
```

面板：<http://127.0.0.1:9090/ui/>。`external-controller` 绑 **127.0.0.1** 且 yaml 里 **`secret` 为空** 时，面板与脚本一般**无需** Bearer；若你为安全在 yaml 写了 `secret`，MetacubexD 会提示输入。

### 1.4 启动 / 停止

```bash
~/Desktop/mihomo/startup-mihomo.sh
~/Desktop/mihomo/shutdown-mihomo.sh
~/Desktop/mihomo/mihomo-control.sh switch   # ⌃⌥⌘ M 同款
```

快捷键见 **`快捷键.md`**。

### 1.5 端口

| 项目 | 值 |
|------|-----|
| 混合代理 | `127.0.0.1:7890` |
| 面板 API | `127.0.0.1:9090` |

### 1.6 公开到 GitHub（脱敏）

本仓库**不应**包含：`~/.config/mihomo/` 下的 **订阅 yaml**、节点、`uuid`、**.active-config** 等。

若历史上曾把真实 `secret` 写进脚本或提交到远端，建议在 yaml 中**轮换**。**仅本机 127.0.0.1、且 `secret` 留空**时，脚本与面板通常**不必**配密钥；若 **`allow-lan: true`** 或监听非回环地址，仍应在 yaml 设置强 `secret`。

### 1.7 拷贝新订阅后统一端口 / 面板路径

订阅拉下来的 yaml 常为分拆口或未含 `external-ui`，可能与本地脚本不一致。**先拷贝** `*.yaml` 到 **`~/.config/mihomo/`**，再执行：

```bash
~/Desktop/mihomo/install-cfg.sh
```

可选参数：数据目录：**`~/Desktop/mihomo/install-cfg.sh /路径/到/配置目录`**。脚本会对目录下**每个 `.yaml`** 写入顶层 **`mixed-port: 7890`**、**`external-controller: '127.0.0.1:9090'`**、**`external-ui: ui`**，并删掉冲突的顶层 **`port:` / `socks-port` / `redir-port`** 等。**可重复执行**（会先去掉上次由本脚本注入的同一段）。

执行后若核心在跑：**菜单里对该 yaml 再设一次当前配置**，或 **`mihomo-control.sh off` → `on`**。

## 2. 常见问题

**面板 `/ui/` 404**：当前 yaml 里需有 **`external-ui: ui`**，且 **`~/.config/mihomo/ui/`** 已按上文「Web 面板」解压过 MetaCubeXD；仍 404 时可运行 **`install-cfg.sh`** 后再重载配置。

**日志**：`~/.config/mihomo/mihomo.log`、`hotkey.log`

**停止失败**：`~/Desktop/mihomo/mihomo-control.sh off`

**关闭免密（方案 2）**：一次性执行 `~/Desktop/mihomo/install-sudoers.sh`（仅输入一次密码），之后停止不再弹窗。未安装时仍会走管理员密码兜底。

**节点选择**：见 `代理与节点选择.md`
