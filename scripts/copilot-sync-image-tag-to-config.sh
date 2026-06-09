#!/usr/bin/env bash
# 将当前 COPILOT_IMAGE_TAG 写回 diting-prod.yaml（Helm 真相源与线上一致）。
# 用法: COPILOT_IMAGE_TAG=xxx bash copilot-sync-image-tag-to-config.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CFG="${CONFIG_ROOT:-$INFRA_ROOT/config}/diting-prod.yaml"

if [ ! -f "$CFG" ]; then
  echo "⚠️  跳过 tag 回写：缺少 $CFG" >&2
  exit 0
fi

TAG="${COPILOT_IMAGE_TAG:-$(bash "$SCRIPT_DIR/copilot-resolve-image-tag.sh")}"
CURRENT="$(yq eval '.stack.copilot.image.tag // ""' "$CFG")"
if [ "$CURRENT" = "$TAG" ]; then
  echo "ℹ️  diting-prod.yaml copilot.image.tag 已是 ${TAG}"
  exit 0
fi

yq eval -i ".stack.copilot.image.tag = \"${TAG}\"" "$CFG"
echo "✅ 已同步 diting-prod.yaml · stack.copilot.image.tag=${TAG}（原 ${CURRENT:-空}）"
