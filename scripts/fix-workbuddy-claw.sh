#!/usr/bin/env bash
# fix-workbuddy-claw.sh
# 修复 WorkBuddy 在 PD Windows ARM64 VM 中无法启动的 Claw 工作区权限问题
#
# 用法：
#   ./fix-workbuddy-claw.sh                    # 使用默认配置
#   ./fix-workbuddy-claw.sh 10.211.55.5 wyu37433  # 指定 IP 和用户名
#
# 前提条件：
#   - Mac 端能通过 SSH 连到 VM（免密或密码）
#   - VM 中 WorkBuddy 已安装但启动失败（白屏 / select-daemon-runtime 错误）

set -euo pipefail

VM_IP="${1:-10.211.55.5}"
VM_USER="${2:-wyu37433}"
VM_UUID="{6ae2e6e5-e930-4572-a962-f493297744f3}"
WORKBUDDY_EXE="C:\\Users\\${VM_USER}\\AppData\\Local\\Programs\\WorkBuddy\\WorkBuddy.exe"
LOG_DIR="C:\\Users\\${VM_USER}\\.workbuddy\\logs"

echo "=== WorkBuddy Claw Workspace Permission Fix ==="
echo "VM: ${VM_IP}  User: ${VM_USER}"

# Step 1: Kill stale processes
echo ""
echo ">>> Step 1/5: Cleaning up stale WorkBuddy processes..."
prlctl exec "${VM_UUID}" cmd /c "taskkill /F /IM WorkBuddy.exe 2>nul & taskkill /F /IM RepairApp.exe 2>nul & echo done" 2>&1 || true
sleep 2

# Step 2: Create Claw directories
echo ">>> Step 2/5: Creating workspace directories..."
ssh "${VM_USER}@${VM_IP}" "powershell -NoProfile -Command \"
  New-Item -ItemType Directory -Force -Path 'C:\\Users\\${VM_USER}\\WorkBuddy\\Claw' | Out-Null
  New-Item -ItemType Directory -Force -Path 'C:\\Users\\${VM_USER}\\WorkBuddy\\ClawFallback' | Out-Null
  Write-Host 'Directories created.'
\""

# Step 3: Fix ACL
echo ">>> Step 3/5: Fixing directory ACL permissions..."
USER_SID=$(ssh "${VM_USER}@${VM_IP}" "powershell -NoProfile -Command \"[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value\"")
echo "  User SID: ${USER_SID}"

ssh "${VM_USER}@${VM_IP}" "powershell -NoProfile -Command \"
  icacls 'C:\\Users\\${VM_USER}\\WorkBuddy' /grant '*${USER_SID}:(OI)(CI)F' 2>&1 | Out-Null
  icacls 'C:\\Users\\${VM_USER}\\WorkBuddy'
\""

# Step 4: Verify writability
echo ">>> Step 4/5: Verifying directory writability..."
ssh "${VM_USER}@${VM_IP}" "powershell -NoProfile -Command \"
  Set-Content -Path 'C:\\Users\\${VM_USER}\\WorkBuddy\\Claw\\_test.txt' -Value 'ok'
  if (Get-Content 'C:\\Users\\${VM_USER}\\WorkBuddy\\Claw\\_test.txt' -ErrorAction SilentlyContinue) {
    Write-Host 'PASS: Claw is writable'
  } else {
    Write-Host 'FAIL: Claw is not writable'
    exit 1
  }
  Remove-Item 'C:\\Users\\${VM_USER}\\WorkBuddy\\Claw\\_test.txt' -Force
\""

# Step 5: Restart WorkBuddy via scheduled task
echo ">>> Step 5/5: Restarting WorkBuddy via scheduled task..."
ssh "${VM_USER}@${VM_IP}" "schtasks /Delete /TN 'WBRestart' /F 2>nul" || true
ssh "${VM_USER}@${VM_IP}" "schtasks /Create /TN 'WBRestart' /TR '\"\\\"${WORKBUDDY_EXE}\\\"\"' /SC ONCE /ST 00:00 /RU '${VM_USER}' /IT /F"
ssh "${VM_USER}@${VM_IP}" "schtasks /Run /TN 'WBRestart'"
echo "  WorkBuddy launch command sent, waiting 15 seconds..."

sleep 15

echo ""
echo ">>> Verifying startup result..."
WORKBUDDY_COUNT=$(prlctl exec "${VM_UUID}" cmd /c "tasklist | findstr /I WorkBuddy 2>nul | find /c /v \"\"" 2>&1 | tr -d '[:space:]')
echo "  WorkBuddy.exe process count: ${WORKBUDDY_COUNT}"

echo ">>> Latest startup log:"
prlctl exec "${VM_UUID}" cmd /c "findstr /C:select-daemon-runtime ${LOG_DIR}\\main.log" 2>&1 | tail -3

ssh "${VM_USER}@${VM_IP}" "schtasks /Delete /TN 'WBRestart' /F 2>nul" || true

echo ""
if [ "${WORKBUDDY_COUNT:-0}" -ge "2" ]; then
  echo "SUCCESS: WorkBuddy fixed! Process count: ${WORKBUDDY_COUNT}"
else
  echo "WARNING: Low process count (${WORKBUDDY_COUNT:-0}), please check VM desktop"
fi
