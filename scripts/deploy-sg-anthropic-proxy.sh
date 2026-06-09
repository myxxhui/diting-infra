#!/usr/bin/env bash
# 确保新加坡 Anthropic 出口代理可用：已存在且健康则复用，否则 up-proxy / 首次 deploy-proxy
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

echo "▶ [deploy-sg-anthropic-proxy] PROJECT=${PROJECT} ENV=${ENV} region=ap-southeast-1"

# state 漂移但云上已有 proxy ECS 时，先尝试直接健康复用（避免重复 deploy-proxy）
if [ "${FORCE_PROXY_DEPLOY:-0}" != "1" ] && sg_proxy_read_outputs_from_cloud "$ENV" 2>/dev/null; then
  _port="${PROXY_PORT:-$PROXY_PORT_CFG}"
  if sg_proxy_health_check "$PROXY_IP" "$_port" "$PROXY_USER" "$PROXY_PASSWORD" 3 5; then
    echo "✅ [deploy-sg-anthropic-proxy] 云上 proxy 已存在且健康，跳过 deploy-proxy"
    _write_conn_and_finish "$PROXY_IP" "$_port"
    exit 0
  fi
  echo "⚠️  [deploy-sg-anthropic-proxy] 云上 proxy 存在但尚未就绪（ip=${PROXY_IP}），等待 cloud-init/3proxy 后再验"
fi

# 强制重建（排障）：FORCE_PROXY_DEPLOY=1 跳过复用探测
if [ "${FORCE_PROXY_DEPLOY:-0}" != "1" ]; then
  if sg_proxy_resolve_endpoint "$INFRA_ROOT" "$PROJECT" "$ENV" "$CONN_FILE" "$PROXY_PORT_CFG"; then
    _port="${PROXY_PORT:-$PROXY_PORT_CFG}"
    if sg_proxy_state_has_instance "$INFRA_ROOT" "$PROJECT" "$ENV" 2>/dev/null; then
      sg_proxy_read_outputs "$INFRA_ROOT" "$PROJECT" "$ENV" "$ENV" || true
      echo "ℹ️  [deploy-sg-anthropic-proxy] state 已有 proxy instance=${PROXY_INSTANCE_ID:-?} ip=${PROXY_IP}"
    else
      echo "ℹ️  [deploy-sg-anthropic-proxy] 无 state，探测 sg-proxy.conn / 已知 endpoint ip=${PROXY_IP}"
    fi
    if sg_proxy_health_check "$PROXY_IP" "$_port" "$PROXY_USER" "$PROXY_PASSWORD" 3 5; then
      echo "✅ [deploy-sg-anthropic-proxy] 现有代理健康，跳过 Terraform apply（不新建 ECS/EIP）"
      _write_conn_and_finish "$PROXY_IP" "$_port"
      exit 0
    fi
    if sg_proxy_state_has_instance "$INFRA_ROOT" "$PROJECT" "$ENV" 2>/dev/null; then
      echo "⚠️  [deploy-sg-anthropic-proxy] state 中实例不可用，仅 up-proxy（非全量 apply）"
      make -C "$INFRA_ROOT/deploy-engine" up-proxy "$PROJECT" "$ENV"
      sg_proxy_read_outputs "$INFRA_ROOT" "$PROJECT" "$ENV" "$ENV" || true
      _port="${PROXY_PORT:-$PROXY_PORT_CFG}"
      if sg_proxy_health_check "${PROXY_IP:-}" "$_port" "$PROXY_USER" "$PROXY_PASSWORD" 6 10; then
        _write_conn_and_finish "$PROXY_IP" "$_port"
        exit 0
      fi
      echo "错误: up-proxy 后代理仍不可用，请检查安全组 3128、3proxy 与密码"
      exit 1
    fi
    echo "⚠️  [deploy-sg-anthropic-proxy] 已知 endpoint 不健康，将进入创建/拉起流程"
  fi
fi

if sg_proxy_state_has_instance "$INFRA_ROOT" "$PROJECT" "$ENV"; then
  echo "▶ [deploy-sg-anthropic-proxy] state 有 proxy 记录但 output 异常 → up-proxy"
  make -C "$INFRA_ROOT/deploy-engine" up-proxy "$PROJECT" "$ENV"
else
  echo "▶ [deploy-sg-anthropic-proxy] 首次部署（VPC/SG/NAS/OSS + proxy ECS）→ deploy-proxy"
  make -C "$INFRA_ROOT/deploy-engine" deploy-proxy "$PROJECT" "$ENV"
fi

sg_proxy_read_outputs "$INFRA_ROOT" "$PROJECT" "$ENV" "$ENV" || {
  echo "错误: deploy/up 后仍无法读取 anthropic_proxy_public_ip（已尝试 Terraform output 与云上 ECS 回填）"
  exit 1
}
_port="${PROXY_PORT:-$PROXY_PORT_CFG}"
if ! sg_proxy_health_check "$PROXY_IP" "$_port" "$PROXY_USER" "$PROXY_PASSWORD" 8 15; then
  echo "错误: 代理 ECS 已创建/拉起但 3128 健康检查未通过（instance=${PROXY_INSTANCE_ID:-?} ip=${PROXY_IP}）"
  exit 1
fi
_write_conn_and_finish "$PROXY_IP" "$_port"
