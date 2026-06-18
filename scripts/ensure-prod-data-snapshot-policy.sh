#!/usr/bin/env bash
# 为权威 prod 独立数据盘配置/对齐自动快照策略（每日 16:00 UTC+8 · 保留 7 天）
# 配置来源：config/diting-prod.yaml stack.storage.prod_data_disk_snapshot
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=terraform-output-safe.sh
source "$SCRIPT_DIR/terraform-output-safe.sh"

CFG="${CONFIG_ROOT:-$INFRA_ROOT/config}/diting-prod.yaml"
DISK_FILE="${INFRA_ROOT}/prod.disk_id"
POLICY_ID_FILE="${INFRA_ROOT}/prod.snapshot_policy_id"

if [ -f "$INFRA_ROOT/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$INFRA_ROOT/.env"
  set +a
fi

if ! command -v aliyun >/dev/null 2>&1; then
  echo "❌ 未安装 aliyun CLI，无法配置自动快照"
  exit 1
fi
if ! command -v yq >/dev/null 2>&1; then
  echo "❌ 未安装 yq，无法读取 $CFG"
  exit 1
fi

ENABLED="$(yq eval '.stack.storage.prod_data_disk_snapshot.enabled // true' "$CFG")"
if [ "$ENABLED" != "true" ]; then
  echo "ℹ️  prod_data_disk_snapshot.enabled=false，跳过"
  exit 0
fi

POLICY_NAME="$(yq eval '.stack.storage.prod_data_disk_snapshot.policy_name // "diting-prod-data-daily"' "$CFG")"
TIME_HOUR="$(yq eval '.stack.storage.prod_data_disk_snapshot.time_point_hour // 16' "$CFG")"
RETENTION="$(yq eval '.stack.storage.prod_data_disk_snapshot.retention_days // 7' "$CFG")"
WEEKDAYS="$(yq eval '.stack.storage.prod_data_disk_snapshot.repeat_weekdays // [1,2,3,4,5,6,7] | map(tostring) | join(",")' "$CFG")"
HK_REGION="$(grep -E '^\s*region\s*=' "${INFRA_ROOT}/config/terraform-diting-prod.tfvars" 2>/dev/null | head -1 | sed -E 's/^[^=]*=\s*"?([^"]+)"?.*/\1/' | tr -d ' ')"
HK_REGION="${HK_REGION:-cn-hongkong}"

DISK_ID=""
if read_disk_id_safe "$DISK_FILE" >/dev/null 2>&1; then
  DISK_ID="$(read_disk_id_safe "$DISK_FILE")"
fi
if [ -z "$DISK_ID" ]; then
  DISK_ID="$(grep -E '^\s*use_existing_data_disk_id\s*=' "${INFRA_ROOT}/config/terraform-diting-prod.tfvars" 2>/dev/null | head -1 | sed -E 's/.*=\s*"([^"]+)".*/\1/' | tr -d ' ' || true)"
fi
if [ -z "$DISK_ID" ]; then
  echo "❌ 未找到权威数据盘 ID（prod.disk_id / tfvars use_existing_data_disk_id）"
  exit 1
fi

TIME_POINTS_JSON="$(python3 - <<PY
import json
print(json.dumps([str(int("$TIME_HOUR"))]))
PY
)"
WEEKDAYS_JSON="$(python3 - <<PY
import json
days = [d.strip() for d in "$WEEKDAYS".split(",") if d.strip()]
print(json.dumps(days))
PY
)"

echo "▶ [prod-data-snapshot] 盘=$DISK_ID region=$HK_REGION"
echo "   策略=$POLICY_NAME · 每日 ${TIME_HOUR}:00 (UTC+8，15:30 后首个整点) · 保留 ${RETENTION} 天"

export ALICLOUD_REGION="$HK_REGION"
POLICY_ID="$(python3 - <<'PY' "$POLICY_NAME" "$TIME_POINTS_JSON" "$WEEKDAYS_JSON" "$RETENTION" "$DISK_ID"
import json, os, subprocess, sys

policy_name, time_points_json, weekdays_json, retention, disk_id = sys.argv[1:6]
region = os.environ.get("ALICLOUD_REGION", "cn-hongkong")
time_points = json.loads(time_points_json)
weekdays = json.loads(weekdays_json)
retention = int(retention)

def log(msg):
    print(msg, flush=True, file=sys.stderr)

def run(action, **params):
    env = os.environ.copy()
    env["ALICLOUD_REGION"] = region
    pascal = action in ("DescribeAutoSnapshotPolicyEx", "DescribeDisks")
    args = ["aliyun", "ecs", action, f"--{'RegionId' if pascal else 'regionId'}", region]
    for k, v in params.items():
        if v is None or v == "":
            continue
        args.extend([f"--{k}", str(v)])
    p = subprocess.run(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip() or p.stdout.strip() or f"{action} failed")
    return json.loads(p.stdout) if p.stdout.strip() else {}

def find_policy_id():
    data = run("DescribeAutoSnapshotPolicyEx", AutoSnapshotPolicyName=policy_name)
    for pol in data.get("AutoSnapshotPolicies", {}).get("AutoSnapshotPolicy") or []:
        if (pol.get("AutoSnapshotPolicyName") or "") == policy_name:
            return pol.get("AutoSnapshotPolicyId") or ""
    return ""

def parse_json_list(val):
    if val is None:
        return []
    if isinstance(val, list):
        return [str(x) for x in val]
    if isinstance(val, str):
        try:
            return [str(x) for x in json.loads(val)]
        except json.JSONDecodeError:
            return [val]
    if isinstance(val, dict):
        inner = val.get("TimePoint") or val.get("RepeatWeekday") or []
        return parse_json_list(inner)
    return []

def policy_matches(pol):
    tp = sorted(parse_json_list(pol.get("TimePoints")))
    rw = sorted(parse_json_list(pol.get("RepeatWeekdays")))
    want_tp = sorted(time_points)
    want_rw = sorted(weekdays)
    return tp == want_tp and rw == want_rw and int(pol.get("RetentionDays") or 0) == retention

pid = find_policy_id()
if pid:
    detail = run("DescribeAutoSnapshotPolicyEx", AutoSnapshotPolicyId=pid)
    pols = detail.get("AutoSnapshotPolicies", {}).get("AutoSnapshotPolicy") or []
    pol = pols[0] if pols else {}
    if not policy_matches(pol):
        log(f"▶ 更新已有策略 {pid}")
        run(
            "ModifyAutoSnapshotPolicyEx",
            autoSnapshotPolicyId=pid,
            timePoints=json.dumps(time_points),
            repeatWeekdays=json.dumps(weekdays),
            retentionDays=str(retention),
        )
else:
    log(f"▶ 创建策略 {policy_name}")
    out = run(
        "CreateAutoSnapshotPolicy",
        autoSnapshotPolicyName=policy_name,
        timePoints=json.dumps(time_points),
        repeatWeekdays=json.dumps(weekdays),
        retentionDays=str(retention),
    )
    pid = out.get("AutoSnapshotPolicyId") or find_policy_id()

if not pid:
    raise SystemExit("❌ 无法获取 AutoSnapshotPolicyId")

disk = run("DescribeDisks", DiskIds=json.dumps([disk_id]))
disks = disk.get("Disks", {}).get("Disk") or []
if not disks:
    raise SystemExit(f"❌ 磁盘不存在: {disk_id}")

def list_policies_with_disks():
    """列出本 region 内 DiskNums>0 的快照策略（用于多策略 reconciler）。"""
    out = []
    page = 1
    while True:
        data = run("DescribeAutoSnapshotPolicyEx", PageNumber=str(page), PageSize="50")
        batch = data.get("AutoSnapshotPolicies", {}).get("AutoSnapshotPolicy") or []
        if not batch:
            break
        for pol in batch:
            if int(pol.get("DiskNums") or 0) > 0:
                out.append(pol)
        total = int(data.get("TotalCount") or 0)
        if page * 50 >= total:
            break
        page += 1
    return out

def cancel_policy_on_disk(policy_id, reason=""):
    if not policy_id or policy_id == pid:
        return
    try:
        run(
            "CancelAutoSnapshotPolicy",
            autoSnapshotPolicyId=policy_id,
            diskIds=json.dumps([disk_id]),
        )
        log(f"▶ 已解绑冗余策略 {policy_id} ← 盘 {disk_id}" + (f" ({reason})" if reason else ""))
    except RuntimeError as exc:
        msg = str(exc)
        if "NotFound" in msg or "InvalidAutoSnapshotPolicyId" in msg:
            return
        raise

# 多策略 reconciler：盘上仅保留 canonical pid（显式 autoSnapshotPolicyId，避免 TooMany 403）
for pol in list_policies_with_disks():
    other = (pol.get("AutoSnapshotPolicyId") or "").strip()
    if other and other != pid:
        name = pol.get("AutoSnapshotPolicyName") or other
        cancel_policy_on_disk(other, name)

disk = run("DescribeDisks", DiskIds=json.dumps([disk_id]))
disks = disk.get("Disks", {}).get("Disk") or []
cur = (disks[0].get("AutoSnapshotPolicyId") or "").strip()
if cur and cur != pid:
    cancel_policy_on_disk(cur, "DescribeDisks.AutoSnapshotPolicyId")

if cur != pid:
    run("ApplyAutoSnapshotPolicy", autoSnapshotPolicyId=pid, diskIds=json.dumps([disk_id]))
    log(f"✅ 已绑定策略 {pid} → 盘 {disk_id}")
else:
    log(f"✅ 策略 {pid} 已绑定盘 {disk_id}（无需变更）")

print(pid)
PY
)"

printf '%s\n' "$POLICY_ID" > "$POLICY_ID_FILE"
echo "   策略 ID 已写入 $POLICY_ID_FILE"
