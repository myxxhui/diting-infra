#!/usr/bin/env bash
# 确保新加坡 Anthropic 出口代理可用：至多 1 台 ECS；健康则复用+import state，否则 up/deploy
# [Ref: deploy-engine up-proxy · anthropic-proxy-vps-setup.md]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=sg-anthropic-proxy-helpers.sh
source "$SCRIPT_DIR/sg-anthropic-proxy-helpers.sh"

PROJECT="${PROJECT:-diting}"
CFG="${CONFIG_ROOT:-$INFRA_ROOT/config}/diting-prod.yaml"
CONN_FILE="${INFRA_ROOT}/sg-proxy.conn"
ENV="$(yq eval '.anthropic_proxy.deploy_engine_env // "sg-proxy"' "$CFG")"
PROXY_USER="$(yq eval '.anthropic_proxy.user // "ditingproxy"' "$CFG")"
PROXY_PORT_CFG="$(yq eval '.anthropic_proxy.port // 3128' "$CFG")"
SG_REGION="ap-southeast-1"

sg_proxy_load_env "$INFRA_ROOT"
[ -n "${TF_VAR_instance_password:-}" ] || {
  echo "错误: 请在 diting-infra/.env 设置 TF_VAR_instance_password（与 proxy 认证可复用）"
  exit 1
}
export TF_VAR_instance_password
export CONFIG_ROOT="$INFRA_ROOT/config"

PROXY_PASSWORD="$(sg_proxy_resolve_password "$INFRA_ROOT")" || {
  echo "错误: 无法解析代理密码（ANTHROPIC_PROXY_PASSWORD / TF_VAR_instance_password）"
  exit 1
}

_write_conn_and_finish() {
  local ip="$1"
  local port="$2"
  sg_proxy_write_conn_file "$CONN_FILE" "$ip" "$port" "$PROXY_USER"
  echo "✅ [deploy-sg-anthropic-proxy] 代理可用 公网 IP=${ip} 端口=${port}"
  echo "   连接信息已写入 $CONN_FILE"
}

echo "▶ [deploy-sg-anthropic-proxy] PROJECT=${PROJECT} ENV=${ENV} region=${SG_REGION}"

if [ "${FORCE_PROXY_DEPLOY:-0}" = "1" ]; then
  echo "▶ [deploy-sg-anthropic-proxy] FORCE_PROXY_DEPLOY=1 → 清理全部 proxy ECS 后重建"
  sg_proxy_orphan_cleanup "$SG_REGION" "$ENV" "$CONN_FILE" ""
else
  # 根因修复：部署前先对账（删重复机、import state、健康则直接复用）
  if sg_proxy_reconcile_before_deploy \
      "$INFRA_ROOT" "$PROJECT" "$ENV" "$CONN_FILE" \
      "$PROXY_PORT_CFG" "$PROXY_USER" "$PROXY_PASSWORD" "$SG_REGION"; then
    _write_conn_and_finish "$PROXY_IP" "${PROXY_PORT:-$PROXY_PORT_CFG}"
    exit 0
  fi
fi

if sg_proxy_state_has_instance "$INFRA_ROOT" "$PROJECT" "$ENV"; then
  echo "▶ [deploy-sg-anthropic-proxy] state 有 proxy 记录 → up-proxy"
  make -C "$INFRA_ROOT/deploy-engine" up-proxy "$PROJECT" "$ENV"
else
  echo "▶ [deploy-sg-anthropic-proxy] 无可用 proxy → deploy-proxy（创建前已清理孤儿）"
  make -C "$INFRA_ROOT/deploy-engine" deploy-proxy "$PROJECT" "$ENV"
fi

sg_proxy_read_outputs "$INFRA_ROOT" "$PROJECT" "$ENV" "$ENV" || {
  echo "错误: deploy/up 后仍无法读取 anthropic_proxy_public_ip"
  exit 1
}
_port="${PROXY_PORT:-$PROXY_PORT_CFG}"
if ! sg_proxy_health_check "$PROXY_IP" "$_port" "$PROXY_USER" "$PROXY_PASSWORD" 8 15; then
  echo "错误: 代理 ECS 已创建/拉起但 3128 健康检查未通过（instance=${PROXY_INSTANCE_ID:-?} ip=${PROXY_IP}）"
  exit 1
fi
_write_conn_and_finish "$PROXY_IP" "$_port"
