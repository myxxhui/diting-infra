#!/usr/bin/env bash
# step_18 · 五区工作台 P0 生产部署 + HTTP 验收
# [Ref: 33_ §12 · diting-doc step_18]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"

echo "▶ [step18] 1/3 本机单测（diting-src copilot-step18-test）"
make -C "$INFRA_ROOT/../diting-src" copilot-step18-test

echo "▶ [step18] 2/3 Copilot 统一部署（smart · 跳过 Anthropic 代理探活若集群不可达）"
export COPILOT_SKIP_ANTHROPIC_PROBE="${COPILOT_SKIP_ANTHROPIC_PROBE:-1}"
make -C "$INFRA_ROOT" copilot-deploy

echo "▶ [step18] 3/3 生产 P0 HTTP 验收"
make -C "$INFRA_ROOT" copilot-step18-verify

echo "✅ [copilot-step18-prod-deploy] 五区工作台 P0 部署与验收完成"
