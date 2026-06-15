#!/usr/bin/env bash
# 单 stack 计费模式切换：down → 合并 tfvars → up/deploy
# [Ref: 31_Spot计费感知与巡检规约.md]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/spot-billing-lib.sh
source "$SCRIPT_DIR/lib/spot-billing-lib.sh"

STACK="${STACK:-}"
BILLING="${BILLING:-}"
INTERACTIVE="${INTERACTIVE:-0}"

if [ -z "$STACK" ] || [ -z "$BILLING" ]; then
  echo "用法: make switch-stack-billing STACK=proxy|base BILLING=spot|ondemand [INTERACTIVE=1]"
  exit 1
fi
case "$STACK" in proxy|base) ;; *)
  echo "错误: STACK 须为 proxy 或 base"
  exit 1
  ;;
esac
case "$BILLING" in spot|ondemand) ;; *)
  echo "错误: BILLING 须为 spot 或 ondemand"
  exit 1
  ;;
esac

spot_load_env "$INFRA_ROOT"

if [ "$(spot_policy_pref require_confirm_on_switch "$INFRA_ROOT")" = "true" ]; then
  if [ "$INTERACTIVE" != "1" ] && [ "${SPOT_AUTO_CONFIRM:-0}" != "1" ]; then
    echo "❌ 切换计费模式须 INTERACTIVE=1（policy.require_confirm_on_switch=true）"
    echo "   示例: make switch-stack-billing STACK=${STACK} BILLING=${BILLING} INTERACTIVE=1"
    exit 1
  fi
fi

if [ "$INTERACTIVE" = "1" ] || [ "${SPOT_AUTO_CONFIRM:-0}" = "1" ]; then
  read -r -p "确认切换 ${STACK} → ${BILLING}？将 down 并重建 ECS+EIP [y/N]: " ans
  case "${ans:-n}" in
    y|Y|yes|YES) ;;
    *) echo "已取消"; exit 0 ;;
  esac
fi

project="$(spot_stack_pref "$STACK" project "$INFRA_ROOT")"
env="$(spot_stack_pref "$STACK" env "$INFRA_ROOT")"

export SPOT_FORCE_BILLING="$BILLING"
spot_prepare_stack_tfvars "$INFRA_ROOT" "$STACK" "$BILLING" >/dev/null
spot_prepare_active_config "$INFRA_ROOT"
spot_deploy_engine_env "$INFRA_ROOT"

echo "▶ [switch-stack-billing] STACK=${STACK} BILLING=${BILLING} · CONFIG_ROOT=${CONFIG_ROOT}"

if [ "$STACK" = "proxy" ]; then
  make -C "$INFRA_ROOT/deploy-engine" down-proxy "$project" "$env" CONFIG_ROOT="$CONFIG_ROOT" \
    TF_VAR_FILE="$CONFIG_ROOT/terraform-${project}-${env}.tfvars" || true
  if spot_tf_state_has_stack "$INFRA_ROOT" "$project" "$env" proxy; then
    make -C "$INFRA_ROOT/deploy-engine" up-proxy "$project" "$env" CONFIG_ROOT="$CONFIG_ROOT" \
      TF_VAR_FILE="$CONFIG_ROOT/terraform-${project}-${env}.tfvars"
  else
    make -C "$INFRA_ROOT/deploy-engine" deploy-proxy "$project" "$env" CONFIG_ROOT="$CONFIG_ROOT" \
      TF_VAR_FILE="$CONFIG_ROOT/terraform-${project}-${env}.tfvars"
  fi
  make -C "$INFRA_ROOT" sync-anthropic-proxy-to-copilot
  make -C "$INFRA_ROOT" verify-sg-anthropic-proxy
else
  make -C "$INFRA_ROOT" down-stack diting-stack CONFIG_ROOT="$CONFIG_ROOT" || true
  make -C "$INFRA_ROOT" up-stack diting-stack CONFIG_ROOT="$CONFIG_ROOT"
  CONFIG_ROOT="$CONFIG_ROOT" PROJECT="$project" ENV="$env" \
    CONN_FILE="$INFRA_ROOT/prod.conn" bash "$INFRA_ROOT/scripts/platform-step03-deploy-stack.sh"
fi

spot_update_state_json "$INFRA_ROOT" "$STACK" "$BILLING"
echo "✅ [switch-stack-billing] ${STACK} 已切换为 ${BILLING}"
