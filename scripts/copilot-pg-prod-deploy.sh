#!/usr/bin/env bash
# Copilot → PostgreSQL（postgresql-l2 / ESSD 数据盘）+ 构建推送 git sha 镜像 + Helm 升级
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_ROOT="$(cd "$INFRA_ROOT/../diting-src" && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
export COPILOT_IMAGE_TAG="${COPILOT_IMAGE_TAG:-$(git -C "$SRC_ROOT" rev-parse --short HEAD 2>/dev/null || echo latest)}"

echo "▶ [copilot-pg] 1/4 确保 PostgreSQL 库 diting_copilot"
bash "$SCRIPT_DIR/copilot-ensure-pg-db.sh"

echo "▶ [copilot-pg] 2/4 构建并推送镜像 tag=${COPILOT_IMAGE_TAG}"
bash "$SCRIPT_DIR/copilot-strip-hotfix-mounts.sh" 2>/dev/null || true
make -C "$INFRA_ROOT" copilot-build-push

echo "▶ [copilot-pg] 3/4 Helm upgrade（postgres + image.tag）"
bash "$SCRIPT_DIR/copilot-sync-ai-from-src-env.sh"

echo "▶ [copilot-pg] 4/4 验收"
make -C "$INFRA_ROOT" copilot-wave4-verify

echo "✅ [copilot-pg] 完成 · 镜像 tag=${COPILOT_IMAGE_TAG}"
