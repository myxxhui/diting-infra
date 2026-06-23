#!/usr/bin/env bash
# 部署非阻塞告警：写入 DEPLOY_WARNINGS_FILE，收尾由 prod-deploy-summary 统一汇总
# 用法: source deploy-warnings-lib.sh && deploy_warn "消息"
deploy_warn() {
  local msg="${1:-}"
  [ -n "$msg" ] || return 0
  echo "⚠️  $msg" >&2
  if [ -n "${DEPLOY_WARNINGS_FILE:-}" ]; then
    mkdir -p "$(dirname "$DEPLOY_WARNINGS_FILE")"
    printf '%s\n' "$msg" >> "$DEPLOY_WARNINGS_FILE"
  fi
}

deploy_warn_summary() {
  local f="${DEPLOY_WARNINGS_FILE:-}"
  if [ -z "$f" ] || [ ! -s "$f" ]; then
    return 0
  fi
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║              部署告警汇总（非阻塞 · 部署已继续完成）              ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  local i=1 line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    echo "  ${i}. ${line}"
    i=$((i + 1))
  done < "$f"
  echo ""
}
