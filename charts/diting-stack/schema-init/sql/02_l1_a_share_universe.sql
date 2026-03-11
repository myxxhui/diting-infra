-- L1 TimescaleDB：全 A 股标的池表（11_ 数据采集与输入层规约）
-- 与 ohlcv 同库；get_current_a_share_universe() 读取；run_ingest_universe 写入。
-- [Ref: 03_原子目标与规约/_共享规约/11_数据采集与输入层规约.md]

CREATE TABLE IF NOT EXISTS a_share_universe (
    symbol   TEXT NOT NULL PRIMARY KEY,
    market   TEXT NOT NULL DEFAULT 'A',
    updated_at TIMESTAMPTZ NOT NULL,
    count    INTEGER,
    source   TEXT
);

CREATE INDEX IF NOT EXISTS idx_a_share_universe_updated_at ON a_share_universe(updated_at);

COMMENT ON TABLE a_share_universe IS 'L1 全 A 股标的池，供 get_current_a_share_universe 与 Module A/B 使用';
