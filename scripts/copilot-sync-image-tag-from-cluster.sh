#!/usr/bin/env bash
# 从运行中 Pod 读取镜像 tag，写回 diting-prod.yaml（Helm 与线上一致）。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CFG="${CONFIG_ROOT:-$INFRA_ROOT/config}/diting-prod.yaml"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
NS="${STACK_NS:-platform}"

IMAGE="$(kubectl -n "$NS" get deploy diting-copilot -o jsonpath='{.spec.template.spec.containers[?(@.name=="copilot")].image}' 2>/dev/null || true)"
if [ -z "$IMAGE" ]; then
  echo "⚠️  无法读取 diting-copilot 镜像" >&2
  exit 1
fi
TAG="${IMAGE##*:}"
export COPILOT_IMAGE_TAG="$TAG"
echo "▶ 集群当前镜像 tag=${TAG}"
bash "$SCRIPT_DIR/copilot-sync-image-tag-to-config.sh"
