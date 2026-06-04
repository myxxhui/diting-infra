#!/usr/bin/env bash
# 在 postgresql-l2（ESSD 数据盘）上创建 Copilot 库 diting_copilot（幂等）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
CFG="${CONFIG_ROOT:-$INFRA_ROOT/config}/diting-prod.yaml"
NS="$(yq eval '.stack.namespace // "platform"' "$CFG")"
DB="$(yq eval '.stack.copilot.postgres.database // "diting_copilot"' "$CFG")"
PG_USER="$(yq eval '.stack.copilot.postgres.user // "postgres"' "$CFG")"
PG_PASS="$(yq eval '.stack.copilot.postgres.password // "postgres"' "$CFG")"
PG_POD="postgresql-l2-0"

kubectl wait --for=condition=ready pod/"$PG_POD" -n "$NS" --timeout=300s
EXISTS="$(kubectl exec -n "$NS" "$PG_POD" -- env PGPASSWORD="$PG_PASS" \
  psql -U "$PG_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB}'" 2>/dev/null | tr -d '[:space:]')"
if [ "$EXISTS" = "1" ]; then
  echo "[copilot-ensure-pg-db] 数据库已存在: ${DB} @ ${NS}/${PG_POD}"
else
  kubectl exec -n "$NS" "$PG_POD" -- env PGPASSWORD="$PG_PASS" \
    psql -U "$PG_USER" -d postgres -v ON_ERROR_STOP=1 -c \
    "CREATE DATABASE \"${DB}\" WITH TEMPLATE template0 ENCODING 'UTF8'"
  echo "[copilot-ensure-pg-db] 已创建数据库: ${DB}"
fi
