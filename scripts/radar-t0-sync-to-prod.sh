#!/usr/bin/env bash
# 本机 radar T0 缓存 → 生产 copilot PVC /data/radar_t0_cache/
# 前置：KUBECONFIG 可达 platform/diting-copilot；本机已 make radar-t0-prefetch-with-t2（或 radar-t0-prefetch）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_CACHE="${RADAR_T0_CACHE_DIR:-$INFRA_ROOT/../diting-src/data/cache/radar_t0}"
NS="${RADAR_T0_SYNC_NS:-platform}"
DEPLOY="${RADAR_T0_SYNC_DEPLOY:-diting-copilot}"
POD_PATH="/data/radar_t0_cache"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"

[ -d "$SRC_CACHE" ] || { echo "❌ 本地缓存目录不存在: $SRC_CACHE（先 make radar-t0-prefetch-with-t2）"; exit 1; }
count=$(find "$SRC_CACHE" -maxdepth 1 -name '*.json' ! -name manifest.json 2>/dev/null | wc -l | tr -d ' ')
[ "$count" -gt 0 ] || { echo "❌ $SRC_CACHE 无标的 json"; exit 1; }

echo "▶ [radar-t0-sync] 本地 $SRC_CACHE ($count 个 json) → pod:$POD_PATH"
kubectl exec -n "$NS" "deployment/$DEPLOY" -- mkdir -p "$POD_PATH"
for f in "$SRC_CACHE"/*.json; do
  base=$(basename "$f")
  kubectl cp "$f" "$NS/$(kubectl get pod -n "$NS" -l component=copilot -o jsonpath='{.items[0].metadata.name}'):$POD_PATH/$base"
done
echo "✅ [radar-t0-sync] 已同步 $count 个文件到 $DEPLOY:$POD_PATH"
kubectl exec -n "$NS" "deployment/$DEPLOY" -- ls -la "$POD_PATH" | head -20
