-- L2：细分信号缓存表，与 12_右脑数据支撑与Segment规约 §2.3 一致
-- 信号层 refresh_segment_signals_for_symbols 写入，Module C 消费
-- [Ref: 12_右脑数据支撑与Segment规约]

CREATE TABLE IF NOT EXISTS segment_signal_cache (
    segment_id     VARCHAR(64) PRIMARY KEY,
    signal_summary TEXT NOT NULL,
    signal_at      TIMESTAMPTZ,
    fetched_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ttl_sec        INT NOT NULL DEFAULT 3600
);
CREATE INDEX IF NOT EXISTS idx_segment_signal_cache_fetched ON segment_signal_cache(fetched_at);

COMMENT ON TABLE segment_signal_cache IS '细分垂直信号缓存；信号层 refresh_segment_signals_for_symbols 写入，Module C 消费';
