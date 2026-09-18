# WorkBuddy 无法启动修复实录（PD Windows ARM64 VM）

> 环境：Parallels PD 虚拟机（Windows 11 ARM64）+ 腾讯 WorkBuddy 5.5.6
> 症状：双击 WorkBuddy 后白屏退出，无法打开主窗口

## 症状

- WorkBuddy 启动后只有白色窗口，随即退出
- 日志目录 `C:\Users\<user>\.workbuddy\logs\`
- `startup-*.log` 出现 FATAL：

```
[StartupPipeline] aborted: phase=daemon-bringup
  step=daemon.select-daemon-runtime reason=step-failed
```

- `main.log` 中 preload 重试 19 次后放弃：

```
__bootstrap exhausted all retries (attempts=19, total=90406ms, budget=90000ms)
  — renderer:ready will NOT be sent, falling back to RendererLoadGuard
```

## 根因

通过反编译 `resources/app.asar`（用 `npx @electron/asar extract`）定位到
`main/host-power-events.js` 的 `resolveClawFallbackCwd`：

**WorkBuddy daemon 启动时要创建 Claw 工作区目录** `C:\Users\<user>\WorkBuddy\Claw`：

- 若 `C:\Users\<user>\WorkBuddy` 不存在或**用户无写权限** → `mkdir` 抛 `EPERM`
- daemon 进程启动失败 → 主进程等 daemon ready 信号超时 → 整个启动管道中止

真实错误在 `main.log` 中：

```
All Claw workspace paths failed. Primary: Error: Failed to create Claw workspace
directory "C:\Users\wyu37433\WorkBuddy\Claw" (EPERM: EPERM: operation not
permitted, mkdir 'C:\Users\wyu37433\WorkBuddy\Claw').
ClawFallback: EPERM: EPERM: operation not permitted, mkdir 'C:\Users\wyu37433\WorkBuddy\ClawFallback'.
```

### 为什么目录没有写权限？

`C:\Users\wyu37433\WorkBuddy` 目录（若被某种方式创建）的 Owner 是
`BUILTIN\Administrators`，ACL 只有：

- `NT AUTHORITY\Authenticated Users: RX`
- `BUILTIN\Users: RX`
- `SYSTEM / Administrators: Full`

普通用户 `wyu37433` **没有写权限**，`mkdir` 子目录时返回 `EPERM`。

## 修复步骤

### 1. 创建 Claw 目录（用用户身份 SSH，能写）

```powershell
New-Item -ItemType Directory -Force -Path 'C:\Users\wyu37433\WorkBuddy\Claw'
New-Item -ItemType Directory -Force -Path 'C:\Users\wyu37433\WorkBuddy\ClawFallback'
```

### 2. 授权用户完全控制（用 SID 精确授权）

```powershell
# 取当前用户 SID
[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
# 例如 S-1-5-21-3174444877-3705323739-3957209053-1000

icacls 'C:\Users\wyu37433\WorkBuddy' /grant '*S-1-5-21-...-1000:(OI)(CI)F'
```

> 注意：`icacls` 的 SID 不认 `*S-1-5-21-*` 通配符，必须用完整 SID。
> `(OI)(CI)F` = 对象继承 + 容器继承 + 完全控制，子目录自动继承。

### 3. 验证可写性

```powershell
Set-Content -Path 'C:\Users\wyu37433\WorkBuddy\Claw\_test.txt' -Value 'ok'
Get-Content 'C:\Users\wyu37433\WorkBuddy\Claw\_test.txt'
Remove-Item 'C:\Users\wyu37433\WorkBuddy\Claw\_test.txt' -Force
```

### 4. 杀残留进程 + 在用户会话重启

```powershell
taskkill /F /IM WorkBuddy.exe
```

用计划任务在交互式用户会话（Session 1）启动（需用户身份创建）：

```powershell
schtasks /Create /TN "WBRestart" /TR "C:\Users\wyu37433\AppData\Local\Programs\WorkBuddy\WorkBuddy.exe" /SC ONCE /ST 00:00 /RU "wyu37433" /IT /F
schtasks /Run /TN "WBRestart"
```

> `/IT` = 仅在用户登录时运行，缺了它不会在 GUI 会话中显示窗口。
> 验证后删除：`schtasks /Delete /TN "WBRestart" /F`

## 验证结果

日志确认启动成功：

```
[StartupPipeline] step daemon.select-daemon-runtime ok (4244ms)
```

`daemon.log` 中 daemon-server 各 RPC 正常响应：
`config:getClientMenus`、`wb:extensions:list`、`wb:conversations:listPinned`、`wb:workspaces:list` 等。

`tasklist` 可见多个 `WorkBuddy.exe`（主进程 480MB+ / Tab 渲染进程 438MB）+ `node.exe`。

## 一键修复脚本

仓库内提供 `scripts/fix-workbuddy-claw.sh`：

```bash
./scripts/fix-workbuddy-claw.sh          # 默认 10.211.55.5 / wyu37433
./scripts/fix-workbuddy-claw.sh IP USER  # 自定义
```

脚本自动完成：杀残留进程 → 建目录 → 修 ACL（自动解析 SID）→ 验证可写 → 计划任务重启 → 校验进程数和日志。

## 排查要点（通用）

1. **不要只看外层错误**：`select-daemon-runtime step-failed` 只是结果，真正原因要挖 `main.log` 里子进程 stderr 转储的真实异常（找 `Error:` / `EPERM` 等关键行）。
2. **daemon 是子进程**：`daemon.log` 里 `daemon_started` 出现 ≠ 成功，主进程还在等 ready 握手（B8 打点缺失 = 失败）。
3. **app.asar 可反编译**：`npx @electron/asar extract app.asar out/`，错误信息里的函数名/路径能直接定位逻辑。
4. **SYSTEM vs 用户**：`prlctl exec` 是 SYSTEM 身份，Windows 桌面应用 GUI 要用用户会话计划任务（`/RU` + `/IT`）。
5. **PD ARM64 VM**：`PROCESSOR_ARCHITECTURE=ARM64`，但 WorkBuddy 自带运行时是 x64（`node-v22.22.2-win-x64`），这本身不是问题——别被误导去改架构。
