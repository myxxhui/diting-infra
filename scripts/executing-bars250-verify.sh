#!/usr/bin/env bash
# 验收 executing_daily_bars：执行区标的均 >= 200 根腾讯 250 日底库
# [Ref: 28_ §2.2.2]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONN="${INFRA_ROOT}/prod.conn"
MIN_BARS="${MIN_BARS:-200}"

if [[ -f "$CONN" ]]; then
  # shellcheck disable=SC1090
  source "$CONN"
fi

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
NS="${EXECUTING_T0_NS:-platform}"

echo "▶ [executing-bars250-verify] 最低根数=$MIN_BARS"

kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec deployment/diting-copilot -- \
  env MIN_BARS="$MIN_BARS" python - <<'PY'
import asyncio
import os
import sys

from sqlalchemy import func, select, text

from apps.copilot.db.database import AsyncSessionLocal, init_db
from apps.copilot.db.models import ExecutingCollectSymbol, ExecutingDailyBar
from apps.copilot.modules.executing.collectors.daily_bars import MIN_BARS_ACCEPT

MIN_BARS = int(os.environ.get("MIN_BARS", "200"))


async def main() -> int:
    await init_db()
    async with AsyncSessionLocal() as session:
        symbols = (
            await session.scalars(
                select(ExecutingCollectSymbol.symbol).where(
                    ExecutingCollectSymbol.enabled.is_(True)
                )
            )
        ).all()
        if not symbols:
            print("❌ executing_collect_symbols 为空")
            return 1
        print(f"执行区标的 {len(symbols)} 个: {', '.join(symbols)}")
        failed = []
        for sym in symbols:
            s = str(sym).zfill(6)[-6:]
            cnt = await session.scalar(
                select(func.count())
                .select_from(ExecutingDailyBar)
                .where(
                    ExecutingDailyBar.symbol == s,
                    ExecutingDailyBar.adjust == "qfq",
                    ExecutingDailyBar.source == "tencent_fqkline",
                )
            )
            row = await session.execute(
                text(
                    """
                    SELECT MIN(trade_date), MAX(trade_date), MAX(source)
                    FROM executing_daily_bars
                    WHERE symbol = :sym AND adjust = 'qfq'
                    """
                ),
                {"sym": s},
            )
            min_d, max_d, src = row.one()
            ok = (cnt or 0) >= MIN_BARS
            mark = "✅" if ok else "❌"
            print(f"{mark} {s}: bars={cnt} range={min_d}..{max_d} source={src}")
            if not ok:
                failed.append(s)
        if failed:
            print(f"❌ 未达标标的: {failed} (需要 >= {MIN_BARS})")
            return 1
        print(f"✅ 全部 {len(symbols)} 标的 >= {MIN_BARS} 根")
        return 0


sys.exit(asyncio.run(main()))
PY
