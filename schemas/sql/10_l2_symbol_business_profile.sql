-- L2：标的主营业务构成（按产品/披露分部），供 Module A 输出真实 segment_shares
-- 数据源：AkShare stock_zygc_em（东方财富主营构成），生产任务 run_ingest_business_profile
-- [Ref: 12_右脑数据支撑与Segment规约, 11_数据采集与输入层规约]

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

COMMENT ON TABLE symbol_business_profile IS '标的主营构成多行：segment_id 注册于 segment_registry';
COMMENT ON COLUMN symbol_business_profile.revenue_share IS '该分部营收占营业收入比例 0~1（与披露一致）';
COMMENT ON COLUMN symbol_business_profile.is_primary IS '同一 symbol 仅一行 TRUE（占比最高）';
