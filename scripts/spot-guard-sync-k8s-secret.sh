#!/usr/bin/env bash
# 将 Spot Guard 所需 AK/SK + 代理密码同步为 K8s Secret diting-spot-guard
# 工作目录：diting-infra · 密钥来自 .env（不入库）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="${INFRA_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONFIG_ROOT="${1:-$INFRA_ROOT/config}"
CFG="$CONFIG_ROOT/diting-prod.yaml"
STACK_NS="${STACK_NS:-$(command -v yq >/dev/null && yq eval '.stack.namespace // "platform"' "$CFG" 2>/dev/null || echo platform)}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
export KUBECONFIG

if ! yq eval '.stack.spotGuardCron.enabled // false' "$CFG" 2>/dev/null | grep -q true; then
  echo "[spot-guard-sync] spotGuardCron.enabled=false · 跳过 Secret"
  exit 0
fi

if [ -f "$INFRA_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$INFRA_ROOT/.env"
  set +a
fi

AK="${ALICLOUD_ACCESS_KEY:-${ALIYUN_AK:-}}"
SK="${ALICLOUD_SECRET_KEY:-${ALIYUN_SK:-}}"
if [ -z "$AK" ] || [ -z "$SK" ]; then
  echo "⚠️  [spot-guard-sync] 缺 ALICLOUD_ACCESS_KEY/SECRET · 跳过 diting-spot-guard"
  exit 0
fi

PROXY_PASS="${ANTHROPIC_PROXY_PASSWORD:-${TF_VAR_instance_password:-}}"
PROXY_HOST="${ANTHROPIC_PROXY_HOST:-}"
SG_CONN="$INFRA_ROOT/sg-proxy.conn"
if [ -z "$PROXY_HOST" ] && [ -f "$SG_CONN" ]; then
  PROXY_HOST="$(grep -E '^(SG_PROXY_PUBLIC_IP|ANTHROPIC_PROXY_HOST)=' "$SG_CONN" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' ' || true)"
fi

kubectl create secret generic diting-spot-guard -n "$STACK_NS" \
  --from-literal=ALICLOUD_ACCESS_KEY="$AK" \
  --from-literal=ALICLOUD_SECRET_KEY="$SK" \
  --from-literal=SPOT_GUARD_PROXY_PASSWORD="${PROXY_PASS:-}" \
  --from-literal=SPOT_GUARD_PROXY_HOST="${PROXY_HOST:-}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[OK] Secret diting-spot-guard @ $STACK_NS (proxy_host=${PROXY_HOST:-空})"
