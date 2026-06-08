"""Pod 内联 PG T0 导出（镜像未含 scripts/ 时的 fallback）。"""
import asyncio
import json
import os
from sqlalchemy import func, select
from apps.copilot.db.database import AsyncSessionLocal, init_db
from apps.copilot.db.models import ExecutingDailyBar, ExecutingT0Raw, ExecutingT0SyncWatermark
from apps.copilot.modules.executing.collectors.daily_bars import rows_to_ohlcv_lists
from apps.copilot.modules.executing.storage import load_daily_bars

SYMS = [s.strip().zfill(6)[-6:] for s in os.environ.get("EXECUTING_SYMBOLS", "601138,002837,300502").split(",") if s.strip()]


async def main() -> None:
    await init_db()
    out: dict = {"symbols": {}, "watermarks": []}
    async with AsyncSessionLocal() as session:
        for w in (await session.scalars(select(ExecutingT0SyncWatermark))).all():
            if w.job_id in ("quote-intraday", "quote-intraday-close", "l4-atr-bars-sync"):
                out["watermarks"].append(
                    {
                        "job_id": w.job_id,
                        "symbol": w.symbol,
                        "last_success_at": w.last_success_at.isoformat() if w.last_success_at else None,
                        "last_trade_date": str(w.last_trade_date) if w.last_trade_date else None,
                        "last_row_count": w.last_row_count,
                    }
                )
        for sym in SYMS:
            rows = await load_daily_bars(session, sym, limit=250)
            cnt = await session.scalar(
                select(func.count())
                .select_from(ExecutingDailyBar)
                .where(ExecutingDailyBar.symbol == sym, ExecutingDailyBar.adjust == "qfq")
            )
            t0 = (
                await session.scalars(
                    select(ExecutingT0Raw)
                    .where(ExecutingT0Raw.symbol == sym, ExecutingT0Raw.probe_key == "qmt_atr_trailing")
                    .order_by(ExecutingT0Raw.collected_at.desc())
                    .limit(1)
                )
            ).first()
            out["symbols"][sym] = {
                "pg_count": int(cnt or 0),
                "loaded": len(rows),
                "range": [rows[0].trade_date.isoformat(), rows[-1].trade_date.isoformat()] if rows else None,
                "last_5_bars": rows_to_ohlcv_lists(rows[-5:]) if rows else {},
                "t0_raw_latest": (
                    {
                        "collected_at": t0.collected_at.isoformat() if t0.collected_at else None,
                        "payload": t0.payload_json,
                    }
                    if t0
                    else None
                ),
            }
    print(json.dumps(out, ensure_ascii=False, indent=2))


asyncio.run(main())
