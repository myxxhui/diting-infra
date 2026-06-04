#!/usr/bin/env bash
# 检查 prod 平台「重建可继承」静态存储是否就绪（不执行 down/deploy）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_ROOT="${CONFIG_ROOT:-$INFRA_ROOT/config}"
PROJECT="${PROJECT:-diting}"
ENV="${ENV:-prod}"
CFG="$CONFIG_ROOT/${PROJECT}-${ENV}.yaml"
STACK_NS="$(yq eval '.stack.namespace // "platform"' "$CFG")"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-${PROJECT}-${ENV}}"

fail=0
_check() {
  local name="$1" pv="$2" pvc="$3"
  if kubectl get pv "$pv" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null | grep -q Retain \
    && kubectl get pvc -n "$STACK_NS" "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Bound; then
    echo "  ✅ $name · PV=$pv Retain · PVC=$pvc Bound"
  else
    echo "  ❌ $name · PV=$pv 或 PVC=$pvc 未就绪"
    fail=1
  fi
}

echo "[platform-persist-status] namespace=$STACK_NS"
_check "TimescaleDB L1" "$(yq eval '.stack.storage.timescaledb.pv.name' "$CFG")" "$(yq eval '.stack.storage.timescaledb.pvc.name' "$CFG")"
_check "PostgreSQL L2" "$(yq eval '.stack.storage.postgresL2.pv.name' "$CFG")" "$(yq eval '.stack.storage.postgresL2.pvc.name' "$CFG")"
if [ "$(yq eval '.stack.storage.redis.enabled // false' "$CFG")" = "true" ]; then
  _check "Redis" "$(yq eval '.stack.storage.redis.pv.name' "$CFG")" "$(yq eval '.stack.storage.redis.pvc.name' "$CFG")"
fi
if [ "$(yq eval '.stack.storage.radarT0Cache.enabled // false' "$CFG")" = "true" ]; then
  _check "雷达 T0 缓存" "$(yq eval '.stack.storage.radarT0Cache.pv.name' "$CFG")" "$(yq eval '.stack.storage.radarT0Cache.pvc.name' "$CFG")"
fi
if [ "$(yq eval '.stack.storage.copilotReports.enabled // false' "$CFG")" = "true" ]; then
  _check "Copilot 月报" "$(yq eval '.stack.storage.copilotReports.pv.name' "$CFG")" "$(yq eval '.stack.storage.copilotReports.pvc.name' "$CFG")"
fi

DISK_ID="$(terraform -chdir="$INFRA_ROOT/deploy-engine/deploy/terraform/alicloud" output -raw data_disk_id 2>/dev/null || true)"
[ -n "$DISK_ID" ] && echo "  ℹ️  terraform data_disk_id=$DISK_ID"

if [ "$fail" -eq 0 ]; then
  echo "✅ [platform-persist-status] 平台业务静态卷均已 Retain + Bound"
else
  echo "❌ [platform-persist-status] 存在未就绪项"
  exit 1
fi
