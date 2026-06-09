#!/usr/bin/env bash
# 等待 diting-copilot Deployment rollout（可选快速部署末尾）
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
NS="${STACK_NS:-platform}"
TIMEOUT="${COPILOT_ROLLOUT_TIMEOUT:-120s}"

echo "▶ [copilot-rollout] 等待 deployment/diting-copilot · timeout=${TIMEOUT}"
env -u HTTPS_PROXY -u HTTP_PROXY kubectl rollout status "deployment/diting-copilot" -n "$NS" --timeout="$TIMEOUT"
IMG="$(kubectl -n "$NS" get deploy diting-copilot -o jsonpath='{.spec.template.spec.containers[0].image}')"
echo "✅ [copilot-rollout] Ready · image=${IMG}"
