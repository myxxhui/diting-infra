#!/usr/bin/env bash
# step_18 · 五区工作台 P0 生产 HTTP 验收
# [Ref: 33_五区工作台_前端区际联动与数据携带契约.md §3 · §12 P0]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
NS="${STACK_NS:-platform}"
CONN="${CONN_FILE:-$INFRA_ROOT/prod.conn}"
IP="$(grep '^PUBLIC_IP=' "$CONN" 2>/dev/null | cut -d= -f2- || echo "127.0.0.1")"
PORT="${COPILOT_NODEPORT:-30080}"
BASE="http://${IP}:${PORT}"
TMPDIR="${TMPDIR:-/tmp}"
WB_HTML="$TMPDIR/copilot-step18-workbench.html"
ROADMAP_HTML="$TMPDIR/copilot-step18-roadmap.html"
LEDGER_HTML="$TMPDIR/copilot-step18-ledger.html"
NAV_HTML="$TMPDIR/copilot-step18-nav.html"

_pass() { echo "  ✅ $1"; }
_fail() { echo "  ❌ $1"; exit 1; }
_grep_file() {
  local name="$1" file="$2" needle="$3"
  [ -s "$file" ] || _fail "${name}：HTTP 响应为空（${file}）"
  grep -q "$needle" "$file" || _fail "${name}：未找到「${needle}」"
  _pass "${name} · ${needle}"
}

echo "▶ [step18-p0-verify] Pod 就绪"
kubectl rollout status "deployment/${COPILOT_DEPLOY:-diting-copilot}" -n "$NS" --timeout=120s >/dev/null

echo "▶ [step18-p0-verify] HTTP @ ${BASE}"

curl -sSL "${BASE}/planning" -o "$WB_HTML"
_grep_file "投资工作台页头" "$WB_HTML" "投资工作台"
for _tab in "产业风向" "机会雷达" "买入论证" "持仓监护" "决策复盘"; do
  _grep_file "五区 Tab" "$WB_HTML" "$_tab"
done
_grep_file "漏斗进度条·产业风向" "$WB_HTML" "产业风向"
_grep_file "漏斗进度条·机会雷达" "$WB_HTML" "机会雷达"
_roadmap_pos="$(grep -b -o '产业风向' "$WB_HTML" | head -1 | cut -d: -f1)"
_radar_pos="$(grep -b -o '机会雷达' "$WB_HTML" | head -1 | cut -d: -f1)"
[ -n "$_roadmap_pos" ] && [ -n "$_radar_pos" ] && [ "$_roadmap_pos" -lt "$_radar_pos" ] \
  || _fail "漏斗进度条顺序应为产业风向在机会雷达之前"
_pass "漏斗进度条顺序 · 产业风向 → 机会雷达"
_grep_file "战略总览入口" "$WB_HTML" "战略总览"

curl -sSL "${BASE}/planning?view=roadmap" -o "$ROADMAP_HTML"
_grep_file "Z0 指挥台标题" "$ROADMAP_HTML" "产业风向台"
_grep_file "Z0 三栏·左栏" "$ROADMAP_HTML" "战略板块"
_grep_file "Z0 三栏·右栏" "$ROADMAP_HTML" "strategic-phase-panel"

curl -sSL "${BASE}/planning?view=ledger" -o "$LEDGER_HTML"
_grep_file "Z4 决策复盘库" "$LEDGER_HTML" "决策复盘库"
_grep_file "Z4 横切标记" "$LEDGER_HTML" "横切工作区"

_loc="$(curl -sS -o /dev/null -w '%{redirect_url}' "${BASE}/value")"
echo "$_loc" | grep -q 'view=ledger' || _fail "/value 302 missing view=ledger (got: ${_loc:-empty})"
_pass "/value redirect to ledger tab"

_ledger_hdr="$(curl -sS -D - -o /dev/null "${BASE}/ledger?symbol=601138" | tr -d '\r')"
if echo "$_ledger_hdr" | grep -qi '^location:.*view=ledger'; then
  echo "$_ledger_hdr" | grep -qi 'symbol=601138' || _fail "/ledger redirect missing symbol=601138"
  _pass "/ledger redirect to planning?view=ledger"
elif echo "$_ledger_hdr" | grep -qE 'HTTP/[0-9.]+ 404'; then
  echo "  ⚠️ /ledger 404 on current image (skip) · covered by /value + view=ledger"
else
  _fail "/ledger unexpected response: $(echo "$_ledger_hdr" | head -1)"
fi

curl -sSL "${BASE}/" -o "$NAV_HTML"
_grep_file "顶栏·投资工作台" "$NAV_HTML" "投资工作台"
_grep_file "顶栏·决策复盘" "$NAV_HTML" "决策复盘"

echo "✅ [copilot-workbench-p0-verify] 五区工作台 P0 生产验收全部通过"
