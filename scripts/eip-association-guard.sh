#!/usr/bin/env bash
# EIP 关联守门：up-stack base 后核查 EIP 是否真绑到当前实例
#
# 背景：base ECS 多次销毁→重建后，alicloud_eip_association 在 terraform state 与
# 实际之间漂移，EIP 与新实例脱钩 → 6443/30001/30379 全部超时（已多次出现）。
#
# 用法：bash scripts/eip-association-guard.sh [STACK]
#   STACK 默认 base；仅对 base stack 守门（train/infer 不分配 EIP）
# 退出码：
#   0  无漂移或漂移已自动修复
#   1  阿里云查询/terraform 内部错误（非漂移）
#   2  漂移修复后仍不可达（需人工介入）
set -euo pipefail

STACK="${1:-base}"
[ "$STACK" = "base" ] || { echo "[guard] STACK=$STACK 不分配 EIP，跳过守门"; exit 0; }

INFRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$INFRA_ROOT/deploy-engine/deploy/terraform/alicloud"
TFVARS="$INFRA_ROOT/config/terraform-diting-prod.tfvars"
TARGET='module.ecs.alicloud_eip_association.stack["base"]'

echo "[guard] 检查 EIP 关联漂移 ..."
cd "$TF_DIR"

# terraform plan -detailed-exitcode：0=无变化 1=错误 2=有 diff
set +e
terraform plan -input=false -target="$TARGET" -var-file="$TFVARS" -detailed-exitcode -out=/tmp/eip-guard.plan >/tmp/eip-guard.out 2>&1
PLAN_EXIT=$?
set -e

case "$PLAN_EXIT" in
  0)
    echo "[guard] ✅ EIP 关联无漂移"
    rm -f /tmp/eip-guard.plan /tmp/eip-guard.out
    ;;
  2)
    echo "[guard] ⚠️ 检测到 EIP 关联漂移，自动 apply"
    terraform apply -input=false -auto-approve /tmp/eip-guard.plan
    echo "[guard] ✅ EIP 重新绑定完成"
    rm -f /tmp/eip-guard.plan
    ;;
  1|*)
    echo "[guard] ❌ terraform plan 失败 (exit=$PLAN_EXIT)"
    tail -20 /tmp/eip-guard.out
    exit 1
    ;;
esac

# 端口可达性复验（base ECS 关键端口）
PUBLIC_IP="$(terraform output -raw public_ip 2>/dev/null || echo '')"
[ -z "$PUBLIC_IP" ] && { echo "[guard] ⚠️ 无 public_ip 输出，跳过端口复验"; exit 0; }
echo "[guard] 端口复验 $PUBLIC_IP ..."
unreach=0
for port in 6443 22; do
  if nc -z -w 5 "$PUBLIC_IP" "$port" >/dev/null 2>&1; then
    echo "  ✅ $port open"
  else
    echo "  ❌ $port timeout"
    unreach=$((unreach + 1))
  fi
done
if [ "$unreach" -gt 0 ]; then
  echo "[guard] ⚠️ 修复后仍有端口不可达；可能 ECS 仍在启动中或安全组异常"
  exit 2
fi
echo "[guard] ✅ 端口复验通过"
