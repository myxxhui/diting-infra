#!/usr/bin/env bash
# 修复已部署新加坡代理 ECS 上 3proxy systemd 重启循环
# 与 deploy-engine user-data-proxy.sh 目标配置对齐（Type=simple · 无 daemon · 长连接超时放宽）
# 用法：bash scripts/fix-sg-3proxy-systemd.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/sg-anthropic-proxy-helpers.sh
source "$SCRIPT_DIR/sg-anthropic-proxy-helpers.sh"

sg_proxy_load_env "$INFRA_ROOT"
PW="$(sg_proxy_resolve_password "$INFRA_ROOT")"
CONN="$INFRA_ROOT/sg-proxy.conn"
PORT="$(yq eval '.anthropic_proxy.port // 3128' "$INFRA_ROOT/config/diting-prod.yaml")"
USER="$(yq eval '.anthropic_proxy.user // "ditingproxy"' "$INFRA_ROOT/config/diting-prod.yaml")"
sg_proxy_resolve_endpoint "$INFRA_ROOT" diting prod "$CONN" "$PORT"

echo "▶ 修复 sg-proxy 3proxy systemd · ${PROXY_IP}:${PROXY_PORT}"

sshpass -p "${TF_VAR_instance_password:-$PW}" ssh -o StrictHostKeyChecking=no "root@${PROXY_IP}" \
  "PROXY_USER='${USER}' PROXY_PASS='${PW}' PROXY_PORT='${PROXY_PORT}' bash -s" <<'REMOTE'
set -euo pipefail
cp /etc/3proxy/3proxy.cfg /etc/3proxy/3proxy.cfg.bak.$(date +%s) 2>/dev/null || true
cat > /etc/3proxy/3proxy.cfg <<EOF
pidfile /run/3proxy.pid
maxconn 200
nserver 8.8.8.8
nserver 223.5.5.5
nscache 65536
timeouts 1 5 30 300 600 3600 15 300
auth strong
users ${PROXY_USER}:CL:${PROXY_PASS}
proxy -p${PROXY_PORT}
EOF
cat > /etc/systemd/system/3proxy.service <<'UNIT'
[Unit]
Description=3proxy Anthropic egress
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl reset-failed 3proxy || true
pkill -x 3proxy || true
sleep 1
systemctl restart 3proxy
sleep 2
systemctl is-active 3proxy
systemctl show 3proxy -p NRestarts,ActiveState
ss -lntp | grep "${PROXY_PORT}"
REMOTE

echo "✅ sg-proxy 3proxy 已修复"
