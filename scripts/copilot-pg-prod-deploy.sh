#!/usr/bin/env bash
# Copilot 生产部署：PG 检查 →（按需）构建推送 → Helm → 验收
# 加速：ACR 已有 tag 跳过 build；COPILOT_SKIP_BUILD=1 仅 Helm；见 make copilot-deploy-fast
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_ROOT="$(cd "$INFRA_ROOT/../diting-src" && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
export COPILOT_IMAGE_TAG="${COPILOT_IMAGE_TAG:-$(bash "$SCRIPT_DIR/copilot-image-tag.sh" resolve)}"

echo "▶ [copilot-pg] 1/4 确保 PostgreSQL 库 diting_copilot"
bash "$SCRIPT_DIR/copilot-ensure-pg-db.sh"

echo "▶ [copilot-pg] 2/4 镜像 tag=${COPILOT_IMAGE_TAG}"
bash "$SCRIPT_DIR/copilot-strip-hotfix-mounts.sh" 2>/dev/null || true
if [ "${COPILOT_SKIP_BUILD:-0}" = "1" ]; then
  echo "   COPILOT_SKIP_BUILD=1 · 跳过构建推送（仅后续 Helm）"
elif [ "${COPILOT_FORCE_BUILD:-0}" = "1" ]; then
  echo "   COPILOT_FORCE_BUILD=1 · 强制构建推送"
  make -C "$INFRA_ROOT" copilot-build-push COPILOT_IMAGE_TAG="$COPILOT_IMAGE_TAG"
elif bash "$SCRIPT_DIR/copilot-acr-image-exists.sh" "$COPILOT_IMAGE_TAG"; then
  echo "   ACR 已有 ${COPILOT_IMAGE_TAG} · 跳过构建推送"
else
  echo "   ACR 无 ${COPILOT_IMAGE_TAG} · 构建并推送"
  make -C "$INFRA_ROOT" copilot-build-push COPILOT_IMAGE_TAG="$COPILOT_IMAGE_TAG"
fi

echo "▶ [copilot-pg] 3/4 Helm upgrade（postgres + image.tag）"
bash "$SCRIPT_DIR/copilot-helm-upgrade.sh"

echo "▶ [copilot-pg] 4/4 验收"
make -C "$INFRA_ROOT" copilot-wave4-verify

echo "✅ [copilot-pg] 完成 · 镜像 tag=${COPILOT_IMAGE_TAG}"
