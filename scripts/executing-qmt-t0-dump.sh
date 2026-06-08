#!/usr/bin/env bash
# 生产验收：导出 #15 qmt_atr_trailing T0 底库 → 文档仓审计 JSON
# [Ref: 28_ §2.2.2]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_ROOT="$(cd "$INFRA_ROOT/../diting-src" && pwd)"
DOC_OUT="$(cd "$INFRA_ROOT/../diting-doc/06_追溯与审计" && pwd)"
CONN="${INFRA_ROOT}/prod.conn"
SYMS="${EXECUTING_SYMBOLS:-601138,002837,300502}"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
OUT_FILE="${DOC_OUT}/executing_qmt_atr_t0_dump_${STAMP}.json"
TMP_PG="/tmp/_qmt_pg_${STAMP}.json"

if [[ -f "$CONN" ]]; then
  # shellcheck disable=SC1090
  source "$CONN"
fi
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
NS="${EXECUTING_T0_NS:-platform}"

echo "▶ [executing-qmt-t0-dump] 标的=$SYMS"

# 部署镜像含 scripts/ 后可直接: python scripts/dump_executing_qmt_t0.py
kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec -i deployment/diting-copilot -- \
  python scripts/dump_executing_qmt_t0.py --symbols "$SYMS" > "$TMP_PG" 2>/dev/null || true
if [[ ! -s "$TMP_PG" ]]; then
  kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec -i deployment/diting-copilot -- \
    python - < "$SCRIPT_DIR/executing-qmt-t0-dump-inline.py" > "$TMP_PG"
fi

REDIS_URL="${REDIS_URL:-}" PYTHONPATH="$SRC_ROOT" \
  python3 "$SRC_ROOT/scripts/dump_executing_qmt_t0.py" \
  --local --symbols "$SYMS" \
  --api-base "http://${PUBLIC_IP:-8.217.142.179}:30080" > /tmp/_qmt_local.json

PYTHONPATH="$SRC_ROOT" OUT_FILE="$OUT_FILE" TMP_PG="$TMP_PG" python3 - <<'PY'
import json
import os
from datetime import datetime, timezone

with open(os.environ["TMP_PG"], encoding="utf-8") as f:
    pg = json.load(f)
with open("/tmp/_qmt_local.json", encoding="utf-8") as f:
    local = json.load(f)

merged = {
    "probe_key": "qmt_atr_trailing",
    "merged_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "pg_and_t0_raw": pg.get("pg_and_t0_raw"),
    "watermarks": (pg.get("pg_and_t0_raw") or {}).get("watermarks"),
    "symbols": (pg.get("pg_and_t0_raw") or {}).get("symbols"),
    "redis_intraday": local.get("redis_intraday"),
    "tencent_fqkline_live": local.get("tencent_fqkline_live"),
    "copilot_api": local.get("copilot_api"),
}
out = os.environ["OUT_FILE"]
with open(out, "w", encoding="utf-8") as f:
    json.dump(merged, f, ensure_ascii=False, indent=2)
print(out)
PY

rm -f "$TMP_PG" /tmp/_qmt_local.json
echo "✅ T0 导出完成 → $OUT_FILE"
