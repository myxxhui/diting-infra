-- sync with diting-infra/schemas/sql/09_l2_segment_registry.sql
CREATE TABLE IF NOT EXISTS segment_registry (
    segment_id   VARCHAR(64) PRIMARY KEY,
    domain       VARCHAR(32)  NOT NULL DEFAULT '宏观',
    sub_domain   VARCHAR(64)  DEFAULT NULL,
    segment_tier SMALLINT      DEFAULT NULL,
    name_cn      VARCHAR(256) NOT NULL DEFAULT '',
    signal_adapter_id VARCHAR(64) DEFAULT NULL,
    signal_refresh_ttl_sec INT DEFAULT NULL,
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_segment_registry_domain ON segment_registry(domain);
CREATE INDEX IF NOT EXISTS idx_segment_registry_tier ON segment_registry(segment_tier) WHERE segment_tier IS NOT NULL;
