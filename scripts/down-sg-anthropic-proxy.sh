#!/usr/bin/env bash
# 回收新加坡 Anthropic 出口代理 ECS+EIP（deploy-engine · down-proxy · env=sg-proxy）
# [Ref: deploy-sg-anthropic-proxy.sh · anthropic-proxy-vps-setup.md]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="${PROJECT:-diting}"
CFG="${CONFIG_ROOT:-$INFRA_ROOT/config}/diting-prod.yaml"
PROXY_ENV="$(yq eval '.anthropic_proxy.deploy_engine_env // "sg-proxy"' "$CFG")"

if [ -f "$INFRA_ROOT/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$INFRA_ROOT/.env"
  set +a
fi

export CONFIG_ROOT="$INFRA_ROOT/config"
export TF_VAR_instance_password="${TF_VAR_instance_password:-}"

echo "▶ [down-sg-anthropic-proxy] PROJECT=$PROJECT ENV=$PROXY_ENV（仅销 STACK=proxy 的 ECS+EIP，保留 VPC/SG/OSS）"
ENV="$PROXY_ENV" make -C "$INFRA_ROOT/deploy-engine" down-proxy "$PROJECT" "$PROXY_ENV"

echo "✅ [down-sg-anthropic-proxy] 新加坡代理 ECS+EIP 已回收"
echo "   再次 make deploy diting prod 且 anthropic_proxy.enabled=true 时将重建并 sync-anthropic-proxy-to-copilot"
