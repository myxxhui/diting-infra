-- L2 PostgreSQL：新闻/公告（标的新闻 + 行业新闻 + 全市场）分离 scope
-- [Ref: 11_数据采集与输入层规约] [Ref: 07_行业新闻与标的新闻分离存储_设计]
-- title_hash = md5(title) 在 Python 端计算；唯一 (scope, scope_id, title_hash, published_at)

CREATE TABLE IF NOT EXISTS news_content (
    id           SERIAL PRIMARY KEY,
    symbol       VARCHAR(32)  DEFAULT NULL,
    source       VARCHAR(32)  NOT NULL DEFAULT 'akshare',
    source_type  VARCHAR(32)  NOT NULL DEFAULT 'news',
    title        TEXT         NOT NULL DEFAULT '',
    title_hash   VARCHAR(32)  NOT NULL DEFAULT '',
    content      TEXT         NOT NULL DEFAULT '',
    url          VARCHAR(1024) NOT NULL DEFAULT '',
    keywords     TEXT         NOT NULL DEFAULT '',
    published_at TIMESTAMP    NOT NULL DEFAULT '1970-01-01',
    created_at   TIMESTAMP    NOT NULL DEFAULT NOW(),
    scope        VARCHAR(32)  NOT NULL DEFAULT 'symbol',
    scope_id     VARCHAR(128) NOT NULL DEFAULT ''
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_news_content_scope_dedup
    ON news_content (scope, scope_id, title_hash, published_at);

CREATE INDEX IF NOT EXISTS idx_news_content_symbol ON news_content(symbol);
CREATE INDEX IF NOT EXISTS idx_news_content_published ON news_content(published_at);
CREATE INDEX IF NOT EXISTS idx_news_content_symbol_pub ON news_content(symbol, published_at DESC);
CREATE INDEX IF NOT EXISTS idx_news_content_scope_scope_id ON news_content(scope, scope_id);
CREATE INDEX IF NOT EXISTS idx_news_content_scope_id_pub ON news_content(scope, scope_id, published_at DESC);

COMMENT ON TABLE news_content IS 'Module C / 信号层：market=全市场 industry=申万行业名 symbol=个股';
COMMENT ON COLUMN news_content.scope IS 'market | industry | symbol';
COMMENT ON COLUMN news_content.scope_id IS 'market→_MARKET_ industry→申万一级名 symbol→标的代码';
