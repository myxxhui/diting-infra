-- L2 PostgreSQL：Module A 语义分类结果快照，按批次存放，供 Module B 按 batch_id 或最新批次读取
-- 由 Module A 分类完成后写入；表结构与 ClassifierOutput.proto 对齐
-- [Ref: 01_语义分类器_实践, 09_核心模块架构规约, Stage3 规约]

CREATE TABLE IF NOT EXISTS classifier_output_snapshot (
    id                BIGSERIAL PRIMARY KEY,
    batch_id           VARCHAR(64)  NOT NULL,
    symbol             VARCHAR(32)  NOT NULL,
    primary_tag        VARCHAR(16)  NOT NULL DEFAULT '未知',
    primary_confidence DOUBLE PRECISION NOT NULL DEFAULT 0,
    tags_json          JSONB,
    correlation_id     VARCHAR(64)  NOT NULL DEFAULT '',
    created_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_classifier_output_snapshot_batch ON classifier_output_snapshot(batch_id);
CREATE INDEX IF NOT EXISTS idx_classifier_output_snapshot_symbol ON classifier_output_snapshot(symbol);
CREATE INDEX IF NOT EXISTS idx_classifier_output_snapshot_created ON classifier_output_snapshot(created_at DESC);

COMMENT ON TABLE classifier_output_snapshot IS 'Module A 分类结果快照，供 Module B 按 batch_id/最新批次读取';
COMMENT ON COLUMN classifier_output_snapshot.primary_tag IS '领域标签：农业/科技/宏观/未知/自定义，以中文为主便于过滤';
