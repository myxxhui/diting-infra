#!/usr/bin/env bash
# 从 diting-src/.env 读取 ANTHROPIC_API_KEY / RADAR_T2_ENABLED（+ SMTP）并 helm upgrade copilot
# 用途：行情雷达模式 C 深度研报需 pod 内可调 Opus（T2 必开）；密钥不入库，部署时从本地 .env 注入。
# [Ref: step_14 模式 C · 25_ §2 · 系统规则 §7.2 第 13 条 .env 注入]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_ENV="${SRC_ENV:-$INFRA_ROOT/../diting-src/.env}"
CFG="${CONFIG_ROOT:-$INFRA_ROOT/config}/diting-prod.yaml"
STACK_NS="$(yq eval '.stack.namespace // "platform"' "$CFG")"

[ -f "$SRC_ENV" ] || { echo "错误: 缺少 $SRC_ENV"; exit 1; }
set -a && source "$SRC_ENV" && set +a
[ -n "${ANTHROPIC_API_KEY:-}" ] \
  || { echo "错误: $SRC_ENV 缺 ANTHROPIC_API_KEY（模式 C T2 Opus 必需）"; exit 1; }

_COPILOT_TAG="${COPILOT_IMAGE_TAG:-$(yq eval '.stack.copilot.image.tag // "latest"' "$CFG")}"
_PG_ENABLED="$(yq eval '.stack.copilot.postgres.enabled // false' "$CFG")"
_PG_PERSIST="$(yq eval '.stack.copilot.persistence.enabled // false' "$CFG")"
TMP="$(mktemp)"
yq eval '{"storage": .stack.storage, "schemaInit": .stack.schemaInit, "module_a": .stack.module_a, "ingest": .stack.ingest, "copilot": .stack.copilot}' "$CFG" > "$TMP"
yq eval -i "
  .ingest.timescaleHost = \"timescaledb-postgresql.${STACK_NS}.svc.cluster.local\" |
  .ingest.postgresL2Host = \"postgresql-l2.${STACK_NS}.svc.cluster.local\" |
  .module_a.timescaleHost = \"timescaledb-postgresql.${STACK_NS}.svc.cluster.local\" |
  .module_a.postgresL2Host = \"postgresql-l2.${STACK_NS}.svc.cluster.local\" |
  .storage.timescaledb.pvc.namespace = \"${STACK_NS}\" |
  .storage.postgresL2.pvc.namespace = \"${STACK_NS}\" |
  .copilot.redisHost = \"redis-master.${STACK_NS}.svc.cluster.local\" |
  .copilot.redisPort = \"6379\" |
  .copilot.redisDb = \"0\" |
  .copilot.ai.radarT2Enabled = \"${RADAR_T2_ENABLED:-true}\" |
  .copilot.ai.lighthouseModel = \"${LIGHTHOUSE_REMOTE_MODEL:-claude-opus-4-6}\" |
  .copilot.ai.anthropicModel = \"${ANTHROPIC_MODEL:-claude-opus-4-6}\" |
  .copilot.ai.anthropicBaseUrl = \"${ANTHROPIC_BASE_URL:-https://api.anthropic.com}\" |
  .copilot.ai.anthropicApiKey = \"${ANTHROPIC_API_KEY}\" |
  .copilot.ai.deepseekApiKey = \"${DEEPSEEK_API_KEY:-}\" |
  .copilot.ai.deepseekBaseUrl = \"${DEEPSEEK_BASE_URL:-https://api.deepseek.com}\" |
  .copilot.ai.deepseekModel = \"${DEEPSEEK_MODEL:-deepseek-chat}\" |
  .copilot.ai.radarT1Mode = \"${RADAR_T1_MODE:-auto}\" |
  .copilot.radarT0CacheMaxAgeHours = \"${RADAR_T0_CACHE_MAX_AGE_HOURS:-24}\" |
  .copilot.radarT0RetentionDays = \"${RADAR_T0_RETENTION_DAYS:-1}\" |
  .copilot.radarFileRetentionHours = \"${RADAR_FILE_RETENTION_HOURS:-24}\" |
  .copilot.radarDbRetentionDays = \"${RADAR_DB_RETENTION_DAYS:-30}\" |
  .copilot.radarDbMaxVersions = \"${RADAR_DB_MAX_VERSIONS:-7}\" |
  .copilot.radarRecentAnalysisDays = \"${RADAR_RECENT_ANALYSIS_DAYS:-7}\" |
  .copilot.radarChatDefaultModel = \"${RADAR_CHAT_DEFAULT_MODEL:-claude-opus-4-6}\" |
  .copilot.image.tag = \"${_COPILOT_TAG}\" |
  .copilot.postgres.enabled = ${_PG_ENABLED} |
  .copilot.persistence.enabled = ${_PG_PERSIST}
" "$TMP"

# 若 .env 提供出口代理则注入（HK ECS 同时打通东财(T0) 与 Anthropic(T2)）
if [ -n "${HTTPS_PROXY:-}" ]; then
  yq eval -i "
    .copilot.ai.httpsProxy = \"${HTTPS_PROXY}\" |
    .copilot.ai.httpProxy = \"${HTTP_PROXY:-$HTTPS_PROXY}\" |
    .copilot.ai.noProxy = \"${NO_PROXY:-localhost,127.0.0.1,.svc,.svc.cluster.local,.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}\"
  " "$TMP"
  echo "ℹ️  已注入出口代理 HTTPS_PROXY=${HTTPS_PROXY}"
fi

# 若 .env 提供 SMTP 则一并保留（与 copilot-sync-smtp 同源，避免覆盖丢失）
if [ -n "${COPILOT_SMTP_USERNAME:-}" ] && [ -n "${COPILOT_SMTP_PASSWORD:-}" ]; then
  yq eval -i "
    .copilot.smtp.enabled = true |
    .copilot.smtp.host = \"${COPILOT_SMTP_HOST:-smtp.126.com}\" |
    .copilot.smtp.port = \"${COPILOT_SMTP_PORT:-465}\" |
    .copilot.smtp.useSsl = \"${COPILOT_SMTP_USE_SSL:-true}\" |
    .copilot.smtp.username = \"${COPILOT_SMTP_USERNAME}\" |
    .copilot.smtp.password = \"${COPILOT_SMTP_PASSWORD}\" |
    .copilot.smtp.from = \"${COPILOT_SMTP_FROM:-$COPILOT_SMTP_USERNAME}\" |
    .copilot.smtp.to = \"${COPILOT_SMTP_TO:-$COPILOT_SMTP_USERNAME}\"
  " "$TMP"
fi

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
helm upgrade diting-stack "$INFRA_ROOT/charts/diting-stack" -n "$STACK_NS" -f "$TMP" --wait --timeout=5m
rm -f "$TMP"
kubectl rollout status deployment/diting-copilot -n "$STACK_NS" --timeout=120s
echo "✅ Copilot AI(Opus) env 已注入 · RADAR_T2_ENABLED=${RADAR_T2_ENABLED:-true} · namespace=$STACK_NS"
