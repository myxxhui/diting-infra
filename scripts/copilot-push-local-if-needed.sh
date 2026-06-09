#!/usr/bin/env bash
# ACR 无 tag 但本地已构建 diting-copilot:<tag> 时，仅 push 不 rebuild。
# 用法: copilot-push-local-if-needed.sh [tag]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_ROOT="${SRC_ROOT:-$INFRA_ROOT/../diting-src}"
[ -f "$INFRA_ROOT/.env" ] && set -a && source "$INFRA_ROOT/.env" && set +a

TAG="${1:-${COPILOT_IMAGE_TAG:-$(bash "$SCRIPT_DIR/copilot-resolve-image-tag.sh" "$SRC_ROOT")}}"
LOCAL_REF="diting-copilot:${TAG}"

if bash "$SCRIPT_DIR/copilot-acr-image-exists.sh" "$TAG"; then
  echo "▶ [copilot-push-local] ACR 已有 ${TAG} · 跳过 push"
  exit 0
fi

if ! docker image inspect "$LOCAL_REF" >/dev/null 2>&1; then
  echo "▶ [copilot-push-local] 本地无 ${LOCAL_REF} · 需完整 build"
  exit 1
fi

echo "▶ [copilot-push-local] 本地已有 ${LOCAL_REF} · 仅 push（跳过 docker build）"
make -C "$SRC_ROOT" push-copilot-image-only \
  COPILOT_IMAGE_TAG="$TAG" \
  DITING_ACR_PASSWORD="${DITING_ACR_PASSWORD:-${ACR_PASSWORD:-}}"
echo "✅ [copilot-push-local] push 完成 · tag=${TAG}"
