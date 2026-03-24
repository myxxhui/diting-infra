-- L2：细分注册表，与 12_右脑数据支撑与Segment规约 一致
-- segment_id 稳定键：主营披露行为 seg_bp_{md16}；亦可为命名型多层 segment_id
-- [Ref: 12_右脑数据支撑与Segment规约]

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

COMMENT ON TABLE segment_registry IS '细分领域注册；标的主营构成 segment_id 逻辑外键';
COMMENT ON COLUMN segment_registry.domain IS '农业|科技|宏观 宽域标签（与 classifier 一致）';
COMMENT ON COLUMN segment_registry.sub_domain IS '赛道/板块：申万或归一化板块名，与 domain 正交';
COMMENT ON COLUMN segment_registry.segment_tier IS '1=domain 2=sector 3=business；主营披露哈希行一般为 3';
COMMENT ON COLUMN segment_registry.signal_adapter_id IS '信号适配器；空则按前缀/默认 news 适配器';
COMMENT ON COLUMN segment_registry.signal_refresh_ttl_sec IS '空则使用全局 signal_layer.ttl_sec';
