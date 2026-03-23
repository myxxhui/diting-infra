-- L2：细分信号审计表，audit_enabled=true 时信号层写入
-- [Ref: 06_B轨_信号层生产级数据采集_设计] §3.2
-- 每次信号理解（含 AI 成功/失败）可选写一条，便于复查与同 segment 同日复用

CREATE TABLE IF NOT EXISTS segment_signal_audit (
    id                   SERIAL PRIMARY KEY,
    segment_id           VARCHAR(64) NOT NULL,
    source_type          VARCHAR(32) NOT NULL DEFAULT 'rule',
    raw_snippet          TEXT,
    model_conclusion_json TEXT,
    error_message        TEXT,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_segment_signal_audit_segment_created ON segment_signal_audit(segment_id, created_at);

COMMENT ON TABLE segment_signal_audit IS '细分信号理解审计；audit_enabled 时每次理解写一条，支持复查与 audit_reuse_same_day';
