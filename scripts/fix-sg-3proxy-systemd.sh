#!/usr/bin/env bash
# 修复已部署新加坡代理 ECS 上 3proxy systemd 重启循环（主目录实现，不改 deploy-engine 子模块）
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

sg_proxy_apply_3proxy_runtime_fix "$PROXY_IP" "$PROXY_PORT" "$USER" "$PW" "${TF_VAR_instance_password:-$PW}"
echo "✅ sg-proxy 3proxy 已修复"
