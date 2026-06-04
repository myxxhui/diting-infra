#!/usr/bin/env bash
# 28_ 执行中工作区 · 集群内 tier-2 验收（不依赖 prod.conn PUBLIC_IP / 本机 NodePort 可达）
set -euo pipefail
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
NS="${COPILOT_NS:-platform}"
SYMBOL="${EXECUTING_SYMBOL:-601138}"

echo "▶ [copilot-executing-tier2-verify-k8s] namespace=$NS symbol=$SYMBOL"

kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec deploy/diting-copilot -- \
  env EXECUTING_SYMBOL="$SYMBOL" python - <<'PY'
import json
import os
import sys
import urllib.request

base = "http://127.0.0.1:8080"
symbol = os.environ.get("EXECUTING_SYMBOL", "601138").zfill(6)[-6:]
failures = []


def get(path: str) -> tuple[int, str]:
    req = urllib.request.Request(base + path, headers={"Accept": "text/html,application/json"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.status, resp.read().decode("utf-8", errors="replace")


for label, path, check in [
    ("positions", "/api/executing/positions", lambda b: json.loads(b) and any(
        str(p.get("symbol", "")).endswith(symbol) for p in json.loads(b)
    )),
    ("sync-status", "/api/executing/sync-status", lambda b: all(
        k in json.loads(b) for k in ("stale_count", "missing_count", "probes")
    )),
    ("planning", "/planning?view=executing", lambda b: "executing" in b.lower() or "执行" in b),
    ("detail", f"/api/executing/{symbol}/detail", lambda b: all(
        x in b for x in ("executing-workspace", "层 A", "层 B", "层 C")
    )),
]:
    try:
        code, body = get(path)
        if code != 200 or not check(body):
            failures.append(f"{label} {path} code={code}")
    except Exception as exc:
        failures.append(f"{label} {path}: {exc}")

if failures:
    print("❌ 集群内 tier-2 失败:")
    for f in failures:
        print(" ", f)
    sys.exit(1)

print("✅ 集群内 tier-2 HTTP 验收通过（不含 25/25 数据准出）")
PY

kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec deploy/diting-copilot -- \
  python -m apps.copilot.jobs.executing_t0 --status 2>&1 | tail -20

echo "✅ [copilot-executing-tier2-verify-k8s] 完成"
