#!/usr/bin/env bash
# Stage2-06 生产数据环境后半部分：10 步按序执行，任一步失败则先回收环境再退出。
# 用法: INFRA=/path/to/diting-infra CORE=/path/to/diting-core [INGEST_IMAGE=registry/ns/diting-ingest:test] scripts/prod-run-phase2-steps.sh
# 要求: 本机可连通 prod（47.86.243.240:30432/30433/30379）；采集镜像已推送到集群可拉取的 registry 时设置 INGEST_IMAGE。
# [Ref: 06_生产级数据要求_实践]

set -e
INFRA="${INFRA:?请设置 INFRA 为 diting-infra 根目录}"
CORE="${CORE:?请设置 CORE 为 diting-core 根目录}"

# 可选：跳过前置连通性检查（SKIP_REACH_CHECK=1）
if [ "${SKIP_REACH_CHECK:-0}" != "1" ]; then
  echo "检查本机是否可连通 prod（prod.conn 中 PUBLIC_IP:30432）..."
  _host=$(grep -E '^TIMESCALE_DSN=' "$INFRA/prod.conn" 2>/dev/null | sed -n 's/.*@\([^:\/]*\):.*/\1/p')
  _port="${PROD_CHECK_PORT:-30432}"
  if [ -n "$_host" ] && (timeout 5 bash -c "echo >/dev/tcp/$_host/$_port" 2>/dev/null); then
    echo "  可连通 $_host:$_port，继续."
  else
    echo "  无法连通 prod ($_host:$_port)。请从可访问 prod 的机器执行，或推送采集镜像后设置 INGEST_IMAGE 并在 prod 节点执行。"
    echo "  若确需跳过此检查并继续（可能步骤 2 失败并触发回收），请设置 SKIP_REACH_CHECK=1"
    exit 1
  fi
fi

teardown() {
  echo "[回收环境] make down diting prod..."
  (cd "$INFRA" && make down diting prod) || true
}

cleanup_on_fail() {
  echo "[失败] 步骤 $1 未通过，执行回收环境后退出."
  teardown
  exit 1
}

echo "========== 步骤 1: 复制 prod.conn → diting-core/.env =========="
cp -f "$INFRA/prod.conn" "$CORE/.env" || cleanup_on_fail 1
echo "步骤 1 通过."

echo "========== 步骤 2: make verify diting prod =========="
(cd "$CORE" && make verify diting prod) || cleanup_on_fail 2
echo "步骤 2 通过."

echo "========== 步骤 3: 少量真实行情 K3s Job (ingest-test-real) =========="
(cd "$INFRA" && make deploy-ingest-job WAIT=wait) || cleanup_on_fail 3
echo "步骤 3 通过."

echo "========== 步骤 4: make verify-data-test =========="
(cd "$CORE" && make verify-data-test) || cleanup_on_fail 4
echo "步骤 4 通过."

echo "========== 步骤 5: make down diting prod（保留数据盘） =========="
(cd "$INFRA" && make down diting prod) || cleanup_on_fail 5
echo "步骤 5 通过."

echo "========== 步骤 6: make deploy diting prod（再次 Up） =========="
(cd "$INFRA" && make deploy diting prod) || cleanup_on_fail 6
echo "步骤 6 通过."

echo "========== 步骤 7: 数据继承验证 =========="
cp -f "$INFRA/prod.conn" "$CORE/.env"
(cd "$CORE" && make verify diting prod && make verify-data-test) || cleanup_on_fail 7
echo "步骤 7 通过."

echo "========== 步骤 8: 全量生产级采集 K3s Job (ingest-production) =========="
(cd "$INFRA" && make deploy-ingest-job INGEST_TARGET=ingest-production WAIT=wait) || cleanup_on_fail 8
echo "步骤 8 通过."

echo "========== 步骤 9: make verify-data-production =========="
(cd "$CORE" && make verify-data-production) || cleanup_on_fail 9
echo "步骤 9 通过."

echo "========== 步骤 10: 回收环境 =========="
teardown
echo "步骤 10 完成."
echo ""
echo "========== 全部 10 步验证通过 =========="
