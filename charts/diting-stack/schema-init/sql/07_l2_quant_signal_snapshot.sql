-- L2 PostgreSQL：Module B 量化扫描结果；通过表供 Module C，全量表供查询
-- [Ref: 02_量化扫描引擎_实践, 09_核心模块架构规约, Stage3 规约]

CREATE TABLE IF NOT EXISTS quant_signal_snapshot (
    id                BIGSERIAL PRIMARY KEY,
    batch_id           VARCHAR(64)  NOT NULL,
    symbol             VARCHAR(32)  NOT NULL,
    symbol_name        VARCHAR(128) NOT NULL DEFAULT '',
    technical_score    DOUBLE PRECISION NOT NULL DEFAULT 0,
    strategy_source    VARCHAR(16)  NOT NULL DEFAULT 'UNSPECIFIED',
    sector_strength    DOUBLE PRECISION NOT NULL DEFAULT 0,
    correlation_id     VARCHAR(64)  NOT NULL DEFAULT '',
    created_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_quant_signal_snapshot_batch ON quant_signal_snapshot(batch_id);
CREATE INDEX IF NOT EXISTS idx_quant_signal_snapshot_symbol ON quant_signal_snapshot(symbol);
CREATE INDEX IF NOT EXISTS idx_quant_signal_snapshot_created ON quant_signal_snapshot(created_at DESC);

COMMENT ON TABLE quant_signal_snapshot IS 'Module B 通过阈值的扫描结果，供 Module C 读取';

CREATE TABLE IF NOT EXISTS quant_signal_scan_all (
    id                BIGSERIAL PRIMARY KEY,
    batch_id           VARCHAR(64)  NOT NULL,
    symbol             VARCHAR(32)  NOT NULL,
    symbol_name        VARCHAR(128) NOT NULL DEFAULT '',
    technical_score    DOUBLE PRECISION NOT NULL DEFAULT 0,
    strategy_source    VARCHAR(16)  NOT NULL DEFAULT 'UNSPECIFIED',
    sector_strength    DOUBLE PRECISION NOT NULL DEFAULT 0,
    passed             BOOLEAN       NOT NULL DEFAULT FALSE,
    correlation_id     VARCHAR(64)  NOT NULL DEFAULT '',
    created_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_quant_signal_scan_all_batch ON quant_signal_scan_all(batch_id);
CREATE INDEX IF NOT EXISTS idx_quant_signal_scan_all_symbol ON quant_signal_scan_all(symbol);
CREATE INDEX IF NOT EXISTS idx_quant_signal_scan_all_passed ON quant_signal_scan_all(passed);
CREATE INDEX IF NOT EXISTS idx_quant_signal_scan_all_created ON quant_signal_scan_all(created_at DESC);

COMMENT ON TABLE quant_signal_scan_all IS 'Module B 全量扫描结果（通过/未通过），保存当前分数供查询';
