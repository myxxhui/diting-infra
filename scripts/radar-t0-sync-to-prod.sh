#!/usr/bin/env bash
# 本机 radar T0/T1/T2 版本化缓存 → 生产 copilot PVC /data/radar_t0_cache/
# 同步：根目录 *.json（latest 指针）+ versions/{symbol}/*.json（近 7 天历史）
# 前置：KUBECONFIG 可达 platform/diting-copilot；本机已 make radar-t0-prefetch-with-t2
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
ver_count=$(find "$SRC_CACHE/versions" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[ "$count" -gt 0 ] || { echo "❌ $SRC_CACHE 无标的 latest json"; exit 1; }

POD=$(kubectl get pod -n "$NS" -l component=copilot -o jsonpath='{.items[0].metadata.name}')

echo "▶ [radar-t0-sync] 本地 ${SRC_CACHE} -> pod:${POD_PATH} (latest ${count}, versions ${ver_count})"
kubectl exec -n "$NS" "deployment/$DEPLOY" -- mkdir -p "${POD_PATH}" "${POD_PATH}/versions"

for f in "$SRC_CACHE"/*.json; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  [ "$base" = "manifest.json" ] && continue
  kubectl cp "$f" "${NS}/${POD}:${POD_PATH}/${base}"
done

if [ -d "$SRC_CACHE/versions" ]; then
  while IFS= read -r -d '' vf; do
    rel="${vf#"$SRC_CACHE/versions/"}"
    kubectl exec -n "$NS" "deployment/$DEPLOY" -- mkdir -p "${POD_PATH}/versions/$(dirname "$rel")"
    kubectl cp "$vf" "${NS}/${POD}:${POD_PATH}/versions/${rel}"
  done < <(find "$SRC_CACHE/versions" -name '*.json' -print0)
fi

echo "✅ [radar-t0-sync] synced latest=${count} versions=${ver_count} -> ${DEPLOY}:${POD_PATH}"
kubectl exec -n "$NS" "deployment/$DEPLOY" -- sh -c "ls -la ${POD_PATH} | head -15; echo ---; ls -la ${POD_PATH}/versions 2>/dev/null | head -10 || true"
