#!/usr/bin/env bash
# 剥离 diting-copilot 上历史 ConfigMap 热修挂载，恢复镜像内代码为准
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
NS="${STACK_NS:-platform}"
DEPLOY="${COPILOT_DEPLOY:-diting-copilot}"
TMP="$(mktemp)"
kubectl get deployment "$DEPLOY" -n "$NS" -o json > "$TMP"
python3 - "$TMP" << 'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    obj = json.load(f)
spec = obj["spec"]["template"]["spec"]
spec["volumes"] = [v for v in spec.get("volumes", []) if v.get("name") != "radar-hotfix"]
c = spec["containers"][0]
c["volumeMounts"] = [m for m in c.get("volumeMounts", []) if m.get("name") != "radar-hotfix"]
with open(path, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False)
print(f"volumes={len(spec['volumes'])} mounts={len(c['volumeMounts'])}")
PY
kubectl apply -f "$TMP"
rm -f "$TMP"
kubectl rollout status "deployment/${DEPLOY}" -n "$NS" --timeout=300s
echo "✅ ${DEPLOY} 热修挂载已剥离"
