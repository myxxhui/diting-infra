#!/usr/bin/env bash
# 生产 copilot pod 内：读 load_generic_t0_collect_symbols（executing ∪ radar）批量 T0 采集
# 用法：bash scripts/radar-t0-collect-prod.sh
# 可选：SYMBOL=601138 仅采单只（仍会 UPSERT 入表）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
NS="${RADAR_T0_SYNC_NS:-platform}"
DEPLOY="${RADAR_T0_SYNC_DEPLOY:-diting-copilot}"

echo "▶ [radar-t0-collect-prod] pod=$DEPLOY ns=$NS"
kubectl rollout status "deployment/$DEPLOY" -n "$NS" --timeout=300s
kubectl exec -n "$NS" "deployment/$DEPLOY" -- mkdir -p /data/radar_t0_cache

if [ -n "${SYMBOL:-}" ]; then
  echo "▶ 单标的 SYMBOL=$SYMBOL"
  kubectl exec -n "$NS" "deployment/$DEPLOY" -- \
    env RADAR_T0_CACHE_DIR=/data/radar_t0_cache PYTHONPATH=/app \
    python3 scripts/radar_t0_collect_once.py --symbol "$SYMBOL"
else
  echo "▶ 批量：通用 T0 宇宙 enabled 标的"
  kubectl exec -n "$NS" "deployment/$DEPLOY" -- \
    env RADAR_T0_CACHE_DIR=/data/radar_t0_cache PYTHONPATH=/app \
    python3 scripts/radar_t0_collect_once.py --all
fi

echo "▶ [radar-t0-collect-prod] 列表快照："
kubectl exec -n "$NS" "deployment/$DEPLOY" -- \
  env PYTHONPATH=/app python3 scripts/radar_t0_collect_once.py --list
