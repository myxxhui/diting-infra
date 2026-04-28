#!/usr/bin/env bash
# 部署采集 Job：仅调用 Helm（charts/ingest）；Secret 由 make prod-sync-conn-secret 提供，schema-init 由 Chart 的 pre-install hook 自动执行。
# 用法: prod-apply-ingest-job.sh <CONFIG_ROOT> <CONN_FILE> <PROJECT> <ENV> [wait]
# [Ref: 06_生产级数据要求_实践]
set -e
CONFIG_ROOT="${1:-$(pwd)/config}"
CONN_FILE="${2:-prod.conn}"
PROJECT="${3:-diting}"
ENV="${4:-prod}"
WAIT_FOR_JOB="${5:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHARTS_INGEST="${INFRA_ROOT}/charts/ingest"
CFG="${CONFIG_ROOT}/${PROJECT}-${ENV}.yaml"
KUBECONFIG_PATH="${HOME}/.kube/config-${PROJECT}-${ENV}"
export KUBECONFIG="${KUBECONFIG_PATH}"

if [ ! -f "$CFG" ]; then
  echo "错误: 配置文件不存在 $CFG"
  exit 1
fi
if [ ! -f "$CONN_FILE" ]; then
  echo "错误: 连接文件不存在 $CONN_FILE，请先执行 make deploy diting prod 或 make prod-write-conn"
  exit 1
fi
if [ ! -d "$CHARTS_INGEST" ]; then
  echo "错误: Chart 不存在 $CHARTS_INGEST"
  exit 1
fi

USE_JOB=$(command -v yq >/dev/null 2>&1 && yq eval '.data_ingestion.use_k3s_job // true' "$CFG" || echo "true")
if [ "$USE_JOB" != "true" ]; then
  echo "data_ingestion.use_k3s_job 未启用，跳过 K3s Job 采集"
  exit 0
fi

# 支持环境变量覆盖，便于使用已推送到 registry 的镜像（如 INGEST_IMAGE=registry.cn-hongkong.aliyuncs.com/ns/diting-ingest:test）
INGEST_IMAGE="${INGEST_IMAGE:-$(command -v yq >/dev/null 2>&1 && yq eval '.data_ingestion.image // "diting-ingest:test"' "$CFG" || echo "diting-ingest:test")}"
INGEST_TARGET="${INGEST_TARGET:-$(command -v yq >/dev/null 2>&1 && yq eval '.data_ingestion.target // "ingest-test-real"' "$CFG" || echo "ingest-test-real")}"

RUN_ID="${RUN_ID:-$(date +%s)}"
echo "部署采集 Job（Helm Chart，含 pre-install schema-init）: image=$INGEST_IMAGE, makeTarget=$INGEST_TARGET, runId=$RUN_ID"
helm upgrade --install diting-ingest "$CHARTS_INGEST" -n default \
  --set image="$INGEST_IMAGE" \
  --set makeTarget="$INGEST_TARGET" \
  --set runId="$RUN_ID"

JOB_NAME="diting-ingest-${RUN_ID}"
if [ "$WAIT_FOR_JOB" = "wait" ]; then
  echo "等待 Job $JOB_NAME 完成..."
  if kubectl wait --for=condition=complete "job/$JOB_NAME" -n default --timeout=3600s 2>/dev/null; then
    echo "✅ 采集 Job 已完成"
  else
    echo "⚠️ Job 未在超时内完成，请检查: kubectl logs job/$JOB_NAME -n default -f"
    exit 1
  fi
else
  echo "Job 已提交: $JOB_NAME；查看: kubectl get jobs -n default; 日志: kubectl logs job/$JOB_NAME -n default -f"
fi
