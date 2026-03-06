-- 本地验证用：L2 data_versions 表，与 schemas/sql/02_l2_data_versions.sql 一致
-- [Ref: 07_数据版本控制规约]

CREATE TABLE IF NOT EXISTS data_versions (
    id         SERIAL PRIMARY KEY,
    data_type  VARCHAR(50) NOT NULL,
    version_id VARCHAR(100) NOT NULL,
    timestamp  TIMESTAMP NOT NULL,
    file_path  VARCHAR(500) NOT NULL,
    file_size  BIGINT,
    checksum   VARCHAR(64),
    created_at TIMESTAMP DEFAULT NOW(),
    UNIQUE(data_type, version_id)
);
CREATE INDEX IF NOT EXISTS idx_data_versions_timestamp ON data_versions(timestamp);
CREATE INDEX IF NOT EXISTS idx_data_versions_type ON data_versions(data_type);

-- Module A 输入：行业/营收汇总表（与 schemas/sql/03_l2_industry_revenue_summary.sql 一致）
CREATE TABLE IF NOT EXISTS industry_revenue_summary (
    symbol          VARCHAR(32) PRIMARY KEY,
    industry_name   VARCHAR(128) NOT NULL DEFAULT '',
    revenue_ratio   DOUBLE PRECISION NOT NULL DEFAULT 0,
    rnd_ratio       DOUBLE PRECISION NOT NULL DEFAULT 0,
    commodity_ratio DOUBLE PRECISION NOT NULL DEFAULT 0,
    updated_at      TIMESTAMP NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_industry_revenue_summary_updated ON industry_revenue_summary(updated_at);
