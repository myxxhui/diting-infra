#!/bin/sh
# Schema init 执行脚本：按顺序对 TimescaleDB 与 L2 PostgreSQL 执行 schemas/sql 下建表脚本
# 要求环境变量：TIMESCALE_DSN、PG_L2_DSN（由 K8s Secret 注入）
set -e
if [ -z "$TIMESCALE_DSN" ] || [ -z "$PG_L2_DSN" ]; then
  echo "Missing TIMESCALE_DSN or PG_L2_DSN"
  exit 1
fi

# 等待 L1/L2 可连接再建表（部署后 DB 可能尚未就绪）
wait_for_db() {
  _dsn="$1"
  _name="$2"
  _n=0
  _max=40
  while [ $_n -lt $_max ]; do
    if psql "$_dsn" -c "SELECT 1" >/dev/null 2>&1; then
      echo "$_name 已就绪"
      return 0
    fi
    _n=$((_n + 1))
    echo "等待 $_name 可连接... ($_n/$_max)"
    sleep 3
  done
  echo "错误: $_name 在 120s 内不可用"
  return 1
}
wait_for_db "$TIMESCALE_DSN" "TimescaleDB"
wait_for_db "$PG_L2_DSN" "PostgreSQL L2"

echo "Running 01_l1_ohlcv.sql on TimescaleDB..."
psql "$TIMESCALE_DSN" -v ON_ERROR_STOP=1 -f /sql/01_l1_ohlcv.sql
echo "Running 02_l1_a_share_universe.sql on TimescaleDB..."
psql "$TIMESCALE_DSN" -v ON_ERROR_STOP=1 -f /sql/02_l1_a_share_universe.sql
echo "Running 02_a_share_universe_add_market.sql (migration, no-op if columns exist)..."
psql "$TIMESCALE_DSN" -v ON_ERROR_STOP=1 -f /sql/02_a_share_universe_add_market.sql
echo "Running 02_l2_data_versions.sql on L2 PostgreSQL..."
psql "$PG_L2_DSN" -v ON_ERROR_STOP=1 -f /sql/02_l2_data_versions.sql
echo "Running 03_l2_industry_revenue_summary.sql on L2 PostgreSQL..."
psql "$PG_L2_DSN" -v ON_ERROR_STOP=1 -f /sql/03_l2_industry_revenue_summary.sql
echo "Schema init done."
