#!/usr/bin/env bash
# 解析 Copilot 镜像 tag：git short sha；工作区脏则追加 -d<diff-hash>，避免同 sha 覆盖旧镜像。
# 用法: copilot-resolve-image-tag.sh [diting-src 路径]
# 输出: 一行 tag（如 be1f47c6 或 be1f47c6-d4a1b2c）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_ROOT="${1:-$INFRA_ROOT/../diting-src}"

if ! git -C "$SRC_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "latest"
  exit 0
fi

SHA="$(git -C "$SRC_ROOT" rev-parse --short HEAD 2>/dev/null || echo latest)"
if git -C "$SRC_ROOT" diff-index --quiet HEAD -- 2>/dev/null; then
  printf '%s\n' "$SHA"
  exit 0
fi

# 未提交/未暂存变更 → 内容哈希后缀（7 位），同内容复用同 tag
DIRTY_HASH="$(
  {
    git -C "$SRC_ROOT" diff HEAD 2>/dev/null || true
    git -C "$SRC_ROOT" diff 2>/dev/null || true
    git -C "$SRC_ROOT" ls-files --others --exclude-standard 2>/dev/null || true
  } | (shasum -a 256 2>/dev/null || sha256sum 2>/dev/null) | cut -c1-7
)"
if [ -z "$DIRTY_HASH" ]; then
  DIRTY_HASH="$(date -u +%m%d%H%M)"
fi
printf '%s-d%s\n' "$SHA" "$DIRTY_HASH"
