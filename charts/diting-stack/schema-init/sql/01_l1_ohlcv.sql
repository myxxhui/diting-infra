-- L1 TimescaleDB：OHLCV 行情表（11_ 数据采集与输入层规约；05_ MarketDataFeed 契约）
-- 执行于 TimescaleDB，由 Schema init Job 执行；严禁在应用代码中执行 DDL。
-- [Ref: 03_原子目标与规约/_共享规约/11_数据采集与输入层规约.md]
-- [Ref: 03_原子目标与规约/_共享规约/05_接口抽象层规约.md]

CREATE TABLE IF NOT EXISTS ohlcv (
    symbol   VARCHAR(32) NOT NULL,
    period   VARCHAR(16) NOT NULL,
    datetime TIMESTAMPTZ NOT NULL,
    open     DOUBLE PRECISION NOT NULL,
    high     DOUBLE PRECISION NOT NULL,
    low      DOUBLE PRECISION NOT NULL,
    close    DOUBLE PRECISION NOT NULL,
    volume   BIGINT,
    PRIMARY KEY (symbol, period, datetime)
);

-- 仅用两参数 create_hypertable（所有 TS 版本都有）；已是 hypertable 时忽略错误，避免依赖 if_not_exists 或 timescaledb_information
DO $$
BEGIN
  PERFORM create_hypertable('ohlcv'::regclass, 'datetime'::name);
EXCEPTION
  WHEN OTHERS THEN NULL;
END $$;

CREATE INDEX IF NOT EXISTS idx_ohlcv_symbol_period ON ohlcv (symbol, period, datetime DESC);

COMMENT ON TABLE ohlcv IS 'L1 行情 OHLCV，供 MarketDataFeed 与采集任务读写';
