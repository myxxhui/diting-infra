#!/usr/bin/env bash
# P-step_04 · Spot 无库存时定时重试 make up-stack diting-training
# [Ref: 03_/共享平台基础/.../step_04_GPU训练组按需Up.md · 14 表 BLOCKED(spot_inventory_zero)]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$INFRA_ROOT"

REGION="${REGION:-cn-hongkong}"
INSTANCE_TYPE="${INSTANCE_TYPE:-ecs.gn6i-c4g1.xlarge}"
SPOT_STRATEGY="${SPOT_STRATEGY:-SpotAsPriceGo}"
PREFERRED_ZONE="${PREFERRED_ZONE:-cn-hongkong-b}"
RETRY_INTERVAL_SEC="${RETRY_INTERVAL_SEC:-7200}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-0}"
LOG_FILE="${LOG_FILE:-$INFRA_ROOT/logs/retry-up-stack-training.log}"
STATE_FILE="${STATE_FILE:-$INFRA_ROOT/logs/retry-up-stack-training.state}"
PID_FILE="${PID_FILE:-$INFRA_ROOT/logs/retry-up-stack-training.pid}"

mkdir -p "$(dirname "$LOG_FILE")"

if [ -f "$INFRA_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$INFRA_ROOT/.env"
  set +a
fi

export ALIBABA_CLOUD_ACCESS_KEY_ID="${ALICLOUD_ACCESS_KEY:-${ALIBABA_CLOUD_ACCESS_KEY_ID:-}}"
export ALIBABA_CLOUD_ACCESS_KEY_SECRET="${ALICLOUD_SECRET_KEY:-${ALIBABA_CLOUD_ACCESS_KEY_SECRET:-}}"
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}

write_state() {
  local status="$1"
  local detail="$2"
  local next_at="${3:-}"
  cat >"$STATE_FILE" <<EOF
status=$status
detail=$detail
last_attempt=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
next_attempt=$next_at
region=$REGION
instance_type=$INSTANCE_TYPE
preferred_zone=$PREFERRED_ZONE
retry_interval_sec=$RETRY_INTERVAL_SEC
pid=$$
EOF
}

spot_has_stock() {
  command -v aliyun >/dev/null 2>&1 || return 2
  [ -n "${ALIBABA_CLOUD_ACCESS_KEY_ID:-}" ] || return 2
  [ -n "${ALIBABA_CLOUD_ACCESS_KEY_SECRET:-}" ] || return 2

  local strategy="$1"
  local out
  if ! out="$(aliyun ecs DescribeAvailableResource \
    --RegionId "$REGION" \
    --DestinationResource InstanceType \
    --InstanceType "$INSTANCE_TYPE" \
    --SpotStrategy "$strategy" 2>/dev/null)"; then
    return 2
  fi

  python3 - <<'PY' "$out" "$PREFERRED_ZONE"
import json, sys
raw, preferred = sys.argv[1], sys.argv[2]
data = json.loads(raw)
available = []
for z in data.get("AvailableZones", {}).get("AvailableZone", []):
    zid = z.get("ZoneId")
    for ar in z.get("AvailableResources", {}).get("AvailableResource", []):
        for sr in ar.get("SupportedResources", {}).get("SupportedResource", []):
            if sr.get("Status") == "Available":
                available.append(zid)
if preferred in available:
    print(preferred)
    raise SystemExit(0)
if available:
    print(available[0])
    raise SystemExit(0)
raise SystemExit(1)
PY
}

# Spot 无货时探测按量 NoSpot（tfvars train.spot_strategy=NoSpot 时使用）
gpu_has_stock() {
  local stock_zone=""
  if stock_zone="$(spot_has_stock "SpotAsPriceGo" 2>/dev/null)"; then
    log "库存: Spot Available @ ${stock_zone}"
    echo "$stock_zone"
    return 0
  fi
  if stock_zone="$(spot_has_stock "NoSpot" 2>/dev/null)"; then
    log "库存: 按量 NoSpot Available @ ${stock_zone}（Spot 售罄）"
    echo "$stock_zone"
    return 0
  fi
  return 1
}

attempt_up_stack() {
  log "执行: CONFIG_ROOT=$INFRA_ROOT/config make up-stack diting-training"
  CONFIG_ROOT="$INFRA_ROOT/config" make up-stack diting-training 2>&1 | tee -a "$LOG_FILE"
}

log "=== retry-up-stack-training 启动 ==="
log "region=$REGION instance=$INSTANCE_TYPE spot=$SPOT_STRATEGY interval=${RETRY_INTERVAL_SEC}s max_attempts=${MAX_ATTEMPTS:-∞}"
echo "$$" >"$PID_FILE"

attempt=0
while true; do
  attempt=$((attempt + 1))
  log "--- 第 ${attempt} 次尝试 ---"

  stock_zone=""
  stock_rc=0
  stock_zone="$(gpu_has_stock)" || stock_rc=$?

  if [ "$stock_rc" -eq 0 ]; then
    log "GPU 库存探测: Available @ ${stock_zone}"
  elif [ "$stock_rc" -eq 2 ]; then
    log "Spot 库存探测跳过（aliyun/凭证不可用），直接尝试 up-stack"
  else
    next_at="$(date -u -v+${RETRY_INTERVAL_SEC}S '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "+${RETRY_INTERVAL_SEC} seconds" '+%Y-%m-%dT%H:%M:%SZ')"
    log "GPU 库存探测: SoldOut（${REGION} · ${INSTANCE_TYPE} · Spot+按量均无）· 下次 ${next_at}（${RETRY_INTERVAL_SEC}s 后）"
    write_state "waiting_spot" "SoldOut" "$next_at"
    if [ "${RETRY_ONCE:-0}" = "1" ] || { [ "$MAX_ATTEMPTS" -gt 0 ] && [ "$attempt" -ge "$MAX_ATTEMPTS" ]; }; then
      log "单次/已达最大次数，退出"
      exit 1
    fi
    sleep "$RETRY_INTERVAL_SEC"
    continue
  fi

  write_state "attempting" "up-stack diting-training" ""
  set +e
  attempt_up_stack
  rc=${PIPESTATUS[0]}
  set -e

  if [ "$rc" -eq 0 ]; then
    log "✅ up-stack diting-training 成功 · 停止重试循环"
    write_state "success" "train stack up" ""
    rm -f "$PID_FILE"
    exit 0
  fi

  if tail -30 "$LOG_FILE" | grep -q "OperationDenied.NoStock"; then
    next_at="$(date -u -v+${RETRY_INTERVAL_SEC}S '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "+${RETRY_INTERVAL_SEC} seconds" '+%Y-%m-%dT%H:%M:%SZ')"
    log "❌ NoStock · 下次 ${next_at}（${RETRY_INTERVAL_SEC}s 后）"
    write_state "waiting_spot" "NoStock from terraform" "$next_at"
  else
    next_at="$(date -u -v+${RETRY_INTERVAL_SEC}S '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "+${RETRY_INTERVAL_SEC} seconds" '+%Y-%m-%dT%H:%M:%SZ')"
    log "❌ up-stack 失败 exit=$rc · 下次 ${next_at}（${RETRY_INTERVAL_SEC}s 后）"
    write_state "retrying_error" "exit=$rc" "$next_at"
  fi

  if [ "${RETRY_ONCE:-0}" = "1" ]; then
    exit "$rc"
  fi
  if [ "$MAX_ATTEMPTS" -gt 0 ] && [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    log "已达 MAX_ATTEMPTS=$MAX_ATTEMPTS，退出"
    exit "$rc"
  fi

  sleep "$RETRY_INTERVAL_SEC"
done
