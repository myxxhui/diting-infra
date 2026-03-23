-- L2：B 轨候选快照，B 模块写入，Module C（track=b）与信号层 refresh 消费
-- [Ref: 03_/B轨/02_B轨数据与存储规约, 01_B轨系统设计]
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
