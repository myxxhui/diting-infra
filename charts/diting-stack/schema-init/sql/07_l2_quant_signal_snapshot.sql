-- L2 PostgreSQL：Module B 量化扫描结果；通过表供 Module C，全量表供查询
-- 与 diting-src/scripts/init_l2_quant_signal_table.py、l2_snapshot_writer 对齐
-- [Ref: 02_量化扫描引擎_实践, 09_核心模块架构规约, Stage3 规约, 02_B模块策略_策略实现规约 §8]

CREATE TABLE IF NOT EXISTS quant_signal_snapshot (
    id                BIGSERIAL PRIMARY KEY,
    batch_id           VARCHAR(64)  NOT NULL,
    symbol             VARCHAR(32)  NOT NULL,
    symbol_name        VARCHAR(128) NOT NULL DEFAULT '',
    technical_score    DOUBLE PRECISION NOT NULL DEFAULT 0,
    strategy_source    VARCHAR(16)  NOT NULL DEFAULT 'UNSPECIFIED',
    sector_strength    DOUBLE PRECISION NOT NULL DEFAULT 0,
    trend_score        DOUBLE PRECISION NOT NULL DEFAULT 0,
    reversion_score    DOUBLE PRECISION NOT NULL DEFAULT 0,
    breakout_score     DOUBLE PRECISION NOT NULL DEFAULT 0,
    momentum_score     DOUBLE PRECISION NOT NULL DEFAULT 0,
    technical_score_percentile DOUBLE PRECISION,
    long_term_score    DOUBLE PRECISION,
    long_term_candidate BOOLEAN NOT NULL DEFAULT FALSE,
    correlation_id     VARCHAR(64)  NOT NULL DEFAULT '',
    signal_tier        VARCHAR(16) NOT NULL DEFAULT '',
    alert_passed       BOOLEAN NOT NULL DEFAULT FALSE,
    confirmed_passed   BOOLEAN NOT NULL DEFAULT FALSE,
    entry_reference_price DOUBLE PRECISION,
    stop_loss_price    DOUBLE PRECISION,
    take_profit_json   TEXT,
    risk_rules_json    TEXT,
    scanner_rules_fingerprint VARCHAR(32) NOT NULL DEFAULT '',
    evaluation_source  VARCHAR(16)  NOT NULL DEFAULT 'FRESH',
    created_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_quant_signal_snapshot_batch ON quant_signal_snapshot(batch_id);
CREATE INDEX IF NOT EXISTS idx_quant_signal_snapshot_symbol ON quant_signal_snapshot(symbol);
CREATE INDEX IF NOT EXISTS idx_quant_signal_snapshot_created ON quant_signal_snapshot(created_at DESC);

COMMENT ON TABLE quant_signal_snapshot IS 'Module B 量化扫描结果（预警/确认档与建议止损止盈），供 Module C 读取';

CREATE TABLE IF NOT EXISTS quant_signal_scan_all (
    id                BIGSERIAL PRIMARY KEY,
    batch_id           VARCHAR(64)  NOT NULL,
    symbol             VARCHAR(32)  NOT NULL,
    symbol_name        VARCHAR(128) NOT NULL DEFAULT '',
    technical_score    DOUBLE PRECISION NOT NULL DEFAULT 0,
    strategy_source    VARCHAR(16)  NOT NULL DEFAULT 'UNSPECIFIED',
    sector_strength    DOUBLE PRECISION NOT NULL DEFAULT 0,
    trend_score        DOUBLE PRECISION NOT NULL DEFAULT 0,
    reversion_score    DOUBLE PRECISION NOT NULL DEFAULT 0,
    breakout_score     DOUBLE PRECISION NOT NULL DEFAULT 0,
    momentum_score     DOUBLE PRECISION NOT NULL DEFAULT 0,
    technical_score_percentile DOUBLE PRECISION,
    passed             BOOLEAN       NOT NULL DEFAULT FALSE,
    long_term_score    DOUBLE PRECISION,
    long_term_candidate BOOLEAN NOT NULL DEFAULT FALSE,
    correlation_id     VARCHAR(64)  NOT NULL DEFAULT '',
    signal_tier        VARCHAR(16) NOT NULL DEFAULT '',
    alert_passed       BOOLEAN NOT NULL DEFAULT FALSE,
    confirmed_passed   BOOLEAN NOT NULL DEFAULT FALSE,
    entry_reference_price DOUBLE PRECISION,
    stop_loss_price    DOUBLE PRECISION,
    take_profit_json   TEXT,
    risk_rules_json    TEXT,
    scanner_rules_fingerprint VARCHAR(32) NOT NULL DEFAULT '',
    evaluation_source  VARCHAR(16)  NOT NULL DEFAULT 'FRESH',
    created_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_quant_signal_scan_all_batch ON quant_signal_scan_all(batch_id);
CREATE INDEX IF NOT EXISTS idx_quant_signal_scan_all_symbol ON quant_signal_scan_all(symbol);
CREATE INDEX IF NOT EXISTS idx_quant_signal_scan_all_passed ON quant_signal_scan_all(passed);
CREATE INDEX IF NOT EXISTS idx_quant_signal_scan_all_created ON quant_signal_scan_all(created_at DESC);

COMMENT ON TABLE quant_signal_scan_all IS 'Module B 全量扫描结果（通过/未通过），含池分、双档与建议风控 JSON';

ALTER TABLE quant_signal_snapshot ADD COLUMN IF NOT EXISTS scan_input_ohlcv_max_ts TIMESTAMPTZ;
ALTER TABLE quant_signal_snapshot ADD COLUMN IF NOT EXISTS scan_input_news_max_ts TIMESTAMPTZ;
ALTER TABLE quant_signal_scan_all ADD COLUMN IF NOT EXISTS scan_input_ohlcv_max_ts TIMESTAMPTZ;
ALTER TABLE quant_signal_scan_all ADD COLUMN IF NOT EXISTS scan_input_news_max_ts TIMESTAMPTZ;
