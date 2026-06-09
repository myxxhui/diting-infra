#!/usr/bin/env bash
# 仅 Helm 升级 + Copilot rollout（不构建镜像；CI 已 push 或 ACR 已有 tag 时用）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
chmod +x "$SCRIPT_DIR/copilot-resolve-image-tag.sh" "$SCRIPT_DIR/copilot-sync-image-tag-to-config.sh"
export COPILOT_IMAGE_TAG="${COPILOT_IMAGE_TAG:-$(bash "$SCRIPT_DIR/copilot-resolve-image-tag.sh")}"

echo "▶ [copilot-helm] tag=${COPILOT_IMAGE_TAG} · 仅 Helm + rollout"
bash "$SCRIPT_DIR/copilot-sync-ai-from-src-env.sh"

if [ "${COPILOT_SYNC_CONFIG_TAG:-1}" = "1" ]; then
  bash "$SCRIPT_DIR/copilot-sync-image-tag-to-config.sh"
fi
echo "✅ [copilot-helm] 完成"
