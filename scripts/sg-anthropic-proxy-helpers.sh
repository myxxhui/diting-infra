#!/usr/bin/env bash
# 新加坡 Anthropic 出口代理：Terraform 状态读取 + 代理健康检查（供 deploy/verify 复用）
# [Ref: anthropic-proxy-vps-setup.md · deploy-engine up-proxy/down-proxy]
set -euo pipefail

sg_proxy_load_env() {
  local infra_root="$1"
  if [ -f "$infra_root/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$infra_root/.env"
    set +a
  fi
}

sg_proxy_resolve_password() {
  local infra_root="$1"
  local src_env="${2:-$infra_root/../diting-src/.env}"
  if [ -n "${ANTHROPIC_PROXY_PASSWORD:-}" ]; then
    printf '%s' "$ANTHROPIC_PROXY_PASSWORD"
    return 0
  fi
  if [ -n "${TF_VAR_instance_password:-}" ]; then
    printf '%s' "$TF_VAR_instance_password"
    return 0
  fi
  if [ -f "$src_env" ]; then
    local _pw
    _pw="$(grep -E '^ANTHROPIC_PROXY_PASSWORD=' "$src_env" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
    if [ -n "$_pw" ]; then
      printf '%s' "$_pw"
      return 0
    fi
  fi
  return 1
}

sg_proxy_tf_init() {
  local infra_root="$1"
  local project="$2"
  local env="$3"
  local tf_dir="$infra_root/deploy-engine/deploy/terraform/alicloud"
  sg_proxy_load_env "$infra_root"
  (
    cd "$tf_dir"
    terraform init \
      -backend-config="prefix=${project}/${env}" \
      -reconfigure \
      -input=false \
      -no-color >/dev/null
  )
}

sg_proxy_state_has_instance() {
  local infra_root="$1"
  local project="$2"
  local env="$3"
  local tf_dir="$infra_root/deploy-engine/deploy/terraform/alicloud"
  sg_proxy_tf_init "$infra_root" "$project" "$env"
  (
    cd "$tf_dir"
    terraform state list 2>/dev/null | grep -q 'module\.ecs\.alicloud_instance\.stack\["proxy"\]'
  )
}

sg_proxy_read_outputs() {
  local infra_root="$1"
  local project="$2"
  local env="$3"
  local tf_dir="$infra_root/deploy-engine/deploy/terraform/alicloud"
  sg_proxy_tf_init "$infra_root" "$project" "$env"
  PROXY_IP=""
  PROXY_PORT=""
  PROXY_INSTANCE_ID=""
  (
    cd "$tf_dir"
    PROXY_IP="$(terraform output -raw anthropic_proxy_public_ip 2>/dev/null || true)"
    PROXY_PORT="$(terraform output -raw anthropic_proxy_port 2>/dev/null || true)"
    PROXY_INSTANCE_ID="$(terraform output -raw instance_id 2>/dev/null || true)"
  )
  export PROXY_IP PROXY_PORT PROXY_INSTANCE_ID
  [ -n "$PROXY_IP" ] && [ "$PROXY_IP" != "null" ]
}

# 返回 0 = 代理端口可达且 HTTP CONNECT 认证通过（能转发到 Anthropic 边缘）
sg_proxy_health_check() {
  local host="$1"
  local port="$2"
  local user="$3"
  local password="$4"
  local retries="${5:-3}"
  local wait_sec="${6:-5}"

  [ -n "$host" ] && [ -n "$port" ] && [ -n "$user" ] && [ -n "$password" ] || return 1

  local attempt code
  for attempt in $(seq 1 "$retries"); do
    if timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
      code="$(
        curl -s -o /dev/null -w '%{http_code}' -m 20 \
          -U "${user}:${password}" \
          -x "http://${host}:${port}" \
          "https://api.anthropic.com/v1/messages" 2>/dev/null || echo "000"
      )"
      # 经代理到达 Anthropic 时常见 401/403/405/415；407=代理认证失败；000=未连通
      case "$code" in
        401|403|404|405|415|200) return 0 ;;
        407) echo "⚠️  [sg-proxy] 代理认证失败 (HTTP 407)，请核对密码与 TF_VAR_instance_password" >&2 ;;
        *) echo "ℹ️  [sg-proxy] 健康探测 attempt=${attempt}/${retries} http_code=${code}" >&2 ;;
      esac
    else
      echo "ℹ️  [sg-proxy] 健康探测 attempt=${attempt}/${retries} TCP ${host}:${port} 不可达" >&2
    fi
    [ "$attempt" -lt "$retries" ] && sleep "$wait_sec"
  done
  return 1
}

sg_proxy_write_conn_file() {
  local conn_file="$1"
  local ip="$2"
  local port="$3"
  local user="$4"
  {
    echo "SG_PROXY_PUBLIC_IP=${ip}"
    echo "SG_PROXY_PORT=${port}"
    echo "SG_PROXY_USER=${user}"
    echo "ANTHROPIC_PROXY_HOST=${ip}"
  } >"$conn_file"
}

# 解析代理 host/port：优先 Terraform output，回退 sg-proxy.conn
sg_proxy_resolve_endpoint() {
  local infra_root="$1"
  local project="$2"
  local env="$3"
  local conn_file="$4"
  local default_port="$5"
  PROXY_IP=""
  PROXY_PORT=""
  if sg_proxy_read_outputs "$infra_root" "$project" "$env" 2>/dev/null; then
    :
  elif [ -f "$conn_file" ]; then
    # shellcheck source=/dev/null
    source "$conn_file"
    PROXY_IP="${ANTHROPIC_PROXY_HOST:-${SG_PROXY_PUBLIC_IP:-}}"
    PROXY_PORT="${SG_PROXY_PORT:-$default_port}"
  fi
  export PROXY_IP PROXY_PORT
  [ -n "$PROXY_IP" ]
}
