#!/usr/bin/env bash
# 波次四正式生产部署：ACR 新镜像 + Helm values（无 ConfigMap 热修挂载）
# [Ref: 24_ §10 波次四 · migrate_step19 · radar_symbol_versions]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
NS="${STACK_NS:-platform}"
DEPLOY="${COPILOT_DEPLOY:-diting-copilot}"

echo "▶ [wave4] 1/5 移除历史 radar-hotfix 挂载（回归镜像内代码）"
bash "$SCRIPT_DIR/copilot-strip-hotfix-mounts.sh"

echo "▶ [wave4] 2/5 构建并推送 diting-copilot 镜像"
make -C "$INFRA_ROOT" copilot-build-push

echo "▶ [wave4] 3/5 Helm upgrade（波次四 env + Opus 密钥从 diting-src/.env）"
bash "$SCRIPT_DIR/copilot-sync-ai-from-src-env.sh"

echo "▶ [wave4] 4/5 强制滚动到新镜像"
kubectl rollout restart "deployment/${DEPLOY}" -n "$NS"
kubectl rollout status "deployment/${DEPLOY}" -n "$NS" --timeout=300s

echo "▶ [wave4] 5/5 生产验收"
make -C "$INFRA_ROOT" copilot-wave4-verify

echo "✅ [wave4] 波次四正式部署完成（镜像 + Helm，非热修）"
