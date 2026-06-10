#!/usr/bin/env bash
# 29_ 三大底座 · 中间件部署验收（Redis / ARQ Worker / OpenSearch / Cron enqueue）
# 工作目录: diting-infra
# [Ref: 29_ §9]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CFG="${CONFIG_ROOT:-$INFRA_ROOT/config}/diting-prod.yaml"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
NS="$(yq eval '.stack.namespace // "platform"' "$CFG")"
COPILOT_PORT="$(yq eval '.stack.copilot.service.nodePort // 30080' "$CFG")"
OS_PORT="$(yq eval '.stack.opensearch.service.nodePort // 30200' "$CFG")"
REDIS_NODEPORT="$(yq eval '.ports.redis // 30379' "$CFG" 2>/dev/null || echo 30379)"

FAIL=0
_pass() { echo "  ✅ $1"; }
_fail() { echo "  ❌ $1"; FAIL=1; }
_warn() { echo "  ⚠️  $1"; }

echo "=== 29_ 基础设施中间件验收 · namespace=${NS} ==="

echo ""
echo "[1/8] K3s 核心 Pod（Redis / PostgreSQL / TimescaleDB）"
if kubectl -n "$NS" get pods -l "app.kubernetes.io/name=redis" 2>/dev/null | grep -q Running; then
  _pass "Redis → Running"
else
  _fail "Redis 未 Running"
fi
if kubectl -n "$NS" get pods -l "app.kubernetes.io/name=postgresql" 2>/dev/null | grep -q Running; then
  _pass "PostgreSQL L2 → Running"
else
  _fail "PostgreSQL L2 未 Running"
fi
if kubectl -n "$NS" get pods 2>/dev/null | grep -E 'timescaledb-postgresql|timescale' | grep -q Running; then
  _pass "TimescaleDB L1 → Running"
else
  _fail "TimescaleDB L1 未 Running"
fi

echo ""
echo "[2/8] OpenSearch Deployment"
if [ "$(yq eval '.stack.opensearch.enabled // false' "$CFG")" = "true" ]; then
  if kubectl -n "$NS" get deploy diting-opensearch >/dev/null 2>&1; then
    ready="$(kubectl -n "$NS" get deploy diting-opensearch -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo 0/0)"
    if [[ "$ready" == "1/1" ]] || [[ "$ready" == */1 ]]; then
      _pass "diting-opensearch ready=${ready}"
    else
      _fail "diting-opensearch ready=${ready}"
    fi
  else
    _fail "diting-opensearch Deployment 不存在"
  fi
else
  _warn "stack.opensearch.enabled=false · 跳过"
fi

echo ""
echo "[3/8] ARQ Worker Deployment"
if [ "$(yq eval '.stack.copilot.arqWorker.enabled // false' "$CFG")" = "true" ]; then
  if kubectl -n "$NS" get deploy diting-copilot-arq-worker >/dev/null 2>&1; then
    ready="$(kubectl -n "$NS" get deploy diting-copilot-arq-worker -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo 0/0)"
    if [[ "$ready" == "1/1" ]] || [[ "$ready" == */1 ]]; then
      _pass "diting-copilot-arq-worker ready=${ready}"
    else
      _fail "diting-copilot-arq-worker ready=${ready}"
    fi
  else
    _fail "diting-copilot-arq-worker Deployment 不存在"
  fi
else
  _warn "stack.copilot.arqWorker.enabled=false · 跳过"
fi

echo ""
echo "[4/8] Copilot /health"
COPILOT_POD="$(kubectl -n "$NS" get pods -l component=copilot -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | awk '{print $1}')"
WORKER_POD="$(kubectl -n "$NS" get pods -l component=copilot-arq-worker -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | awk '{print $1}')"
if [ -n "$COPILOT_POD" ]; then
  code="$(kubectl -n "$NS" exec "$COPILOT_POD" -- python -c "import urllib.request; r=urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=5); print(r.status)" 2>/dev/null || echo 000)"
  if [ "$code" = "200" ]; then
    _pass "Copilot /health → 200 (pod=${COPILOT_POD})"
  else
    _fail "Copilot /health → ${code}"
  fi
else
  _fail "无 Running 的 Copilot Pod"
fi

echo ""
echo "[5/8] OpenSearch cluster health"
if [ "$(yq eval '.stack.opensearch.enabled // false' "$CFG")" = "true" ]; then
  CHECK_POD="${WORKER_POD:-$COPILOT_POD}"
  OS_SVC="$(yq eval '.stack.opensearch.serviceName // "opensearch"' "$CFG")"
  OS_PORT_IN="$(yq eval '.stack.opensearch.service.port // 9200' "$CFG")"
  if [ -n "$CHECK_POD" ]; then
    os_status="$(kubectl -n "$NS" exec "$CHECK_POD" -- python -c "
import json, urllib.request
r = urllib.request.urlopen('http://${OS_SVC}.${NS}.svc.cluster.local:${OS_PORT_IN}/_cluster/health', timeout=8)
print(json.load(r).get('status','error'))
" 2>/dev/null || echo error)"
    if [[ "$os_status" == "green" || "$os_status" == "yellow" ]]; then
      _pass "OpenSearch health → ${os_status} (via ${CHECK_POD})"
    else
      _fail "OpenSearch health → ${os_status}"
    fi
  else
    _fail "无 Pod 可用于 OpenSearch 集群内探测"
  fi
else
  _warn "stack.opensearch.enabled=false · 跳过"
fi

echo ""
echo "[6/8] Pod 内 ARQ --check"
if [ -n "$WORKER_POD" ]; then
  if kubectl -n "$NS" exec "$WORKER_POD" -- python -m apps.copilot.workers.arq_worker --check 2>&1 | tee /tmp/arq-check.log | grep -q "基础设施检查通过"; then
    _pass "ARQ Worker --check 通过 (pod=${WORKER_POD})"
  else
    _fail "ARQ Worker --check 失败 · 见 /tmp/arq-check.log"
  fi
else
  _warn "无 ARQ Worker Pod · 跳过 --check"
fi

echo ""
echo "[7/8] CronJob 调度边界（JL4 直跑 · l3- 前缀 enqueue）"
l4_cmd="$(kubectl -n "$NS" get cronjob executing-t0-quote-intraday -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].command}' 2>/dev/null || true)"
if echo "$l4_cmd" | grep -q '\-\-enqueue'; then
  _fail "JL4 CronJob quote-intraday 不应 --enqueue: ${l4_cmd}"
else
  _pass "JL4 CronJob quote-intraday 直跑（无 --enqueue）"
fi
# 未来 l3-* Cron 应 enqueue（当前可能尚未注册）
l3_cj="$(kubectl -n "$NS" get cronjob -l component=executing-t0 -o name 2>/dev/null | grep 'l3-' | head -1 || true)"
if [ -n "$l3_cj" ]; then
  l3_cmd="$(kubectl -n "$NS" get "$l3_cj" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].command}' 2>/dev/null || true)"
  if echo "$l3_cmd" | grep -q '\-\-enqueue'; then
    _pass "${l3_cj} 已 enqueue"
  else
    _fail "${l3_cj} 应为 enqueue 模式: ${l3_cmd}"
  fi
else
  _pass "尚无 l3-* CronJob（JL3 开发时按前缀 l3- 注册即可 enqueue）"
fi

echo ""
echo "[8/8] 数据盘持久化（PV Retain + hostPath 绑定）"
DATA_PATH="$(yq eval '.stack.storage.dataPath // "/mnt/titan-data/postgres"' "$CFG")"
for pv in timescaledb-data-pv postgresql-l2-data-pv diting-redis-data-pv diting-opensearch-data-pv diting-radar-t0-cache-pv diting-copilot-reports-pv; do
  policy="$(kubectl get pv "$pv" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null || echo missing)"
  if [ "$policy" = "Retain" ]; then
    _pass "PV ${pv} · Retain"
  else
    _fail "PV ${pv} · reclaim=${policy:-missing}"
  fi
done
# Redis AOF
if kubectl -n "$NS" exec redis-master-0 -- redis-cli CONFIG GET appendonly 2>/dev/null | grep -q yes; then
  _pass "Redis AOF appendonly=yes（队列/热状态可落盘）"
else
  _fail "Redis 未开启 AOF"
fi
echo "  ℹ️  数据根路径: ${DATA_PATH}（ECS 复挂 ESSD 后 PV hostPath 子目录保留）"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "=== ✅ 基础设施中间件验收通过 · 可开始 JL3 指标开发 ==="
  exit 0
else
  echo "=== ❌ 基础设施验收未通过 · 请先修复后再开发 JL3 ==="
  exit 1
fi
