#!/usr/bin/env bash
# make deploy diting prod 收尾：部署总结与业务访问地址
# 用法: prod-deploy-summary.sh <CONFIG_ROOT> <CONN_FILE> <PROJECT> <ENV>
set -euo pipefail

CONFIG_ROOT="${1:-$(pwd)/config}"
CONN_FILE="${2:-prod.conn}"
PROJECT="${3:-diting}"
ENV="${4:-prod}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
case "$CONN_FILE" in /*) ;; *) CONN_FILE="$INFRA_ROOT/$CONN_FILE" ;; esac
CFG="$CONFIG_ROOT/${PROJECT}-${ENV}.yaml"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-${PROJECT}-${ENV}}"

command -v yq >/dev/null 2>&1 || { echo "错误: 需要 yq"; exit 1; }

PUBLIC_IP="<EIP>"
TIMESCALE_DSN=""
PG_L2_DSN=""
REDIS_URL=""
if [ -f "$CONN_FILE" ]; then
  PUBLIC_IP="$(grep -E '^PUBLIC_IP=' "$CONN_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' ' || true)"
  TIMESCALE_DSN="$(grep -E '^TIMESCALE_DSN=' "$CONN_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  PG_L2_DSN="$(grep -E '^PG_L2_DSN=' "$CONN_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  REDIS_URL="$(grep -E '^REDIS_URL=' "$CONN_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
fi
[ -z "$PUBLIC_IP" ] && PUBLIC_IP="<EIP>"

STACK_NS="$(yq eval '.stack.namespace // "platform"' "$CFG" 2>/dev/null || echo platform)"
COPILOT_PORT="$(yq eval '.stack.copilot.service.nodePort // 30080' "$CFG" 2>/dev/null || echo 30080)"
PORT_L1="$(yq eval '(.stack.databases.timescaledb.service.nodePort // .ports.timescaledb) // 30001' "$CFG" 2>/dev/null || echo 30001)"
PORT_L2="$(yq eval '(.stack.databases.postgres_l2.service.nodePort // .ports.postgres_l2) // 30002' "$CFG" 2>/dev/null || echo 30002)"
REDIS_VALUES="$CONFIG_ROOT/redis-values-${PROJECT}-${ENV}.yaml"
[ -f "$REDIS_VALUES" ] || REDIS_VALUES="$CONFIG_ROOT/redis-values-prod.yaml"
if [ -f "$REDIS_VALUES" ]; then
  PORT_REDIS="$(yq eval '.master.service.nodePorts.redis // "30379"' "$REDIS_VALUES" 2>/dev/null || echo 30379)"
else
  PORT_REDIS="30379"
fi

INGEST_ENABLED="$(yq eval '.data_ingestion.enabled // false' "$CFG" 2>/dev/null || echo false)"
PROXY_ENABLED="$(yq eval '.anthropic_proxy.enabled // false' "$CFG" 2>/dev/null || echo false)"

POD_RUNNING=""
POD_TOTAL=""
INGEST_JOB=""
if command -v kubectl >/dev/null 2>&1 && [ -f "$KUBECONFIG" ]; then
  POD_TOTAL="$(kubectl --kubeconfig="$KUBECONFIG" get pods -n "$STACK_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  POD_RUNNING="$(kubectl --kubeconfig="$KUBECONFIG" get pods -n "$STACK_NS" --no-headers 2>/dev/null | awk '$3=="Running" || $3=="Completed" {c++} END{print c+0}')"
  INGEST_JOB="$(kubectl --kubeconfig="$KUBECONFIG" get jobs -n "$STACK_NS" -l component=ingest \
    --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)"
fi

PROXY_LINE=""
if [ "$PROXY_ENABLED" = "true" ] && [ -f "$INFRA_ROOT/sg-proxy.conn" ]; then
  # shellcheck source=/dev/null
  source "$INFRA_ROOT/sg-proxy.conn" 2>/dev/null || true
  _ph="${ANTHROPIC_PROXY_HOST:-${SG_PROXY_PUBLIC_IP:-}}"
  _pp="${ANTHROPIC_PROXY_PORT:-${SG_PROXY_PORT:-3128}}"
  [ -n "$_ph" ] && PROXY_LINE="http://${_ph}:${_pp} (Anthropic 专用代理)"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              diting-prod 部署总结 · ${PROJECT}/${ENV}              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "【集群】"
echo "  公网 IP        : ${PUBLIC_IP}"
echo "  K3s API        : https://${PUBLIC_IP}:6443"
echo "  Kubeconfig     : ${KUBECONFIG}"
echo "  Context        : ${PROJECT}-${ENV}"
echo "  命名空间       : ${STACK_NS}"
if [ -n "$POD_TOTAL" ] && [ "$POD_TOTAL" != "0" ]; then
  echo "  Pod 状态       : ${POD_RUNNING}/${POD_TOTAL} Running/Completed（其余由 K8s 拉起中）"
fi
echo ""
echo "【业务访问 · NodePort（集群外）】"
echo "  Copilot HTTP   : http://${PUBLIC_IP}:${COPILOT_PORT}"
echo "  TimescaleDB L1 : ${PUBLIC_IP}:${PORT_L1}  (db=postgres)"
echo "  PostgreSQL L2  : ${PUBLIC_IP}:${PORT_L2}  (db=diting_l2, diting_copilot)"
echo "  Redis          : ${PUBLIC_IP}:${PORT_REDIS}  (db/0)"
echo ""
echo "【连接串 · 已写入 ${CONN_FILE}】"
[ -n "$TIMESCALE_DSN" ] && echo "  TIMESCALE_DSN  : ${TIMESCALE_DSN}"
[ -n "$PG_L2_DSN" ] && echo "  PG_L2_DSN      : ${PG_L2_DSN}"
[ -n "$REDIS_URL" ] && echo "  REDIS_URL      : ${REDIS_URL}"
echo ""
if [ "$INGEST_ENABLED" = "true" ]; then
  echo "【数据采集】"
  if [ -n "$INGEST_JOB" ]; then
    echo "  最近 ingest Job: ${INGEST_JOB}（异步 · 不阻塞部署）"
    echo "  查看进度       : kubectl logs job/${INGEST_JOB} -n ${STACK_NS} -f"
  else
    echo "  ingest Job     : 已触发或待创建（kubectl get jobs -n ${STACK_NS} -l component=ingest）"
  fi
  echo ""
fi
if [ -n "$PROXY_LINE" ]; then
  echo "【新加坡 Anthropic 代理】"
  echo "  ${PROXY_LINE}"
  echo ""
fi
echo "【常用验收】"
echo "  kubectl --kubeconfig=${KUBECONFIG} get pods -n ${STACK_NS}"
echo "  kubectl --kubeconfig=${KUBECONFIG} get jobs -n ${STACK_NS}"
echo "  curl -s -o /dev/null -w '%{http_code}' http://${PUBLIC_IP}:${COPILOT_PORT}/health || true"
echo ""
echo "【说明】"
echo "  make Entering/Leaving 为子 make 递归日志，已默认抑制；业务 Pod/CronJob 由 K8s 异步监管。"
echo ""
