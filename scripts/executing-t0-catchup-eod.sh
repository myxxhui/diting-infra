#!/usr/bin/env bash
# 补跑 JL4 日频 EOD 采集（错过 Cron 或部署后 catch-up）
# [Ref: 28_ §4.4 · jobs_runner.JL4_EOD_CATCHUP_JOB_IDS]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
NS="${EXECUTING_T0_NS:-platform}"

JOBS=(
  l4-etf-redemption-morning
  l4-margin-skew-morning
  l4-smart-money-eod
  l2-super-order-eod
  l4-turnover-accel-eod
  l4-beta-correlation-eod
  l4-block-trade-eod
  l4-retail-concentration-eod
  l4-insider-sell-eod
  l4-atr-bars-sync
)

echo "▶ [executing-t0-catchup-eod] Pod 内顺序补采 ${#JOBS[@]} 个 JL4 EOD job"
for jid in "${JOBS[@]}"; do
  echo "▶ job=${jid}"
  kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec deploy/diting-copilot -- \
    python -m apps.copilot.jobs.executing_t0 "$jid" || {
      echo "⚠️  ${jid} 失败（继续下一项）"
    }
done
echo "✅ [executing-t0-catchup-eod] 完成"
