#!/usr/bin/env bash
# 复用已有数据盘时，从 OSS remote state 移除 alicloud_disk.prod_data（不销毁云上盘）
# [Ref: terraform-diting-prod.tfvars use_existing_data_disk_id · main.tf prevent_destroy]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=terraform-output-safe.sh
source "$SCRIPT_DIR/terraform-output-safe.sh"

PROJECT="${1:-diting}"
ENV="${2:-prod}"
CONFIG_ROOT="${CONFIG_ROOT:-$INFRA_ROOT/config}"
TF_DIR="${3:-$INFRA_ROOT/deploy-engine/deploy/terraform/alicloud}"
DISK_FILE="${4:-$INFRA_ROOT/prod.disk_id}"
TFVARS="$CONFIG_ROOT/terraform-${PROJECT}-${ENV}.tfvars"

if [ -f "$INFRA_ROOT/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$INFRA_ROOT/.env"
  set +a
fi
export ALICLOUD_ACCESS_KEY="${ALICLOUD_ACCESS_KEY:-}"
export ALICLOUD_SECRET_KEY="${ALICLOUD_SECRET_KEY:-}"

_resolve_disk_id() {
  local disk_id=""
  if [ -n "${TF_VAR_use_existing_data_disk_id:-}" ]; then
    disk_id="$TF_VAR_use_existing_data_disk_id"
  elif read_disk_id_safe "$DISK_FILE" >/dev/null 2>&1; then
    disk_id="$(read_disk_id_safe "$DISK_FILE")"
  elif [ -f "$TFVARS" ]; then
    disk_id="$(grep -E '^\s*use_existing_data_disk_id\s*=' "$TFVARS" 2>/dev/null | head -1 | sed -E 's/^[^=]*=\s*"?([^"#]+)"?.*/\1/' | tr -d ' ' || true)"
  fi
  if [ -n "$disk_id" ] && [[ "$disk_id" =~ ^d-[a-z0-9]+$ ]]; then
    printf '%s' "$disk_id"
    return 0
  fi
  return 1
}

DISK_ID="$(_resolve_disk_id || true)"
if [ -z "$DISK_ID" ]; then
  echo "ℹ️  [prod-disk-handoff] 未配置已有数据盘 ID，跳过 state 移交"
  exit 0
fi

if [ -f "$TF_DIR/terraform.tfstate" ] && [ ! -s "$TF_DIR/terraform.tfstate" ]; then
  rm -f "$TF_DIR/terraform.tfstate"
fi

(
  cd "$TF_DIR"
  terraform init \
    -backend-config="prefix=${PROJECT}/${ENV}" \
    -reconfigure \
    -input=false \
    -no-color >/dev/null
)

STATE_LIST="$(
  cd "$TF_DIR"
  terraform state list 2>/dev/null || true
)"

if ! printf '%s\n' "$STATE_LIST" | grep -q 'alicloud_disk\.prod_data\[0\]'; then
  echo "ℹ️  [prod-disk-handoff] state 无 prod_data 资源，跳过（复用盘 ${DISK_ID}）"
  exit 0
fi

STATE_DISK_ID="$(
  cd "$TF_DIR"
  terraform state show 'alicloud_disk.prod_data[0]' 2>/dev/null \
    | grep -E '^\s*id\s*=' | head -1 | sed -E 's/.*=\s*"([^"]+)".*/\1/' || true
)"

if [ -n "$STATE_DISK_ID" ] && [ "$STATE_DISK_ID" != "$DISK_ID" ]; then
  echo "⚠️  [prod-disk-handoff] state 盘 ${STATE_DISK_ID} 与目标复用盘 ${DISK_ID} 不一致，仍从 state 移除托管（请人工核对）" >&2
fi

echo "▶ [prod-disk-handoff] 从 OSS state 移除 prod_data 托管，复用已有盘 ${DISK_ID}（不销毁云上盘）"
(
  cd "$TF_DIR"
  terraform state rm 'data.alicloud_vswitches.data_disk_zone[0]' 2>/dev/null || true
  terraform state rm 'alicloud_disk.prod_data[0]'
)
echo "✅ [prod-disk-handoff] 完成 · 后续 apply 将通过 use_existing_data_disk_id 挂载 ${DISK_ID}"
