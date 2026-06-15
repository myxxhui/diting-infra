#!/usr/bin/env bash
# 本地统一巡检（15min cron）：运行意图 vs 云上 ECS/EIP · Spot 机会 · 126 邮件
# 集群内 CronJob 仅作集群 Up 时补充；主路径为本脚本 + CRON=1
# [Ref: 31_Spot计费感知与巡检规约.md]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/spot-billing-lib.sh
source "$SCRIPT_DIR/lib/spot-billing-lib.sh"
# shellcheck source=sg-anthropic-proxy-helpers.sh
source "$SCRIPT_DIR/sg-anthropic-proxy-helpers.sh"

spot_load_env "$INFRA_ROOT"

CRON="${CRON:-0}"
INTERACTIVE="${INTERACTIVE:-0}"
WATCH_INTERVAL="$(spot_policy_pref watch_interval_minutes "$INFRA_ROOT")"

echo "▶ [cluster-spot-watch] 本地巡检（cron=${CRON} interactive=${INTERACTIVE} 间隔=${WATCH_INTERVAL}min）"

_conclusion="HEALTHY"
_detail=""
_action=""
_intent_lines=""

_finish_watch() {
  local rc="${1:-0}"
  spot_watch_send_email "$INFRA_ROOT" "$_conclusion" "$_detail" "$_action" || true
  exit "$rc"
}

# --- 余额（仅预期 Up 时阻断 deploy 类建议）---
if command -v aliyun >/dev/null 2>&1; then
  if ! sg_proxy_check_balance 100; then
    if spot_stack_expect_running "$INFRA_ROOT" proxy || spot_stack_expect_running "$INFRA_ROOT" base; then
      _conclusion="BALANCE_BLOCK"
      _detail="账户余额不足 100 CNY · 预期集群应运行"
      _action="充值后 make redeploy-prod-ondemand-fallback"
      spot_write_watch_report "$INFRA_ROOT" "$_conclusion" "$_detail"
      echo "❌ [cluster-spot-watch] ${_detail}"
      _finish_watch 1
    fi
  fi
fi

# --- 香港 K8s（base 预期 Up 时才有意义）---
_base_project="$(spot_stack_pref base project "$INFRA_ROOT")"
_base_env="$(spot_stack_pref base env "$INFRA_ROOT")"
_k8s_ok=0
_kubeconfig="$HOME/.kube/config-${_base_project}-${_base_env}"
if [ -f "$_kubeconfig" ]; then
  if KUBECONFIG="$_kubeconfig" kubectl cluster-info --request-timeout=15s >/dev/null 2>&1; then
    _k8s_ok=1
  fi
fi

# --- 新加坡 proxy 健康 ---
_proxy_project="$(spot_stack_pref proxy project "$INFRA_ROOT")"
_proxy_env="$(spot_stack_pref proxy env "$INFRA_ROOT")"
_proxy_healthy=0
if [ -f "$INFRA_ROOT/sg-proxy.conn" ]; then
  if bash -c "source '$SCRIPT_DIR/sg-anthropic-proxy-helpers.sh'; sg_proxy_load_env '$INFRA_ROOT'; \
    PW=\$(sg_proxy_resolve_password '$INFRA_ROOT'); \
    PORT=\$(yq eval '.anthropic_proxy.port // 3128' '$INFRA_ROOT/config/diting-prod.yaml'); \
    USER=\$(yq eval '.anthropic_proxy.user // \"ditingproxy\"' '$INFRA_ROOT/config/diting-prod.yaml'); \
    sg_proxy_resolve_endpoint '$INFRA_ROOT' $_proxy_project $_proxy_env '$INFRA_ROOT/sg-proxy.conn' \"\$PORT\" && \
    sg_proxy_health_check \"\$PROXY_IP\" \"\${PROXY_PORT:-\$PORT}\" \"\$USER\" \"\$PW\" 2 3" 2>/dev/null; then
    _proxy_healthy=1
  fi
fi

_worst_rank=0
# rank: 0=ok 1=opportunity 2=unexpected/preempted/eip_lingering 3=balance

_diagnose_stack() {
  local stack_id="$1"
  local region itype billing suffix intent_line expect_up=0
  region="$(spot_stack_pref "$stack_id" region "$INFRA_ROOT")"
  itype="$(spot_stack_pref "$stack_id" instance_type "$INFRA_ROOT")"
  billing="$(spot_read_state_field "$INFRA_ROOT" "$stack_id" billing)"
  [ -z "$billing" ] && billing="ondemand"
  suffix="$(spot_stack_name_suffix "$stack_id" "$INFRA_ROOT")"
  intent_line="$(spot_intent_summary_line "$INFRA_ROOT" "$stack_id")"
  _intent_lines="${_intent_lines}${intent_line}"$'\n'

  local ecs_rc=1 eip_rc=1
  local ecs_out="" eip_out=""
  local iid_hint ecs_ok=0 eip_ok=0
  iid_hint="$(spot_read_state_field "$INFRA_ROOT" "$stack_id" instance_id)"

  if ecs_out="$(spot_cloud_find_instance "$region" "$suffix" "$iid_hint" 2>/dev/null)"; then
    ecs_rc=0
  fi
  if eip_out="$(spot_cloud_find_eip "$region" "$stack_id" "$INFRA_ROOT" "$ecs_out" 2>/dev/null)"; then
    eip_rc=0
  fi
  [ "$ecs_rc" -eq 0 ] && ecs_ok=1
  [ "$eip_rc" -eq 0 ] && eip_ok=1

  if spot_stack_expect_running "$INFRA_ROOT" "$stack_id"; then
    expect_up=1
  fi

  # --- 预期已关闭：ECS 无但 EIP 仍挂着 → 发邮件提醒清理 ---
  if [ "$expect_up" -eq 0 ]; then
    echo "  ${stack_id}: 预期关闭(stopped) · ecs=${ecs_ok} eip=${eip_ok}"
    if [ "$ecs_ok" -eq 0 ] && [ "$eip_ok" -eq 1 ]; then
      local eip_addr eip_alloc
      eip_addr="$(spot_read_state_field "$INFRA_ROOT" "$stack_id" eip_address)"
      eip_alloc="$(spot_read_state_field "$INFRA_ROOT" "$stack_id" eip_allocation_id)"
      [ -z "$eip_addr" ] && eip_addr="$(echo "$eip_out" | sed -n '2p')"
      [ -z "$eip_alloc" ] && eip_alloc="$(echo "$eip_out" | sed -n '1p')"
      if [ "$_worst_rank" -lt 2 ]; then
        _conclusion="EIP_LINGERING"
        _detail="${stack_id} 预期已关闭 · ECS 不存在 · EIP 仍保留（${eip_addr:-未知} / ${eip_alloc:-未知}）· 可能持续计费"
        _action="控制台释放 orphan EIP · 或 make down diting prod 复核回收"
        _worst_rank=2
      fi
    fi
    return 0
  fi

  echo "  ${stack_id}: 预期运行 · ecs=${ecs_ok} eip=${eip_ok} billing=${billing} k8s=${_k8s_ok} proxy_ok=${_proxy_healthy}"

  # 非预期释放：预期 Up 但 ECS 没了
  if [ "$ecs_ok" -eq 0 ]; then
    local spot_stock=0
    spot_has_stock "$region" "$itype" "SpotAsPriceGo" "$(spot_stack_pref "$stack_id" preferred_zone "$INFRA_ROOT")" >/dev/null 2>&1 && spot_stock=1 || spot_stock=$?

    if [ "$eip_ok" -eq 1 ]; then
      if [ "$billing" = "spot" ] && [ "$spot_stock" -ne 1 ]; then
        _conclusion="PREEMPTED_LIKELY"
        _detail="${stack_id} 预期运行 · ECS 不存在 · EIP 仍存在 · 上次 spot · Spot 无货"
        _action="make redeploy-prod-ondemand-fallback"
        _worst_rank=2
      else
        _conclusion="UNEXPECTED_RELEASE"
        _detail="${stack_id} 预期运行 · ECS 不存在 · EIP 仍存在（非预期释放）"
        _action="make deploy diting prod"
        _worst_rank=2
      fi
      return 0
    fi
    # ECS 与 EIP 都没了，但仍预期 Up
    if [ "$stack_id" = "base" ] && [ "$_k8s_ok" = "0" ]; then
      if [ "$billing" = "spot" ] && [ "$spot_stock" -ne 1 ]; then
        _conclusion="PREEMPTED_LIKELY"
        _detail="香港 base 预期运行 · ECS/EIP 均不可见 · kubectl 不可达 · 疑似 Spot 抢占"
        _action="make redeploy-prod-ondemand-fallback"
      else
        _conclusion="UNEXPECTED_RELEASE"
        _detail="香港 base 预期运行 · ECS/EIP 均不可见 · 集群不可达"
        _action="make deploy diting prod"
      fi
      _worst_rank=2
      return 0
    fi
    if [ "$stack_id" = "proxy" ] && [ "$_proxy_healthy" = "0" ]; then
      _conclusion="UNEXPECTED_RELEASE"
      _detail="新加坡 proxy 预期运行 · ECS 不可见 · 代理不可用"
      _action="make deploy diting prod"
      _worst_rank=2
      return 0
    fi
  fi

  # Spot 机会：集群实际在跑 + 当前按量
  if [ "$billing" = "ondemand" ] && spot_has_stock "$region" "$itype" "SpotAsPriceGo" "$(spot_stack_pref "$stack_id" preferred_zone "$INFRA_ROOT")" >/dev/null 2>&1; then
    if [ "$stack_id" = "base" ] && [ "$_k8s_ok" = "1" ] && [ "$_worst_rank" -lt 2 ]; then
      if [ "$_worst_rank" -lt 1 ]; then
        _conclusion="SPOT_OPPORTUNITY"
        _detail="base 按量运行中 · 香港 Spot 有货 · 可切换竞价省成本"
        _action="make switch-stack-billing STACK=base BILLING=spot INTERACTIVE=1"
        _worst_rank=1
      fi
    elif [ "$stack_id" = "proxy" ] && [ "$_proxy_healthy" = "1" ] && [ "$_worst_rank" -lt 2 ]; then
      if [ "$_worst_rank" -lt 1 ]; then
        _conclusion="SPOT_OPPORTUNITY"
        _detail="proxy 按量运行中 · 新加坡 Spot 有货 · 可切换竞价"
        _action="make switch-stack-billing STACK=proxy BILLING=spot INTERACTIVE=1"
        _worst_rank=1
      fi
    fi
  fi
}

echo "▶ [cluster-spot-watch] 运行意图 / 计费"
_diagnose_stack proxy
_diagnose_stack base

if [ "$_worst_rank" -eq 0 ]; then
  _detail="运行意图与云状态一致 · k8s=${_k8s_ok} proxy_ok=${_proxy_healthy}"$'\n'"${_intent_lines}"
fi

spot_write_watch_report "$INFRA_ROOT" "$_conclusion" "$_detail"
echo "▶ [cluster-spot-watch] 结论=${_conclusion}"
echo "   ${_detail}"

case "$_conclusion" in
  HEALTHY)
    echo "✅ [cluster-spot-watch] 无异常（含预期关闭栈不发告警）"
    _finish_watch 0
    ;;
  PREEMPTED_LIKELY|UNEXPECTED_RELEASE|BALANCE_BLOCK|EIP_LINGERING)
    echo "⚠️  [cluster-spot-watch] 建议: ${_action}"
    if [ "$_conclusion" = "PREEMPTED_LIKELY" ] && spot_confirm "是否立即切换按量并重部署？"; then
      spot_watch_send_email "$INFRA_ROOT" "$_conclusion" "$_detail" "$_action" || true
      exec make -C "$INFRA_ROOT" redeploy-prod-ondemand-fallback
    fi
    _finish_watch 2
    ;;
  SPOT_OPPORTUNITY)
    echo "💡 [cluster-spot-watch] 可选: ${_action}"
    if spot_confirm "是否切换为竞价实例？"; then
      spot_watch_send_email "$INFRA_ROOT" "$_conclusion" "$_detail" "$_action" || true
      if [[ "$_action" == *STACK=proxy* ]]; then
        exec make -C "$INFRA_ROOT" switch-stack-billing STACK=proxy BILLING=spot INTERACTIVE=1
      else
        exec make -C "$INFRA_ROOT" switch-stack-billing STACK=base BILLING=spot INTERACTIVE=1
      fi
    fi
    _finish_watch 0
    ;;
  *)
    _finish_watch 0
    ;;
esac
