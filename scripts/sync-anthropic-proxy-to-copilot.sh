#!/usr/bin/env bash
# 将新加坡代理 URL 写入 diting-src/.env 并 helm 注入 Copilot（HTTPS_PROXY）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_ENV="${SRC_ENV:-$INFRA_ROOT/../diting-src/.env}"
CONN_FILE="${INFRA_ROOT}/sg-proxy.conn"

# 优先从云上解析当前代理 IP 写入 conn（避免 Secret 长期指向已回收 EIP）
if [ -f "$SCRIPT_DIR/sg-anthropic-proxy-helpers.sh" ]; then
  # shellcheck source=sg-anthropic-proxy-helpers.sh
  source "$SCRIPT_DIR/sg-anthropic-proxy-helpers.sh"
  if sg_proxy_resolve_endpoint "$INFRA_ROOT" diting sg-proxy "$CONN_FILE" "3128"; then
    sg_proxy_write_conn_file "$CONN_FILE" "$PROXY_IP" "${PROXY_PORT:-3128}" \
      "${ANTHROPIC_PROXY_USER:-ditingproxy}"
    echo "ℹ️  [sync-anthropic-proxy] 已刷新 sg-proxy.conn · ip=${PROXY_IP} port=${PROXY_PORT:-3128}"
  fi
fi

[ -f "$CONN_FILE" ] || {
  echo "错误: 缺少 $CONN_FILE，请先 make deploy-sg-anthropic-proxy"
  exit 1
}
# shellcheck source=/dev/null
source "$CONN_FILE"

PROXY_USER="${ANTHROPIC_PROXY_USER:-${SG_PROXY_USER:-ditingproxy}}"
PROXY_PORT="${SG_PROXY_PORT:-3128}"
PROXY_HOST="${ANTHROPIC_PROXY_HOST:-$SG_PROXY_PUBLIC_IP}"

if [ -f "$INFRA_ROOT/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$INFRA_ROOT/.env"
  set +a
fi

if [ -z "${ANTHROPIC_PROXY_PASSWORD:-}" ]; then
  if [ -n "${TF_VAR_instance_password:-}" ]; then
    ANTHROPIC_PROXY_PASSWORD="$TF_VAR_instance_password"
  elif [ -f "$SRC_ENV" ]; then
    _pw="$(grep -E '^ANTHROPIC_PROXY_PASSWORD=' "$SRC_ENV" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
    [ -n "$_pw" ] && ANTHROPIC_PROXY_PASSWORD="$_pw"
  fi
fi
[ -n "${ANTHROPIC_PROXY_PASSWORD:-}" ] || {
  echo "错误: 请设置 ANTHROPIC_PROXY_PASSWORD 或 TF_VAR_instance_password"
  exit 1
}

# URL 编码密码中的特殊字符（简单处理 @ :）
_esc_pw="${ANTHROPIC_PROXY_PASSWORD//@/%40}"
_esc_pw="${_esc_pw//:/%3A}"
PROXY_URL="http://${PROXY_USER}:${_esc_pw}@${PROXY_HOST}:${PROXY_PORT}"

# macOS sed -i 需空扩展名参数；Linux GNU sed 为 sed -i
_sed_inplace() {
  local file="$1" expr="$2"
  if [[ "$(uname -s)" == Darwin ]]; then
    sed -i '' "$expr" "$file"
  else
    sed -i "$expr" "$file"
  fi
}

_merge_env() {
  local key="$1" val="$2" file="$3"
  touch "$file"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    _sed_inplace "$file" "s|^${key}=.*|${key}=${val}|"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

_merge_env "ANTHROPIC_HTTPS_PROXY" "$PROXY_URL" "$SRC_ENV"
# 移除进程级代理，避免 Copilot 内 akshare / DeepSeek 误走新加坡 3proxy
for _k in HTTPS_PROXY HTTP_PROXY; do
  if grep -q "^${_k}=" "$SRC_ENV" 2>/dev/null; then
    _sed_inplace "$SRC_ENV" "/^${_k}=/d"
  fi
done
_merge_env "ANTHROPIC_PROXY_USER" "$PROXY_USER" "$SRC_ENV"
_merge_env "ANTHROPIC_PROXY_HOST" "$PROXY_HOST" "$SRC_ENV"
_merge_env "ANTHROPIC_PROXY_PORT" "$PROXY_PORT" "$SRC_ENV"

echo "▶ [sync-anthropic-proxy] ANTHROPIC_HTTPS_PROXY -> Copilot (host=${PROXY_HOST} port=${PROXY_PORT})"
# 强制 diting-prod kubeconfig（helm 不得走 shell 里残留的 ~/.kube/config 旧 context）
_DITING_KC="$HOME/.kube/config-diting-prod"
[ -f "$_DITING_KC" ] || {
  echo "错误: 缺少 $_DITING_KC，请先完成 make deploy diting prod 或 make kubeconfig-sync prod diting"
  exit 1
}
export KUBECONFIG="$_DITING_KC"
_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
echo "ℹ️  [sync-anthropic-proxy] KUBECONFIG=$_DITING_KC server=${_SERVER:-unknown}"
kubectl cluster-info --request-timeout=10s >/dev/null 2>&1 || {
  echo "错误: 无法连接 diting-prod 集群（server=${_SERVER:-}）"
  exit 1
}
bash "$SCRIPT_DIR/copilot-sync-ai-from-src-env.sh"
echo "✅ [sync-anthropic-proxy] 已合并 $SRC_ENV 并 helm 提交 platform/diting-copilot（业务第二梯队 · 不等待 Pod Ready）"
echo "   查看: kubectl get pods -n platform -l app.kubernetes.io/name=diting-copilot"
