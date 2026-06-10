#!/usr/bin/env bash
# Copilot 镜像 tag：解析 / 写回 config / 从集群同步
#   copilot-image-tag.sh [resolve] [diting-src路径]     → 输出 tag（默认 resolve）
#   copilot-image-tag.sh write-config                   → COPILOT_IMAGE_TAG → diting-prod.yaml
#   copilot-image-tag.sh from-cluster                   → 读集群 deployment → write-config
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CFG="${CONFIG_ROOT:-$INFRA_ROOT/config}/diting-prod.yaml"
SRC_ROOT="${SRC_ROOT:-$INFRA_ROOT/../diting-src}"

_cmd_resolve() {
  local src="${1:-$SRC_ROOT}"
  if ! git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "latest"
    return 0
  fi
  local sha dirty_hash
  sha="$(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo latest)"
  if git -C "$src" diff-index --quiet HEAD -- 2>/dev/null; then
    printf '%s\n' "$sha"
    return 0
  fi
  dirty_hash="$(
    {
      git -C "$src" diff HEAD 2>/dev/null || true
      git -C "$src" diff 2>/dev/null || true
      git -C "$src" ls-files --others --exclude-standard 2>/dev/null || true
    } | (shasum -a 256 2>/dev/null || sha256sum 2>/dev/null) | cut -c1-7
  )"
  [ -n "$dirty_hash" ] || dirty_hash="$(date -u +%m%d%H%M)"
  printf '%s-d%s\n' "$sha" "$dirty_hash"
}

_cmd_write_config() {
  [ -f "$CFG" ] || { echo "⚠️  跳过 tag 回写：缺少 $CFG" >&2; return 0; }
  local tag="${COPILOT_IMAGE_TAG:-$(_cmd_resolve "$SRC_ROOT")}"
  local current
  current="$(yq eval '.stack.copilot.image.tag // ""' "$CFG")"
  if [ "$current" = "$tag" ]; then
    echo "ℹ️  diting-prod.yaml copilot.image.tag 已是 ${tag}"
    return 0
  fi
  yq eval -i ".stack.copilot.image.tag = \"${tag}\"" "$CFG"
  echo "✅ 已同步 diting-prod.yaml · stack.copilot.image.tag=${tag}（原 ${current:-空}）"
}

_cmd_from_cluster() {
  export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
  local ns="${STACK_NS:-platform}"
  local image
  image="$(kubectl -n "$ns" get deploy diting-copilot -o jsonpath='{.spec.template.spec.containers[?(@.name=="copilot")].image}' 2>/dev/null || true)"
  if [ -z "$image" ]; then
    echo "⚠️  无法读取 diting-copilot 镜像" >&2
    return 1
  fi
  export COPILOT_IMAGE_TAG="${image##*:}"
  echo "▶ 集群当前镜像 tag=${COPILOT_IMAGE_TAG}"
  _cmd_write_config
}

case "${1:-resolve}" in
  resolve|"")
    _cmd_resolve "${2:-$SRC_ROOT}"
    ;;
  write-config|sync-config)
    _cmd_write_config
    ;;
  from-cluster|sync-from-cluster)
    _cmd_from_cluster
    ;;
  -h|--help)
    echo "用法: $0 [resolve|write-config|from-cluster] [diting-src路径]"
    ;;
  *)
    # 兼容旧调用：copilot-image-tag.sh /path/to/diting-src
    if [ -d "$1" ]; then
      _cmd_resolve "$1"
    else
      echo "未知子命令: $1" >&2
      exit 2
    fi
    ;;
esac
