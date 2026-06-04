#!/usr/bin/env bash
# 部署新加坡 Anthropic 出口代理 ECS（deploy-engine · env=sg-proxy · STACK=proxy）
# [Ref: deploy-engine deploy-proxy · anthropic-proxy-vps-setup.md]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="${PROJECT:-diting}"
CFG="${CONFIG_ROOT:-$INFRA_ROOT/config}/diting-prod.yaml"
CONN_FILE="${INFRA_ROOT}/sg-proxy.conn"

if [ -f "$INFRA_ROOT/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$INFRA_ROOT/.env"
  set +a
fi
# make 默认 ENV=dev 会覆盖；从 diting-prod.yaml 读取代理环境名
ENV="$(yq eval '.anthropic_proxy.deploy_engine_env // "sg-proxy"' "$CFG")"
export ENV

[ -n "${TF_VAR_instance_password:-}" ] || {
  echo "错误: 请在 diting-infra/.env 设置 TF_VAR_instance_password（与 proxy 认证可复用）"
  exit 1
}

export TF_VAR_instance_password
export CONFIG_ROOT="$INFRA_ROOT/config"

echo "▶ [deploy-sg-anthropic-proxy] PROJECT=$PROJECT ENV=$ENV region=ap-southeast-1"
make -C "$INFRA_ROOT/deploy-engine" deploy-proxy "$PROJECT" "$ENV"

TF_DIR="$INFRA_ROOT/deploy-engine/deploy/terraform/alicloud"
PROXY_IP="$(cd "$TF_DIR" && terraform output -raw anthropic_proxy_public_ip 2>/dev/null || true)"
PROXY_PORT="$(cd "$TF_DIR" && terraform output -raw anthropic_proxy_port 2>/dev/null || echo "3128")"

if [ -z "$PROXY_IP" ] || [ "$PROXY_IP" = "null" ]; then
  echo "错误: 未获取 anthropic_proxy_public_ip，请检查 terraform output"
  exit 1
fi

PROXY_USER="${ANTHROPIC_PROXY_USER:-ditingproxy}"
{
  echo "SG_PROXY_PUBLIC_IP=$PROXY_IP"
  echo "SG_PROXY_PORT=$PROXY_PORT"
  echo "SG_PROXY_USER=$PROXY_USER"
  echo "ANTHROPIC_PROXY_HOST=$PROXY_IP"
} > "$CONN_FILE"

echo "✅ [deploy-sg-anthropic-proxy] 代理 ECS 公网 IP=$PROXY_IP 端口=$PROXY_PORT"
echo "   连接信息已写入 $CONN_FILE"
echo "   下一步: make sync-anthropic-proxy-to-copilot"
