-- L2：Module C MoE 专家意见快照（按批次），供判官联调与 query-module-c-output
-- [Ref: 04_A轨_MoE议会_实践]

CREATE TABLE IF NOT EXISTS moe_expert_opinion_snapshot (
    id                BIGSERIAL PRIMARY KEY,
    batch_id           VARCHAR(64)  NOT NULL,
    symbol             VARCHAR(32)  NOT NULL,
    opinions_json      JSONB        NOT NULL DEFAULT '[]',
    correlation_id     VARCHAR(64)  NOT NULL DEFAULT '',
    moe_run_metadata   JSONB        NOT NULL DEFAULT '{}'::jsonb,
    created_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_moe_expert_opinion_batch ON moe_expert_opinion_snapshot(batch_id);
CREATE INDEX IF NOT EXISTS idx_moe_expert_opinion_symbol ON moe_expert_opinion_snapshot(symbol);
CREATE INDEX IF NOT EXISTS idx_moe_expert_opinion_created ON moe_expert_opinion_snapshot(created_at DESC);

COMMENT ON TABLE moe_expert_opinion_snapshot IS 'Module C ExpertOpinion 列表（JSON），短线+可选 LONG_TERM VC-Agent；moe_run_metadata 存 stub/批次/A·B 行数等可追溯字段';
