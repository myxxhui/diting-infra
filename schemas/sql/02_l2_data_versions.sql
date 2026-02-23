-- L2 PostgreSQL：数据版本元数据表（07_ 数据版本控制规约）
-- 执行于 L2 知识库 PostgreSQL，由 Schema init Job 执行。
-- [Ref: 03_原子目标与规约/_共享规约/07_数据版本控制规约.md]

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

COMMENT ON TABLE data_versions IS '数据版本元数据（DVC/Git），07_ 规约';
