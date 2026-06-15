#!/usr/bin/env bash
# 启动前 Spot 优先探测 · 生成 .generated / .spot-active tfvars
# [Ref: 31_Spot计费感知与巡检规约.md]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/spot-billing-lib.sh
source "$SCRIPT_DIR/lib/spot-billing-lib.sh"

spot_load_env "$INFRA_ROOT"

if [ "${SPOT_PREFER:-1}" = "0" ]; then
  echo "ℹ️  [spot-prefer] SPOT_PREFER=0 · 跳过 Spot 探测，使用 canonical tfvars"
  exit 0
fi

echo "▶ [spot-prefer-on-deploy] 探测 Spot 库存并生成 tfvars（policy=$(spot_policy_pref default "$INFRA_ROOT")）"

_billing_proxy="" _billing_base=""
_billing_proxy="$(spot_resolve_billing_mode proxy "$INFRA_ROOT")"
spot_prepare_stack_tfvars "$INFRA_ROOT" proxy "$_billing_proxy" >/dev/null
spot_print_stack_summary "$INFRA_ROOT" proxy "$_billing_proxy"

_billing_base="$(spot_resolve_billing_mode base "$INFRA_ROOT")"
spot_prepare_stack_tfvars "$INFRA_ROOT" base "$_billing_base" >/dev/null
spot_print_stack_summary "$INFRA_ROOT" base "$_billing_base"

spot_prepare_active_config "$INFRA_ROOT"
echo "✅ [spot-prefer-on-deploy] 活跃配置目录: $(spot_active_config_root "$INFRA_ROOT")"
