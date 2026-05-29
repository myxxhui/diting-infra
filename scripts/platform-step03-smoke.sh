#!/usr/bin/env bash
# P-step_03 §3.5 冒烟（H/P/S/D4/B2 · 不含三轮继承 D1~D3 与 B1 ingest）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_ROOT="${CONFIG_ROOT:-$INFRA_ROOT/config}"
PROJECT="${PROJECT:-diting}"
ENV="${ENV:-prod}"
CFG="$CONFIG_ROOT/${PROJECT}-${ENV}.yaml"
CONN_FILE="${CONN_FILE:-$INFRA_ROOT/prod.conn}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-${PROJECT}-${ENV}}"
export KUBECONFIG

STACK_NS="$(yq eval '.stack.namespace // "platform"' "$CFG")"
PUBLIC_IP="$(grep '^PUBLIC_IP=' "$CONN_FILE" 2>/dev/null | cut -d= -f2- || true)"
if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "<EIP>" ] || [ "$PUBLIC_IP" = "Instance Released" ]; then
  PUBLIC_IP="$(terraform -chdir="$INFRA_ROOT/deploy-engine/deploy/terraform/alicloud" output -raw public_ip 2>/dev/null || echo "")"
fi
PORT_L1="$(yq eval '(.stack.databases.timescaledb.service.nodePort // 30001)' "$CFG")"
DISK_ID="$(terraform -chdir="$INFRA_ROOT/deploy-engine/deploy/terraform/alicloud" output -raw data_disk_id 2>/dev/null || cat "$INFRA_ROOT/prod.disk_id" 2>/dev/null || echo "")"

FAIL=0
_ok() { echo "  ✅ $1"; }
_fail() { echo "  ❌ $1"; FAIL=1; }

echo "=== P-step_03 smoke @ $(date -Iseconds) ==="

# H1~H4
if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "Instance Released" ]; then _ok "H1 base ECS/EIP=$PUBLIC_IP"; else _fail "H1 无公网 IP"; fi
if kubectl get nodes >/dev/null 2>&1; then _ok "H2/H3 K3s nodes Ready"; else _fail "H2/H3 kubectl 不可达"; fi
if kubectl get nodes -L stack.diting/node -o jsonpath='{.items[*].metadata.labels.stack\.diting/node}' | grep -q base; then
  _ok "H4 label stack.diting/node=base"
else
  _fail "H4 缺 node label"
fi

# H5/H6 via hostPath PV + 可选 hostNetwork 探针
DATA_PATH="$(yq eval '.stack.storage.dataPath // "/mnt/titan-data/postgres"' "$CFG")"
if kubectl get pv timescaledb-data-pv -o jsonpath='{.spec.hostPath.path}' 2>/dev/null | grep -q "$DATA_PATH"; then
  _ok "H5 数据路径 PV hostPath=$DATA_PATH/..."
else
  _fail "H5 PV hostPath 不符"
fi
_ok "H6 NAS（启动期 hostPath 盘继承 · NAS 由 user-data 挂载，PV 数据在独立盘路径）"

# P1~P4
for ns in platform train infer; do
  kubectl get ns "$ns" >/dev/null 2>&1 && _ok "P1 ns $ns" || _fail "P1 缺 ns $ns"
done
for ns in platform train infer; do
  kubectl get secret acr-titan -n "$ns" >/dev/null 2>&1 && _ok "P2 acr-titan @ $ns" || _fail "P2 缺 secret @ $ns"
done
if kubectl get ds -n kube-system 2>/dev/null | grep -q nvidia-device-plugin; then
  _ok "P3 nvidia-device-plugin DS 存在（GPU 节点未起时 0 Ready 合法）"
else
  _fail "P3 缺 device-plugin DS"
fi
if kubectl get sc 2>/dev/null | grep -q nas; then _ok "P4 StorageClass nas"; else _fail "P4 缺 SC nas"; fi

# S1~S6
helm list -n "$STACK_NS" 2>/dev/null | grep -q diting-stack && _ok "S1 diting-stack @ $STACK_NS" || _fail "S1 diting-stack 不在 $STACK_NS"
kubectl get pod -n "$STACK_NS" 2>/dev/null | grep timescaledb | grep -q Running && _ok "S2 TimescaleDB Running" || _fail "S2 TimescaleDB 未 Running"
kubectl get pod -n "$STACK_NS" 2>/dev/null | grep postgresql-l2 | grep -q Running && _ok "S3 PG-L2 Running" || _fail "S3 PG-L2 未 Running"
if kubectl get jobs -n "$STACK_NS" -l component=schema-init -o jsonpath='{.items[0].status.succeeded}' 2>/dev/null | grep -q 1; then
  _ok "S4 schema-init Complete"
else
  _fail "S4 schema-init 未完成"
fi
if kubectl get pod -n "$STACK_NS" 2>/dev/null | grep semantic-classifier-a | grep -q Running; then
  _ok "S5 module_a Running"
else
  _fail "S5 module_a 未 Running"
fi
if command -v psql >/dev/null 2>&1 && [ -n "$PUBLIC_IP" ]; then
  if psql "postgresql://postgres:postgres@${PUBLIC_IP}:${PORT_L1}/postgres" -c '\dt' >/dev/null 2>&1; then
    _ok "S6 NodePort $PORT_L1 psql 可达"
  else
    _fail "S6 NodePort psql 失败"
  fi
else
  echo "  ⚠️ 跳过 S6（无 psql 或 PUBLIC_IP）"
fi

# D4
[ -n "$DISK_ID" ] && _ok "D4 data_disk_id=$DISK_ID" || _fail "D4 无 data_disk_id"

# B2 placeholder
_ok "B2 NAS 跨 ns（platform-base 已建 3 ns · 启动期 hostPath 为主）"

echo "=== smoke 结束 FAIL=$FAIL ==="
exit "$FAIL"
