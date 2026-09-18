# FsTTY + Codex MCP：Mac 端 Codex 远程操控 PD Windows 虚拟机

通过 [FsTTY](https://github.com/359956085/FsTTY) 把 PD 虚拟机里的 SSH 会话以 MCP 工具形式暴露给 Mac 端 Codex，让 AI 安全地远程操控 Windows 机器。

## 架构

```
Mac (Codex App/CLI)
   │  Streamable HTTP (Bearer Token)
   ▼
PD 虚拟机 Windows 11 (10.211.55.5:37653/mcp)
   └─ FsTTY (17 个 MCP 工具)
        └─ SSH 会话 (sshd :22)
```

- 被控端：FsTTY 1.4.0（完整 SSH 客户端 + MCP Server）
- 操作端：Codex App / CLI（配置 `~/.codex/config.toml`）
- 安全：Agent 不接触密码/私钥，权限按会话分组控制，有审计日志

## 目录结构

```
远程工具/
├── README.md                  # 本文档（部署经验）
├── bin/
│   └── FsTTY_1.4.0_x64-setup.exe   # Windows 端安装包
└── scripts/
    ├── deploy_fstty_mcp.sh    # Mac 端一键部署脚本（写 MCP 配置 + 验证）
    └── setup_vm_sshd.ps1      # Windows VM 端 SSH 服务准备脚本
```

## 快速开始

### 1. Windows VM 端

1. 下载 `bin/FsTTY_1.4.0_x64-setup.exe`，在 VM 用户会话中安装（需 UAC）
2. （可选）运行 `scripts/setup_vm_sshd.ps1` 确保 OpenSSH Server 已启用
3. 打开 FsTTY，新建 SSH 会话（如 `127.0.0.1:22`）
4. 设置 → MCP → 开启 Streamable HTTP，记下端口（默认 37653）和 Bearer Token

### 2. Mac 端

```bash
./scripts/deploy_fstty_mcp.sh 10.211.55.5 <你的Token>
```

脚本会：检查 MCP 端点连通 → 备份 `~/.codex/config.toml` → 写入 `[mcp_servers.fstty]` → 验证配置

也可手动写入：

```toml
[mcp_servers.fstty]
url = "http://10.211.55.5:37653/mcp"
http_headers = { Authorization = "Bearer <你的Token>" }
startup_timeout_sec = 30
```

重启 Codex App 或新开会话后生效。

### 3. 验证

```bash
codex exec --skip-git-repo-check '列出所有 MCP 工具名称'
# 应能看到 mcp__fstty__* 系列（17 个工具）
```

## 部署经验（坑与关键点）

### 安装包必须走用户会话
- FsTTY 安装器涉及凭据服务、UAC、原用户令牌校验。
- 用 SYSTEM 身份（如 `prlctl exec`）静默安装会失败或产生错误安装登记。
- **正确做法**：把安装包拷到 VM 桌面，通过计划任务在用户会话（Session 1）里启动 GUI 安装器，由用户在 VM 桌面确认 UAC。
- 计划任务创建要带 `/RU <用户名> /IT`，否则 SYSTEM 上下文无法映射用户 SID。

### Mac 到 VM 的连接
- PD 虚拟机默认网络是 `10.211.55.x` 段（宿主机为 `.1`）。
- Windows 防火墙会拦 ICMP（ping 不通），但 TCP 22/37653 是通的，用 `nc -z` 或 curl 验证端口。
- SSH 免密：`ssh wyu37433@10.211.55.5` 可直接连（需先配置密钥/密码）。

### FsTTY MCP 握手细节
- Streamable HTTP 端点要求 `Accept: application/json, text/event-stream`，否则返回 `Not Acceptable`。
- `initialize` 返回 `serverInfo: rmcp 3.0.0-beta.3`，capabilities 含 `tools`。
- 权限不足时服务器返回 `get_permission_guide` 指引，按提示在 FsTTY 设置里开启对应权限即可。

### 权限矩阵（重要）
- 文件读取默认开启；文件传输/命令/编辑/删除默认关闭。
- 命令权限可能绕过编辑/删除限制，只授予可信 Agent。
- 新会话分组默认未向 MCP 开放，需手动授权。

### 安全边界
- HTTP 明文传输，只用于可信局域网/VPN，不要暴露公网。
- 审计日志：`%APPDATA%\FsTTY\logs\mcp-audit-YYYY-MM-DD.log`（保留 15 天）。
- MCP 工具不会返回密码、私钥、Token。

## 环境参考

- Mac：Codex CLI 0.154.0
- PD：Windows 11，IP 10.211.55.5，OpenSSH Server (22) 已启用
- FsTTY：v1.4.0 x64，MCP 端口 37653
- 协议：Streamable HTTP (rmcp 3.0.0-beta.3)

## License

MIT

## WorkBuddy 修复实录

PD Windows ARM64 VM 中 WorkBuddy 白屏退出的完整诊断与修复经验。

### 问题现象

- WorkBuddy 启动后白屏退出，日志 `startup-*.log` 报：
  ```
  StartupPipeline aborted: phase=daemon-bringup step=daemon.select-daemon-runtime reason=step-failed
  ```

### 根因

WorkBuddy daemon 启动时创建 `C:\Users\<user>\WorkBuddy\Claw` 工作区目录，若目录不存在或用户无写权限 → `EPERM` → daemon 起不来 → 主进程等 ready 信号超时 → 白屏退出。

常见触发条件：
- `C:\Users\<user>\WorkBuddy` 目录 ACL 只给了 Administrators/SYSTEM，普通用户只有 RX
- PD 虚拟机首次安装或权限重置后出现

### 修复方法

```bash
# 一键修复（Mac 端执行）
./scripts/fix-workbuddy-claw.sh [VM_IP] [VM_USER]
```

脚本自动：杀残留进程 → 创建 Claw/ClawFallback 目录 → 修 ACL 授权 → 验证可写 → 计划任务重启 WorkBuddy → 校验启动日志。

详细步骤见 [docs/WORKBUDDY_FIX.md](docs/WORKBUDDY_FIX.md)。

### 排查要点

1. `daemon.log` 出现 `daemon_started` ≠ 成功，还需主进程等 ready 握手
2. `main.log` 中找真正异常（`EPERM` / `Error:` 等），外层错误只是结果
3. `app.asar` 可用 `npx @electron/asar extract` 反编译分析
4. `prlctl exec` 是 SYSTEM 身份，GUI 应用要走用户会话计划任务（`/RU` + `/IT`）
5. PD ARM64 VM 的 `PROCESSOR_ARCHITECTURE=ARM64` 不是问题所在，别被误导
