#!/usr/bin/env bash
# Spot 计费共享库 · proxy/base 启动探测 / tfvars 合并 / 云状态查询
# [Ref: 31_Spot计费感知与巡检规约.md]
set -euo pipefail

SPOT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPOT_INFRA_ROOT="$(cd "$SPOT_LIB_DIR/../.." && pwd)"

spot_load_env() {
  local infra_root="${1:-$SPOT_INFRA_ROOT}"
  if [ -f "$infra_root/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$infra_root/.env"
    set +a
  fi
  export ALIBABA_CLOUD_ACCESS_KEY_ID="${ALICLOUD_ACCESS_KEY:-${ALIBABA_CLOUD_ACCESS_KEY_ID:-}}"
  export ALIBABA_CLOUD_ACCESS_KEY_SECRET="${ALICLOUD_SECRET_KEY:-${ALIBABA_CLOUD_ACCESS_KEY_SECRET:-}}"
}

spot_prefs_file() {
  echo "${1:-$SPOT_INFRA_ROOT}/config/spot-billing-prefs.yaml"
}

spot_state_file() {
  echo "${1:-$SPOT_INFRA_ROOT}/config/.spot-billing-state.json"
}

spot_watch_report_file() {
  echo "${1:-$SPOT_INFRA_ROOT}/config/.spot-watch-last-report.json"
}

spot_generated_dir() {
  echo "${1:-$SPOT_INFRA_ROOT}/config/.generated"
}

spot_active_config_root() {
  echo "${1:-$SPOT_INFRA_ROOT}/config/.spot-active"
}

spot_stack_pref() {
  local stack_id="$1"
  local key="$2"
  local infra_root="${3:-$SPOT_INFRA_ROOT}"
  yq eval ".stacks.${stack_id}.${key}" "$(spot_prefs_file "$infra_root")"
}

spot_policy_pref() {
  local key="$1"
  local infra_root="${2:-$SPOT_INFRA_ROOT}"
  yq eval ".policy.${key}" "$(spot_prefs_file "$infra_root")"
}

spot_canonical_tfvars() {
  local infra_root="$1" project="$2" env="$3"
  local p="$infra_root/config/terraform-${project}-${env}.tfvars"
  if [ ! -f "$p" ] && [ -f "$infra_root/config/terraform-${project}-${env}.tfvars.example" ]; then
    p="$infra_root/config/terraform-${project}-${env}.tfvars.example"
  fi
  echo "$p"
}

spot_resolved_tfvars() {
  local infra_root="$1" project="$2" env="$3"
  local active
  active="$(spot_active_config_root "$infra_root")/terraform-${project}-${env}.tfvars"
  if [ -f "$active" ]; then
    echo "$active"
  else
    spot_canonical_tfvars "$infra_root" "$project" "$env"
  fi
}

# 返回 0=有货(zone stdout) 1=售罄 2=CLI/凭证不可用
spot_has_stock() {
  local region="$1" instance_type="$2" strategy="$3" preferred_zone="${4:-}"

  command -v aliyun >/dev/null 2>&1 || return 2
  [ -n "${ALIBABA_CLOUD_ACCESS_KEY_ID:-}" ] || return 2
  [ -n "${ALIBABA_CLOUD_ACCESS_KEY_SECRET:-}" ] || return 2

  local out
  if ! out="$(aliyun ecs DescribeAvailableResource \
    --RegionId "$region" \
    --DestinationResource InstanceType \
    --InstanceType "$instance_type" \
    --SpotStrategy "$strategy" 2>/dev/null)"; then
    return 2
  fi

  python3 - <<'PY' "$out" "$preferred_zone"
import json, sys
raw, preferred = sys.argv[1], sys.argv[2]
data = json.loads(raw)
available = []
for z in data.get("AvailableZones", {}).get("AvailableZone", []):
    zid = z.get("ZoneId") or ""
    for ar in z.get("AvailableResources", {}).get("AvailableResource", []) or []:
        for sr in ar.get("SupportedResources", {}).get("SupportedResource", []) or []:
            if sr.get("Status") == "Available" and zid:
                available.append(zid)
if preferred and preferred in available:
    print(preferred)
    raise SystemExit(0)
if available:
    print(available[0])
    raise SystemExit(0)
raise SystemExit(1)
PY
}

# 解析 stack 计费模式 → stdout: spot|ondemand；写 SPOT_RESOLVED_ZONE
spot_resolve_billing_mode() {
  local stack_id="$1"
  local infra_root="${2:-$SPOT_INFRA_ROOT}"

  local policy region itype pzone fallback spot_str
  policy="$(spot_policy_pref default "$infra_root")"
  region="$(spot_stack_pref "$stack_id" region "$infra_root")"
  itype="$(spot_stack_pref "$stack_id" instance_type "$infra_root")"
  pzone="$(spot_stack_pref "$stack_id" preferred_zone "$infra_root")"
  fallback="$(spot_stack_pref "$stack_id" ondemand_fallback "$infra_root")"
  spot_str="$(spot_stack_pref "$stack_id" spot_strategy "$infra_root")"

  if [ "${SPOT_FORCE_BILLING:-}" = "spot" ] || [ "${SPOT_FORCE_BILLING:-}" = "ondemand" ]; then
    echo "${SPOT_FORCE_BILLING}"
    return 0
  fi
  if [ "${SPOT_PREFER:-1}" = "0" ] || [ "$policy" = "ondemand_only" ]; then
    echo "ondemand"
    return 0
  fi

  local zone=""
  if zone="$(spot_has_stock "$region" "$itype" "$spot_str" "$pzone" 2>/dev/null)"; then
    SPOT_RESOLVED_ZONE="$zone"
    export SPOT_RESOLVED_ZONE
    echo "spot"
    return 0
  fi
  local rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "ondemand"
    return 0
  fi
  if [ "$fallback" = "true" ]; then
    if zone="$(spot_has_stock "$region" "$itype" "NoSpot" "$pzone" 2>/dev/null)"; then
      SPOT_RESOLVED_ZONE="$zone"
      export SPOT_RESOLVED_ZONE
    fi
    echo "ondemand"
    return 0
  fi
  echo "ondemand"
}

spot_merge_tfvars_file() {
  local canonical="$1" out="$2" stack_id="$3" billing="$4"

  mkdir -p "$(dirname "$out")"
  python3 - <<'PY' "$canonical" "$out" "$stack_id" "$billing"
import re, sys, shutil

canonical, out, stack_id, billing = sys.argv[1:5]
strategy = "SpotAsPriceGo" if billing == "spot" else "NoSpot"
enable_spot = "true" if billing == "spot" else "false"

with open(canonical, encoding="utf-8") as f:
    content = f.read()

content = re.sub(
    r"(?m)^enable_spot\s+=\s+\S+",
    f"enable_spot      = {enable_spot}",
    content,
    count=1,
)
content = re.sub(
    r'(?m)^spot_strategy\s+=\s+"[^"]*"',
    f'spot_strategy    = "{strategy}"',
    content,
    count=1,
)

def patch_stack_block(text: str, sid: str, strat: str) -> str:
    pattern = rf"({re.escape(sid)}\s*=\s*\{{)(.*?)(\n\s*\}})"
    def repl(m):
        block = m.group(2)
        if re.search(r"(?m)^\s*spot_strategy\s+=", block):
            block = re.sub(
                r'(?m)^(\s*spot_strategy\s+=\s+)"[^"]*"',
                rf'\1"{strat}"',
                block,
            )
        else:
            block = block + f'\n    spot_strategy        = "{strat}"'
        return m.group(1) + block + m.group(3)
    return re.sub(pattern, repl, text, flags=re.DOTALL)

content = patch_stack_block(content, stack_id, strategy)

with open(out, "w", encoding="utf-8") as f:
    f.write(content)
PY
}

spot_update_state_json() {
  local infra_root="$1" stack_id="$2" billing="$3" instance_id="${4:-}"
  local sf zone
  sf="$(spot_state_file "$infra_root")"
  zone="${SPOT_RESOLVED_ZONE:-}"
  python3 - <<'PY' "$sf" "$stack_id" "$billing" "$instance_id" "$zone"
import json, os, sys, datetime
path, stack_id, billing, instance_id, zone = sys.argv[1:6]
data = {}
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
entry = data.get(stack_id, {})
entry.update({
    "billing": billing,
    "last_probe": datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
})
if instance_id:
    entry["instance_id"] = instance_id
if zone:
    entry["resolved_zone"] = zone
data[stack_id] = entry
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}

spot_read_state_field() {
  local infra_root="$1" stack_id="$2" field="$3"
  python3 - <<'PY' "$(spot_state_file "$infra_root")" "$stack_id" "$field"
import json, os, sys
path, stack_id, field = sys.argv[1:4]
if not os.path.isfile(path):
    raise SystemExit(0)
with open(path, encoding="utf-8") as f:
    data = json.load(f)
print(data.get(stack_id, {}).get(field, "") or "")
PY
}

# 云上实例名 · deploy-engine 命名 ${project}-${stack_id}-${env}
spot_stack_instance_name() {
  local stack_id="$1"
  local infra_root="${2:-$SPOT_INFRA_ROOT}"
  local project env sid
  project="$(spot_stack_pref "$stack_id" project "$infra_root")"
  env="$(spot_stack_pref "$stack_id" env "$infra_root")"
  sid="$(spot_stack_pref "$stack_id" stack_id "$infra_root")"
  echo "${project}-${sid}-${env}"
}

spot_stack_name_suffix() {
  local stack_id="$1"
  local infra_root="${2:-$SPOT_INFRA_ROOT}"
  local env sid
  env="$(spot_stack_pref "$stack_id" env "$infra_root")"
  sid="$(spot_stack_pref "$stack_id" stack_id "$infra_root")"
  echo "-${sid}-${env}"
}

# operational_intent: running | stopped · 区分「预期 Up」与「主动 Down」
spot_set_operational_intent() {
  local infra_root="$1" stack_id="$2" intent="$3" reason="${4:-}"
  local sf
  sf="$(spot_state_file "$infra_root")"
  python3 - <<'PY' "$sf" "$stack_id" "$intent" "$reason"
import json, os, sys, datetime
path, stack_id, intent, reason = sys.argv[1:5]
now = datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"
data = {}
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
entry = data.get(stack_id, {})
entry["operational_intent"] = intent
entry["intent_updated_at"] = now
if reason:
    entry["intent_reason"] = reason
if intent == "running":
    entry["last_up_at"] = now
elif intent == "stopped":
    entry["last_down_at"] = now
    entry["last_down_reason"] = reason or "user_intentional"
data[stack_id] = entry
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"[spot-intent] {stack_id} → {intent} ({reason or '-'})")
PY
}

spot_mark_all_intent() {
  local infra_root="$1" intent="$2" reason="${3:-}"
  for sid in proxy base; do
    spot_set_operational_intent "$infra_root" "$sid" "$intent" "$reason"
  done
}

# 从云上刷新 instance / EIP 快照写入 state（deploy 成功后调用）
spot_refresh_cloud_snapshot() {
  local infra_root="$1" stack_id="$2"
  local region suffix iid_hint
  region="$(spot_stack_pref "$stack_id" region "$infra_root")"
  suffix="$(spot_stack_name_suffix "$stack_id" "$infra_root")"
  iid_hint="$(spot_read_state_field "$infra_root" "$stack_id" instance_id)"

  local cloud_out eip_out
  cloud_out=""
  if cloud_out="$(spot_cloud_find_instance "$region" "$suffix" "$iid_hint" 2>/dev/null)"; then
    :
  else
    cloud_out=""
  fi
  eip_out="$(spot_cloud_find_eip "$region" "$stack_id" "$infra_root" "$cloud_out" 2>/dev/null || true)"

  local sf
  sf="$(spot_state_file "$infra_root")"
  python3 - <<'PY' "$sf" "$stack_id" "$cloud_out" "$eip_out"
import json, os, sys, datetime
path, stack_id, cloud_out, eip_out = sys.argv[1:5]
now = datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"
data = {}
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
entry = data.get(stack_id, {})
if cloud_out.strip():
    lines = cloud_out.strip().splitlines()
    if len(lines) >= 1 and lines[0]:
        entry["instance_id"] = lines[0]
    if len(lines) >= 2:
        entry["instance_status"] = lines[1]
    if len(lines) >= 3:
        entry["instance_name"] = lines[2]
    entry["cloud_snapshot_at"] = now
else:
    entry.pop("instance_id", None)
    entry.pop("instance_status", None)
    entry["cloud_snapshot_at"] = now
if eip_out.strip():
    parts = eip_out.strip().splitlines()
    if len(parts) >= 1:
        entry["eip_allocation_id"] = parts[0]
    if len(parts) >= 2:
        entry["eip_address"] = parts[1]
    if len(parts) >= 3:
        entry["eip_status"] = parts[2]
else:
    entry.pop("eip_allocation_id", None)
    entry.pop("eip_address", None)
    entry.pop("eip_status", None)
data[stack_id] = entry
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}

spot_refresh_all_cloud_snapshots() {
  local infra_root="$1"
  for sid in proxy base; do
    spot_refresh_cloud_snapshot "$infra_root" "$sid" || true
  done
}

# stdout: allocation_id\\nip\\nstatus · 未绑定实例的 EIP 也算存在
spot_cloud_find_eip() {
  local region="$1" stack_id="$2" infra_root="$3" cloud_out="${4:-}"
  local hint_ip hint_alloc iid
  hint_alloc="$(spot_read_state_field "$infra_root" "$stack_id" eip_allocation_id)"
  hint_ip="$(spot_read_state_field "$infra_root" "$stack_id" eip_address)"
  iid=""
  if [ -n "$cloud_out" ]; then
    iid="$(echo "$cloud_out" | sed -n '1p')"
  fi

  command -v aliyun >/dev/null 2>&1 || return 2
  ALICLOUD_REGION="$region" HINT_ALLOC="$hint_alloc" HINT_IP="$hint_ip" INSTANCE_ID="$iid" python3 - <<'PY'
import json, os, subprocess, sys
region = os.environ.get("ALICLOUD_REGION", "")
hint_alloc = os.environ.get("HINT_ALLOC", "")
hint_ip = os.environ.get("HINT_IP", "")
instance_id = os.environ.get("INSTANCE_ID", "")

def describe(page=1):
    args = ["aliyun", "ecs", "DescribeEipAddresses", "--RegionId", region, "--PageSize", "100", "--PageNumber", str(page)]
    p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    if p.returncode != 0:
        return None
    return json.loads(p.stdout or "{}")

found_any = False
for page in range(1, 6):
    data = describe(page)
    if not data:
        raise SystemExit(2)
    items = data.get("EipAddresses", {}).get("EipAddress") or []
    if not items:
        break
    found_any = True
    for eip in items:
        alloc = eip.get("AllocationId") or ""
        ip = eip.get("IpAddress") or ""
        status = eip.get("Status") or ""
        bound = eip.get("InstanceId") or ""
        matched = (
            (hint_alloc and alloc == hint_alloc)
            or (hint_ip and ip == hint_ip)
            or (instance_id and bound == instance_id)
        )
        if matched:
            print(alloc)
            print(ip)
            print(status)
            raise SystemExit(0)
raise SystemExit(1)
PY
}

# 读取 operational_intent；空则 unknown
spot_read_operational_intent() {
  local infra_root="$1" stack_id="$2"
  local v
  v="$(spot_read_state_field "$infra_root" "$stack_id" operational_intent)"
  if [ -n "$v" ]; then
    echo "$v"
  else
    echo "unknown"
  fi
}

# 本 stack 是否「预期正在运行」
spot_stack_expect_running() {
  local infra_root="$1" stack_id="$2"
  local intent project env sid
  intent="$(spot_read_operational_intent "$infra_root" "$stack_id")"
  if [ "$intent" = "stopped" ]; then
    return 1
  fi
  if [ "$intent" = "running" ]; then
    return 0
  fi
  # unknown：兼容旧 state · tf state 仍有 stack 则视为预期 Up
  project="$(spot_stack_pref "$stack_id" project "$infra_root")"
  env="$(spot_stack_pref "$stack_id" env "$infra_root")"
  if spot_tf_state_has_stack "$infra_root" "$project" "$env" "$stack_id"; then
    return 0
  fi
  return 1
}

spot_intent_summary_line() {
  local infra_root="$1" stack_id="$2"
  local intent down_at billing
  intent="$(spot_read_operational_intent "$infra_root" "$stack_id")"
  billing="$(spot_read_state_field "$infra_root" "$stack_id" billing)"
  down_at="$(spot_read_state_field "$infra_root" "$stack_id" last_down_at)"
  [ -z "$billing" ] && billing="?"
  echo "  · ${stack_id}: intent=${intent} billing=${billing} last_down=${down_at:--}"
}

spot_prepare_stack_tfvars() {
  local infra_root="$1" stack_id="$2" billing="${3:-}"

  local project env
  project="$(spot_stack_pref "$stack_id" project "$infra_root")"
  env="$(spot_stack_pref "$stack_id" env "$infra_root")"

  if [ -z "$billing" ]; then
    billing="$(spot_resolve_billing_mode "$stack_id" "$infra_root")"
  fi

  local canonical generated
  canonical="$(spot_canonical_tfvars "$infra_root" "$project" "$env")"
  if [ ! -f "$canonical" ]; then
    echo "❌ [spot] canonical tfvars 不存在: $canonical" >&2
    return 1
  fi
  generated="$(spot_generated_dir "$infra_root")/terraform-${project}-${env}.tfvars"
  spot_merge_tfvars_file "$canonical" "$generated" "$stack_id" "$billing"
  spot_update_state_json "$infra_root" "$stack_id" "$billing"
  echo "$generated"
}

spot_prepare_active_config() {
  local infra_root="${1:-$SPOT_INFRA_ROOT}"
  local active gen
  active="$(spot_active_config_root "$infra_root")"
  gen="$(spot_generated_dir "$infra_root")"
  mkdir -p "$active" "$gen"

  for name in diting-prod.yaml deploy.yaml; do
    if [ -f "$infra_root/config/$name" ]; then
      ln -sf "../$name" "$active/$name"
    fi
  done

  local stack_id project env src dst
  for stack_id in proxy base; do
    project="$(spot_stack_pref "$stack_id" project "$infra_root")"
    env="$(spot_stack_pref "$stack_id" env "$infra_root")"
    src="$gen/terraform-${project}-${env}.tfvars"
    dst="$active/terraform-${project}-${env}.tfvars"
    if [ -f "$src" ]; then
      cp -f "$src" "$dst"
    fi
  done
  export SPOT_ACTIVE_CONFIG_ROOT="$active"
}

spot_print_stack_summary() {
  local infra_root="$1" stack_id="$2" billing="$3"
  local region itype
  region="$(spot_stack_pref "$stack_id" region "$infra_root")"
  itype="$(spot_stack_pref "$stack_id" instance_type "$infra_root")"
  local mode_zh="按量 NoSpot"
  [ "$billing" = "spot" ] && mode_zh="竞价 SpotAsPriceGo"
  local zone="${SPOT_RESOLVED_ZONE:-}"
  if [ -n "$zone" ]; then
    echo "  · ${stack_id}: ${mode_zh} · ${region} · ${itype} · 可用区 ${zone}"
  else
    echo "  · ${stack_id}: ${mode_zh} · ${region} · ${itype}"
  fi
}

# 云上实例是否存在（DescribeInstances by name suffix）
spot_cloud_find_instance() {
  local region="$1" name_suffix="$2" instance_id_hint="${3:-}"

  command -v aliyun >/dev/null 2>&1 || return 2
  ALICLOUD_REGION="$region" NAME_SUFFIX="$name_suffix" HINT="$instance_id_hint" python3 - <<'PY'
import json, os, subprocess, sys
region = os.environ.get("ALICLOUD_REGION", "")
suffix = os.environ.get("NAME_SUFFIX", "")
hint = os.environ.get("HINT", "")
p = subprocess.run(
    ["aliyun", "ecs", "DescribeInstances", "--PageSize", "100", "--region", region],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
)
if p.returncode != 0:
    sys.exit(2)
items = json.loads(p.stdout or "{}").get("Instances", {}).get("Instance") or []
for inst in items:
    iid = inst.get("InstanceId") or ""
    name = inst.get("InstanceName") or ""
    if hint and iid == hint:
        print(iid)
        print(inst.get("Status") or "")
        print(name)
        raise SystemExit(0)
    if suffix and suffix in name:
        print(iid)
        print(inst.get("Status") or "")
        print(name)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

spot_tf_state_has_stack() {
  local infra_root="$1" project="$2" env="$3" stack_id="$4"
  local tf_dir="$infra_root/deploy-engine/deploy/terraform/alicloud"
  spot_load_env "$infra_root"
  (
    cd "$tf_dir"
    if [ -f terraform.tfstate ] && [ ! -s terraform.tfstate ]; then rm -f terraform.tfstate; fi
    terraform init -backend-config="prefix=${project}/${env}" -reconfigure -input=false -no-color >/dev/null 2>&1 || true
    terraform state list 2>/dev/null || true
  ) | grep -qE "module\.ecs\.alicloud_instance\.stack\[\"${stack_id}\"\]"
}

spot_write_watch_report() {
  local infra_root="$1" conclusion="$2" detail="$3"
  python3 - <<'PY' "$(spot_watch_report_file "$infra_root")" "$conclusion" "$detail"
import json, sys, datetime
path, conclusion, detail = sys.argv[1:4]
doc = {
    "conclusion": conclusion,
    "detail": detail,
    "checked_at": datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"结论={conclusion} · 已写入 {path}")
PY
}

# CRON=1 时将巡检报告发邮件（126 · 读 diting-src/.env COPILOT_SMTP_*）
spot_watch_send_email() {
  local infra_root="$1" conclusion="$2" detail="$3" action="$4"
  local send_cron send_healthy prefs_send

  send_cron="$(yq eval '.watch_email.send_on_cron // true' "$(spot_prefs_file "$infra_root")")"
  send_healthy="$(yq eval '.watch_email.send_on_healthy // true' "$(spot_prefs_file "$infra_root")")"
  prefs_send="$(yq eval '.watch_email.enabled // true' "$(spot_prefs_file "$infra_root")")"

  [ "$prefs_send" = "true" ] || { echo "ℹ️  [spot-watch] 邮件已禁用（watch_email.enabled=false）"; return 0; }
  if [ "${CRON:-0}" != "1" ] && [ "${SPOT_WATCH_EMAIL:-0}" != "1" ]; then
    return 0
  fi
  if [ "$send_cron" != "true" ] && [ "${CRON:-0}" = "1" ]; then
    return 0
  fi
  if [ "$conclusion" = "HEALTHY" ] && [ "$send_healthy" != "true" ]; then
    echo "ℹ️  [spot-watch] HEALTHY 跳过发信（send_on_healthy=false）"
    return 0
  fi

  python3 "$SPOT_LIB_DIR/../spot-watch-send-email.py" \
    --infra-root "$infra_root" \
    --conclusion "$conclusion" \
    --detail "$detail" \
    --action "$action" || return 1
}

spot_confirm() {
  local prompt="$1"
  if [ "${CRON:-0}" = "1" ]; then
    echo "ℹ️  [spot-watch] CRON=1 跳过交互: $prompt"
    return 1
  fi
  if [ "${INTERACTIVE:-0}" != "1" ] && [ "${SPOT_AUTO_CONFIRM:-0}" != "1" ]; then
    echo "ℹ️  [spot-watch] 需 INTERACTIVE=1 才执行切换 · $prompt"
    echo "   建议: make cluster-spot-watch INTERACTIVE=1"
    return 1
  fi
  read -r -p "$prompt [y/N]: " ans
  case "${ans:-n}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

spot_deploy_engine_env() {
  local infra_root="${1:-$SPOT_INFRA_ROOT}"
  export CONFIG_ROOT="$(spot_active_config_root "$infra_root")"
  export SPOT_TFVARS_ROOT="$CONFIG_ROOT"
}
