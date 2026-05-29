#!/usr/bin/env bash
# P-step_03 三轮数据继承：INSERT marker → down-stack → deploy → SELECT marker
# 用法: ROUNDS=3 test-data-persistence.sh
set -euo pipefail

# 安全护栏：本测试每轮 down-stack + deploy 会销毁并重建生产 ECS，须显式确认
if [ "${CONFIRM_PERSIST_DESTROY:-}" != "yes" ]; then
  echo "❌ [test-data-persistence] 拒绝执行：本测试会 down-stack 并 destroy/recreate 生产 ECS"
  echo "   若确需在维护窗口验证数据盘继承，请显式："
  echo "   CONFIRM_PERSIST_DESTROY=yes ROUNDS=1 make platform-step03-test-persist"
  exit 1
fi

ROUNDS="${ROUNDS:-3}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_ROOT="${CONFIG_ROOT:-$INFRA_ROOT/config}"
PROJECT="${PROJECT:-diting}"
ENV="${ENV:-prod}"
CFG="$CONFIG_ROOT/${PROJECT}-${ENV}.yaml"
CONN_FILE="${CONN_FILE:-$INFRA_ROOT/prod.conn}"
PORT_L1="$(yq eval '(.stack.databases.timescaledb.service.nodePort // 30001)' "$CFG")"
PSQL="${PSQL:-$(command -v psql 2>/dev/null || true)}"
[ -z "$PSQL" ] && [ -x /opt/homebrew/opt/libpq/bin/psql ] && PSQL=/opt/homebrew/opt/libpq/bin/psql

_get_ip() {
  local ip conn_ip
  # redeploy 后 terraform 公网 IP 优先于 prod.conn（避免 conn 滞后导致连错 IP）
  ip="$(terraform -chdir="$INFRA_ROOT/deploy-engine/deploy/terraform/alicloud" output -raw public_ip 2>/dev/null || true)"
  if [ -n "$ip" ] && [ "$ip" != "Instance Released" ]; then
    echo "$ip"
    return 0
  fi
  conn_ip="$(grep '^PUBLIC_IP=' "$CONN_FILE" 2>/dev/null | cut -d= -f2- || true)"
  if [ -n "$conn_ip" ] && [ "$conn_ip" != "<EIP>" ] && [ "$conn_ip" != "Instance Released" ]; then
    echo "$conn_ip"
    return 0
  fi
  echo ""
}

_psql() {
  local ip="$1"
  "$PSQL" "postgresql://postgres:postgres@${ip}:${PORT_L1}/postgres" -v ON_ERROR_STOP=1 -c "$2"
}

_wait_k3s() {
  local ip="$1"
  echo "  等待 K3s @ $ip ..."
  for i in $(seq 1 90); do
    export KUBECONFIG="$HOME/.kube/config-${PROJECT}-${ENV}"
    if kubectl get nodes >/dev/null 2>&1; then
      echo "  K3s Ready (${i}*10s)"
      return 0
    fi
    sleep 10
  done
  echo "  ❌ K3s 超时"; return 1
}

_wait_db_ready() {
  local ip="$1"
  export KUBECONFIG="$HOME/.kube/config-${PROJECT}-${ENV}"
  local stack_ns
  stack_ns="$(yq eval '.stack.namespace // "platform"' "$CFG")"
  echo "  等待 TimescaleDB Pod Ready（instance=timescaledb）..."
  kubectl wait --for=condition=ready pod \
    -l app.kubernetes.io/instance=timescaledb,app.kubernetes.io/name=postgresql \
    -n "$stack_ns" --timeout=600s 2>/dev/null || true

  echo "  等待集群内 pg_isready ..."
  for i in $(seq 1 60); do
    if kubectl exec -n "$stack_ns" timescaledb-postgresql-0 -- pg_isready -U postgres >/dev/null 2>&1; then
      echo "  pg_isready OK (${i}*10s) ✅"
      break
    fi
    [ "$i" -eq 60 ] && { echo "  ❌ pg_isready 超时"; return 1; }
    sleep 10
  done

  echo "  等待 NodePort ${ip}:${PORT_L1} 外网 psql ..."
  local last_err=""
  for i in $(seq 1 36); do
    if last_err="$("$PSQL" "postgresql://postgres:postgres@${ip}:${PORT_L1}/postgres" -c "SELECT 1" 2>&1)"; then
      echo "  TimescaleDB 外网可连接 (${i}*10s) ✅"
      return 0
    fi
    if [ $((i % 6)) -eq 0 ]; then
      echo "  仍不可连 (${i}/36) · 最近错误: ${last_err:-unknown}"
    fi
    sleep 10
  done
  echo "  ❌ TimescaleDB 连接超时（ip=${ip} port=${PORT_L1}）"
  echo "  最近 psql 错误: ${last_err:-unknown}"
  return 1
}

_wait_marker() {
  local ip="$1" marker="$2" round="$3"
  for i in $(seq 1 36); do
    ROW="$("$PSQL" "postgresql://postgres:postgres@${ip}:${PORT_L1}/postgres" -tA -c \
      "SELECT marker FROM diting_persist_test WHERE marker='${marker}';" 2>/dev/null || true)"
    if [ "$ROW" = "$marker" ]; then
      echo "  D${round} SELECT marker 命中 (${i}*10s) ✅"
      return 0
    fi
    [ "$i" -lt 36 ] && echo "  等待 marker 可读 (${i}/36)..." && sleep 10
  done
  echo "  ❌ D${round} 数据丢失 marker=$marker"; return 1
}

command -v "$PSQL" >/dev/null 2>&1 || { echo "错误: 需要 psql（brew install libpq）"; exit 1; }

DISK_BEFORE="$(terraform -chdir="$INFRA_ROOT/deploy-engine/deploy/terraform/alicloud" output -raw data_disk_id 2>/dev/null || true)"
echo "[persist] 起始 data_disk_id=$DISK_BEFORE · ROUNDS=$ROUNDS"

for round in $(seq 1 "$ROUNDS"); do
  echo ""
  echo "========== 第 ${round}/${ROUNDS} 轮 =========="
  IP="$(_get_ip)"
  MARKER="persist_r${round}_$(date +%s)"
  _psql "$IP" "CREATE TABLE IF NOT EXISTS diting_persist_test (marker TEXT PRIMARY KEY, created_at TIMESTAMPTZ DEFAULT now());"
  _psql "$IP" "INSERT INTO diting_persist_test (marker) VALUES ('${MARKER}') ON CONFLICT DO NOTHING;"
  echo "  INSERT marker=$MARKER ✅"

  echo "  [down-stack diting-stack] ..."
  (cd "$INFRA_ROOT" && CONFIG_ROOT="$CONFIG_ROOT" make down-stack diting-stack)

  echo "  [deploy diting prod] 起 ECS + K3s + stack ..."
  (cd "$INFRA_ROOT" && CONFIG_ROOT="$CONFIG_ROOT" SKIP_INGEST=1 make deploy diting prod)

  IP="$(_get_ip)"
  _wait_k3s "$IP"
  CONFIG_ROOT="$CONFIG_ROOT" PROJECT="$PROJECT" ENV="$ENV" CONN_FILE="$CONN_FILE" \
    bash "$SCRIPT_DIR/platform-step03-deploy-stack.sh"
  IP="$(_get_ip)"
  _wait_db_ready "$IP"

  DISK_AFTER="$(terraform -chdir="$INFRA_ROOT/deploy-engine/deploy/terraform/alicloud" output -raw data_disk_id 2>/dev/null || true)"
  if [ "$DISK_BEFORE" = "$DISK_AFTER" ] && [ -n "$DISK_AFTER" ]; then
    echo "  D4 data_disk_id 不变: $DISK_AFTER ✅"
  else
    echo "  ❌ D4 disk_id 变化: before=$DISK_BEFORE after=$DISK_AFTER"; exit 1
  fi

  _wait_marker "$IP" "$MARKER" "$round" || exit 1
done

echo ""
echo "✅ [test-data-persistence] ${ROUNDS} 轮全部通过"
