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
# 勿用 TMP：make「export」可能注入同名环境变量；trap 清理避免 rm 被遮蔽时误执行 values 文件（exit 126）
_VALUES_FILE="$(mktemp)"
trap '/usr/bin/rm -f "$_VALUES_FILE"' EXIT INT TERM
CHART_VALUES="$INFRA_ROOT/charts/diting-stack/values.yaml"
yq eval '{"storage": .stack.storage, "schemaInit": .stack.schemaInit, "module_a": .stack.module_a, "ingest": .stack.ingest, "copilot": .stack.copilot}' "$CFG" > "$_VALUES_FILE"
# radarT0Jobs：prod 可覆盖 enabled/bootstrapHook；cron 表默认来自 chart values.yaml
yq eval -i '
  .copilot.radarT0Jobs = (
    (load("'"$CHART_VALUES"'").copilot.radarT0Jobs // {}) *
    (.copilot.radarT0Jobs // {})
  )
' "$_VALUES_FILE"
yq eval -i '
  .copilot.executingT0Jobs = (
    (load("'"$CHART_VALUES"'").copilot.executingT0Jobs // {}) *
    (.copilot.executingT0Jobs // {})
  )
' "$_VALUES_FILE"
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
  .copilot.ai.executingT2Enabled = \"${EXECUTING_T2_ENABLED:-${RADAR_T2_ENABLED:-true}}\" |
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
" "$_VALUES_FILE"

# 仅 Opus/Anthropic 走新加坡代理（勿注入进程级 HTTPS_PROXY，避免 akshare/DeepSeek 误走代理）
_ANTH_PROXY="${ANTHROPIC_HTTPS_PROXY:-${HTTPS_PROXY:-}}"
if [ -n "$_ANTH_PROXY" ]; then
  yq eval -i ".copilot.ai.anthropicHttpsProxy = \"${_ANTH_PROXY}\"" "$_VALUES_FILE"
  echo "ℹ️  已注入 Anthropic 专用代理 ANTHROPIC_HTTPS_PROXY（Pod 不设 HTTPS_PROXY）"
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
  " "$_VALUES_FILE"
fi

# prod 专用：默认 diting-prod kubeconfig，避免误用 ~/.kube/config 中过期 API（如旧 EIP 47.239.91.106）
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
# 集群 API 不得走出口代理（仅 Pod 内 Anthropic 客户端读 ANTHROPIC_HTTPS_PROXY）
env -u HTTPS_PROXY -u HTTP_PROXY helm upgrade diting-stack "$INFRA_ROOT/charts/diting-stack" -n "$STACK_NS" -f "$_VALUES_FILE" --timeout=10m --no-hooks
trap - EXIT INT TERM
/usr/bin/rm -f "$_VALUES_FILE"
# Helm 升级 Secret 不会删除已废弃的 data 键，显式移除进程级 HTTPS_PROXY/HTTP_PROXY
for _stale in HTTPS_PROXY HTTP_PROXY NO_PROXY; do
  env -u HTTPS_PROXY -u HTTP_PROXY kubectl patch secret diting-copilot-conn -n "$STACK_NS" \
    --type=json -p="[{\"op\":\"remove\",\"path\":\"/data/${_stale}\"}]" 2>/dev/null || true
done
env -u HTTPS_PROXY -u HTTP_PROXY kubectl rollout restart deployment/diting-copilot -n "$STACK_NS" 2>/dev/null || true
echo "✅ Copilot AI(Opus) env 已提交（业务第二梯队 · 不等待 Pod Ready）· RADAR_T2_ENABLED=${RADAR_T2_ENABLED:-true} · namespace=$STACK_NS"
