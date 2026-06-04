#!/usr/bin/env bash
# 将新加坡代理 URL 写入 diting-src/.env 并 helm 注入 Copilot（HTTPS_PROXY）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_ENV="${SRC_ENV:-$INFRA_ROOT/../diting-src/.env}"
CONN_FILE="${INFRA_ROOT}/sg-proxy.conn"

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

_merge_env() {
  local key="$1" val="$2" file="$3"
  touch "$file"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

_merge_env "HTTPS_PROXY" "$PROXY_URL" "$SRC_ENV"
_merge_env "HTTP_PROXY" "$PROXY_URL" "$SRC_ENV"
_merge_env "NO_PROXY" "localhost,127.0.0.1,.svc,.svc.cluster.local,.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16" "$SRC_ENV"
_merge_env "ANTHROPIC_PROXY_USER" "$PROXY_USER" "$SRC_ENV"
_merge_env "ANTHROPIC_PROXY_HOST" "$PROXY_HOST" "$SRC_ENV"
_merge_env "ANTHROPIC_PROXY_PORT" "$PROXY_PORT" "$SRC_ENV"

echo "▶ [sync-anthropic-proxy] HTTPS_PROXY → Copilot（host=$PROXY_HOST port=$PROXY_PORT）"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
bash "$SCRIPT_DIR/copilot-sync-ai-from-src-env.sh"
env -u HTTPS_PROXY -u HTTP_PROXY kubectl rollout restart deployment/diting-copilot -n platform 2>/dev/null || true
env -u HTTPS_PROXY -u HTTP_PROXY kubectl rollout status deployment/diting-copilot -n platform --timeout=180s 2>/dev/null || true
echo "✅ [sync-anthropic-proxy] 已合并 $SRC_ENV 并 helm 注入 platform/diting-copilot"
