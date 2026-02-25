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
