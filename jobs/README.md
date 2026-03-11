# Stage2-01 Schema init（云原生，由 Chart 管理）

建表由 **diting-stack Chart** 云原生实现：ConfigMap、Secret、Job 均在 `helm install/upgrade` 时创建或更新，无需单独脚本。

- **SQL 与脚本**：`charts/diting-stack/schema-init/`（ConfigMap `diting-schema-init-sql`）
- **连接串**：Chart 根据 `ingest.*` 生成 Secret `diting-db-connection`（集群内 DSN + sslmode=disable）
- **Job**：每次升级创建新 Job `diting-schema-init-<revision>`，不阻塞部署；Pod 内脚本会等待 DB 就绪再执行 SQL

## 前置条件

- `stack.schemaInit.enabled` 为 true（默认 true）
- 部署时传入的 values 包含 `ingest.timescaleHost`、`ingest.postgresL2Host` 等（与 `stack.ingest` / `stack.databases` 一致）
- TimescaleDB、PostgreSQL L2 由同一流程在 Stack 之后部署（Makefile 顺序：Stack → DBs）

## 查看建表 Job

```bash
kubectl get jobs -n default -l component=schema-init
kubectl logs job/diting-schema-init-<revision> -n default -f
```

## 验证

- Job 完成：对应 Job 的 COMPLETIONS 为 1/1
- 表存在：`psql $TIMESCALE_DSN -c "\dt"` 可见 `ohlcv`、`a_share_universe`；`psql $PG_L2_DSN -c "\dt"` 可见 `data_versions`、`industry_revenue_summary`

## 清理

验证结束后须清除验证环境。建表 Job 可通过标签删除：`kubectl delete job -n default -l component=schema-init`。详见 `docs/Stage2-01-部署与验证.md`。

## 本地一键建表 / 一键采集

若需在本机补充建表或本机执行采集写入生产库，见 **`docs/本地一键建表与采集.md`**。简要命令：

- **本地建表**：`make local-schema-init-prod`（需 `prod.conn`）
- **本地采集（测试集）**：`export REPO_I_ROOT=...; make local-ingest-prod`（约 15 标，快速验证）
- **本地采集（与集群一致，满足 Module A/B）**：`export REPO_I_ROOT=...; make local-ingest-deploy-prod`
- **本地生产全量（符合 AB 模块）**：`export REPO_I_ROOT=...; make local-ingest-production-prod`
- **本地生产全量 + 后台 + 日志**：`export REPO_I_ROOT=...; make local-ingest-production-prod-background`（日志默认 `ingest-production.log`，`tail -f` 看进度）
- **集群内采集（合上电脑也会继续）**：`make trigger-ingest`
