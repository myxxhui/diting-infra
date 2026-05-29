#!/usr/bin/env bash
# 拉取 kubeconfig 并注册到 kubecm（不修改 deploy-engine 子模块）
# 用法: CONFIG_ROOT=... bash scripts/kubeconfig-fetch.sh prod diting
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV="${1:-prod}"
PROJECT="${2:-diting}"
export CONFIG_ROOT="${CONFIG_ROOT:-$INFRA_ROOT/config}"
[ -f "$INFRA_ROOT/.env" ] && set -a && source "$INFRA_ROOT/.env" && set +a
export TF_VAR_instance_password="${TF_VAR_instance_password:-${INSTANCE_PASSWORD:-}}"
export INSTANCE_PASSWORD="${INSTANCE_PASSWORD:-${TF_VAR_instance_password:-}}"

bash "$INFRA_ROOT/deploy-engine/deploy/scripts/get-kubeconfig.sh" "$ENV" "$PROJECT"
bash "$SCRIPT_DIR/kubecm-helpers.sh" add-and-switch "$PROJECT" "$ENV"
