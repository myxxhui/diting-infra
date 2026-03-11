-- 迁移：为已存在但无 market/count/source 的 a_share_universe 表补列（与 11_ 规约一致）
-- 适用：表已有 symbol, name, list_date, updated_at 等列，缺少 market, count, source。
-- 执行于 L1/TimescaleDB（与 ohlcv 同库）。

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'a_share_universe'
  ) AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'a_share_universe' AND column_name = 'market'
  ) THEN
    ALTER TABLE a_share_universe ADD COLUMN IF NOT EXISTS market TEXT NOT NULL DEFAULT 'A';
    ALTER TABLE a_share_universe ADD COLUMN IF NOT EXISTS count INTEGER;
    ALTER TABLE a_share_universe ADD COLUMN IF NOT EXISTS source TEXT;
  END IF;
END $$;
