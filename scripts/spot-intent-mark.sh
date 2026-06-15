#!/usr/bin/env bash
# 运行意图标记：deploy → running · down → stopped
# [Ref: 31_Spot计费感知与巡检规约.md §2.3]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/spot-billing-lib.sh
source "$SCRIPT_DIR/lib/spot-billing-lib.sh"

spot_load_env "$INFRA_ROOT"
OP="${1:-}"

case "$OP" in
  up)
    spot_mark_all_intent "$INFRA_ROOT" "running" "make deploy diting prod"
    spot_refresh_all_cloud_snapshots "$INFRA_ROOT"
    echo "✅ [spot-intent] 已标记 proxy/base 为 running · 已刷新云上快照"
    ;;
  down)
    spot_mark_all_intent "$INFRA_ROOT" "stopped" "make down diting prod"
    echo "✅ [spot-intent] 已标记 proxy/base 为 stopped（主动关闭 · 巡检不发告警）"
    ;;
  status)
    echo "▶ [spot-intent] 当前运行意图"
    spot_intent_summary_line "$INFRA_ROOT" proxy
    spot_intent_summary_line "$INFRA_ROOT" base
    ;;
  *)
    echo "用法: $0 up|down|status"
    exit 1
    ;;
esac
