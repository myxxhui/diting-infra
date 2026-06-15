#!/usr/bin/env bash
# 新机器 / 换目录拉仓后：make deploy diting prod 前置检查
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$INFRA_ROOT"

ERR=0
warn() { echo "⚠️  $*"; }
fail() { echo "❌ $*"; ERR=1; }
ok() { echo "✅ $*"; }

echo "=== diting-infra 部署前置检查（make deploy diting prod）==="
echo "工作目录: $INFRA_ROOT"
echo ""

# 子模块
if [ ! -f deploy-engine/Makefile ] || [ ! -d deploy-engine/deploy/terraform/alicloud ]; then
  fail "deploy-engine 子模块未就绪 · 请执行: git submodule update --init --remote deploy-engine"
else
  ok "deploy-engine 子模块已初始化"
fi

# 本地配置（不随 Git 带走）
if [ ! -f .env ]; then
  fail "缺少 .env · 请执行: make init-local-config 后填写 ALICLOUD_ACCESS_KEY / ALICLOUD_SECRET_KEY / TF_VAR_instance_password"
else
  # shellcheck disable=SC1091
  set -a; source .env 2>/dev/null || true; set +a
  if [ -z "${ALICLOUD_ACCESS_KEY:-}" ] || [ -z "${ALICLOUD_SECRET_KEY:-}" ]; then
    fail ".env 缺少 ALICLOUD_ACCESS_KEY 或 ALICLOUD_SECRET_KEY"
  else
    ok "阿里云 AK/SK 已在 .env 配置"
  fi
  if [ -z "${TF_VAR_instance_password:-}" ]; then
    fail ".env 缺少 TF_VAR_instance_password（ECS root 密码，≥8 位）"
  else
    ok "TF_VAR_instance_password 已配置"
  fi
fi

PROD_TFVARS="config/terraform-diting-prod.tfvars"
SG_TFVARS="config/terraform-diting-sg-proxy.tfvars"
if [ ! -f "$PROD_TFVARS" ]; then
  fail "缺少 $PROD_TFVARS · 请执行: cp config/terraform-diting-prod.tfvars.example $PROD_TFVARS"
else
  ok "香港 prod tfvars: $PROD_TFVARS"
fi
if [ ! -f "$SG_TFVARS" ]; then
  fail "缺少 $SG_TFVARS（新加坡代理栈）"
else
  ok "新加坡 sg-proxy tfvars: ${SG_TFVARS} (随仓提交, 同账号可复用 VPC/NAS ID)"
fi

for cmd in terraform helm kubectl yq nc; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "命令可用: $cmd"
  else
    fail "未找到 $cmd（部署/健康检查需要）"
  fi
done

if command -v aliyun >/dev/null 2>&1; then
  ok "aliyun CLI 可用（down 时孤儿 proxy ECS 回收更可靠）"
  # shellcheck disable=SC1091
  set -a; source .env 2>/dev/null || true; set +a
  _bal="$(aliyun bssopenapi QueryAccountBalance 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Data',{}).get('AvailableCashAmount',''))" 2>/dev/null || true)"
  if [ -n "$_bal" ]; then
    if python3 -c "import sys; sys.exit(0 if float('${_bal}') >= 100 else 1)"; then
      ok "阿里云可用余额 ${_bal} CNY（≥100，可创建按量 ECS）"
    else
      fail "阿里云可用余额 ${_bal} CNY 不足 100 · 充值后再 deploy（InvalidAccountStatus.NotEnoughBalance）"
    fi
  else
    warn "无法读取阿里云余额 · deploy 可能因 NotEnoughBalance 失败"
  fi
else
  warn "未安装 aliyun CLI · down-sg-anthropic-proxy 在 state 为空时可能无法回收云上孤儿实例"
fi

# 本地生成文件不应进 Git
if git ls-files --error-unmatch sg-proxy.conn >/dev/null 2>&1; then
  warn "sg-proxy.conn 仍被 Git 跟踪 · 应加入 .gitignore 并由部署脚本生成"
fi

echo ""
if [ "$ERR" -eq 0 ]; then
  echo "=== 检查通过 · 可执行: make deploy diting prod ==="
  echo "=== Spot 日常巡检（建议 cron 每 15 分钟）: make cluster-spot-watch CRON=1 ==="
  echo "=== 巡检报告邮件 → huishaoqi@126.com（读 diting-src/.env COPILOT_SMTP_*）==="
  echo "=== 交互式切换/恢复: make cluster-spot-watch INTERACTIVE=1 ==="
  exit 0
fi
echo "=== 检查未通过 · 请先修复上述项 ==="
exit 1
