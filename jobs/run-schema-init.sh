#!/bin/sh
# Schema init 执行脚本：按顺序对 TimescaleDB 与 L2 PostgreSQL 执行 schemas/sql 下建表脚本
# 要求环境变量：TIMESCALE_DSN、PG_L2_DSN（由 K8s Secret 注入）
set -e
if [ -z "$TIMESCALE_DSN" ] || [ -z "$PG_L2_DSN" ]; then
  echo "Missing TIMESCALE_DSN or PG_L2_DSN"
  exit 1
fi
echo "Running 01_l1_ohlcv.sql on TimescaleDB..."
psql "$TIMESCALE_DSN" -v ON_ERROR_STOP=1 -f /sql/01_l1_ohlcv.sql
echo "Running 02_l2_data_versions.sql on L2 PostgreSQL..."
psql "$PG_L2_DSN" -v ON_ERROR_STOP=1 -f /sql/02_l2_data_versions.sql
echo "Running 03_l2_industry_revenue_summary.sql on L2 PostgreSQL..."
psql "$PG_L2_DSN" -v ON_ERROR_STOP=1 -f /sql/03_l2_industry_revenue_summary.sql
echo "Schema init done."
