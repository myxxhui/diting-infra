#!/usr/bin/env bash
# 数据盘快照：Terraform 与 ensure 脚本双写 reconciler
# 根因：Terraform attachment 销毁时 CancelAutoSnapshotPolicy 未带 policyId，
#       若盘上已挂多条策略 → OperationDenied.TooManyAutoSnapshotPolicies
# 策略：diting-infra 以 config/diting-prod.yaml + ensure-prod-data-snapshot-policy.sh 为唯一真相源；
#       tfvars 设 enable_prod_data_disk_snapshot=false 并从 state 移除快照资源，避免 apply 时 destroy。
# [Ref: 03_/共享平台基础/ · Makefile deploy-diting-prod]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=terraform-output-safe.sh
source "$SCRIPT_DIR/terraform-output-safe.sh"

PROJECT="${1:-diting}"
ENV="${2:-prod}"
CONFIG_ROOT="${CONFIG_ROOT:-$INFRA_ROOT/config}"
TF_DIR="${INFRA_ROOT}/deploy-engine/deploy/terraform/alicloud"
TFVARS="$CONFIG_ROOT/terraform-${PROJECT}-${ENV}.tfvars"

if [ -f "$INFRA_ROOT/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$INFRA_ROOT/.env"
  set +a
fi

_enabled="true"
if [ -f "$TFVARS" ]; then
  _enabled="$(grep -E '^[[:space:]]*enable_prod_data_disk_snapshot[[:space:]]*=' "$TFVARS" 2>/dev/null | head -1 | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*#.*//' | tr -d '[:space:]')"
fi

if [ "$_enabled" = "true" ]; then
  echo "ℹ️  [snapshot-reconcile] enable_prod_data_disk_snapshot=true · 保留 Terraform 快照资源（建议改为 false 并由 ensure 脚本管理）"
  exit 0
fi

echo "▶ [snapshot-reconcile] enable_prod_data_disk_snapshot=false · 从 Terraform state 移除快照资源（不调用 Cancel API）"

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

_rm_state() {
  local addr="$1"
  if terraform -chdir="$TF_DIR" state show "$addr" >/dev/null 2>&1; then
    echo "  · state rm $addr"
    terraform -chdir="$TF_DIR" state rm "$addr" >/dev/null
  fi
}

_rm_state 'alicloud_ecs_auto_snapshot_policy_attachment.prod_data[0]'
_rm_state 'alicloud_ecs_auto_snapshot_policy.prod_data[0]'

echo "✅ [snapshot-reconcile] Terraform 快照资源已从 state 剥离（云上策略由 ensure-prod-data-snapshot 管理）"
