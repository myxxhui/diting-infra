#!/usr/bin/env bash
# 根据 config/security-group-rules.yaml 为 prod 安全组添加入站规则（NodePort 等）
# 用法：在 diting-infra 根目录执行 scripts/apply-security-group-rules.sh 或 make apply-security-group-rules
# 依赖：aliyun CLI、yq；若未安装 aliyun CLI 则仅打印说明并退出 0（不阻断部署）
# [Ref: docs/安全组规则说明.md]

set -e
INFRA_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG_FILE="${INFRA_ROOT}/config/security-group-rules.yaml"
TF_DIR="${INFRA_ROOT}/deploy-engine/deploy/terraform/alicloud"
REGION="${REGION:-$(yq eval '.region // "cn-hongkong"' "$INFRA_ROOT/config/security-group-rules.yaml" 2>/dev/null)}"
REGION="${REGION:-cn-hongkong}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[apply-security-group-rules] 未找到 $CONFIG_FILE，跳过"
  exit 0
fi

if ! command -v yq &>/dev/null; then
  echo "[apply-security-group-rules] 未安装 yq，跳过规则应用；请根据 config/security-group-rules.yaml 在控制台放通端口"
  exit 0
fi

SG_ID=""
if [ -d "$TF_DIR" ]; then
  SG_ID=$(cd "$TF_DIR" && terraform output -raw security_group_id 2>/dev/null || true)
fi
if [ -z "$SG_ID" ] || [ "$SG_ID" = "" ]; then
  echo "[apply-security-group-rules] 无法从 deploy-engine 获取 security_group_id（未 apply 或 state 不存在），跳过"
  exit 0
fi

if ! command -v aliyun &>/dev/null; then
  echo "[apply-security-group-rules] 未安装 aliyun CLI，请根据 docs/安全组规则说明.md 在控制台放通以下端口："
  (yq eval '.inbound_rules[] | "  - \(.port) (\(.description))"' "$CONFIG_FILE" 2>/dev/null || yq '.inbound_rules[] | "  - \(.port) (\(.description))"' "$CONFIG_FILE" 2>/dev/null) || true
  exit 0
fi

# 读取规则并逐条添加（VPC 安全组使用 NicType=intranet）
count=0
rules_out=$(yq eval '.inbound_rules[] | "\(.port)|\(.cidr // "0.0.0.0/0")|\(.description)"' "$CONFIG_FILE" 2>/dev/null || yq '.inbound_rules[] | "\(.port)|\(.cidr)|\(.description)"' "$CONFIG_FILE" 2>/dev/null || true)
if [ -z "$rules_out" ]; then
  echo "[apply-security-group-rules] 无 inbound_rules 或 yq 解析失败，跳过"
  exit 0
fi
while IFS= read -r line; do
  [ -z "$line" ] && continue
  port=$(echo "$line" | cut -d'|' -f1 | tr -d ' ')
  cidr=$(echo "$line" | cut -d'|' -f2 | tr -d ' ')
  desc=$(echo "$line" | cut -d'|' -f3- | sed 's/^ *//')
  if [ -z "$port" ] || [ "$port" = "null" ]; then continue; fi
  if aliyun ecs AuthorizeSecurityGroup \
    --RegionId "$REGION" \
    --SecurityGroupId "$SG_ID" \
    --IpProtocol tcp \
    --PortRange "${port}/${port}" \
    --SourceCidrIp "${cidr:-0.0.0.0/0}" \
    --Priority 1 \
    --NicType intranet \
    --Description "$desc" 2>/dev/null; then
    echo "[apply-security-group-rules] 已添加规则: port $port -> $cidr ($desc)"
    count=$((count + 1))
  else
    echo "[apply-security-group-rules] 规则已存在或跳过: port $port ($desc)"
  fi
done <<< "$rules_out"

if [ "$count" -gt 0 ]; then
  echo "[apply-security-group-rules] 共添加 $count 条入站规则"
fi
exit 0
