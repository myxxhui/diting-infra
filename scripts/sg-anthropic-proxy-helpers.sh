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
  # 0 字节本地 terraform.tfstate 会干扰 OSS remote backend，导致 apply 后 output/state 读不到
  if [ -f "$tf_dir/terraform.tfstate" ] && [ ! -s "$tf_dir/terraform.tfstate" ]; then
    rm -f "$tf_dir/terraform.tfstate"
  fi
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
  local proxy_env="${4:-sg-proxy}"
  local tf_dir="$infra_root/deploy-engine/deploy/terraform/alicloud"
  local out_json old_pwd

  sg_proxy_tf_init "$infra_root" "$project" "$env"
  PROXY_IP=""
  PROXY_PORT=""
  PROXY_INSTANCE_ID=""

  # 禁止在 ( subshell ) 内赋值——变量无法传回父 shell，会导致 deploy 后误判「读不到 output」
  old_pwd="$PWD"
  cd "$tf_dir"
  out_json="$(terraform output -json 2>/dev/null || echo '{}')"
  cd "$old_pwd"

  if [ -n "$out_json" ] && [ "$out_json" != "{}" ]; then
    read -r PROXY_IP PROXY_PORT PROXY_INSTANCE_ID <<EOF
$(OUT_JSON="$out_json" python3 - <<'PY'
import json, os
d = json.loads(os.environ.get("OUT_JSON") or "{}")

def oval(key):
    o = d.get(key) or {}
    return o.get("value") if isinstance(o, dict) else o

ip = oval("anthropic_proxy_public_ip") or oval("public_ip") or ""
if not ip:
    stacks = oval("stacks_info") or {}
    if isinstance(stacks, dict):
        ip = (stacks.get("proxy") or {}).get("public_ip") or ""
port = str(oval("anthropic_proxy_port") or "3128")
iid = oval("instance_id") or ""
if not iid:
    stacks = oval("stacks_info") or {}
    if isinstance(stacks, dict):
        iid = (stacks.get("proxy") or {}).get("instance_id") or ""
print(ip)
print(port)
print(iid)
PY
)
EOF
  fi

  if [ -z "$PROXY_IP" ] || [ "$PROXY_IP" = "null" ]; then
    sg_proxy_read_outputs_from_cloud "$proxy_env" || true
  fi

  export PROXY_IP PROXY_PORT PROXY_INSTANCE_ID
  [ -n "$PROXY_IP" ] && [ "$PROXY_IP" != "null" ]
}

# OSS state 为空或漂移时，从新加坡 ECS 实例名 *-proxy-<env> 回填 IP（与 orphan_cleanup 对称）
sg_proxy_read_outputs_from_cloud() {
  local proxy_env="${1:-sg-proxy}"
  local region="${2:-ap-southeast-1}"
  local suffix="-proxy-${proxy_env}"

  command -v aliyun >/dev/null 2>&1 || return 1
  read -r PROXY_IP PROXY_INSTANCE_ID <<EOF
$(ALICLOUD_REGION="$region" SUFFIX="$suffix" python3 - <<'PY'
import json, os, subprocess, sys
region = os.environ.get("ALICLOUD_REGION", "ap-southeast-1")
suffix = os.environ.get("SUFFIX", "-proxy-sg-proxy")
p = subprocess.run(
    ["aliyun", "ecs", "DescribeInstances", "--region", region, "--PageSize", "50"],
    capture_output=True, text=True,
)
if p.returncode != 0:
    sys.exit(1)
data = json.loads(p.stdout or "{}")
instances = data.get("Instances", {}).get("Instance") or []
for inst in instances:
    name = inst.get("InstanceName") or ""
    if suffix not in name:
        continue
    iid = inst.get("InstanceId") or ""
    eip = (inst.get("EipAddress") or {}).get("IpAddress") or ""
    pubs = (inst.get("PublicIpAddress") or {}).get("IpAddress") or []
    pub = pubs[0] if pubs else ""
    ip = eip or pub
    if ip:
        print(ip)
        print(iid)
        sys.exit(0)
sys.exit(1)
PY
)
EOF
  [ -n "$PROXY_IP" ] || return 1
  PROXY_PORT="${PROXY_PORT:-3128}"
  export PROXY_IP PROXY_PORT PROXY_INSTANCE_ID
  echo "ℹ️  [sg-proxy] Terraform output 为空，已从云上实例回填 ip=${PROXY_IP} instance=${PROXY_INSTANCE_ID:-?}"
  return 0
}

# macOS 默认无 GNU timeout；优先 nc，回退 bash /dev/tcp
sg_proxy_tcp_reachable() {
  local host="$1"
  local port="$2"
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 3 "$host" "$port" 2>/dev/null
    return $?
  fi
  bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null
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
    if sg_proxy_tcp_reachable "$host" "$port"; then
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

# Terraform state 为空或漂移时，按实例名 / sg-proxy.conn IP 用 aliyun CLI 回收孤儿 proxy ECS+EIP
# 匹配：*-proxy-sg-proxy（历史 project 可能为 deploy-engine 或 diting）
sg_proxy_orphan_cleanup() {
  local region="${1:-ap-southeast-1}"
  local proxy_env="${2:-sg-proxy}"
  local conn_file="${3:-}"

  if ! command -v aliyun >/dev/null 2>&1; then
    echo "⚠️  [sg-proxy-orphan] 未安装 aliyun CLI，跳过 state 外孤儿回收（请控制台手动释放 *-proxy-${proxy_env}）"
    return 0
  fi

  local conn_ip=""
  if [ -n "$conn_file" ] && [ -f "$conn_file" ]; then
    conn_ip="$(grep -E '^(SG_PROXY_PUBLIC_IP|ANTHROPIC_PROXY_HOST)=' "$conn_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' ' || true)"
  fi

  local suffix="-proxy-${proxy_env}"
  echo "▶ [sg-proxy-orphan] 扫描 ${region} 孤儿代理（实例名 *${suffix} / conn IP=${conn_ip:-无}）"

  ALICLOUD_REGION="$region" python3 - <<'PY' "$suffix" "$conn_ip"
import json, os, subprocess, sys

suffix, conn_ip = sys.argv[1], sys.argv[2]
region = os.environ.get("ALICLOUD_REGION", "ap-southeast-1")

def run(*args):
    p = subprocess.run(["aliyun", *args, "--region", region], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip() or p.stdout.strip() or "aliyun failed")
    return json.loads(p.stdout) if p.stdout.strip() else {}

def release_eip(allocation_id, ip=""):
    print(f"  释放 EIP {allocation_id} ip={ip}")
    run("vpc", "ReleaseEipAddress", "--AllocationId", allocation_id)

def unassoc_eip(allocation_id, instance_id):
    print(f"  解绑 EIP {allocation_id} ← instance {instance_id}")
    run("vpc", "UnassociateEipAddress", "--AllocationId", allocation_id, "--InstanceId", instance_id)

def delete_instance(instance_id, name=""):
    print(f"  删除 ECS {instance_id} name={name}")
    run("ecs", "DeleteInstance", "--InstanceId", instance_id, "--Force", "true")

inst_data = run("ecs", "DescribeInstances", "--PageSize", "100")
instances = inst_data.get("Instances", {}).get("Instance") or []
targets = []
for inst in instances:
    name = inst.get("InstanceName") or ""
    iid = inst.get("InstanceId") or ""
    eip = (inst.get("EipAddress") or {}).get("IpAddress") or ""
    if suffix in name or (conn_ip and eip == conn_ip):
        targets.append((iid, name, eip, (inst.get("EipAddress") or {}).get("AllocationId") or ""))

if not targets:
    print("  未发现匹配的 proxy ECS（Terraform 可能已销或从未创建）")
else:
    for iid, name, eip, alloc in targets:
        if alloc and iid:
            try:
                unassoc_eip(alloc, iid)
            except Exception as e:
                print(f"  ⚠️ 解绑 EIP 跳过: {e}")
        if alloc:
            try:
                release_eip(alloc, eip)
            except Exception as e:
                print(f"  ⚠️ 释放 EIP 跳过: {e}")
        try:
            delete_instance(iid, name)
        except Exception as e:
            print(f"  ❌ 删除 ECS 失败 {iid}: {e}")
            sys.exit(1)

if conn_ip:
    eip_data = run("vpc", "DescribeEipAddresses", "--PageSize", "50")
    for addr in eip_data.get("EipAddresses", {}).get("EipAddress") or []:
        ip = addr.get("IpAddress") or ""
        status = addr.get("Status") or ""
        alloc = addr.get("AllocationId") or ""
        if ip == conn_ip and status == "Available" and alloc:
            try:
                release_eip(alloc, ip)
            except Exception as e:
                print(f"  ⚠️ 释放孤立 Available EIP 跳过: {e}")
PY
}
