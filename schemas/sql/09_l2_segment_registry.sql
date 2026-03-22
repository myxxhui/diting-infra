-- L2：细分注册表，与 12_右脑数据支撑与Segment规约 一致
-- segment_id 稳定键，由采集侧对「主营构成」名称哈希生成（见 diting-core diting/ingestion/business_profile.py）
-- [Ref: 12_右脑数据支撑与Segment规约]

CREATE TABLE IF NOT EXISTS segment_registry (
    segment_id   VARCHAR(64) PRIMARY KEY,
    domain       VARCHAR(32)  NOT NULL DEFAULT '宏观',
    name_cn      VARCHAR(256) NOT NULL DEFAULT '',
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_segment_registry_domain ON segment_registry(domain);

COMMENT ON TABLE segment_registry IS '细分领域注册；标的主营构成 segment_id 逻辑外键';
COMMENT ON COLUMN segment_registry.domain IS '农业|科技|宏观 或与 classifier 领域对齐的宽域标签';
