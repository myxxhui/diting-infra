#!/usr/bin/env bash
# Helm 升级 Copilot（sync-ai 含 helm upgrade）+ 可选 rollout 等待
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
chmod +x "$SCRIPT_DIR/copilot-image-tag.sh" "$SCRIPT_DIR/copilot-sync-ai-from-src-env.sh"
export COPILOT_IMAGE_TAG="${COPILOT_IMAGE_TAG:-$(bash "$SCRIPT_DIR/copilot-image-tag.sh" resolve)}"

echo "▶ [copilot-helm] tag=${COPILOT_IMAGE_TAG} · Helm upgrade"
bash "$SCRIPT_DIR/copilot-sync-ai-from-src-env.sh"

if [ "${COPILOT_SYNC_CONFIG_TAG:-1}" = "1" ]; then
  bash "$SCRIPT_DIR/copilot-image-tag.sh" write-config
fi

if [ "${COPILOT_WAIT_ROLLOUT:-1}" = "1" ]; then
  NS="${STACK_NS:-platform}"
  TIMEOUT="${COPILOT_ROLLOUT_TIMEOUT:-120s}"
  echo "▶ [copilot-helm] 等待 deployment/diting-copilot · timeout=${TIMEOUT}"
  env -u HTTPS_PROXY -u HTTP_PROXY kubectl rollout status "deployment/diting-copilot" -n "$NS" --timeout="$TIMEOUT"
  IMG="$(kubectl -n "$NS" get deploy diting-copilot -o jsonpath='{.spec.template.spec.containers[0].image}')"
  echo "✅ [copilot-helm] Ready · image=${IMG}"
else
  echo "✅ [copilot-helm] 完成（COPILOT_WAIT_ROLLOUT=0 跳过 rollout 等待）"
fi
