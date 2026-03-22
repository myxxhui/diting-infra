-- sync with diting-infra/schemas/sql/10_l2_symbol_business_profile.sql
CREATE TABLE IF NOT EXISTS symbol_business_profile (
    id              BIGSERIAL PRIMARY KEY,
    symbol          VARCHAR(32)  NOT NULL,
    segment_id      VARCHAR(64)  NOT NULL,
    segment_label_cn VARCHAR(256) NOT NULL DEFAULT '',
    revenue_share   DOUBLE PRECISION NOT NULL DEFAULT 0,
    is_primary      BOOLEAN NOT NULL DEFAULT FALSE,
    report_date     VARCHAR(32)  DEFAULT NULL,
    source          VARCHAR(32)  NOT NULL DEFAULT 'akshare_zygc',
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE(symbol, segment_id)
);

CREATE INDEX IF NOT EXISTS idx_symbol_business_profile_symbol ON symbol_business_profile(symbol);
CREATE INDEX IF NOT EXISTS idx_symbol_business_profile_updated ON symbol_business_profile(updated_at DESC);
