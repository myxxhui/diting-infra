-- sync with diting-infra/schemas/sql/04_l2_news_content.sql
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
