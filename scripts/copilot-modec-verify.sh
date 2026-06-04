#!/usr/bin/env bash
# 模式 C 生产验收：POST 异步扫描 → 轮询 GET /api/radar/scans/{id} 直至 done/error
# [Ref: planning_routes api_create_radar_scan · run_scan_job]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STACK_NS="${STACK_NS:-platform}"
SYMBOL="${RADAR_SYMBOL:-601138}"
POLL_SEC="${MODEC_VERIFY_POLL_SEC:-3}"
MAX_WAIT="${MODEC_VERIFY_MAX_WAIT:-300}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"

export KUBECONFIG
echo "▶ [copilot-modec-verify] symbol=${SYMBOL} 异步真扫（最长 ${MAX_WAIT}s）"

kubectl exec -i -n "$STACK_NS" deployment/diting-copilot -- \
  python3 - "$SYMBOL" "$POLL_SEC" "$MAX_WAIT" <<'PY'
import json
import sys
import time
import urllib.parse
import urllib.request

symbol = sys.argv[1].zfill(6)[-6:]
poll_sec = float(sys.argv[2])
max_wait = float(sys.argv[3])
base = "http://127.0.0.1:8080"
headers = {"Accept": "application/json"}


def req(method: str, path: str, data: dict | None = None, timeout: float = 30) -> dict:
    body = None
    h = dict(headers)
    if data is not None:
        body = urllib.parse.urlencode(data).encode()
        h["Content-Type"] = "application/x-www-form-urlencoded"
    r = urllib.request.Request(f"{base}{path}", data=body, method=method, headers=h)
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


created = req(
    "POST",
    "/api/radar/scans",
    {"input_type": "symbol", "query_text": symbol, "enable_t2": "true"},
    timeout=30,
)
scan_id = created.get("id")
if not scan_id:
    raise SystemExit(f"POST 未返回 scan id: {created!r}")

status = created.get("status", "running")
deadline = time.monotonic() + max_wait
while status not in ("done", "error") and time.monotonic() < deadline:
    time.sleep(poll_sec)
    got = req("GET", f"/api/radar/scans/{scan_id}", timeout=60)
    status = got.get("status", "running")
    if status == "running":
        sj = got.get("summary_json") or {}
        print(f"  … 轮询 scan_id={scan_id} status=running", flush=True)
        continue
    created = got
    break

if status == "error":
    err = (created.get("summary_json") or {}).get("error") or created
    raise SystemExit(f"扫描失败: {err}")

if status != "done":
    raise SystemExit(f"超时（>{max_wait}s）: scan_id={scan_id} 仍为 {status}")

cands = created.get("candidates") or []
if not cands:
    raise SystemExit(f"scan done 但无 candidates: {created!r}")

c = cands[0]
s = c.get("t2_status")
cost = (c.get("cost") or {}).get("cost_yuan")
dims = (c.get("deep_analysis") or {}).get("dimensions") or {}
overall = ((c.get("deep_analysis") or {}).get("overall") or {}).get("conclusion")
print(
    f"t2_status={s} | 维度数={len(dims)} | 成本 ¥{cost} | "
    f"route={(c.get('cost') or {}).get('route')} | 结论={overall}"
)

if s != "ok":
    raise SystemExit(f"模式 C T2 非 ok: {c.get('t2_detail')}")
if len(dims) != 9:
    raise SystemExit(f"维度数应为 9，实际 {len(dims)}")
if not cost or float(cost) <= 0:
    raise SystemExit(f"成本未透出: {c.get('cost')}")

print("✅ 模式 C 真扫验收通过")
PY

echo "✅ [copilot-modec-verify] 模式 C 真扫验收通过（9 维 + 成本）"
