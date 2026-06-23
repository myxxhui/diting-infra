#!/usr/bin/env bash
# 探测新加坡 Anthropic 代理是否可用（不创建 ECS/EIP）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/deploy-warnings-lib.sh
source "$SCRIPT_DIR/lib/deploy-warnings-lib.sh"
# shellcheck source=sg-anthropic-proxy-helpers.sh
source "$SCRIPT_DIR/sg-anthropic-proxy-helpers.sh"

CONFIG_ROOT="${CONFIG_ROOT:-$INFRA_ROOT/config}"
CFG="$CONFIG_ROOT/diting-prod.yaml"
CONN="$INFRA_ROOT/sg-proxy.conn"
PROJ="${SG_PROXY_PROJECT:-diting}"
ENV="$(yq eval '.anthropic_proxy.deploy_engine_env // "sg-proxy"' "$CFG")"
USER="$(yq eval '.anthropic_proxy.user // "ditingproxy"' "$CFG")"
PORT="$(yq eval '.anthropic_proxy.port // 3128' "$CFG")"

sg_proxy_load_env "$INFRA_ROOT"
PW="$(sg_proxy_resolve_password "$INFRA_ROOT")"

_fail() {
  local msg="$1"
  if [ -n "${DEPLOY_WARNINGS_FILE:-}" ]; then
    deploy_warn "$msg"
    exit 0
  fi
  echo "❌ $msg" >&2
  exit 1
}

sg_proxy_resolve_endpoint "$INFRA_ROOT" "$PROJ" "$ENV" "$CONN" "$PORT" \
  || _fail "无 sg-proxy Terraform output/conn"

if sg_proxy_health_check "$PROXY_IP" "${PROXY_PORT:-$PORT}" "$USER" "$PW" 1 1; then
  echo "✅ sg-proxy 健康 ip=$PROXY_IP port=${PROXY_PORT:-$PORT}"
else
  _fail "sg-proxy 不可用 ip=$PROXY_IP port=${PROXY_PORT:-$PORT}"
fi
