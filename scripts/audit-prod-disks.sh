#!/usr/bin/env bash
# 审计香港 prod 独立数据盘：以 prod.disk_id / tfvars 为 canonical，列出并可选删除孤儿盘
# 规划口径：香港 1 块 ESSD 独立数据盘（PG/Timescale/Redis 等 subPath）；新加坡 proxy 无独立盘
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=terraform-output-safe.sh
source "$SCRIPT_DIR/terraform-output-safe.sh"

APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    -h|--help)
      echo "用法: audit-prod-disks.sh [--apply]"
      echo "  默认仅报告；--apply 删除未挂载且非 canonical 的孤儿 data 盘（需 aliyun CLI）"
      exit 0
      ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

if [ -f "$INFRA_ROOT/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$INFRA_ROOT/.env"
  set +a
fi

DISK_FILE="${INFRA_ROOT}/prod.disk_id"
TFVARS="${INFRA_ROOT}/config/terraform-diting-prod.tfvars"
HK_REGION="cn-hongkong"
SG_REGION="ap-southeast-1"

canonical=""
if read_disk_id_safe "$DISK_FILE" >/dev/null 2>&1; then
  canonical="$(read_disk_id_safe "$DISK_FILE")"
fi
if [ -z "$canonical" ] && [ -f "$TFVARS" ]; then
  canonical="$(grep -E '^\s*use_existing_data_disk_id\s*=' "$TFVARS" | head -1 | sed -E 's/.*=\s*"([^"]+)".*/\1/' | tr -d ' ' || true)"
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  Diting 数据盘审计"
echo "═══════════════════════════════════════════════════════════════"
echo "  权威盘 ID（canonical）: ${canonical:-未配置}"
echo "  挂载规划: /mnt/titan-data/postgres → subPath: timescaledb | postgresql-l2 | radar_t0_cache | redis | …"
echo "  新加坡 proxy: 无独立数据盘（attach_data_disk=false）"
echo ""

if ! command -v aliyun >/dev/null 2>&1; then
  echo "⚠️  未安装 aliyun CLI，仅输出本地 canonical 配置"
  exit 0
fi

_list_data_disks() {
  local region="$1"
  ALICLOUD_REGION="$region" python3 - <<'PY'
import json, os, subprocess, sys
region = os.environ.get("ALICLOUD_REGION", "cn-hongkong")
p = subprocess.run(
    ["aliyun", "ecs", "DescribeDisks", "--RegionId", region, "--PageSize", "100"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
)
if p.returncode != 0:
    print(f"ERR\t{p.stderr.strip()}", file=sys.stderr)
    sys.exit(1)
for d in json.loads(p.stdout or "{}").get("Disks", {}).get("Disk") or []:
    dtype = d.get("Type") or ""
    if dtype != "data":
        continue
    print("\t".join([
        d.get("DiskId") or "",
        d.get("DiskName") or "",
        str(d.get("Size") or ""),
        d.get("Status") or "",
        d.get("InstanceId") or "-",
        d.get("Category") or "",
        d.get("CreationTime") or "",
    ]))
PY
}

echo "── 香港 (${HK_REGION}) 独立 data 盘 ──"
hk_count=0
orphans=()
while IFS=$'\t' read -r did name size status iid cat created; do
  [ -n "$did" ] || continue
  hk_count=$((hk_count + 1))
  tag=""
  if [ -n "$canonical" ] && [ "$did" = "$canonical" ]; then
    tag="✅ CANONICAL（PG/Timescale/Redis/Copilot 数据）"
  elif [ "$status" = "Available" ] && { [ -z "$iid" ] || [ "$iid" = "-" ]; }; then
    tag="⚠️  孤儿盘（未挂载）"
    orphans+=("$did")
  else
    tag="ℹ️  非 canonical"
  fi
  echo "  $did  name=${name:-—}  ${size}GB  status=$status  instance=${iid}  $tag"
  echo "       category=$cat  created=$created"
done < <(_list_data_disks "$HK_REGION")
[ "$hk_count" -eq 0 ] && echo "  （无独立 data 盘）"

echo ""
echo "── 新加坡 (${SG_REGION}) 独立 data 盘（预期 0）──"
sg_count=0
while IFS=$'\t' read -r did name size status iid cat created; do
  [ -n "$did" ] || continue
  sg_count=$((sg_count + 1))
  echo "  $did  ${size}GB  status=$status  instance=${iid:-—}  ⚠️  proxy 不应有独立盘"
  if [ "$status" = "Available" ] && [ -z "$iid" ]; then
    orphans+=("$did")
  fi
done < <(_list_data_disks "$SG_REGION")
[ "$sg_count" -eq 0 ] && echo "  （无 · 符合预期）"

echo ""
echo "── 自动快照策略 ──"
if command -v aliyun >/dev/null 2>&1 && [ -n "$canonical" ]; then
  ALICLOUD_REGION="$HK_REGION" CANONICAL="$canonical" python3 - <<'PY'
import json, os, subprocess, sys
region = os.environ.get("ALICLOUD_REGION", "cn-hongkong")
disk_id = os.environ.get("CANONICAL", "")
p = subprocess.run(
    ["aliyun", "ecs", "DescribeDisks", "--RegionId", region, "--DiskIds", json.dumps([disk_id])],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
)
if p.returncode != 0:
    print("  ⚠️  无法查询磁盘快照策略")
    sys.exit(0)
disks = json.loads(p.stdout or "{}").get("Disks", {}).get("Disk") or []
if not disks:
    print("  ⚠️  磁盘不存在")
    sys.exit(0)
d = disks[0]
pid = d.get("AutoSnapshotPolicyId") or ""
ena = d.get("EnableAutomatedSnapshotPolicy")
if pid:
    q = subprocess.run(
        ["aliyun", "ecs", "DescribeAutoSnapshotPolicyEx", "--RegionId", region,
         "--AutoSnapshotPolicyId", pid],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
    )
    pol = {}
    if q.returncode == 0:
        arr = json.loads(q.stdout or "{}").get("AutoSnapshotPolicies", {}).get("AutoSnapshotPolicy") or []
        pol = arr[0] if arr else {}
    tp = []
    tp_raw = pol.get("TimePoints")
    if isinstance(tp_raw, str):
        try:
            tp = json.loads(tp_raw)
        except json.JSONDecodeError:
            tp = [tp_raw]
    elif isinstance(tp_raw, dict):
        tp = tp_raw.get("TimePoint") or []
    elif isinstance(tp_raw, list):
        tp = tp_raw
    rd = pol.get("RetentionDays")
    name = pol.get("AutoSnapshotPolicyName") or pid
    hours = ",".join(f"{h}:00" for h in tp) if tp else "?"
    print(f"  ✅ 已绑定策略 {name} ({pid})")
    print(f"     时间点(UTC+8): {hours} · 保留 {rd} 天 · EnableAutomatedSnapshotPolicy={ena}")
else:
    print("  ⚠️  未绑定自动快照策略 → 执行 make ensure-prod-data-snapshot")
PY
else
  echo "  （跳过：无 aliyun 或无 canonical 盘 ID）"
fi

echo ""
echo "── 系统盘说明 ──"
echo "  ECS 每台自带 1 块 system 盘（Type=system）；删除 ECS 后应随实例释放。"
echo "  若控制台看到「5 块盘」，常见为 N 台 ECS 系统盘 + 1 块独立 data 盘，并非 5 块数据盘。"

if [ "${#orphans[@]}" -eq 0 ]; then
  echo ""
  echo "✅ 未发现可安全删除的孤儿 data 盘"
  exit 0
fi

echo ""
echo "── 待删除孤儿盘（${#orphans[@]}）──"
for did in "${orphans[@]}"; do
  if [ -n "$canonical" ] && [ "$did" = "$canonical" ]; then
    echo "  跳过 canonical: $did"
    continue
  fi
  echo "  $did"
done

if [ "$APPLY" -ne 1 ]; then
  echo ""
  echo "ℹ️  干跑模式；确认后执行: bash scripts/audit-prod-disks.sh --apply"
  exit 0
fi

echo ""
echo "▶ 开始删除孤儿盘..."
for did in "${orphans[@]}"; do
  if [ -n "$canonical" ] && [ "$did" = "$canonical" ]; then
    continue
  fi
  echo "  删除 $did ..."
  if aliyun ecs DeleteDisk --DiskId "$did" --region "$HK_REGION" 2>/dev/null \
      || aliyun ecs DeleteDisk --DiskId "$did" --region "$SG_REGION" 2>/dev/null; then
    echo "  ✅ 已删除 $did"
  else
    echo "  ❌ 删除失败 $did（可能仍挂载或受保护）"
    exit 1
  fi
done
echo "✅ 孤儿盘清理完成"
