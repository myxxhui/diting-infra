#!/usr/bin/env bash
# Copilot 标准部署入口 · 三档速度（rollout / push / full）
# 用法:
#   copilot-deploy.sh              # 默认 smart：ACR 有→rollout；本地有→push；否则 full build
#   copilot-deploy.sh rollout      # ~30s：仅 Helm+rollout（镜像已在 ACR）
#   copilot-deploy.sh push         # ~1–5min：本地已 build → push + Helm
#   copilot-deploy.sh full         # ~5–10min：强制 docker build + push + Helm
# 环境变量: COPILOT_IMAGE_TAG · COPILOT_WAIT_ROLLOUT=1 · EXECUTING_T0_BOOTSTRAP=1
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"

MODE="${1:-smart}"
SRC_ROOT="${SRC_ROOT:-$INFRA_ROOT/../diting-src}"
chmod +x "$SCRIPT_DIR"/copilot-*.sh "$SCRIPT_DIR"/executing-t0-bootstrap-sync.sh 2>/dev/null || true

export COPILOT_IMAGE_TAG="${COPILOT_IMAGE_TAG:-$(bash "$SCRIPT_DIR/copilot-resolve-image-tag.sh" "$SRC_ROOT")}"
echo "▶ [copilot-deploy] mode=${MODE} tag=${COPILOT_IMAGE_TAG}"

_t0_bootstrap() {
  if [ "${EXECUTING_T0_BOOTSTRAP:-0}" = "1" ]; then
    echo "▶ [copilot-deploy] executing T0 bootstrap（EXECUTING_T0_BOOTSTRAP=1）"
    bash "$SCRIPT_DIR/executing-t0-bootstrap-sync.sh"
  else
    echo "ℹ️  [copilot-deploy] 跳过 executing bootstrap（需补采时: EXECUTING_T0_BOOTSTRAP=1 make executing-t0-bootstrap-sync）"
  fi
}

_rollout_wait() {
  if [ "${COPILOT_WAIT_ROLLOUT:-1}" = "1" ]; then
    bash "$SCRIPT_DIR/copilot-rollout-wait.sh"
  fi
}

case "$MODE" in
  rollout|helm|fast)
    echo "▶ [copilot-deploy] 档位 A · rollout only（~30s）"
    bash "$SCRIPT_DIR/copilot-helm-upgrade.sh"
    _rollout_wait
    ;;
  push|push-only)
    echo "▶ [copilot-deploy] 档位 B · push local + helm（~1–5min）"
    bash "$SCRIPT_DIR/copilot-push-local-if-needed.sh" "$COPILOT_IMAGE_TAG" \
      || make -C "$INFRA_ROOT" copilot-build-push COPILOT_IMAGE_TAG="$COPILOT_IMAGE_TAG"
    bash "$SCRIPT_DIR/copilot-helm-upgrade.sh"
    _rollout_wait
    ;;
  full|build)
    echo "▶ [copilot-deploy] 档位 C · full build + push + helm（~5–10min）"
    make -C "$INFRA_ROOT" copilot-build-push COPILOT_IMAGE_TAG="$COPILOT_IMAGE_TAG"
    bash "$SCRIPT_DIR/copilot-helm-upgrade.sh"
    _rollout_wait
    ;;
  smart|"")
    if bash "$SCRIPT_DIR/copilot-acr-image-exists.sh" "$COPILOT_IMAGE_TAG"; then
      echo "▶ [copilot-deploy] smart→rollout（ACR 已有 ${COPILOT_IMAGE_TAG}）"
      bash "$SCRIPT_DIR/copilot-helm-upgrade.sh"
      _rollout_wait
    elif bash "$SCRIPT_DIR/copilot-push-local-if-needed.sh" "$COPILOT_IMAGE_TAG"; then
      echo "▶ [copilot-deploy] smart→push 完成"
      bash "$SCRIPT_DIR/copilot-helm-upgrade.sh"
      _rollout_wait
    else
      echo "▶ [copilot-deploy] smart→full build"
      make -C "$INFRA_ROOT" copilot-build-push COPILOT_IMAGE_TAG="$COPILOT_IMAGE_TAG"
      bash "$SCRIPT_DIR/copilot-helm-upgrade.sh"
      _rollout_wait
    fi
    ;;
  *)
    echo "用法: $0 [smart|rollout|push|full]" >&2
    exit 2
    ;;
esac

_t0_bootstrap
echo "✅ [copilot-deploy] 完成 · mode=${MODE} tag=${COPILOT_IMAGE_TAG}"
