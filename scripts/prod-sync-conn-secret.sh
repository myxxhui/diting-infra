#!/usr/bin/env bash
# 将 prod.conn 同步为 K8s Secret diting-db-connection（集群内 DSN）
set -euo pipefail
CONFIG_ROOT="${1:-$(pwd)/config}"
CONN_FILE="${2:-prod.conn}"
PROJECT="${3:-diting}"
ENV="${4:-prod}"
CFG="$CONFIG_ROOT/${PROJECT}-${ENV}.yaml"
STACK_NS="${STACK_NS:-$(command -v yq >/dev/null && yq eval '.stack.namespace // "platform"' "$CFG" 2>/dev/null || echo platform)}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-${PROJECT}-${ENV}}"
export KUBECONFIG

[ -f "$CONN_FILE" ] || { echo "错误: $CONN_FILE 不存在"; exit 1; }

_TMP="$(mktemp)"
grep -E '^(TIMESCALE_DSN|PG_L2_DSN|REDIS_URL)=' "$CONN_FILE" > "$_TMP" || true
sed -i.bak \
  -e "s|\(TIMESCALE_DSN=postgresql://[^@]*@\)[^/]*|\1timescaledb-postgresql.${STACK_NS}.svc:5432|" \
  -e "s|\(PG_L2_DSN=postgresql://[^@]*@\)[^/]*|\1postgresql-l2.${STACK_NS}.svc:5432|" \
  -e "s|\(REDIS_URL=redis://\)[^/]*|\1redis-master.${STACK_NS}.svc:6379|" \
  "$_TMP" 2>/dev/null || \
sed -i '' \
  -e "s|\(TIMESCALE_DSN=postgresql://[^@]*@\)[^/]*|\1timescaledb-postgresql.${STACK_NS}.svc:5432|" \
  -e "s|\(PG_L2_DSN=postgresql://[^@]*@\)[^/]*|\1postgresql-l2.${STACK_NS}.svc:5432|" \
  -e "s|\(REDIS_URL=redis://\)[^/]*|\1redis-master.${STACK_NS}.svc:6379|" \
  "$_TMP"

kubectl create secret generic diting-db-connection --from-env-file="$_TMP" -n "$STACK_NS" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f "$_TMP" "$_TMP.bak"
echo "[OK] Secret diting-db-connection @ $STACK_NS"
