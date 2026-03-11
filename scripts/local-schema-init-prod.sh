#!/usr/bin/env bash
# 本地一键建表：使用 prod.conn 中的连接信息，对生产环境 L1/L2 执行 Chart 内建表 SQL
# 用法: scripts/local-schema-init-prod.sh [prod.conn]
# 前置: 已执行 make deploy diting prod 并存在 prod.conn（或先 make prod-write-conn）
# [Ref: charts/diting-stack/schema-init/]

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONN_FILE="${1:-$REPO_ROOT/prod.conn}"
SQL_DIR="$REPO_ROOT/charts/diting-stack/schema-init/sql"
RUN_SCRIPT="$REPO_ROOT/charts/diting-stack/schema-init/run-schema-init.sh"

if [ ! -f "$CONN_FILE" ]; then
  echo "错误: 连接文件不存在: $CONN_FILE"
  echo "请先执行: make deploy diting prod 或 make prod-write-conn"
  exit 1
fi
if [ ! -f "$RUN_SCRIPT" ]; then
  echo "错误: 建表脚本不存在: $RUN_SCRIPT"
  exit 1
fi

# 从 prod.conn 读取 DSN（排除注释行），并确保含 sslmode=disable（外网连接）
export TIMESCALE_DSN
export PG_L2_DSN
TIMESCALE_DSN=$(grep -E '^TIMESCALE_DSN=' "$CONN_FILE" | sed 's/^TIMESCALE_DSN=//' | tr -d '\r')
PG_L2_DSN=$(grep -E '^PG_L2_DSN=' "$CONN_FILE" | sed 's/^PG_L2_DSN=//' | tr -d '\r')
case "$TIMESCALE_DSN" in
  *sslmode=*) ;;
  *) TIMESCALE_DSN="${TIMESCALE_DSN}?sslmode=disable";;
esac
case "$PG_L2_DSN" in
  *sslmode=*) ;;
  *) PG_L2_DSN="${PG_L2_DSN}?sslmode=disable";;
esac

if [ -z "$TIMESCALE_DSN" ] || [ -z "$PG_L2_DSN" ]; then
  echo "错误: prod.conn 中未找到 TIMESCALE_DSN 或 PG_L2_DSN"
  exit 1
fi

echo "使用 L1: ${TIMESCALE_DSN%%@*}@<EIP>:<port>/postgres"
echo "使用 L2: ${PG_L2_DSN%%@*}@<EIP>:<port>/diting_l2"
echo "执行建表（与 Chart Job 相同 SQL 顺序）..."
docker run --rm \
  -v "$SQL_DIR:/sql:ro" \
  -v "$RUN_SCRIPT:/run-schema-init.sh:ro" \
  -e TIMESCALE_DSN \
  -e PG_L2_DSN \
  --entrypoint /bin/sh \
  postgres:15-alpine \
  -c "sh /run-schema-init.sh"
echo "✅ 本地建表完成"
