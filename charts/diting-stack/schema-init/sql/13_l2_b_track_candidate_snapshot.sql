-- sync with diting-infra/schemas/sql/13_l2_b_track_candidate_snapshot.sql
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
