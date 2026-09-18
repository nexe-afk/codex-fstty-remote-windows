#!/usr/bin/env bash
# =============================================================================
# FsTTY + Codex MCP 一键部署脚本（Mac 端）
# 作用：将 FsTTY MCP 配置写入 ~/.codex/config.toml，并验证连通性
# 用法：./deploy_fstty_mcp.sh <VM_IP> <MCP_TOKEN>
# 示例：./deploy_fstty_mcp.sh 10.211.55.5 fc3ab381...
# =============================================================================
set -euo pipefail

VM_IP="${1:-}"
MCP_TOKEN="${2:-}"
MCP_PORT="${3:-37653}"

if [[ -z "$VM_IP" || -z "$MCP_TOKEN" ]]; then
  echo "用法: $0 <VM_IP> <MCP_TOKEN> [MCP_PORT]"
  echo "示例: $0 10.211.55.5 fc3ab381... 37653"
  exit 1
fi

CONFIG="$HOME/.codex/config.toml"
MCP_URL="http://${VM_IP}:${MCP_PORT}/mcp"

echo "==> 1/4 检查 MCP 端点连通性"
if curl -s -o /dev/null -w "%{http_code}" --max-time 5 -X POST "$MCP_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer ${MCP_TOKEN}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"deploy","version":"1.0"}}}' | grep -q 200; then
  echo "    MCP 端点已就绪（返回 200）"
else
  echo "    ⚠️  MCP 端点无响应，请确认 VM 已开启 FsTTY HTTP 开关且 Token 正确"
fi

echo "==> 2/4 备份原配置"
if [[ -f "$CONFIG" ]]; then
  cp "$CONFIG" "${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  echo "    已备份到 ${CONFIG}.bak.*"
fi

echo "==> 3/4 写入 fstty MCP 配置"
if grep -q "mcp_servers.fstty" "$CONFIG" 2>/dev/null; then
  echo "    已存在 fstty 配置，跳过写入（如需更新请手动编辑）"
else
  cat >> "$CONFIG" <<EOF

[mcp_servers.fstty]
url = "${MCP_URL}"
http_headers = { Authorization = "Bearer ${MCP_TOKEN}" }
startup_timeout_sec = 30
EOF
  echo "    已写入 ${CONFIG}"
fi

echo "==> 4/4 验证配置"
grep -A4 "mcp_servers.fstty" "$CONFIG"

echo ""
echo "部署完成！重启 Codex App 或新开会话后即可看到 mcp__fstty__* 工具。"
