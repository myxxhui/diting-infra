#!/usr/bin/env bash
# kubecm 多 kubeconfig 管理（P 轨 / deploy-engine 配套）
# [Ref: 03_/共享平台基础/.../02_deploy-engine扩展规约.md]
#
# 用法:
#   kubecm-helpers.sh ensure                          # 检查/安装 kubecm
#   kubecm-helpers.sh add-and-switch [project] [env]  # 合并 kubeconfig 并切换为当前 context
#   kubecm-helpers.sh remove [project] [env]        # down 后从 ~/.kube/config 删除 context
#   kubecm-helpers.sh list                          # 列出 context
#
set -euo pipefail

KUBE_DIR="${KUBECONFIG_DIR:-$HOME/.kube}"
DEFAULT_PROJECT="${PROJECT:-diting}"
DEFAULT_ENV="${ENV:-prod}"

log() { echo "[kubecm] $*" >&2; }
warn() { echo "[kubecm] ⚠️  $*" >&2; }

kubeconfig_path() {
  local project="${1:-$DEFAULT_PROJECT}"
  local env="${2:-$DEFAULT_ENV}"
  if [ -n "$project" ]; then
    echo "$KUBE_DIR/config-${project}-${env}"
  else
    echo "$KUBE_DIR/config-${env}"
  fi
}

context_name() {
  local project="${1:-$DEFAULT_PROJECT}"
  local env="${2:-$DEFAULT_ENV}"
  echo "${project}-${env}"
}

_ensure_kubecm_clear_trap() {
  trap - RETURN 2>/dev/null || true
  if [ -n "${_kubecm_tmpdir:-}" ] && [ -d "$_kubecm_tmpdir" ]; then
    rm -rf "$_kubecm_tmpdir"
  fi
  unset _kubecm_tmpdir
}

ensure_kubecm() {
  trap - RETURN 2>/dev/null || true
  if command -v kubecm >/dev/null 2>&1; then
    log "已安装 $(kubecm version 2>/dev/null | head -1 || kubecm version)"
    return 0
  fi
  log "未检测到 kubecm，开始安装…"
  local os arch ver url bin install_dir
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) warn "未知架构 $(uname -m)，尝试 amd64"; arch=amd64 ;;
  esac
  install_dir="${INSTALL_DIR:-}"
  if [ -z "$install_dir" ]; then
    if [ -w /usr/local/bin ] 2>/dev/null; then install_dir=/usr/local/bin
    else install_dir="$HOME/.local/bin"; fi
  fi
  mkdir -p "$install_dir"
  local goos goarch asset
  case "$os" in
    linux) goos=Linux ;;
    darwin) goos=Darwin ;;
    *) goos=Linux ;;
  esac
  case "$arch" in
    amd64) goarch=x86_64 ;;
    arm64) goarch=arm64 ;;
    *) goarch=x86_64 ;;
  esac
  ver=$(curl -fsSL https://api.github.com/repos/sunny0826/kubecm/releases/latest \
    | grep -m1 '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/') || true
  if [ -n "$ver" ]; then
    asset="kubecm_v${ver}_${goos}_${goarch}.tar.gz"
    url="https://github.com/sunny0826/kubecm/releases/download/v${ver}/${asset}"
    _kubecm_tmpdir=$(mktemp -d)
    trap '_ensure_kubecm_clear_trap' RETURN
    log "下载 $url"
    if curl -fsSL "$url" | tar -xz -C "$_kubecm_tmpdir"; then
      bin=$(find "$_kubecm_tmpdir" -name kubecm -type f | head -1)
      if [ -n "$bin" ]; then
        install -m 0755 "$bin" "$install_dir/kubecm"
        export PATH="$install_dir:$HOME/.local/bin:/usr/local/bin:$PATH"
        if command -v kubecm >/dev/null 2>&1; then
          _ensure_kubecm_clear_trap
          log "✅ kubecm v${ver} 安装完成 → $install_dir/kubecm"
          return 0
        fi
      fi
    fi
    _ensure_kubecm_clear_trap
    warn "release 下载失败: $url"
  fi
  if command -v go >/dev/null 2>&1; then
    log "尝试 go install…"
    GOBIN="$install_dir" go install github.com/sunny0826/kubecm@v0.34.0 2>/dev/null \
      || GOBIN="$install_dir" go install github.com/sunny0826/kubecm@latest 2>/dev/null || true
  fi
  export PATH="$install_dir:$HOME/.local/bin:/usr/local/bin:$PATH"
  command -v kubecm >/dev/null 2>&1 || { warn "安装后仍找不到 kubecm，请手动安装: https://github.com/sunny0826/kubecm/releases"; return 1; }
  log "✅ kubecm 就绪: $(kubecm version 2>/dev/null | head -1 || kubecm version)"
}

add_and_switch() {
  local project="${1:-$DEFAULT_PROJECT}"
  local env="${2:-$DEFAULT_ENV}"
  local cfg ctx merged
  cfg=$(kubeconfig_path "$project" "$env")
  ctx=$(context_name "$project" "$env")
  ensure_kubecm || return 1
  mkdir -p "$KUBE_DIR"
  [ -f "$cfg" ] || { warn "kubeconfig 不存在: $cfg（请先 deploy / get-kubeconfig / kubeconfig-restore-state）"; return 1; }
  if ! KUBECONFIG="$cfg" kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
    warn "kubeconfig 不可达: $cfg（仍尝试合并到 ~/.kube/config）"
  fi
  # 仅清理本 project-env 相关条目，勿删其他集群（如 ack-prod）
  for old in "$ctx" "${ctx}-default"; do
    kubectl config delete-context "$old" --kubeconfig="$HOME/.kube/config" 2>/dev/null || true
  done
  # diting 独立文件 context 常为 default，且 cluster 名也为 default；仅当存在 diting 独立文件时才删 default 集群条目
  if KUBECONFIG="$cfg" kubectl config get-contexts -o name 2>/dev/null | grep -qx default; then
    kubectl config delete-context default --kubeconfig="$HOME/.kube/config" 2>/dev/null || true
    kubectl config delete-cluster default --kubeconfig="$HOME/.kube/config" 2>/dev/null || true
    kubectl config unset users.default --kubeconfig="$HOME/.kube/config" 2>/dev/null || true
  fi
  log "合并 kubeconfig → ~/.kube/config · context=$ctx"
  merged=$(mktemp)
  if [ -f "$HOME/.kube/config" ]; then
    # 新 cfg 放后面，flatten 时后出现的 cluster/user 覆盖同名项
    KUBECONFIG="$HOME/.kube/config:$cfg" kubectl config view --flatten > "$merged"
  else
    cp "$cfg" "$merged"
  fi
  install -m 600 "$merged" "$HOME/.kube/config"
  rm -f "$merged"
  # 独立文件通常 context 名为 default，重命名为 project-env
  if KUBECONFIG="$HOME/.kube/config" kubectl config get-contexts -o name 2>/dev/null | grep -qx default; then
    KUBECONFIG="$HOME/.kube/config" kubectl config rename-context default "$ctx" 2>/dev/null || true
  fi
  export KUBECONFIG="$HOME/.kube/config"
  log "切换当前 context → $ctx"
  kubectl config use-context "$ctx" 2>/dev/null \
    || kubectl config use-context "${ctx}-default" 2>/dev/null \
    || warn "无法切换 context（集群可能未启动）"
  # 同步 shell 配置：优先 kubecm 管理的合并 config
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    [ -f "$rc" ] || touch "$rc"
    sed -i.bak '/export KUBECONFIG.*config-.*-/d' "$rc" 2>/dev/null \
      || sed -i '' '/export KUBECONFIG.*config-.*-/d' "$rc" 2>/dev/null || true
    if ! grep -q 'export KUBECONFIG="$HOME/.kube/config"' "$rc" 2>/dev/null \
       && ! grep -q "export KUBECONFIG=\"\$HOME/.kube/config\"" "$rc" 2>/dev/null; then
      echo 'export KUBECONFIG="$HOME/.kube/config"' >> "$rc"
    fi
  done
  log "✅ 当前集群: $ctx · $(kubectl config current-context 2>/dev/null || echo '?')"
  kubectl get nodes --request-timeout=10s 2>/dev/null | head -5 || warn "kubectl get nodes 失败（集群可能仍在启动）"
}

remove_context() {
  local project="${1:-$DEFAULT_PROJECT}"
  local env="${2:-$DEFAULT_ENV}"
  local cfg ctx
  cfg=$(kubeconfig_path "$project" "$env")
  ctx=$(context_name "$project" "$env")
  if command -v kubecm >/dev/null 2>&1; then
    if kubecm ls 2>/dev/null | awk 'NR>2 {print $2}' | grep -qx "$ctx"; then
      log "从 kubecm 删除 context: $ctx"
      kubecm delete "$ctx" -s 2>/dev/null || kubecm delete "$ctx" || true
    else
      log "kubecm 中无 context: $ctx（跳过）"
    fi
  else
    log "kubecm 未安装，跳过 context 删除"
  fi
  if [ -f "$cfg" ]; then
    log "删除 kubeconfig 文件: $cfg"
    rm -f "$cfg"
  fi
  # 清理 shell 里指向已删独立文件的 export
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    sed -i.bak "/export KUBECONFIG=.*config-${project}-${env}/d" "$rc" 2>/dev/null \
      || sed -i '' "/export KUBECONFIG=.*config-${project}-${env}/d" "$rc" 2>/dev/null || true
  done
  log "✅ 已移除 $ctx 相关配置"
}

list_contexts() {
  ensure_kubecm || return 1
  kubecm ls
}

cmd="${1:-ensure}"
shift || true
case "$cmd" in
  ensure) ensure_kubecm ;;
  add-and-switch) add_and_switch "${1:-$DEFAULT_PROJECT}" "${2:-$DEFAULT_ENV}" ;;
  remove) remove_context "${1:-$DEFAULT_PROJECT}" "${2:-$DEFAULT_ENV}" ;;
  list) list_contexts ;;
  *)
    echo "未知命令: $cmd" >&2
    exit 1
    ;;
esac
