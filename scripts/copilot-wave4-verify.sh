#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
NS="${STACK_NS:-platform}"
CONN="${CONN_FILE:-$INFRA_ROOT/prod.conn}"
IP="$(grep '^PUBLIC_IP=' "$CONN" 2>/dev/null | cut -d= -f2- || echo "127.0.0.1")"
PORT=30080

echo "▶ [wave4-verify] Pod 内表结构"
kubectl exec -n "$NS" deployment/diting-copilot -- python3 -c "
import asyncio
from sqlalchemy import text
from apps.copilot.db.database import engine

async def main():
    async with engine.begin() as conn:
        r = await conn.execute(text(
            \"SELECT name FROM sqlite_master WHERE type='table' AND name='radar_symbol_versions'\"
        ))
        assert r.fetchone(), 'missing radar_symbol_versions'
        r2 = await conn.execute(text('PRAGMA table_info(campaign_symbols)'))
        cols = {row[1] for row in r2.fetchall()}
        assert 'ui_removed_at' in cols and 'last_analyzed_at' in cols
    print('OK migrate_step19')

asyncio.run(main())
"

echo "▶ [wave4-verify] HTTP @ ${IP}:${PORT}"
curl -sf "http://${IP}:${PORT}/planning?view=radar" | grep -q '仅采集 T0'
echo "  ✅ 雷达 · 仅采集 T0"
curl -sf "http://${IP}:${PORT}/planning?view=radar_data" | grep -q '采集数据'
echo "  ✅ Tab radar_data"
curl -sf "http://${IP}:${PORT}/planning?view=radar_chat" | grep -q 'radar-chat-model'
echo "  ✅ Opus 对话模型下拉"
curl -sf "http://${IP}:${PORT}/api/radar/audit/601138/versions" | grep -q '"db_retention_days":30'
echo "  ✅ 版本 API（波次四 env · 可无历史版本）"
echo "✅ [copilot-wave4-verify] 全部通过"
