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
import os
from sqlalchemy import text
from apps.copilot.db.database import engine

async def main():
    url = os.environ.get('COPILOT_DB_URL', '')
    async with engine.begin() as conn:
        if 'postgresql' in url:
            r = await conn.execute(text(
                \"SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename='radar_symbol_versions'\"
            ))
            assert r.fetchone(), 'missing radar_symbol_versions'
            r2 = await conn.execute(text(
                \"SELECT column_name FROM information_schema.columns \"
                \"WHERE table_name='campaign_symbols'\"
            ))
            cols = {row[0] for row in r2.fetchall()}
        else:
            r = await conn.execute(text(
                \"SELECT name FROM sqlite_master WHERE type='table' AND name='radar_symbol_versions'\"
            ))
            assert r.fetchone(), 'missing radar_symbol_versions'
            r2 = await conn.execute(text('PRAGMA table_info(campaign_symbols)'))
            cols = {row[1] for row in r2.fetchall()}
        assert 'ui_removed_at' in cols and 'last_analyzed_at' in cols
    print('OK schema ·', 'postgresql' if 'postgresql' in url else 'sqlite')

asyncio.run(main())
"

echo "▶ [wave4-verify] HTTP @ ${IP}:${PORT}"
_radar_html="$(curl -sSL "http://${IP}:${PORT}/planning?view=radar")"
echo "$_radar_html" | grep -q '仅采集 T0'
echo "  ✅ 雷达 · 仅采集 T0"
_audit_html="$(curl -sSL "http://${IP}:${PORT}/audit")"
echo "$_audit_html" | grep -qE '采集数据|数据审计|audit'
echo "  ✅ 采集数据页 /audit"
_opus_html="$(curl -sSL "http://${IP}:${PORT}/opus")"
echo "$_opus_html" | grep -q 'radar-chat-model'
echo "  ✅ Opus 对话 /opus"
_audit_json="$(curl -sSL "http://${IP}:${PORT}/api/radar/audit/601138/versions")"
echo "$_audit_json" | grep -q '"db_retention_days":30'
echo "  ✅ 版本 API（波次四 env · 可无历史版本）"
echo "✅ [copilot-wave4-verify] 全部通过"
