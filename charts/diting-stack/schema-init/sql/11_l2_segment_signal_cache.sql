-- sync with diting-infra/schemas/sql/11_l2_segment_signal_cache.sql + 12_l2_segment_signal_audit.sql
CREATE TABLE IF NOT EXISTS segment_signal_cache (
    segment_id     VARCHAR(64) PRIMARY KEY,
    signal_summary TEXT NOT NULL,
    signal_at      TIMESTAMPTZ,
    fetched_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ttl_sec        INT NOT NULL DEFAULT 3600
);
CREATE INDEX IF NOT EXISTS idx_segment_signal_cache_fetched ON segment_signal_cache(fetched_at);

CREATE TABLE IF NOT EXISTS segment_signal_audit (
    id                   SERIAL PRIMARY KEY,
    segment_id           VARCHAR(64) NOT NULL,
    source_type          VARCHAR(32) NOT NULL DEFAULT 'rule',
    raw_snippet          TEXT,
    model_conclusion_json TEXT,
    error_message        TEXT,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_segment_signal_audit_segment_created ON segment_signal_audit(segment_id, created_at);
