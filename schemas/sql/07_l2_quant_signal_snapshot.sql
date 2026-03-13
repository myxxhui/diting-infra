-- L2 PostgreSQL：Module B 量化扫描结果快照，按批次存放，供 Module C 按 batch_id 或最新批次读取
-- 由 Module B 扫描完成后写入；表结构与 QuantSignal.proto 对齐
-- [Ref: 02_量化扫描引擎_实践, 09_核心模块架构规约, Stage3 规约]

-- 通过阈值的候选：供 Module C 消费
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

COMMENT ON TABLE quant_signal_snapshot IS 'Module B 通过阈值的量化扫描结果，供 Module C 按 batch_id/最新批次读取';

-- 全量扫描结果（含通过/未通过），按 passed 区分，可随时查询当前分数
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

COMMENT ON TABLE quant_signal_scan_all IS 'Module B 全量扫描结果（通过/未通过分开可查），保存当前分数供查询';
