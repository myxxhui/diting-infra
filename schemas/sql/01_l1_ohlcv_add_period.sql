-- 迁移：将旧版 ohlcv（无 period、列为 trade_date）对齐到 01_l1_ohlcv.sql 规范
-- 适用：表已存在且为 (symbol, trade_date, open, high, low, close, volume[, amount]) 结构。
-- 执行前请备份；执行于 TimescaleDB/PostgreSQL。

DO $$
BEGIN
  -- 表存在、无 period、且有 trade_date（旧结构）
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'ohlcv'
  ) AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'ohlcv' AND column_name = 'period'
  ) AND EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'ohlcv' AND column_name = 'trade_date'
  ) THEN
    ALTER TABLE ohlcv ADD COLUMN period VARCHAR(16) DEFAULT 'daily';
    UPDATE ohlcv SET period = 'daily' WHERE period IS NULL;
    ALTER TABLE ohlcv ALTER COLUMN period SET NOT NULL;
    ALTER TABLE ohlcv RENAME COLUMN trade_date TO datetime;
    ALTER TABLE ohlcv ALTER COLUMN datetime TYPE TIMESTAMPTZ USING datetime::timestamptz;
    ALTER TABLE ohlcv DROP CONSTRAINT IF EXISTS ohlcv_pkey;
    ALTER TABLE ohlcv ADD PRIMARY KEY (symbol, period, datetime);
    CREATE INDEX IF NOT EXISTS idx_ohlcv_symbol_period ON ohlcv (symbol, period, datetime DESC);
  END IF;
END $$;
