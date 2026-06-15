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
  # Terraform OSS backend 与 alicloud provider 均依赖显式 AK/SK
  export ALICLOUD_ACCESS_KEY="${ALICLOUD_ACCESS_KEY:-}"
  export ALICLOUD_SECRET_KEY="${ALICLOUD_SECRET_KEY:-}"
}

# 创建按量 ECS 前检查账户可用余额（CNY；国际站/按量产品官方阈值 100 元）
sg_proxy_check_balance() {
  local min_cny="${1:-100}"
  if ! command -v aliyun >/dev/null 2>&1; then
    echo "⚠️  [sg-proxy] 未安装 aliyun CLI，跳过余额预检（deploy 仍可能因 NotEnoughBalance 失败）" >&2
    return 0
  fi
  local available
  available="$(
    aliyun bssopenapi QueryAccountBalance 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Data',{}).get('AvailableCashAmount',''))" 2>/dev/null \
      || true
  )"
  if [ -z "$available" ]; then
    echo "⚠️  [sg-proxy] 无法读取账户余额，跳过预检" >&2
    return 0
  fi
  if python3 -c "import sys; sys.exit(0 if float('${available}') >= float('${min_cny}') else 1)"; then
    echo "ℹ️  [sg-proxy] 账户可用余额 ${available} CNY（阈值 ${min_cny}）"
    return 0
  fi
  echo "❌ [sg-proxy] 阿里云账户可用余额 ${available} CNY 低于 ${min_cny} CNY，无法创建按量 ECS/EIP" >&2
  echo "   按量付费要求账户余额不少于 100 元（InvalidAccountStatus.NotEnoughBalance）" >&2
  return 1
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
  local state_list

  sg_proxy_load_env "$infra_root"
  sg_proxy_tf_init "$infra_root" "$project" "$env"
  state_list="$(
    cd "$tf_dir"
    terraform state list 2>/dev/null || true
  )"
  if [ -z "$state_list" ]; then
    return 1
  fi
  printf '%s\n' "$state_list" | grep -qE 'module\.ecs\.alicloud_(instance|eip_address)\.stack\["proxy"\]'
}

# 释放新加坡 region 内未绑定实例的 proxy 相关 Available EIP（失败 apply 遗留）
sg_proxy_release_available_eips() {
  local region="${1:-ap-southeast-1}"
  local proxy_env="${2:-sg-proxy}"

  if ! command -v aliyun >/dev/null 2>&1; then
    return 0
  fi

  ALICLOUD_REGION="$region" PROXY_ENV="$proxy_env" python3 - <<'PY'
import json, os, subprocess, sys

region = os.environ.get("ALICLOUD_REGION", "ap-southeast-1")
proxy_env = os.environ.get("PROXY_ENV", "sg-proxy")
suffix = f"-proxy-{proxy_env}"

def run(*args):
    p = subprocess.run(
        ["aliyun", *args, "--region", region],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
    )
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip() or p.stdout.strip() or "aliyun failed")
    return json.loads(p.stdout) if p.stdout.strip() else {}

inst_data = run("ecs", "DescribeInstances", "--PageSize", "100")
bound_ips = set()
has_proxy_ecs = False
for inst in inst_data.get("Instances", {}).get("Instance") or []:
    name = inst.get("InstanceName") or ""
    if suffix not in name:
        continue
    has_proxy_ecs = True
    eip = (inst.get("EipAddress") or {}).get("IpAddress") or ""
    if eip:
        bound_ips.add(eip)

eip_data = run("vpc", "DescribeEipAddresses", "--PageSize", "50")
released = 0
for addr in eip_data.get("EipAddresses", {}).get("EipAddress") or []:
    ip = addr.get("IpAddress") or ""
    status = addr.get("Status") or ""
    alloc = addr.get("AllocationId") or ""
    name = addr.get("Name") or ""
    if status != "Available" or not alloc:
        continue
    if ip in bound_ips:
        continue
    # 无 proxy ECS 时释放全部 Available EIP；否则仅释放命名含 proxy 的
    if (not has_proxy_ecs) or suffix in name or "proxy" in name.lower() or "sg-proxy" in name.lower():
        print(f"▶ [sg-proxy] 释放失败 apply 遗留 Available EIP {ip} ({alloc})")
        run("vpc", "ReleaseEipAddress", "--AllocationId", alloc)
        released += 1

if released:
    print(f"ℹ️  [sg-proxy] 已释放 {released} 个孤儿 EIP")
PY
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
# Python 3.6 无 capture_output/text，须用 PIPE + universal_newlines
p = subprocess.run(
    ["aliyun", "ecs", "DescribeInstances", "--region", region, "--PageSize", "50"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
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

# 在 proxy ECS 上应用 3proxy 运行时配置（Type=simple · 无 daemon · 长连接超时放宽）
# 实现在 diting-infra 主目录，不修改 deploy-engine 子模块 user-data-proxy.sh
sg_proxy_apply_3proxy_runtime_fix() {
  local host="$1"
  local port="$2"
  local user="$3"
  local password="$4"
  local ssh_password="${5:-$password}"

  [ -n "$host" ] && [ -n "$port" ] && [ -n "$user" ] && [ -n "$password" ] || return 1
  command -v sshpass >/dev/null 2>&1 || {
    echo "❌ [sg-proxy] 未安装 sshpass，无法 SSH 修复 3proxy" >&2
    return 1
  }

  echo "▶ [sg-proxy] 应用 3proxy 运行时配置 · ${host}:${port}"
  sshpass -p "$ssh_password" ssh -o StrictHostKeyChecking=no "root@${host}" \
    "PROXY_USER='${user}' PROXY_PASS='${password}' PROXY_PORT='${port}' bash -s" <<'REMOTE'
set -euo pipefail
cp /etc/3proxy/3proxy.cfg /etc/3proxy/3proxy.cfg.bak.$(date +%s) 2>/dev/null || true
cat > /etc/3proxy/3proxy.cfg <<EOF
pidfile /run/3proxy.pid
maxconn 200
nserver 8.8.8.8
nserver 223.5.5.5
nscache 65536
timeouts 1 5 30 300 600 3600 15 300
auth strong
users ${PROXY_USER}:CL:${PROXY_PASS}
proxy -p${PROXY_PORT}
EOF
cat > /etc/systemd/system/3proxy.service <<'UNIT'
[Unit]
Description=3proxy Anthropic egress
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl reset-failed 3proxy || true
pkill -x 3proxy || true
sleep 1
systemctl restart 3proxy
sleep 2
systemctl is-active 3proxy
systemctl show 3proxy -p NRestarts,ActiveState
ss -lntp | grep "${PROXY_PORT}"
REMOTE
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

# 列出云上全部 proxy ECS（TSV：instance_id|name|eip|eip_alloc|creation_time）
sg_proxy_list_cloud_instances() {
  local region="${1:-ap-southeast-1}"
  local proxy_env="${2:-sg-proxy}"
  local suffix="-proxy-${proxy_env}"
  ALICLOUD_REGION="$region" python3 - <<'PY' "$suffix"
import json, os, subprocess, sys
suffix = sys.argv[1]
region = os.environ.get("ALICLOUD_REGION", "ap-southeast-1")
p = subprocess.run(
    ["aliyun", "ecs", "DescribeInstances", "--PageSize", "100", "--region", region],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
)
if p.returncode != 0:
    sys.exit(0)
for inst in json.loads(p.stdout or "{}").get("Instances", {}).get("Instance") or []:
    name = inst.get("InstanceName") or ""
    if suffix not in name:
        continue
    iid = inst.get("InstanceId") or ""
    eip = (inst.get("EipAddress") or {}).get("IpAddress") or ""
    alloc = (inst.get("EipAddress") or {}).get("AllocationId") or ""
    created = inst.get("CreationTime") or ""
    print(f"{iid}\t{name}\t{eip}\t{alloc}\t{created}")
PY
}

# 将云上已存在的 proxy ECS 导入 Terraform state（避免「健康复用但 state 空 → 下次又 deploy-proxy 叠 ECS」）
sg_proxy_import_cloud_instance() {
  local infra_root="$1" project="$2" env="$3"
  local instance_id="$4" eip_alloc="${5:-}"

  [ -n "$instance_id" ] || return 1
  local tf_dir="$infra_root/deploy-engine/deploy/terraform/alicloud"
  local tfvars cfg_root
  cfg_root="${SPOT_TFVARS_ROOT:-$infra_root/config}"
  tfvars="$cfg_root/terraform-${project}-${env}.tfvars"
  if [ ! -f "$tfvars" ]; then
    tfvars="$infra_root/config/terraform-${project}-${env}.tfvars"
  fi
  local cfg="$infra_root/config/${project}-${env}.yaml"

  sg_proxy_tf_init "$infra_root" "$project" "$env"
  (
    cd "$tf_dir"
    local tf_args=(-var-file="$tfvars" -var="env_id=$env" -var="project=$project" -var="config_file=$cfg")
    if ! terraform state list 2>/dev/null | grep -q 'module\.ecs\.alicloud_instance\.stack\["proxy"\]'; then
      echo "▶ [sg-proxy-import] 导入 instance → state: $instance_id"
      terraform import "${tf_args[@]}" 'module.ecs.alicloud_instance.stack["proxy"]' "$instance_id"
    fi
    if [ -n "$eip_alloc" ] && ! terraform state list 2>/dev/null | grep -q 'module\.ecs\.alicloud_eip_address\.stack\["proxy"\]'; then
      echo "▶ [sg-proxy-import] 导入 EIP → state: $eip_alloc"
      terraform import "${tf_args[@]}" 'module.ecs.alicloud_eip_address.stack["proxy"]' "$eip_alloc"
    fi
    if [ -n "$eip_alloc" ] && [ -n "$instance_id" ] && ! terraform state list 2>/dev/null | grep -q 'module\.ecs\.alicloud_eip_association\.stack\["proxy"\]'; then
      echo "▶ [sg-proxy-import] 导入 EIP 绑定 → state: ${eip_alloc}:${instance_id}"
      terraform import "${tf_args[@]}" 'module.ecs.alicloud_eip_association.stack["proxy"]' "${eip_alloc}:${instance_id}"
    fi
  )
}

# 部署前对账：至多保留 1 台健康 proxy；删其余孤儿；健康则 import state 并复用。
# 返回 0 = 已复用（调用方写 conn 并 exit）；返回 1 = 需继续 deploy-proxy/up-proxy。
sg_proxy_reconcile_before_deploy() {
  local infra_root="$1" project="$2" env="$3" conn_file="$4"
  local port="$5" user="$6" password="$7"
  local region="${8:-ap-southeast-1}"

  if ! command -v aliyun >/dev/null 2>&1; then
    echo "⚠️  [sg-proxy-reconcile] 未安装 aliyun CLI，跳过云上对账"
    return 1
  fi

  local conn_ip=""
  if [ -f "$conn_file" ]; then
    conn_ip="$(grep -E '^(SG_PROXY_PUBLIC_IP|ANTHROPIC_PROXY_HOST)=' "$conn_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' ' || true)"
  fi

  local -a rows=()
  while IFS= read -r line; do
    [ -n "$line" ] && rows+=("$line")
  done < <(sg_proxy_list_cloud_instances "$region" "$env")

  if [ "${#rows[@]}" -eq 0 ]; then
    echo "ℹ️  [sg-proxy-reconcile] 云上无 proxy ECS，将进入创建流程"
    return 1
  fi

  echo "▶ [sg-proxy-reconcile] 云上 proxy ECS 共 ${#rows[@]} 台，探测健康并去重（目标：至多 1 台）"

  local keeper_id="" keeper_ip="" keeper_alloc="" keeper_created=""
  local row iid name eip alloc created
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r iid name eip alloc created <<<"$row"
    [ -n "$eip" ] || continue
    if sg_proxy_health_check "$eip" "$port" "$user" "$password" 2 3; then
      if [ -n "$conn_ip" ] && [ "$eip" = "$conn_ip" ]; then
        keeper_id="$iid"; keeper_ip="$eip"; keeper_alloc="$alloc"
        break
      fi
      if [ -z "$keeper_id" ]; then
        keeper_id="$iid"; keeper_ip="$eip"; keeper_alloc="$alloc"
      elif [[ "$created" > "${keeper_created:-}" ]]; then
        keeper_id="$iid"; keeper_ip="$eip"; keeper_alloc="$alloc"
      fi
      keeper_created="$created"
    fi
  done

  if [ -z "$keeper_id" ]; then
    echo "⚠️  [sg-proxy-reconcile] 无健康 proxy，清理全部 ${#rows[@]} 台后再创建"
    sg_proxy_orphan_cleanup "$region" "$env" "$conn_file" ""
    return 1
  fi

  echo "✅ [sg-proxy-reconcile] 保留健康实例 ${keeper_id} ip=${keeper_ip}，删除其余"
  sg_proxy_orphan_cleanup "$region" "$env" "$conn_file" "$keeper_id"
  sg_proxy_import_cloud_instance "$infra_root" "$project" "$env" "$keeper_id" "$keeper_alloc" || true
  PROXY_IP="$keeper_ip"
  PROXY_INSTANCE_ID="$keeper_id"
  PROXY_PORT="$port"
  export PROXY_IP PROXY_INSTANCE_ID PROXY_PORT
  return 0
}

# Terraform state 为空或漂移时，按实例名 / sg-proxy.conn IP 用 aliyun CLI 回收孤儿 proxy ECS+EIP
# 第 4 参 keep_instance_id 非空时保留该 ECS（仅删其余同名实例）
sg_proxy_orphan_cleanup() {
  local region="${1:-ap-southeast-1}"
  local proxy_env="${2:-sg-proxy}"
  local conn_file="${3:-}"
  local keep_instance_id="${4:-}"

  if ! command -v aliyun >/dev/null 2>&1; then
    echo "⚠️  [sg-proxy-orphan] 未安装 aliyun CLI，跳过 state 外孤儿回收（请控制台手动释放 *-proxy-${proxy_env}）"
    return 0
  fi

  local conn_ip=""
  if [ -n "$conn_file" ] && [ -f "$conn_file" ]; then
    conn_ip="$(grep -E '^(SG_PROXY_PUBLIC_IP|ANTHROPIC_PROXY_HOST)=' "$conn_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' ' || true)"
  fi

  local suffix="-proxy-${proxy_env}"
  echo "▶ [sg-proxy-orphan] 扫描 ${region} 孤儿代理（实例名 *${suffix} / conn IP=${conn_ip:-无} / keep=${keep_instance_id:-无}）"

  ALICLOUD_REGION="$region" KEEP="$keep_instance_id" python3 - <<'PY' "$suffix" "$conn_ip"
import json, os, subprocess, sys

suffix, conn_ip = sys.argv[1], sys.argv[2]
keep = os.environ.get("KEEP", "")
region = os.environ.get("ALICLOUD_REGION", "ap-southeast-1")

def run(*args):
    p = subprocess.run(
        ["aliyun", *args, "--region", region],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
    )
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
        if keep and iid == keep:
            continue
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

# SSH 修复已部署 proxy 上 3proxy systemd 重启循环（与 user-data-proxy.sh 对齐）
sg_proxy_fix_3proxy_systemd() {
  local infra_root="$1"
  local cfg="${2:-$infra_root/config/diting-prod.yaml}"
  local conn_file="${3:-$infra_root/sg-proxy.conn}"

  sg_proxy_load_env "$infra_root"
  local pw port user
  pw="$(sg_proxy_resolve_password "$infra_root")"
  port="$(yq eval '.anthropic_proxy.port // 3128' "$cfg")"
  user="$(yq eval '.anthropic_proxy.user // "ditingproxy"' "$cfg")"
  sg_proxy_resolve_endpoint "$infra_root" diting sg-proxy "$conn_file" "$port"

  echo "▶ [sg-proxy-fix-3proxy] ${PROXY_IP}:${PROXY_PORT}"
  sshpass -p "${TF_VAR_instance_password:-$pw}" ssh -o StrictHostKeyChecking=no "root@${PROXY_IP}" \
    "PROXY_USER='${user}' PROXY_PASS='${pw}' PROXY_PORT='${PROXY_PORT}' bash -s" <<'REMOTE'
set -euo pipefail
cp /etc/3proxy/3proxy.cfg /etc/3proxy/3proxy.cfg.bak.$(date +%s) 2>/dev/null || true
cat > /etc/3proxy/3proxy.cfg <<EOF
pidfile /run/3proxy.pid
maxconn 200
nserver 8.8.8.8
nserver 223.5.5.5
nscache 65536
timeouts 1 5 30 300 600 3600 15 300
auth strong
users ${PROXY_USER}:CL:${PROXY_PASS}
proxy -p${PROXY_PORT}
EOF
cat > /etc/systemd/system/3proxy.service <<'UNIT'
[Unit]
Description=3proxy Anthropic egress
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl reset-failed 3proxy || true
pkill -x 3proxy || true
sleep 1
systemctl restart 3proxy
sleep 2
systemctl is-active 3proxy
ss -lntp | grep "${PROXY_PORT}"
REMOTE
  echo "✅ [sg-proxy-fix-3proxy] 3proxy systemd 已修复"
}
