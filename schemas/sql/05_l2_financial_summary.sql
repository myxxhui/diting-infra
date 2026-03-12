-- L2 PostgreSQL：财务摘要表，存储每标的多报告期核心财务指标（营收/利润/ROE/EPS 等）
-- 由采集写入（AkShare stock_financial_abstract），供 Module C 查询
-- [Ref: 11_数据采集与输入层规约]

CREATE TABLE IF NOT EXISTS financial_summary (
    symbol              VARCHAR(32) NOT NULL,
    report_date         VARCHAR(8) NOT NULL,
    revenue             DOUBLE PRECISION DEFAULT 0,
    net_profit          DOUBLE PRECISION DEFAULT 0,
    net_profit_parent   DOUBLE PRECISION DEFAULT 0,
    deducted_np         DOUBLE PRECISION DEFAULT 0,
    gross_margin        DOUBLE PRECISION DEFAULT 0,
    net_margin          DOUBLE PRECISION DEFAULT 0,
    roe                 DOUBLE PRECISION DEFAULT 0,
    roa                 DOUBLE PRECISION DEFAULT 0,
    eps                 DOUBLE PRECISION DEFAULT 0,
    bvps                DOUBLE PRECISION DEFAULT 0,
    debt_ratio          DOUBLE PRECISION DEFAULT 0,
    revenue_growth      DOUBLE PRECISION DEFAULT 0,
    np_growth           DOUBLE PRECISION DEFAULT 0,
    ocf                 DOUBLE PRECISION DEFAULT 0,
    current_ratio       DOUBLE PRECISION DEFAULT 0,
    cost_ratio          DOUBLE PRECISION DEFAULT 0,
    equity              DOUBLE PRECISION DEFAULT 0,
    goodwill            DOUBLE PRECISION DEFAULT 0,
    updated_at          TIMESTAMP NOT NULL DEFAULT NOW(),
    PRIMARY KEY (symbol, report_date)
);

CREATE INDEX IF NOT EXISTS idx_fin_symbol ON financial_summary (symbol);
CREATE INDEX IF NOT EXISTS idx_fin_report_date ON financial_summary (report_date);

COMMENT ON TABLE financial_summary IS 'Module C 输入：每标的每报告期财务摘要（营收/利润/ROE/EPS 等），由采集写入';
