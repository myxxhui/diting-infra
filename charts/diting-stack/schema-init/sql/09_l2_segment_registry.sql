-- sync with diting-infra/schemas/sql/09_l2_segment_registry.sql
CREATE TABLE IF NOT EXISTS segment_registry (
    segment_id   VARCHAR(64) PRIMARY KEY,
    domain       VARCHAR(32)  NOT NULL DEFAULT '宏观',
    name_cn      VARCHAR(256) NOT NULL DEFAULT '',
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_segment_registry_domain ON segment_registry(domain);
