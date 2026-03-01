#!/usr/bin/env bash
# 将生产环境连接信息写入 prod.conn（make deploy diting prod 产出）
# 用法: prod-write-conn.sh <CONFIG_ROOT> <DEPLOY_ENGINE_DIR> <CONN_FILE> <PROJECT> <ENV>
# [Ref: 06_生产级数据要求_实践]

set -e
CONFIG_ROOT="${1:-$(pwd)/config}"
DEPLOY_ENGINE_DIR="${2:-deploy-engine}"
CONN_FILE="${3:-prod.conn}"
PROJECT="${4:-diting}"
ENV="${5:-prod}"

ENGINE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="${ENGINE_ROOT}/${DEPLOY_ENGINE_DIR}/deploy/terraform/alicloud"
STATE_FILE="${ENGINE_ROOT}/${DEPLOY_ENGINE_DIR}/.deploy/state-${PROJECT}-${ENV}.json"
KUBECONFIG_PATH="${HOME}/.kube/config-${PROJECT}-${ENV}"

PUBLIC_IP=""
if [ -d "$TF_DIR" ]; then
  # Terraform 使用 backend local，直接读取 terraform.tfstate
  PUBLIC_IP=$(cd "$TF_DIR" && terraform output -raw public_ip 2>/dev/null || true)
fi
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP="<EIP>"
fi

# Stage2-06 前半部分：独立数据盘 ID 持久化（Down 保留盘后再次 Up 时由 Make 注入 TF_VAR_use_existing_data_disk_id）
DISK_ID_FILE="${ENGINE_ROOT}/${ENV}.disk_id"
DATA_DISK_ID=""
if [ -d "$TF_DIR" ]; then
  DATA_DISK_ID=$(cd "$TF_DIR" && terraform output -raw data_disk_id 2>/dev/null || true)
fi
if [ -n "$DATA_DISK_ID" ] && [ "$DATA_DISK_ID" != "" ]; then
  printf '%s' "$DATA_DISK_ID" > "$DISK_ID_FILE"
  echo "[OK] $DISK_ID_FILE 已写入（data_disk_id）"
else
  # 保留已有 disk_id 文件（Down 后再次 Up 时需用）
  [ -f "$DISK_ID_FILE" ] && echo "[OK] 保留已有 $DISK_ID_FILE 供再次 Up 挂载同盘" || true
fi

# NodePort 默认值（TimescaleDB/L2 常用 30001/30002；需与 Helm values 一致）
NODEPORT_L1="${NODEPORT_L1:-30001}"
NODEPORT_L2="${NODEPORT_L2:-30002}"
NODEPORT_REDIS="${NODEPORT_REDIS:-30379}"

cat > "$CONN_FILE" << EOF
# 生产环境连接信息（自动生成；勿提交 Git）
# 来源: make deploy diting prod @ diting-infra
TIMESCALE_DSN=postgresql://postgres:postgres@${PUBLIC_IP}:${NODEPORT_L1}/postgres
PG_L2_DSN=postgresql://postgres:postgres@${PUBLIC_IP}:${NODEPORT_L2}/diting_l2
REDIS_URL=redis://${PUBLIC_IP}:${NODEPORT_REDIS}/0
KUBECONFIG=${KUBECONFIG_PATH}
PUBLIC_IP=${PUBLIC_IP}
EOF
echo "[OK] $CONN_FILE 已写入"
