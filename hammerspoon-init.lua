-- Mihomo 菜单栏：列出 DATA_DIR 全部 *.yaml 可选；关闭 / 退出
-- ⌃⌥⌘M 全局：显示+开 TUN ↔ 隐藏+关服务
-- ⌃⌥⌘L 全局：循环切换 *.yaml（运行中且 ≥2 个配置）
-- 默认配置：仅用「default-*.yaml」且无多义；详见 mihomo-configs.sh cfg_default

require("hs.ipc")

local LOG = os.getenv("HOME") .. "/.config/mihomo/hammerspoon.log"
local BAR_AUTOSAVE = "dev.mihomo.menubar"

local function log(msg)
  local f = io.open(LOG, "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S ") .. msg .. "\n")
    f:close()
  end
end

local home = os.getenv("HOME")
local scriptDir = home .. "/Desktop/mihomo"
local control = scriptDir .. "/mihomo-control.sh"
local statusSh = scriptDir .. "/mihomo-status.sh"
local stateFile = home .. "/.config/mihomo/.switch-on"
local dataDir = home .. "/.config/mihomo"
local mihomoBin = dataDir .. "/mihomo"
local iconOn = scriptDir .. "/menu-icon-on.png"
local iconOff = scriptDir .. "/menu-icon-off.png"

local tips = { off = "已关闭", tun = "TUN", proxy = "系统代理" }

local bar = nil
local timer = nil
local busy = false
local busyGen = 0
local opGen = 0
local uiLockUntil = 0
local lastState = "off"
local globalMHotkey = nil
local configSwitchHotkey = nil
local hotkeySyncTimer = nil
-- 关闭/ off 时递增，用于取消「quiet on」轮询；避免 hs.task 回调丢失时永远没有提示
local feedSeq = 0
local openUserAlerted = {}

local applyState, showBar, hideBar, refresh, runControl, globalToggle, hideAndStop, switchConfig, updateConfigHotkey

local function invalidateOpenFeedback()
  feedSeq = feedSeq + 1
  openUserAlerted = {}
end

local function quoteSh(s)
  return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- 与 mihomo-configs.cfg_list 一致：优先 hs.fs，失败或空表时用 shell cfg_list（避免无「完全磁盘访问」时菜单只剩 关闭/退出）。
local function enumerateYamlConfigsViaShell()
  local out = {}
  local path = os.getenv("PATH") or "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  local inner = ". " .. quoteSh(scriptDir .. "/mihomo-configs.sh") .. " >/dev/null 2>&1 && cfg_list"
  local cmd = "/usr/bin/env HOME=" .. quoteSh(home) .. " PATH=" .. quoteSh(path) .. " /bin/bash -o pipefail -c " .. quoteSh(inner)
  local okOp, f = pcall(io.popen, cmd)
  if not okOp or not f then
    log("ERROR enumerateYamlConfigsViaShell popen failed")
    return out
  end
  for line in f:lines() do
    line = (line or ""):match("^%s*(.-)%s*$") or ""
    if line ~= "" and string.lower(line):match("%.yaml$") then
      table.insert(out, line)
    end
  end
  f:close()
  return out
end

local function enumerateYamlConfigs()
  local out = {}
  if hs and hs.fs and type(hs.fs.directoryContents) == "function" then
    local ok, list = pcall(hs.fs.directoryContents, dataDir)
    if ok and type(list) == "table" then
      for i = 1, #list do
        local name = list[i]
        if type(name) == "string" and string.lower(name):match("%.yaml$") then
          table.insert(out, name)
        end
      end
      table.sort(out)
    end
  end
  if #out == 0 then
    log("NOTICE enumerateYamlConfigs: hs.fs 无 yaml 或不可用，回退 cfg_list HOME=" .. tostring(home) .. " dataDir=" .. tostring(dataDir))
    out = enumerateYamlConfigsViaShell()
    table.sort(out)
    if #out == 0 then
      log("WARN enumerateYamlConfigs: shell cfg_list 仍为空，菜单将无配置文件项（请确认 ~/.config/mihomo 下有 *.yaml 且 Desktop/mihomo 路径正确）")
    end
  end
  return out
end

local function cfgYamlCountViaShell()
  local path = os.getenv("PATH") or "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  local inner = ". " .. quoteSh(scriptDir .. "/mihomo-configs.sh") .. " >/dev/null 2>&1 && cfg_count"
  local cmd = "/usr/bin/env HOME=" .. quoteSh(home) .. " PATH=" .. quoteSh(path) .. " /bin/bash -o pipefail -c " .. quoteSh(inner)
  local f = io.popen(cmd)
  if not f then
    return 0
  end
  local line = (f:read("*l") or ""):match("^%s*(.-)%s*$") or ""
  f:close()
  return tonumber(line) or 0
end

local function cfgYamlCount()
  local t = enumerateYamlConfigs()
  if #t > 0 then
    return #t
  end
  return cfgYamlCountViaShell()
end

local function isMihomoRunning()
  if type(hs.execute) ~= "function" then
    return false
  end
  -- 与 is_mihomo_core_running 同源：axww 防截断；同时要求 -f 与 -d DATA_DIR
  local inner = string.format(
    "set -o pipefail; ps axww -o args= 2>/dev/null | awk -v b=%s -v d=%s 'BEGIN{f=0} index($0,b)&&index($0,\" -f \")&&index($0,\" -d \")&&index($0,d){f=1} END{exit !f}'",
    string.format("%q", mihomoBin),
    string.format("%q", dataDir)
  )
  local full = string.format("/bin/bash -o pipefail -c %q", inner)
  local ok, pack = pcall(function()
    return table.pack(hs.execute(full, false))
  end)
  if not ok or not pack then
    return false
  end
  return pack[2] == true
end

updateConfigHotkey = function()
  if not configSwitchHotkey then
    return
  end
  if isMihomoRunning() and cfgYamlCount() >= 2 then
    configSwitchHotkey:enable()
  else
    configSwitchHotkey:disable()
  end
end

local function startHotkeySyncTimer()
  if hotkeySyncTimer then
    return
  end
  hotkeySyncTimer = hs.timer.doEvery(8, updateConfigHotkey)
end

local function alertUser(msg)
  if not msg or msg == "" then
    return
  end
  local text = msg:match("[^\n]+") or msg
  -- menubar 更新同一时刻弹窗易被吞；略延时。勿用 pcall(hs.alert.show,...) 会错传 self
  hs.timer.doAfter(0.12, function()
    local ok, err = pcall(function()
      hs.alert.show(text, 2)
    end)
    if not ok then
      log("alertUser error: " .. tostring(err))
    end
  end)
end

local function asStdout(s)
  if s == nil then
    return ""
  end
  if type(s) == "string" then
    return s
  end
  return tostring(s)
end

local function isErrorMsg(msg)
  if msg == nil or msg == "" then
    return false
  end
  return msg:find("失败") or msg:find("请先") or msg:find("无需")
end

local function parseStatus(raw)
  if raw == "off" or raw == "tun" or raw == "proxy" then
    return raw, nil
  end
  local mode, cfg = raw:match("^([^:]+):(.+)$")
  if mode and cfg then
    return mode, cfg
  end
  return raw, nil
end

local function tunLabel(cfg)
  if cfg and cfg ~= "" then
    return "TUN-" .. cfg
  end
  return "TUN"
end

local function tooltipText(mode, cfg)
  if mode == "off" then
    return "Mihomo · 已关闭 | 点击选菜单"
  end
  if cfg and cfg ~= "" then
    return "Mihomo · " .. tunLabel(cfg) .. " | 点击选菜单"
  end
  return "Mihomo · " .. (tips[mode] or mode) .. " | 点击选菜单"
end

local function writeStateFile(raw)
  local f = io.open(stateFile, "w")
  if not f then
    return
  end
  f:write(raw)
  f:close()
end

-- 与 applyOptimistic 写入同源；不经过 shell，避免 io.popen 子进程无 HOME 时 mihomo-status 误判为 off
local function peekStateDisk()
  local f = io.open(stateFile, "r")
  if not f then
    return "off"
  end
  local line = f:read("*l") or ""
  f:close()
  return (line:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 磁盘 .active-config：核心 off 时在菜单上对「将用哪个 yaml」打勾
local function peekActiveConfigBasename()
  local p = dataDir .. "/.active-config"
  local f = io.open(p, "r")
  if not f then
    return ""
  end
  local line = f:read("*l") or ""
  f:close()
  line = (line:gsub("^%s+", ""):gsub("%s+$", "")):gsub("%s+", "")
  if line ~= "" then
    local fn = io.open(dataDir .. "/" .. line, "r")
    if fn then
      fn:close()
      return line
    end
  end
  return ""
end

local function yamlStem(fname)
  if not fname or fname == "" then
    return ""
  end
  local s = tostring(fname)
  s = s:gsub("%.yaml$", ""):gsub("%.YAML$", "")
  return s
end

-- hs.task 默认 -lc 可能无 HOME/PATH；与 status() 一致用 quoteSh，避免个别版本 hs.quote 行为异常
local function taskShellLineForControl(cmd, extraYaml)
  local path = os.getenv("PATH") or "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  local h = home or os.getenv("HOME") or ""
  local tail = ""
  if extraYaml and extraYaml ~= "" then
    tail = " " .. quoteSh(extraYaml)
  end
  return "/usr/bin/env HOME=" .. quoteSh(h) .. " PATH=" .. quoteSh(path) .. " MIHOMO_SILENT=1 " .. quoteSh(control) .. " " .. quoteSh(cmd) .. tail
end

local function status()
  local ok, s = pcall(function()
    local path = os.getenv("PATH") or "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    local cmd = "/usr/bin/env HOME=" .. quoteSh(home) .. " PATH=" .. quoteSh(path) .. " /bin/bash " .. quoteSh(statusSh)
    local f = io.popen(cmd)
    if not f then
      return "off"
    end
    local line = (f:read("*l") or "off"):gsub("%s+", "")
    f:close()
    return line
  end)
  return ok and s or "off"
end

local function effectiveStatus()
  local shellSt = status()
  local disk = peekStateDisk()

  -- on/off 或乐观锁内：优先信磁盘上的 tun / tun:cfg，避免 status 尚未跟上时闪成「关」
  if busy or hs.timer.secondsSinceEpoch() < uiLockUntil then
    if disk ~= "" and disk ~= "off" then
      -- Lua 曾写纯 tun/proxy，shell 已把 .switch-on 写成 tun:stem；磁盘仍短名时用 status 补全菜单
      local dm, dc = parseStatus(disk)
      if (dm == "tun" or dm == "proxy") and (dc == nil or dc == "") and shellSt ~= "" and shellSt ~= "off" then
        local sm = select(1, parseStatus(shellSt))
        if sm == dm then
          return shellSt
        end
      end
      return disk
    end
    if shellSt ~= nil and shellSt ~= "" and shellSt ~= "off" then
      return shellSt
    end
    return (shellSt ~= nil and shellSt ~= "") and shellSt or "off"
  end

  -- 稳定后只信 mihomo-status.sh（与 control 同源 pgrep），勿用 Lua io.popen+pgrep 单独判死：
  -- 后者在 Hammerspoon 下偶发假阴性会误写 .switch-on=off 并把图标打成灰，而 TUN 实际仍正常。
  if shellSt == "off" and disk ~= "" and disk ~= "off" then
    writeStateFile("off")
  end
  if shellSt ~= nil and shellSt ~= "" then
    return shellSt
  end
  return "off"
end

local function resolveOptimistic(mode)
  if mode == "off" then
    return "off"
  end
  local _, cfg = parseStatus(lastState)
  -- 勿在此处同步调 status()：主线程 io.popen 若卡住会拖死快捷键整段后续（日志只剩 showBar new）。
  if not cfg or cfg == "" then
    local disk = peekStateDisk()
    _, cfg = parseStatus(disk)
  end
  if cfg and cfg ~= "" then
    return mode .. ":" .. cfg
  end
  return mode
end

-- quiet + on：优先读磁盘状态文件（applyOptimistic 已写 tun），再回退到 status.sh
local function scheduleQuietOnAlert(feedSnap)
  local function tick(attempt)
    if feedSnap ~= feedSeq or not bar then
      return
    end
    if openUserAlerted[feedSnap] then
      return
    end
    local disk = peekStateDisk()
    local shellSt = "off"
    local okSs, sv = pcall(status)
    if okSs and sv and sv ~= "" then
      shellSt = sv
    end
    local st
    if disk == "" or disk == "off" then
      st = shellSt
    elseif isMihomoRunning() then
      -- 进程已就绪：磁盘若仍是 Lua 写的纯 tun/proxy，用 status 行补全 tun:stem，与弹窗/脚本一致
      local _, dc = parseStatus(disk)
      if (disk == "tun" or disk == "proxy") and (dc == nil or dc == "") and shellSt ~= "" and shellSt ~= "off" then
        local sm = select(1, parseStatus(shellSt))
        local dm = select(1, parseStatus(disk))
        if sm == dm then
          st = shellSt
        else
          st = disk
        end
      else
        st = disk
      end
    else
      -- 已写 optimism，但内核尚未拉起或已退出 → 不以 disk 误判为已成功
      st = shellSt
    end
    if st == "off" or st == "" then
      if attempt < 55 then
        hs.timer.doAfter(0.2, function()
          tick(attempt + 1)
        end)
      else
        log("WARN scheduleQuietOnAlert timeout feedSnap=" .. tostring(feedSnap) .. " disk=[" .. tostring(disk) .. "] shell=[" .. tostring(shellSt) .. "]")
      end
      return
    end
    openUserAlerted[feedSnap] = true
    log("scheduleQuietOnAlert ok st=" .. tostring(st))
    local mode, cfg = parseStatus(st)
    if mode == "proxy" then
      alertUser("已开启（系统代理 7890）")
    else
      alertUser("已开启 " .. tunLabel(cfg))
    end
  end
  hs.timer.doAfter(0.12, function()
    tick(0)
  end)
end

local function setBarIconVisual(on)
  if not bar then
    return
  end
  local path = on and iconOn or iconOff
  pcall(function()
    local img = hs.image.imageFromPath(path)
    if img then
      bar:setIcon(img, true)
    else
      bar:setIcon(path, true)
    end
    bar:setTitle("")
  end)
end

local function menuForState(raw)
  local mode, activeCfg = parseStatus(raw)
  local markOff = (mode == "off") and "✓ " or ""
  local prefWhenOff = peekActiveConfigBasename()
  local items = {}
  for _, fname in ipairs(enumerateYamlConfigs()) do
    local stem = yamlStem(fname)
    local isChosen = false
    if mode == "off" then
      isChosen = (prefWhenOff ~= "" and fname == prefWhenOff)
    else
      isChosen = activeCfg == stem
    end
    local mark = isChosen and "✓ " or ""
    local capFname = fname
    table.insert(items, {
      title = mark .. stem,
      fn = function()
        opGen = opGen + 1
        busy = false
        busyGen = 0
        local gen = opGen
        runControl("set-config", function()
          uiLockUntil = hs.timer.secondsSinceEpoch() + 3
          if bar then
            local okS, stLine = pcall(status)
            if okS and stLine and stLine ~= "" and stLine ~= "off" then
              writeStateFile(stLine)
              applyState(stLine)
            else
              applyState(effectiveStatus())
            end
          end
          updateConfigHotkey()
        end, nil, gen, true, capFname)
      end,
    })
  end
  table.insert(items, {
    title = markOff .. "关闭",
    fn = function()
      opGen = opGen + 1
      busy = false
      busyGen = 0
      runControl("off", nil, "off", opGen, true)
    end,
  })
  table.insert(items, {
    title = "退出",
    fn = function()
      hideAndStop("Mihomo 已退出")
    end,
  })
  return items
end

local function syncBarVisuals(raw)
  if not bar then
    return
  end
  lastState = raw
  local mode, cfg = parseStatus(raw)
  setBarIconVisual(mode ~= "off")
  bar:setTooltip(tooltipText(mode, cfg))
  updateConfigHotkey()
end

applyState = function(raw)
  if not bar then
    return
  end
  syncBarVisuals(raw)
  -- 禁用 setMenu(function…)：部分 Hammerspoon 版本上会导致图标无法点击、无下拉菜单（pcall 仍“成功”则更难排查）
  bar:setMenu(menuForState(raw))
end

local function applyOptimistic(mode)
  local raw = resolveOptimistic(mode)
  writeStateFile(raw)
  applyState(raw)
  uiLockUntil = hs.timer.secondsSinceEpoch() + 3
  -- 文案统一在脚本回调里 alertUser，避免与本帧 menubar 更新冲突或被去重误判
end

local function nudgeBarDisplay()
  if not bar then
    return
  end
  applyState(lastState)
  hs.timer.doAfter(0.15, function()
    if bar then
      applyState(lastState)
    end
  end)
end

showBar = function(s)
  if bar then
    applyState(s)
    log("showBar reuse state=" .. s)
    return true
  end
  local b = hs.menubar.new(true, BAR_AUTOSAVE)
  if not b then
    log("ERROR menubar.new failed")
    hs.alert.show("Mihomo: 无法创建菜单栏图标")
    return false
  end
  bar = b
  lastState = s
  applyState(s)
  nudgeBarDisplay()
  log("showBar new state=" .. s)
  return true
end

hideBar = function()
  if timer then
    pcall(function()
      timer:stop()
    end)
    timer = nil
  end
  if not bar then
    log("hideBar skip (no bar)")
    return
  end
  local b = bar
  bar = nil
  lastState = "off"
  local ok, err = pcall(function()
    b:delete()
  end)
  if ok then
    log("hideBar delete ok")
  else
    log("ERROR hideBar delete: " .. tostring(err))
  end
  updateConfigHotkey()
end

local function syncState(alertMsg, gen)
  if not bar or (gen and gen ~= opGen) then
    return
  end
  applyState(status())
  if alertMsg and alertMsg ~= "" then
    alertUser(alertMsg)
  end
end

-- 同步调用 mihomo-control.sh（等同终端）。
-- 禁止 hs.execute(_, true)：Hammerspoon 用 $SHELL -l -i -c 再包一层，在无 TTY 下脚本常根本没跑却仍「成功」，菜单栏 optimism 已满、却无进程。
-- 环境与 PATH 只靠本行内 env；用 bash -c 包住整条命令。
local function shellControlSync(cmd, extraYaml)
  local line = taskShellLineForControl(cmd, extraYaml)
  local fullCmd = "/bin/bash -o pipefail -c " .. quoteSh(line)
  if type(hs.execute) ~= "function" then
    log("ERROR hs.execute missing")
    return 1, "", ""
  end
  local ok, pack = pcall(function()
    return table.pack(hs.execute(fullCmd, false))
  end)
  if not ok then
    log("ERROR shellControlSync pcall: " .. tostring(pack))
    return 1, "", ""
  end
  local sout, st, typ, rc = pack[1], pack[2], pack[3], pack[4]
  local ec = 0
  if st then
    ec = 0
  elseif typ == "exit" and type(rc) == "number" then
    ec = rc
  else
    ec = 1
  end
  log("shellControlSync cmd=" .. tostring(cmd) .. " ec=" .. tostring(ec) .. " stdoutBytes=" .. tostring(#(sout or "")))
  return ec, sout or "", ""
end

local function scheduleVerifyMihomoAfterOn(myGenSnap)
  hs.timer.doAfter(0.55, function()
    if not bar or myGenSnap ~= opGen or busy then
      return
    end
    local okS, st = pcall(status)
    st = (okS and st and st ~= "") and st or "off"
    local mode = select(1, parseStatus(st))
    if mode == "off" then
      invalidateOpenFeedback()
      log(
        "ERROR verify-after-on: still off gen="
          .. tostring(myGenSnap)
          .. " statusLine="
          .. tostring(st)
      )
      writeStateFile("off")
      applyState("off")
      updateConfigHotkey()
      alertUser(
        "未检测到 mihomo 进程。\n请查看 ~/.config/mihomo/hammerspoon.log 与 mihomo.log；或在终端对比： ~/Desktop/mihomo/mihomo-control.sh on"
      )
    end
  end)
end

local function runControlDispatchCompletion(cmd, after, quiet, quietOn, feedSnap, myGen, exitCode, stdOut, stdErr)
  if myGen ~= opGen and myGen ~= busyGen then
    -- 单次同步 shell：无并行任务时仍应释放锁；旧逻辑在 busyGen≠0 时可能留下 busy=true → 后续永远 skip
    log("runControl stale gen=" .. tostring(myGen) .. " cmd=" .. cmd .. " exit=" .. tostring(exitCode))
    busy = false
    busyGen = 0
    return
  end
  if busyGen == myGen then
    busy = false
    busyGen = 0
  else
    log("WARN runControl busyGen mismatch myGen=" .. tostring(myGen) .. " busyGen=" .. tostring(busyGen))
    busy = false
    busyGen = 0
  end
  local msg = (asStdout(stdOut) .. asStdout(stdErr)):gsub("^%s+", ""):gsub("%s+$", "")
  local ec = tonumber(exitCode) or 0
  if (cmd == "on" or cmd == "set-config") and ec ~= 0 then
    invalidateOpenFeedback()
    if msg ~= "" then
      alertUser(msg)
    elseif cmd == "on" then
      alertUser("开启失败（退出码 " .. tostring(exitCode) .. "），请查看 ~/.config/mihomo/mihomo.log")
    else
      alertUser("切换配置失败（退出码 " .. tostring(exitCode) .. "）")
    end
    uiLockUntil = 0
    if bar then
      applyState(effectiveStatus())
    end
    updateConfigHotkey()
    log(
      "runControl FAIL cmd="
        .. cmd
        .. " exit="
        .. tostring(exitCode)
        .. " stdoutBytes="
        .. tostring(#asStdout(stdOut))
        .. " stderrBytes="
        .. tostring(#asStdout(stdErr))
    )
    return
  end
  if isErrorMsg(msg) then
    invalidateOpenFeedback()
    alertUser(msg)
    uiLockUntil = 0
    if bar then
      syncState(nil, myGen)
    end
  elseif cmd == "on" and msg:find("系统代理") then
    writeStateFile(resolveOptimistic("proxy"))
    if bar then
      applyState(resolveOptimistic("proxy"))
    end
    if not openUserAlerted[feedSnap] then
      openUserAlerted[feedSnap] = true
      alertUser(msg ~= "" and msg or "已开启（系统代理 7890）")
    end
    updateConfigHotkey()
  elseif after then
    if msg ~= "" and not (quiet and cmd == "off") then
      alertUser(msg)
    elseif cmd == "switch-config" then
      local st = status()
      local _, stem = parseStatus(st)
      if stem and stem ~= "" then
        alertUser("已切换至 " .. stem)
      else
        alertUser("配置已切换")
      end
    elseif cmd == "on" then
      alertUser("已开启 mihomo")
    end
    after()
    updateConfigHotkey()
  elseif quietOn then
    uiLockUntil = hs.timer.secondsSinceEpoch() + 3
    if bar then
      local okS, stLine = pcall(status)
      if okS and stLine and stLine ~= "" and stLine ~= "off" then
        writeStateFile(stLine)
        applyState(stLine)
      else
        applyState(effectiveStatus())
      end
    end
    updateConfigHotkey()
    if msg ~= "" and not openUserAlerted[feedSnap] then
      openUserAlerted[feedSnap] = true
      alertUser(msg)
    end
  elseif msg ~= "" then
    uiLockUntil = hs.timer.secondsSinceEpoch() + 3
    if bar then
      applyState((cmd == "on" and quiet) and effectiveStatus() or status())
    end
    updateConfigHotkey()
    alertUser(msg)
  elseif bar and not quiet then
    syncState(nil, myGen)
    hs.timer.doAfter(0.5, function()
      if bar and myGen == opGen and hs.timer.secondsSinceEpoch() >= uiLockUntil then
        applyState(status())
      end
    end)
  end
  if cmd == "on" and ec == 0 then
    scheduleVerifyMihomoAfterOn(myGen)
  end
  log(
    "runControl done cmd="
      .. cmd
      .. " exit="
      .. tostring(exitCode)
      .. " stdoutBytes="
      .. tostring(#asStdout(stdOut))
      .. " stderrBytes="
      .. tostring(#asStdout(stdErr))
  )
end

hideAndStop = function(alertMsg)
  invalidateOpenFeedback()
  opGen = opGen + 1
  local gen = opGen
  writeStateFile("off")
  hideBar()
  if alertMsg then
    alertUser(alertMsg)
  end
  log("hideAndStop gen=" .. gen)
  -- 与菜单「TUN」一致：上一轮若误判 busy，否则 ⌃⌥⌘M 再开时会一直 skip busy
  busy = false
  busyGen = 0
  -- 必须走 runControl(off)：与「开」共用 busy，避免 stopServiceAsync 与 on 并发把刚拉起的 mihomo 立刻关掉
  runControl("off", function()
    updateConfigHotkey()
  end, nil, gen, true)
end

runControl = function(cmd, after, optimisticState, gen, quiet, extraYaml)
  if busy then
    log("runControl skip busy cmd=" .. cmd)
    return false
  end
  if cmd == "off" then
    invalidateOpenFeedback()
  end
  local feedSnap = feedSeq
  local quietOn = quiet and cmd == "on"
  local myGen = gen or opGen
  busyGen = myGen
  busy = true
  log(
    "runControl start cmd="
      .. cmd
      .. " myGen="
      .. tostring(myGen)
      .. ((extraYaml and extraYaml ~= "") and (" yaml=" .. extraYaml) or "")
  )
  if optimisticState then
    applyOptimistic(optimisticState)
  end
  if quietOn then
    scheduleQuietOnAlert(feedSnap)
  end
  log("runControl sync exec cmd=" .. cmd)
  local okRpc, rpcErr = pcall(function()
    local ec, sout, serr = shellControlSync(cmd, extraYaml)
    runControlDispatchCompletion(cmd, after, quiet, quietOn, feedSnap, myGen, ec, sout, serr)
  end)
  if not okRpc then
    log("ERROR runControl pcall: " .. tostring(rpcErr))
    busy = false
    busyGen = 0
  end
  return true
end

switchConfig = function()
  if cfgYamlCount() < 2 then
    return
  end
  if not isMihomoRunning() then
    return
  end
  if busy then
    return
  end
  opGen = opGen + 1
  local gen = opGen
  runControl("switch-config", function()
    uiLockUntil = hs.timer.secondsSinceEpoch() + 3
    if bar then
      applyState(status())
    end
  end, nil, gen, true)
end

refresh = function()
  if not bar or hs.timer.secondsSinceEpoch() < uiLockUntil then
    return
  end
  applyState(effectiveStatus())
end

local function startTimer()
  if timer then
    return
  end
  timer = hs.timer.doEvery(8, refresh)
end

globalToggle = function()
  if not bar then
    opGen = opGen + 1
    local gen = opGen
    if not showBar("tun") then
      return
    end
    startTimer()
    local okOpt, optErr = pcall(function()
      applyOptimistic("tun")
    end)
    if not okOpt then
      log("ERROR globalToggle applyOptimistic: " .. tostring(optErr))
    end
    log("globalToggle before tryStartOn gen=" .. tostring(gen))
    local attempts = 0
    local function tryStartOn()
      if gen ~= opGen or not bar then
        return
      end
      -- 对齐菜单「TUN」：避免残留 busy=true 时每 0.2s 重试都只能 skip busy
      busy = false
      busyGen = 0
      if runControl("on", nil, nil, gen, true) then
        log("globalToggle tryStartOn ok attempt=" .. tostring(attempts + 1))
        return
      end
      attempts = attempts + 1
      if attempts >= 10 then
        log("ERROR globalToggle tryStartOn exhausted after " .. tostring(attempts) .. " attempts")
        applyState(effectiveStatus())
        alertUser("多次重试仍无法启动。请在终端执行:\n~/Desktop/mihomo/mihomo-control.sh on\n并 Reload Hammerspoon")
        return
      end
      log("NOTICE globalToggle tryStartOn defer attempt=" .. tostring(attempts))
      hs.timer.doAfter(0.2, tryStartOn)
    end
    tryStartOn()
    log("globalToggle show gen=" .. gen)
    return
  end
  hideAndStop("Mihomo 已关闭")
end

log("--- reload ---")
if not home or home == "" then
  log("ERROR Hammerspoon os.getenv('HOME') 为空；请用「正式」Hammer spoon.app 而非沙盒宿主，或为 launchd 注入 HOME")
end
local ok, err = xpcall(function()
  if globalMHotkey then
    pcall(function()
      globalMHotkey:delete()
    end)
  end
  if configSwitchHotkey then
    pcall(function()
      configSwitchHotkey:delete()
    end)
  end
  globalMHotkey = hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "M", globalToggle)
  configSwitchHotkey = hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "L", switchConfig)
  configSwitchHotkey:disable()
  startHotkeySyncTimer()
  updateConfigHotkey()
end, debug.traceback)

if not ok then
  log("ERROR " .. tostring(err))
  hs.alert.show("Mihomo 加载失败:\n" .. tostring(err))
else
  log("OK menubar+hotkeys")
end
