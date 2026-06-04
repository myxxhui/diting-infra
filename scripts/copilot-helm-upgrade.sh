#!/usr/bin/env bash
# 仅 Helm 升级 + Copilot rollout（不构建镜像；CI 已 push 或 ACR 已有 tag 时用）
# [Ref: copilot-sync-ai-from-src-env.sh]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
export COPILOT_IMAGE_TAG="${COPILOT_IMAGE_TAG:-$(git -C "$INFRA_ROOT/../diting-src" rev-parse --short HEAD 2>/dev/null || echo latest)}"

echo "▶ [copilot-helm] tag=${COPILOT_IMAGE_TAG} · 仅 Helm + rollout"
bash "$SCRIPT_DIR/copilot-sync-ai-from-src-env.sh"
echo "✅ [copilot-helm] 完成"
