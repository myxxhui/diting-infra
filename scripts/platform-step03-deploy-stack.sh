#!/usr/bin/env bash
# P-step_03 · 在 platform ns 部署 platform-base + diting-stack + Bitnami DB
# [Ref: 03_/共享平台基础/.../step_03_CPU_Stack_按需Up.md §7.2]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_ROOT="${CONFIG_ROOT:-$INFRA_ROOT/config}"
PROJECT="${PROJECT:-diting}"
ENV="${ENV:-prod}"
CFG="$CONFIG_ROOT/${PROJECT}-${ENV}.yaml"
CONN_FILE="${CONN_FILE:-$INFRA_ROOT/prod.conn}"
# 避免 Makefile 传入绝对路径时与 INFRA_ROOT 重复拼接
case "$CONN_FILE" in /*) ;; *) CONN_FILE="$INFRA_ROOT/$CONN_FILE" ;; esac
DITING_KUBECONFIG="$HOME/.kube/config-${PROJECT}-${ENV}"

command -v yq >/dev/null 2>&1 || { echo "错误: 需要 yq"; exit 1; }
# 强制使用 diting-prod kubeconfig，忽略 shell 里指向 ACK 的 KUBECONFIG=/root/kubeconfig
if [ -f "$DITING_KUBECONFIG" ]; then
  bash "$SCRIPT_DIR/kubecm-helpers.sh" add-and-switch "$PROJECT" "$ENV" || true
else
  echo "错误: 缺少 $DITING_KUBECONFIG，请先 make kubeconfig-sync prod diting"
  exit 1
fi
export KUBECONFIG="$HOME/.kube/config"
kubectl config use-context "${PROJECT}-${ENV}" 2>/dev/null || kubectl config use-context default
SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo '')"
NODE_COUNT="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo "[platform-step03-deploy] context=$(kubectl config current-context) server=$SERVER nodes=$NODE_COUNT"
if [ -z "$SERVER" ] || ! kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
  echo "错误: 无法连接 diting-prod 集群（server=$SERVER）"
  exit 1
fi
if [ "${NODE_COUNT:-0}" -gt 3 ]; then
  echo "错误: 当前集群有 ${NODE_COUNT} 个节点，疑似 ACK 而非 diting-prod（应为 1 台 K3s）"
  echo "  请: export KUBECONFIG=\$HOME/.kube/config && kubecm switch diting-prod"
  exit 1
fi
command -v helm >/dev/null 2>&1 || { echo "错误: 需要 helm"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "错误: 需要 kubectl"; exit 1; }
[ -f "$CFG" ] || { echo "错误: 配置不存在 $CFG"; exit 1; }

STACK_NS="$(yq eval '.stack.namespace // "platform"' "$CFG")"
echo "[platform-step03-deploy] namespace=$STACK_NS"

# ── 1) 节点 label=base（H4）────────────────────────────────────────────
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  kubectl label node "$node" stack.diting/node=base --overwrite >/dev/null
  echo "  [H4] node $node label stack.diting/node=base ✅"
done

# ── 2) platform-base（P1~P4）──────────────────────────────────────────
PB_SET="storageclassNas.enabled=true,nvidiaRuntimeClass.enabled=false"
ACR_MANIFEST="$INFRA_ROOT/charts/diting-stack/manifests/acr-pull-secret.yaml"
if [ -f "$ACR_MANIFEST" ] && command -v yq >/dev/null 2>&1; then
  ACR_B64="$(yq eval '.data[".dockerconfigjson"] // ""' "$ACR_MANIFEST" 2>/dev/null || true)"
  if [ -n "$ACR_B64" ] && [ "$ACR_B64" != "null" ]; then
    PB_SET="$PB_SET,acrPullSecret.dockerconfigjson=${ACR_B64}"
  fi
fi
if helm list -A 2>/dev/null | grep -q diting-platform-base; then
  helm upgrade diting-platform-base "$INFRA_ROOT/charts/diting-platform-base" \
    --set "$PB_SET" --wait --timeout=5m
else
  helm install diting-platform-base "$INFRA_ROOT/charts/diting-platform-base" \
    --set "$PB_SET" --wait --timeout=5m
fi
echo "  [P1~P4] diting-platform-base ✅"

# ── 3) 从 default 迁出（若存在）────────────────────────────────────────
_migrate_pv() {
  local pv_name="$1"
  local pvc_name="$2"
  local from_ns="$3"
  if kubectl get pvc "$pvc_name" -n "$from_ns" >/dev/null 2>&1; then
    echo "  [migrate] 释放 PVC $from_ns/$pvc_name → PV $pv_name"
    kubectl delete pvc "$pvc_name" -n "$from_ns" --wait=true 2>/dev/null || true
    sleep 2
    if kubectl get pv "$pv_name" >/dev/null 2>&1; then
      kubectl patch pv "$pv_name" -p '{"spec":{"claimRef": null}}' 2>/dev/null || true
    fi
  fi
}

if kubectl get ns default >/dev/null 2>&1; then
  helm uninstall timescaledb -n default 2>/dev/null || true
  helm uninstall postgresql-l2 -n default 2>/dev/null || true
  helm uninstall diting-stack -n default 2>/dev/null || true
  _migrate_pv timescaledb-data-pv data-timescaledb-postgresql-0 default
  _migrate_pv postgresql-l2-data-pv data-postgresql-l2-0 default
fi

# ── 4) diting-stack PV/PVC（先不启 schema-init / module_a）────────────────
TMP_STACK="$(mktemp)"
yq eval '{"storage": .stack.storage, "schemaInit": (.stack.schemaInit | .enabled = false), "module_a": (.stack.module_a | .enabled = false), "ingest": .stack.ingest}' "$CFG" > "$TMP_STACK"
yq eval -i "
  .ingest.timescaleHost = \"timescaledb-postgresql.${STACK_NS}.svc.cluster.local\" |
  .ingest.postgresL2Host = \"postgresql-l2.${STACK_NS}.svc.cluster.local\" |
  .storage.timescaledb.pvc.namespace = \"${STACK_NS}\" |
  .storage.postgresL2.pvc.namespace = \"${STACK_NS}\"
" "$TMP_STACK"

if helm list -n "$STACK_NS" 2>/dev/null | grep -q diting-stack; then
  helm upgrade diting-stack "$INFRA_ROOT/charts/diting-stack" -n "$STACK_NS" -f "$TMP_STACK" --wait --timeout=8m
else
  helm install diting-stack "$INFRA_ROOT/charts/diting-stack" -n "$STACK_NS" -f "$TMP_STACK" --wait --timeout=8m
fi
rm -f "$TMP_STACK"
echo "  [S1] helm diting-stack @ ${STACK_NS} (PV/PVC) OK"

# ── 5) Bitnami DB（S2/S3）──────────────────────────────────────────────
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
# 国内访问 charts.bitnami.com 常 >10min 无响应；90s 超时后用本地 index 继续
if command -v timeout >/dev/null 2>&1; then
  timeout 90 helm repo update bitnami >/dev/null 2>&1 \
    || echo "  ⚠️ bitnami repo update 超时/失败，使用本地 index 继续"
else
  helm repo update bitnami >/dev/null 2>&1 || true
fi

PORT_L1="$(yq eval '(.stack.databases.timescaledb.service.nodePort // .ports.timescaledb) // 30001' "$CFG")"
PORT_L2="$(yq eval '(.stack.databases.postgres_l2.service.nodePort // .ports.postgres_l2) // 30002' "$CFG")"

helm upgrade --install timescaledb bitnami/postgresql -n "$STACK_NS" \
  --set auth.username="$(yq eval '.stack.databases.timescaledb.auth.username // "postgres"' "$CFG")" \
  --set auth.password="$(yq eval '.stack.databases.timescaledb.auth.password // "postgres"' "$CFG")" \
  --set auth.database="$(yq eval '.stack.databases.timescaledb.auth.database // "postgres"' "$CFG")" \
  --set primary.persistence.enabled=true \
  --set primary.persistence.existingClaim=data-timescaledb-postgresql-0 \
  --set primary.service.type=NodePort \
  --set primary.service.nodePorts.postgresql="$PORT_L1" \
  --wait --timeout=8m

helm upgrade --install postgresql-l2 bitnami/postgresql -n "$STACK_NS" \
  --set auth.username="$(yq eval '.stack.databases.postgres_l2.auth.username // "postgres"' "$CFG")" \
  --set auth.password="$(yq eval '.stack.databases.postgres_l2.auth.password // "postgres"' "$CFG")" \
  --set auth.database="$(yq eval '.stack.databases.postgres_l2.auth.database // "diting_l2"' "$CFG")" \
  --set primary.persistence.enabled=true \
  --set primary.persistence.existingClaim=data-postgresql-l2-0 \
  --set primary.service.type=NodePort \
  --set primary.service.nodePorts.postgresql="$PORT_L2" \
  --wait --timeout=8m

echo "  [S2/S3] TimescaleDB + PG-L2 @ $STACK_NS ✅"

# ── 5b) Redis（S2b · 当 deploy_control.enable_redis 或 stack.databases.redis.enabled）──
ENABLE_REDIS="$(yq eval '.deploy_control.enable_redis // false' "$CFG")"
REDIS_DB_ENABLED="$(yq eval '.stack.databases.redis.enabled // false' "$CFG")"
if [ "$ENABLE_REDIS" = "true" ] || [ "$REDIS_DB_ENABLED" = "true" ]; then
  REDIS_VALUES="$CONFIG_ROOT/redis-values-${PROJECT}-${ENV}.yaml"
  [ -f "$REDIS_VALUES" ] || REDIS_VALUES="$CONFIG_ROOT/redis-values-prod.yaml"
  if [ -f "$REDIS_VALUES" ]; then
    helm upgrade --install redis bitnami/redis -n "$STACK_NS" -f "$REDIS_VALUES" --wait --timeout=8m
    echo "  [S2b] Redis @ $STACK_NS ✅"
  else
    echo "  [S2b] ⚠️ Redis values 缺失，跳过"
  fi
fi

# ── 6) diting-stack 全量（schema-init + module_a）──────────────────────
TMP_FULL="$(mktemp)"
yq eval '{"storage": .stack.storage, "schemaInit": .stack.schemaInit, "module_a": .stack.module_a, "ingest": .stack.ingest, "copilot": .stack.copilot}' "$CFG" > "$TMP_FULL"
yq eval -i "
  .ingest.timescaleHost = \"timescaledb-postgresql.${STACK_NS}.svc.cluster.local\" |
  .ingest.postgresL2Host = \"postgresql-l2.${STACK_NS}.svc.cluster.local\" |
  .module_a.timescaleHost = \"timescaledb-postgresql.${STACK_NS}.svc.cluster.local\" |
  .module_a.postgresL2Host = \"postgresql-l2.${STACK_NS}.svc.cluster.local\" |
  .storage.timescaledb.pvc.namespace = \"${STACK_NS}\" |
  .storage.postgresL2.pvc.namespace = \"${STACK_NS}\"
" "$TMP_FULL"
if yq eval '.copilot.enabled // false' "$TMP_FULL" | grep -q true; then
  yq eval -i "
    .copilot.redisHost = \"redis-master.${STACK_NS}.svc.cluster.local\" |
    .copilot.redisPort = \"6379\"
  " "$TMP_FULL"
fi
helm upgrade diting-stack "$INFRA_ROOT/charts/diting-stack" -n "$STACK_NS" -f "$TMP_FULL" --wait --timeout=8m
rm -f "$TMP_FULL"
echo "  [S4/S5] schema-init + module_a chart 升级 ✅"

# ── 7) prod.conn + 集群内 Secret ───────────────────────────────────────
"$SCRIPT_DIR/prod-write-conn.sh" "$CONFIG_ROOT" "deploy-engine" "$CONN_FILE" "$PROJECT" "$ENV" || true
STACK_NS="$STACK_NS" "$SCRIPT_DIR/prod-sync-conn-secret.sh" "$CONFIG_ROOT" "$CONN_FILE" "$PROJECT" "$ENV"

# 等待 schema-init Job（S4）
for _ in $(seq 1 60); do
  if kubectl get jobs -n "$STACK_NS" -l component=schema-init -o jsonpath='{.items[0].status.succeeded}' 2>/dev/null | grep -q 1; then
    echo "  [S4] schema-init Job Complete ✅"
    break
  fi
  sleep 5
done

echo "[platform-step03-deploy] 完成"
