#!/usr/bin/env bash
# 从 deploy-engine state JSON 恢复 kubeconfig（Terraform 漂移 / get-kubeconfig IP 不一致时）
# 用法: bash scripts/kubeconfig-restore-state.sh [project] [env]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="${1:-diting}"
ENV="${2:-prod}"
STATE="$INFRA_ROOT/deploy-engine/.deploy/state-${PROJECT}-${ENV}.json"
OUT="$HOME/.kube/config-${PROJECT}-${ENV}"

[ -f "$STATE" ] || { echo "[restore] 错误: 状态文件不存在 $STATE"; exit 1; }
python3 - "$STATE" "$OUT" <<'PY'
import json, base64, sys
from pathlib import Path
state_path, out_path = sys.argv[1], sys.argv[2]
state = json.load(open(state_path))
ctx = state.get("cluster_ctx") or {}
b64 = ctx.get("KubeConfig") or ""
if not b64:
    sys.exit("[restore] 错误: state 中无 KubeConfig")
Path(out_path).parent.mkdir(parents=True, exist_ok=True)
Path(out_path).write_text(base64.b64decode(b64).decode())
print(f"[restore] ✅ 已写入 {out_path}")
print(f"[restore]    InstanceID={ctx.get('InstanceID','?')} PublicIP={ctx.get('PublicIP','?')}")
PY
bash "$SCRIPT_DIR/kubecm-helpers.sh" add-and-switch "$PROJECT" "$ENV"
