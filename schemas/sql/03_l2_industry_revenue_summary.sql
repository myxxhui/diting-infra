-- L2 PostgreSQL：行业/营收汇总表，供 Module A 语义分类器按标的查询
-- 由采集写入（ingest_industry_revenue 或等价任务），分类器 run 时从此表读取
-- [Ref: 01_语义分类器_实践, 11_数据采集与输入层规约]

CREATE TABLE IF NOT EXISTS industry_revenue_summary (
    symbol          VARCHAR(32) PRIMARY KEY,
    industry_name   VARCHAR(128) NOT NULL DEFAULT '',
    revenue_ratio   DOUBLE PRECISION NOT NULL DEFAULT 0,
    rnd_ratio       DOUBLE PRECISION NOT NULL DEFAULT 0,
    commodity_ratio DOUBLE PRECISION NOT NULL DEFAULT 0,
    updated_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_industry_revenue_summary_updated ON industry_revenue_summary(updated_at);

COMMENT ON TABLE industry_revenue_summary IS 'Module A 输入：每标的行业名与营收/研发/大宗占比，由采集写入';
