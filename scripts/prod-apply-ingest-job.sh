#!/usr/bin/env bash
# 部署采集 Job：helm upgrade diting-stack（ingest.enabled=true），非独立 charts/ingest。
# Secret 由 make prod-sync-conn-secret 提供；schema-init 已在 platform-step03 完成。
# 用法: prod-apply-ingest-job.sh <CONFIG_ROOT> <CONN_FILE> <PROJECT> <ENV> [wait]
# [Ref: docs/ingest-cloud-native.md · charts/diting-stack/templates/ingest/]
set -euo pipefail
CONFIG_ROOT="${1:-$(pwd)/config}"
CONN_FILE="${2:-prod.conn}"
PROJECT="${3:-diting}"
ENV="${4:-prod}"
WAIT_FOR_JOB="${5:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHART_STACK="${INFRA_ROOT}/charts/diting-stack"
CFG="${CONFIG_ROOT}/${PROJECT}-${ENV}.yaml"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-${PROJECT}-${ENV}}"

if [ ! -f "$CFG" ]; then
  echo "错误: 配置文件不存在 $CFG"
  exit 1
fi
if [ ! -f "$CONN_FILE" ]; then
  echo "错误: 连接文件不存在 $CONN_FILE，请先执行 make deploy diting prod 或 make prod-write-conn"
  exit 1
fi
if [ ! -f "$CHART_STACK/Chart.yaml" ]; then
  echo "错误: Chart 不存在 $CHART_STACK/Chart.yaml"
  exit 1
fi

USE_JOB=$(command -v yq >/dev/null 2>&1 && yq eval '.data_ingestion.use_k3s_job // true' "$CFG" || echo "true")
if [ "$USE_JOB" != "true" ]; then
  echo "data_ingestion.use_k3s_job 未启用，跳过 K3s Job 采集"
  exit 0
fi

STACK_NS=$(command -v yq >/dev/null 2>&1 && yq eval '.stack.namespace // "platform"' "$CFG" || echo "platform")
RUN_ID="${RUN_ID:-$(date +%s)}"

# 镜像：环境变量 > data_ingestion.image > stack.ingest 仓库:tag
_default_img() {
  if command -v yq >/dev/null 2>&1; then
    local di
    di=$(yq eval '.data_ingestion.image // ""' "$CFG" 2>/dev/null || true)
    if [ -n "$di" ] && [ "$di" != "null" ]; then
      echo "$di"
      return
    fi
    local repo tag
    repo=$(yq eval '.stack.ingest.image.repository // "diting-ingest"' "$CFG")
    tag=$(yq eval '.stack.ingest.image.tag // "test"' "$CFG")
    echo "${repo}:${tag}"
    return
  fi
  echo "diting-ingest:test"
}
INGEST_IMAGE="${INGEST_IMAGE:-$(_default_img)}"
if [[ "$INGEST_IMAGE" == *:* ]]; then
  INGEST_REPO="${INGEST_IMAGE%%:*}"
  INGEST_TAG="${INGEST_IMAGE#*:}"
else
  INGEST_REPO="$INGEST_IMAGE"
  INGEST_TAG="test"
fi

INGEST_TARGET="${INGEST_TARGET:-$(command -v yq >/dev/null 2>&1 && yq eval '.data_ingestion.target // "ingest-test-real"' "$CFG" || echo "ingest-test-real")}"

echo "部署采集 Job（diting-stack · ingest.enabled=true）: image=${INGEST_REPO}:${INGEST_TAG}, target=${INGEST_TARGET}, ns=${STACK_NS}, runId=${RUN_ID}"

# 解除上次 helm --wait 中断留下的 pending-upgrade 锁
_stack_status=$(helm status diting-stack -n "$STACK_NS" -o json 2>/dev/null | \
  python3 -c "import json,sys; print(json.load(sys.stdin).get('info',{}).get('status',''))" 2>/dev/null || true)
if [ "$_stack_status" = "pending-upgrade" ] || [ "$_stack_status" = "pending-install" ] || [ "$_stack_status" = "pending-rollback" ]; then
  echo "⚠️  diting-stack 处于 $_stack_status，先 rollback --no-hooks 解锁…"
  _last_ok=$(helm history diting-stack -n "$STACK_NS" -o json 2>/dev/null | python3 -c "
import json,sys
revs=json.load(sys.stdin)
ok=[r['revision'] for r in revs if r.get('status')=='deployed']
print(ok[-1] if ok else '')
" 2>/dev/null || true)
  if [ -n "$_last_ok" ]; then
    helm rollback diting-stack "$_last_ok" -n "$STACK_NS" --no-hooks
  else
    echo "错误: 无 deployed 修订可回滚，请手动: helm history diting-stack -n $STACK_NS"
    exit 1
  fi
fi

TMP_VALUES="$(mktemp)"
trap 'rm -f "$TMP_VALUES"' EXIT
yq eval '{"storage": .stack.storage, "schemaInit": .stack.schemaInit, "module_a": .stack.module_a, "ingest": .stack.ingest, "copilot": (.stack.copilot // {})}' "$CFG" > "$TMP_VALUES"
yq eval -i "
  .ingest.enabled = true |
  .ingest.triggerRunAt = \"${RUN_ID}\" |
  .ingest.image.repository = \"${INGEST_REPO}\" |
  .ingest.image.tag = \"${INGEST_TAG}\" |
  .ingest.timescaleHost = \"timescaledb-postgresql.${STACK_NS}.svc.cluster.local\" |
  .ingest.postgresL2Host = \"postgresql-l2.${STACK_NS}.svc.cluster.local\" |
  .ingest.redisHost = \"redis-master.${STACK_NS}.svc.cluster.local\"
" "$TMP_VALUES"

# 勿 --wait：会等 Copilot/schema-init 等全就绪，易超时并锁死 pending-upgrade；采集 Job 单独 kubectl wait
helm upgrade diting-stack "$CHART_STACK" -n "$STACK_NS" -f "$TMP_VALUES" --timeout=10m

# Job 名：diting-ingest-<revision>[-<triggerRunAt>]（见 templates/ingest/job.yaml）
JOB_NAME=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  JOB_NAME=$(kubectl get jobs -n "$STACK_NS" -l component=ingest \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)
  if [ -n "$JOB_NAME" ] && kubectl get job -n "$STACK_NS" "$JOB_NAME" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if [ -z "$JOB_NAME" ]; then
  echo "⚠️ 未找到 ingest Job（label component=ingest）；请检查: kubectl get jobs -n $STACK_NS"
  exit 1
fi

if [ "$WAIT_FOR_JOB" = "wait" ]; then
  echo "等待 Job $JOB_NAME 完成（集群内 make ingest-deploy）..."
  if kubectl wait --for=condition=complete "job/$JOB_NAME" -n "$STACK_NS" --timeout=3600s 2>/dev/null; then
    echo "✅ 采集 Job 已完成: $JOB_NAME"
  else
    echo "⚠️ Job 未在超时内完成，请检查: kubectl logs job/$JOB_NAME -n $STACK_NS -f"
    exit 1
  fi
else
  echo "Job 已提交: $JOB_NAME · 查看: kubectl get jobs -n $STACK_NS -l component=ingest"
  echo "日志: kubectl logs job/$JOB_NAME -n $STACK_NS -f"
fi
