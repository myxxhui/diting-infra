#!/usr/bin/env bash
# 回收新加坡 Anthropic 出口代理 ECS+EIP（deploy-engine · down-proxy · env=sg-proxy）
# [Ref: deploy-sg-anthropic-proxy.sh · anthropic-proxy-vps-setup.md]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=sg-anthropic-proxy-helpers.sh
source "$SCRIPT_DIR/sg-anthropic-proxy-helpers.sh"
PROJECT="${PROJECT:-diting}"
CFG="${CONFIG_ROOT:-$INFRA_ROOT/config}/diting-prod.yaml"
CONN_FILE="${INFRA_ROOT}/sg-proxy.conn"
PROXY_ENV="$(yq eval '.anthropic_proxy.deploy_engine_env // "sg-proxy"' "$CFG")"
PROXY_REGION="$(grep -E '^\s*region\s*=' "${CONFIG_ROOT:-$INFRA_ROOT/config}/terraform-${PROJECT}-${PROXY_ENV}.tfvars" 2>/dev/null | head -1 | sed -E 's/^[^=]*=\s*"?([^"]+)"?.*/\1/' | tr -d ' ')"
PROXY_REGION="${PROXY_REGION:-ap-southeast-1}"

sg_proxy_load_env "$INFRA_ROOT"
export CONFIG_ROOT="$INFRA_ROOT/config"
export TF_VAR_instance_password="${TF_VAR_instance_password:-}"

echo "▶ [down-sg-anthropic-proxy] PROJECT=${PROJECT} ENV=${PROXY_ENV} (仅销 STACK=proxy 的 ECS+EIP，保留 VPC/SG/OSS)"
ENV="$PROXY_ENV" make -C "$INFRA_ROOT/deploy-engine" down-proxy "$PROJECT" "$PROXY_ENV" || true

# state 为空 / 漂移时 Terraform destroy 会 0 destroyed，须补扫云上孤儿（deploy 健康复用路径不写 state）
if sg_proxy_state_has_instance "$INFRA_ROOT" "$PROJECT" "$PROXY_ENV" 2>/dev/null; then
  echo "⚠️  [down-sg-anthropic-proxy] Terraform state 仍含 proxy 实例，请检查 down-proxy 日志"
else
  sg_proxy_orphan_cleanup "$PROXY_REGION" "$PROXY_ENV" "$CONN_FILE"
fi

if [ -f "$CONN_FILE" ]; then
  rm -f "$CONN_FILE"
  echo "  已删除本地 $CONN_FILE"
fi

echo "✅ [down-sg-anthropic-proxy] 新加坡代理 ECS+EIP 已回收（含 state 外孤儿）"
echo "   再次 make deploy diting prod 时将重建并 sync-anthropic-proxy-to-copilot"
