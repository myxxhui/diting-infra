-- L2 PostgreSQL：新闻/公告内容表，供 Module C (MoE 议会) 查询标的相关新闻
-- 由采集写入（run_ingest_news），按 symbol + title_hash + published_at 去重
-- title_hash = md5(title) 在 Python 端计算后写入
-- [Ref: 11_数据采集与输入层规约]

CREATE TABLE IF NOT EXISTS news_content (
    id           SERIAL PRIMARY KEY,
    symbol       VARCHAR(32)  NOT NULL,
    source       VARCHAR(32)  NOT NULL DEFAULT 'akshare',
    source_type  VARCHAR(32)  NOT NULL DEFAULT 'news',
    title        TEXT         NOT NULL DEFAULT '',
    title_hash   VARCHAR(32)  NOT NULL DEFAULT '',
    content      TEXT         NOT NULL DEFAULT '',
    url          VARCHAR(1024) NOT NULL DEFAULT '',
    keywords     TEXT         NOT NULL DEFAULT '',
    published_at TIMESTAMP    NOT NULL DEFAULT '1970-01-01',
    created_at   TIMESTAMP    NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_news_content_dedup
    ON news_content (symbol, title_hash, published_at);

CREATE INDEX IF NOT EXISTS idx_news_content_symbol ON news_content (symbol);
CREATE INDEX IF NOT EXISTS idx_news_content_published ON news_content (published_at);
CREATE INDEX IF NOT EXISTS idx_news_content_symbol_pub ON news_content (symbol, published_at DESC);

COMMENT ON TABLE news_content IS 'Module C 输入：每标的新闻/公告原文，title_hash = md5(title) 在 Python 端计算';
