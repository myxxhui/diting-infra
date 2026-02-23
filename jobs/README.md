# Stage2-01 Schema init Job

建表脚本位于 **schemas/sql/**，由本 Job 在集群内执行；严禁在应用代码中执行 DDL。

## 前置条件

- TimescaleDB、PostgreSQL (L2) 已部署并可用
- Secret **diting-db-connection** 已存在且包含：
  - `TIMESCALE_DSN`：TimescaleDB 连接串（如 `postgresql://user:pass@timescaledb-svc:5432/dbname`）
  - `PG_L2_DSN`：L2 PostgreSQL 连接串

Secret 可由 Sealed-Secrets 提供（明文 Secret 经 kubeseal 加密后提交到 secrets/）。

## 创建 ConfigMap 并运行 Job

在 **diting-infra 根目录**执行：

```bash
# 从 schemas/sql 与 jobs/ 创建 ConfigMap（包含 SQL 与 run-schema-init.sh）
kubectl create configmap diting-schema-init-sql \
  --from-file=schemas/sql/01_l1_ohlcv.sql \
  --from-file=schemas/sql/02_l2_data_versions.sql \
  --from-file=run-schema-init.sh=jobs/run-schema-init.sh \
  -n default --dry-run=client -o yaml | kubectl apply -f -

# 部署并运行 Job
kubectl apply -f jobs/schema-init-job.yaml -n default

# 查看 Job 状态
kubectl get jobs diting-schema-init -n default
kubectl logs job/diting-schema-init -n default -f
```

## 验证

- Job 完成：`kubectl get jobs diting-schema-init` 中 COMPLETIONS 为 1/1
- 表存在：`psql $TIMESCALE_DSN -c "\dt"` 可见 `ohlcv`；`psql $PG_L2_DSN -c "\dt"` 可见 `data_versions`

## 清理

验证结束后（无论是否通过）须清除验证环境（K3s + ECS），避免残留与计费。在 **diting-infra 根目录** 执行：`make stage2-01-down`（仅 K3s 本步资源）后执行 `make down`（回收 ECS/K3s），或直接 `make stage2-01-full-down`。详见 `docs/Stage2-01-部署与验证.md` 中「清除验证环境（必做）」。
