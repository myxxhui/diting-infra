#!/usr/bin/env bash
# 雷达 7 天版本缓存 + 强制刷新 + 审计页 — 生产热修（无需本地 Docker）
# 1) ConfigMap 覆盖 Python/HTML  2) helm 注入 168h/7d  3) rollout  4) 可选 radar-t0-sync
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="${DITING_SRC:-$INFRA_ROOT/../diting-src}"
NS="${RADAR_T0_SYNC_NS:-platform}"
DEPLOY="${RADAR_T0_SYNC_DEPLOY:-diting-copilot}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"

CM_NAME="copilot-radar-hotfix"
RADAR="$SRC/apps/copilot/modules/radar"
ROUTES="$SRC/apps/copilot/routers/planning_routes.py"
WB="$SRC/apps/copilot/templates/planning/workbench.html"

DISPATCHER="$SRC/apps/common/ai_dispatcher.py"
FUNNEL="$SRC/apps/copilot/modules/planning/funnel.py"
DB_INIT="$SRC/apps/copilot/db/database.py"
DB_M19="$SRC/apps/copilot/db/migrate_step19.py"
DB_MODELS="$SRC/apps/copilot/db/models.py"
for f in \
  "$RADAR/symbol_resolve.py" \
  "$RADAR/scanner.py" \
  "$RADAR/t0_cache.py" \
  "$RADAR/t2_resolve.py" \
  "$RADAR/display_layout.py" \
  "$RADAR/workbench_prefs.py" \
  "$RADAR/persistence.py" \
  "$RADAR/pipeline.py" \
  "$RADAR/service.py" \
  "$RADAR/audit_render.py" \
  "$RADAR/chat.py" \
  "$FUNNEL" \
  "$DISPATCHER" \
  "$DB_INIT" \
  "$DB_M19" \
  "$DB_MODELS" \
  "$ROUTES" \
  "$WB"; do
  [ -f "$f" ] || { echo "❌ 缺少 $f"; exit 1; }
done

echo "▶ [radar-audit-hotfix] 更新 ConfigMap $CM_NAME @ $NS"
kubectl create configmap "$CM_NAME" -n "$NS" \
  --from-file=symbol_resolve.py="$RADAR/symbol_resolve.py" \
  --from-file=scanner.py="$RADAR/scanner.py" \
  --from-file=t0_cache.py="$RADAR/t0_cache.py" \
  --from-file=t2_resolve.py="$RADAR/t2_resolve.py" \
  --from-file=display_layout.py="$RADAR/display_layout.py" \
  --from-file=workbench_prefs.py="$RADAR/workbench_prefs.py" \
  --from-file=persistence.py="$RADAR/persistence.py" \
  --from-file=pipeline.py="$RADAR/pipeline.py" \
  --from-file=funnel.py="$FUNNEL" \
  --from-file=ai_dispatcher.py="$DISPATCHER" \
  --from-file=database.py="$DB_INIT" \
  --from-file=migrate_step19.py="$DB_M19" \
  --from-file=models.py="$DB_MODELS" \
  --from-file=service.py="$RADAR/service.py" \
  --from-file=audit_render.py="$RADAR/audit_render.py" \
  --from-file=chat.py="$RADAR/chat.py" \
  --from-file=planning_routes.py="$ROUTES" \
  --from-file=workbench.html="$WB" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "▶ [radar-audit-hotfix] helm upgrade（文件缓存 24h + DB 30 天 + Opus env）"
bash "$SCRIPT_DIR/copilot-sync-ai-from-src-env.sh"

echo "▶ [radar-audit-hotfix] 挂载热修文件到 deployment/${DEPLOY}（须在 helm 之后，避免被覆盖）"
export NS="${NS:-platform}"
export DEPLOY="${DEPLOY:-diting-copilot}"
python3 << 'PY'
import json
import os
import subprocess

ns = os.environ.get("NS", "platform")
dep = os.environ.get("DEPLOY", "diting-copilot")
cm = "copilot-radar-hotfix"
mounts = [
    ("symbol_resolve.py", "/app/apps/copilot/modules/radar/symbol_resolve.py"),
    ("scanner.py", "/app/apps/copilot/modules/radar/scanner.py"),
    ("t0_cache.py", "/app/apps/copilot/modules/radar/t0_cache.py"),
    ("t2_resolve.py", "/app/apps/copilot/modules/radar/t2_resolve.py"),
    ("display_layout.py", "/app/apps/copilot/modules/radar/display_layout.py"),
    ("workbench_prefs.py", "/app/apps/copilot/modules/radar/workbench_prefs.py"),
    ("persistence.py", "/app/apps/copilot/modules/radar/persistence.py"),
    ("pipeline.py", "/app/apps/copilot/modules/radar/pipeline.py"),
    ("funnel.py", "/app/apps/copilot/modules/planning/funnel.py"),
    ("ai_dispatcher.py", "/app/apps/common/ai_dispatcher.py"),
    ("database.py", "/app/apps/copilot/db/database.py"),
    ("migrate_step19.py", "/app/apps/copilot/db/migrate_step19.py"),
    ("models.py", "/app/apps/copilot/db/models.py"),
    ("service.py", "/app/apps/copilot/modules/radar/service.py"),
    ("audit_render.py", "/app/apps/copilot/modules/radar/audit_render.py"),
    ("chat.py", "/app/apps/copilot/modules/radar/chat.py"),
    ("planning_routes.py", "/app/apps/copilot/routers/planning_routes.py"),
    ("workbench.html", "/app/apps/copilot/templates/planning/workbench.html"),
]
kube = os.environ.get("KUBECONFIG", "")
cmd = ["kubectl", "get", "deployment", dep, "-n", ns, "-o", "json"]
if kube:
    env = {**os.environ, "KUBECONFIG": kube}
else:
    env = os.environ.copy()
raw = subprocess.check_output(cmd, env=env)
dep_obj = json.loads(raw)
spec = dep_obj["spec"]["template"]["spec"]
vols = spec.setdefault("volumes", [])
if not any(v.get("name") == "radar-hotfix" for v in vols):
    vols.append({"name": "radar-hotfix", "configMap": {"name": cm}})
c = spec["containers"][0]
existing = {m["mountPath"]: m for m in c.setdefault("volumeMounts", [])}
for key, mpath in mounts:
    existing[mpath] = {
        "name": "radar-hotfix",
        "mountPath": mpath,
        "subPath": key,
    }
c["volumeMounts"] = list(existing.values())
proc = subprocess.run(
    ["kubectl", "apply", "-f", "-"],
    input=json.dumps(dep_obj).encode(),
    env=env,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
if proc.returncode != 0:
    raise SystemExit(proc.stderr.decode() or f"kubectl apply failed {proc.returncode}")
print("✅ volumeMounts 已更新（%d 个热修路径，保留既有 PVC/Secret 挂载）" % len(mounts))
PY
kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=180s

if [ "${SKIP_RADAR_SYNC:-}" != "1" ]; then
  if [ -d "${RADAR_T0_CACHE_DIR:-$SRC/data/cache/radar_t0}" ]; then
    bash "$SCRIPT_DIR/radar-t0-sync-to-prod.sh"
  else
    echo "ℹ️  跳过 radar-t0-sync（本地缓存目录不存在）"
  fi
fi

echo "▶ [radar-audit-hotfix] 验收"
kubectl exec -n "$NS" "deployment/$DEPLOY" -- python3 -c "
import json, os, urllib.request
h = float(os.getenv('RADAR_T0_CACHE_MAX_AGE_HOURS','0'))
d = float(os.getenv('RADAR_T0_RETENTION_DAYS','0'))
assert h >= 168, f'RADAR_T0_CACHE_MAX_AGE_HOURS={h}'
assert d >= 7, f'RADAR_T0_RETENTION_DAYS={d}'
r = urllib.request.urlopen('http://127.0.0.1:8080/api/radar/audit/601138/versions', timeout=30)
body = json.loads(r.read())
print('audit_versions', len(body.get('versions') or []), 'retention_days', body.get('retention_days'))
assert 'versions' in body
"
kubectl exec -n "$NS" "deployment/$DEPLOY" -- python3 -c "
import json, urllib.parse, urllib.request
data=urllib.parse.urlencode({'input_type':'symbol','query_text':'601138','enable_t2':'true'}).encode()
req=urllib.request.Request('http://127.0.0.1:8080/api/radar/scans',data=data,method='POST')
d=json.loads(urllib.request.urlopen(req,timeout=180).read())
c=d['candidates'][0]
s=c.get('t2_status')
dims=(c.get('deep_analysis') or {}).get('dimensions') or {}
print('modec t2_status=',s,'dims=',len(dims),'cache_version=',(d.get('summary_json') or {}).get('cache_version_id'))
assert s=='ok' and len(dims)==9
"
echo "✅ [radar-audit-hotfix] 生产生效：7 天缓存 · 审计 API · 模式 C 扫描"
