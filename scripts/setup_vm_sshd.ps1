# =============================================================================
# FsTTY + Codex MCP - Windows VM 端 SSH 服务准备脚本（管理员 PowerShell）
# 作用：启用 Windows OpenSSH Server 并设为自动启动
# 用法：右键“以管理员身份运行 PowerShell”，执行本脚本
# =============================================================================
Write-Host "==> 检查 OpenSSH Server 功能" -ForegroundColor Cyan
$sshd = Get-WindowsCapability -Online -Name OpenSSH.Server* 2>$null
if ($sshd.State -eq 'Installed') {
    Write-Host "    OpenSSH Server 已安装" -ForegroundColor Green
} else {
    Write-Host "    正在安装 OpenSSH Server..." -ForegroundColor Yellow
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
}

Write-Host "==> 设置 sshd 服务为自动启动并启动" -ForegroundColor Cyan
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd

Write-Host "==> 防火墙放行 22 端口" -ForegroundColor Cyan
if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
}

Write-Host "==> 验证" -ForegroundColor Cyan
Get-Service sshd | Format-List Name,Status,StartType
Write-Host "SSH 服务就绪！" -ForegroundColor Green
