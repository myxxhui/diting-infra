#!/usr/bin/env bash
# 从 diting-src/.env 读取 COPILOT_SMTP_* 并 helm upgrade copilot secret（P1 tier-2 邮件链）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_ENV="${SRC_ENV:-$INFRA_ROOT/../diting-src/.env}"
CFG="${CONFIG_ROOT:-$INFRA_ROOT/config}/diting-prod.yaml"
STACK_NS="$(yq eval '.stack.namespace // "platform"' "$CFG")"

[ -f "$SRC_ENV" ] || { echo "错误: 缺少 $SRC_ENV"; exit 1; }
set -a && source "$SRC_ENV" && set +a
[ -n "${COPILOT_SMTP_USERNAME:-}" ] && [ -n "${COPILOT_SMTP_PASSWORD:-}" ] && [ -n "${COPILOT_SMTP_TO:-}" ] \
  || { echo "错误: $SRC_ENV 缺 COPILOT_SMTP_USERNAME/PASSWORD/TO"; exit 1; }

TMP="$(mktemp)"
yq eval '{"storage": .stack.storage, "schemaInit": .stack.schemaInit, "module_a": .stack.module_a, "ingest": .stack.ingest, "copilot": .stack.copilot}' "$CFG" > "$TMP"
yq eval -i "
  .copilot.redisHost = \"redis-master.${STACK_NS}.svc.cluster.local\" |
  .copilot.redisPort = \"6379\" |
  .copilot.redisDb = \"0\" |
  .copilot.smtp.enabled = true |
  .copilot.smtp.host = \"${COPILOT_SMTP_HOST:-smtp.126.com}\" |
  .copilot.smtp.port = \"${COPILOT_SMTP_PORT:-465}\" |
  .copilot.smtp.useSsl = \"${COPILOT_SMTP_USE_SSL:-true}\" |
  .copilot.smtp.username = \"${COPILOT_SMTP_USERNAME}\" |
  .copilot.smtp.password = \"${COPILOT_SMTP_PASSWORD}\" |
  .copilot.smtp.from = \"${COPILOT_SMTP_FROM:-$COPILOT_SMTP_USERNAME}\" |
  .copilot.smtp.to = \"${COPILOT_SMTP_TO}\"
" "$TMP"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
helm upgrade diting-stack "$INFRA_ROOT/charts/diting-stack" -n "$STACK_NS" -f "$TMP" --wait --timeout=5m
rm -f "$TMP"
kubectl rollout status deployment/diting-copilot -n "$STACK_NS" --timeout=120s
echo "✅ Copilot SMTP 已同步 · Redis db/0 · namespace=$STACK_NS"
