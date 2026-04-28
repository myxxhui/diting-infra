-- L2：`long_term_candidate`/中长期候选链快照表（表名 `b_track_*` 为历史兼容），B 模块写入，Module C 与信号层 refresh 消费
-- [Ref: diting-doc _共享规约/11_数据采集与输入层规约, 平台与产品/01_需求与产品范围]
-- DITING_TRACK=b 时 run_module_c 与 run_refresh_segment_signals 从此表取 symbols

CREATE TABLE IF NOT EXISTS b_track_candidate_snapshot (
    id              BIGSERIAL PRIMARY KEY,
    batch_id        VARCHAR(64) NOT NULL,
    symbol          VARCHAR(32) NOT NULL,
    symbol_name     VARCHAR(64) NOT NULL DEFAULT '',
    phase_score     NUMERIC(10,4) DEFAULT NULL,
    trend_confirm   BOOLEAN DEFAULT NULL,
    sector_strength NUMERIC(10,4) DEFAULT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_b_track_candidate_batch ON b_track_candidate_snapshot(batch_id);
CREATE INDEX IF NOT EXISTS idx_b_track_candidate_created ON b_track_candidate_snapshot(created_at);

COMMENT ON TABLE b_track_candidate_snapshot IS 'B 轨中线候选；DITING_TRACK=b 时 C 与 refresh 从此表取 symbols';
