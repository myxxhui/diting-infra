#!/usr/bin/env bash
# 生产 copilot pod 内 live 采集雷达 T0（写入 PVC /data/radar_t0_cache）
# 用法：SYMBOLS="300502 601138" bash scripts/radar-t0-collect-prod.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
NS="${RADAR_T0_SYNC_NS:-platform}"
DEPLOY="${RADAR_T0_SYNC_DEPLOY:-diting-copilot}"
SYMBOLS="${SYMBOLS:-300502 601138 002837 300602 002270 600312}"

args=()
for s in $SYMBOLS; do
  args+=(--symbol "$s")
done

echo "▶ [radar-t0-collect-prod] pod=$DEPLOY ns=$NS symbols=$SYMBOLS"
kubectl rollout status "deployment/$DEPLOY" -n "$NS" --timeout=300s
kubectl exec -n "$NS" "deployment/$DEPLOY" -- mkdir -p /data/radar_t0_cache
kubectl exec -n "$NS" "deployment/$DEPLOY" -- \
  env RADAR_T0_CACHE_DIR=/data/radar_t0_cache PYTHONPATH=/app \
  python3 scripts/radar_t0_prefetch.py "${args[@]}"
echo "▶ [radar-t0-collect-prod] 缓存目录："
kubectl exec -n "$NS" "deployment/$DEPLOY" -- \
  env RADAR_T0_CACHE_DIR=/data/radar_t0_cache PYTHONPATH=/app \
  python3 -c "import json; from apps.copilot.modules.radar.t0_cache import status_summary; print(json.dumps(status_summary(), ensure_ascii=False, indent=2))"
