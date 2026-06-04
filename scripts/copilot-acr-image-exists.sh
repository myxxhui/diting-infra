#!/usr/bin/env bash
# 检查 ACR 是否已有指定 tag（用于跳过重复 build/push）
# 用法: copilot-acr-image-exists.sh <tag>
# 退出码: 0=存在 1=不存在或无法校验
set -euo pipefail
TAG="${1:?需要镜像 tag}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$INFRA_ROOT/.env" ] && set -a && source "$INFRA_ROOT/.env" && set +a

REGISTRY="${ACR_REGISTRY:-crpi-7vifw4ok9jkcxr60.cn-hongkong.personal.cr.aliyuncs.com}"
REPO="${ACR_REPO_COPILOT:-titan-core/diting-copilot}"
USER="${ACR_USERNAME:-sean_hui}"
IMAGE="${REGISTRY}/${REPO}:${TAG}"
PASS="${DITING_ACR_PASSWORD:-${ACR_PASSWORD:-}}"

if [ -z "$PASS" ]; then
  echo "⚠️  未配置 ACR_PASSWORD，无法查询 ACR manifest" >&2
  exit 1
fi

echo "$PASS" | docker login "$REGISTRY" -u "$USER" --password-stdin >/dev/null 2>&1 \
  || { echo "⚠️  ACR 登录失败" >&2; exit 1; }

if docker manifest inspect "$IMAGE" >/dev/null 2>&1; then
  echo "✓ ACR 已有镜像: $IMAGE"
  exit 0
fi
echo "○ ACR 无此 tag: $IMAGE"
exit 1
