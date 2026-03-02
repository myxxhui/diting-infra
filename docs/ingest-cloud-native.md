# 采集模块云原生方案（生产环境）

## 目标

在生产环境（K3s 集群）内用 **Kubernetes Job/CronJob + 镜像** 跑数据采集，不再依赖本机 `REPO_I_ROOT` 与 `make -C diting-core ingest-test`。

## 原则

| 原则 | 做法 |
|------|------|
| **集群内运行** | 采集在 K8s 内以 Job/CronJob 运行，与 TimescaleDB / PostgreSQL L2 / Redis 同集群，走 Service DNS，无需 NodePort/EIP。 |
| **配置外置** | 连接串、密码由 ConfigMap/Secret 注入，不写进镜像、不依赖 .env 文件。 |
| **镜像可复现** | 由 CI 构建 `diting-ingest` 镜像并推送 registry，部署时只引用镜像 tag。 |
| **可观测** | 日志 stdout，便于集群日志采集；Job 设置 `backoffLimit`、CronJob 可配 `successfulJobsHistoryLimit`。 |
| **资源可控** | 为 Job 设置 `resources.requests/limits`，避免占满节点。 |

## 架构示意

```
                    ┌─────────────────────────────────────────┐
                    │  K3s 集群 (default namespace)            │
  ┌──────────────┐  │  ┌─────────────┐  ┌──────────────────┐  │
  │ 镜像仓库     │  │  │ diting-     │  │ timescaledb-     │  │
  │ diting-      │──┼─▶│ ingest Job  │─▶│ primary :5432    │  │
  │ ingest:tag   │  │  │ (一次性/     │  │ postgresql-l2-   │  │
  └──────────────┘  │  │ 或 CronJob) │  │ primary :5432    │  │
                    │  └──────┬──────┘  │ redis-master:6379│  │
                    │         │         └──────────────────┘  │
                    │         │  env from Secret/ConfigMap    │
                    │         ▼  (TIMESCALE_DSN, PG_L2_DSN,   │
                    │  ┌──────────────┐  REDIS_URL)            │
                    │  │ ingest-conn  │                        │
                    │  │ Secret       │                        │
                    │  └──────────────┘                        │
                    └─────────────────────────────────────────┘
```

## 连接方式：集群内 Service DNS

Job 在集群内，直接使用 K8s Service 名，无需公网 IP / NodePort：

| 组件 | 集群内地址（示例） |
|------|---------------------|
| TimescaleDB | `timescaledb-primary.default.svc.cluster.local:5432` |
| PostgreSQL L2 | `postgresql-l2-primary.default.svc.cluster.local:5432` |
| Redis | `redis-master.default.svc.cluster.local:6379` |

与 `prod.conn` 的「EIP + NodePort」方式互补：prod.conn 用于**集群外**（本机/CI）访问；Job 用**集群内** DNS。

## 部署时检查：全量 vs 增量（当前策略）

**每次部署**（Helm post-install/post-upgrade）触发一次 Job，执行 `make ingest-deploy`：

- 脚本 `diting-core/scripts/run_ingest_deploy.py` 连接 L1，检查 `ohlcv` 表是否存在、是否有数据、`MAX(datetime)` 是否在阈值内。
- **无数据或超过 N 天未更新**（默认 7 天，可配 `INGEST_DEPLOY_FULL_DAYS_THRESHOLD` / values `ingest.fullDaysThreshold`）→ 执行**全量**（`run_ingest_production.py`）。
- **有数据且未过期** → 执行**增量**（当前用 `run_ingest_test.py` 做轻量刷新；后续可替换为真实增量逻辑）。

无需单独 CronJob 或常驻 Pod，部署即检查并补齐数据。

## 推荐形态

1. **部署后一次性采集（当前实现）**  
   - 使用 **Job**：部署完 K3s + 数据库后，由 Makefile/Helm hook 或流水线创建一次 Job，跑 `ingest-test` 或 `ingest-production`。  
   - 镜像：`diting-ingest:<tag>`，入口保持 `make ingest-test` 或直接 `python scripts/run_ingest_test.py`（环境变量由 K8s 注入）。

2. **周期采集（生产稳定后）**  
   - 使用 **CronJob**：例如每日 18:00 跑 `ingest-production`，用同一镜像，通过 env 或 args 区分 ingest-test / ingest-production。

## 与现有流程的关系

- **保留**：`REPO_I_ROOT` + 本机 `make ingest-test` 仍可用于**本地/CI 验证**或未上 K8s 的环境。  
- **生产**：部署完成后由 **Job/CronJob + 镜像** 在集群内执行采集，不再依赖本机 diting-core 目录；`data_ingestion.enabled` 可仅控制「是否创建/调度该 Job 或 CronJob」。

## 实现清单（diting-infra）

- [ ] 在 diting-stack 或独立 chart 中增加 **Ingest Job** 模板（及可选 CronJob）。
- [ ] 用 **Secret** 存 `TIMESCALE_DSN`、`PG_L2_DSN`、`REDIS_URL`（或从 values 生成），Job 通过 `envFrom` 或 `env` 引用。
- [ ] 镜像地址与 tag 可配置（values 或 diting-prod.yaml），默认可用 `diting-ingest:test`，生产建议带 tag。
- [ ] Makefile：部署完数据库后 `helm upgrade` 带上 ingest 相关 values，或单独 `kubectl apply -f` Job（若未用 Helm 管理 Job）。
- [ ] （可选）CI 在 diting-core 内构建并推送 `diting-ingest:$SHA`，部署时传入该 tag。

详见 `charts/diting-stack/templates/ingest/` 下 Job 与 Secret 模板。

## 首次部署顺序建议

1. 部署 diting-stack（仅存储 + init），再部署 timescaledb / postgresql-l2 / redis。
2. 等数据库 Pod 就绪后，再启用采集 Job：
   - 方式 A：`helm upgrade diting-stack ./charts/diting-stack -n default -f config/diting-prod.yaml --set stack.ingest.enabled=true`（若 stack 从 diting-prod 传 values，需在 diting-prod.yaml 中设 `stack.ingest.enabled: true`）。
   - 方式 B：不启用 hook，部署完成后在 Makefile 里用 `kubectl apply -f charts/diting-stack/templates/ingest/job.yaml`（需先渲染出 YAML）或单独一条 `helm upgrade ... --set ingest.enabled=true`。
3. 镜像需集群可拉取：单节点可 `docker save | ssh node docker load`，或 CI 构建推送到镜像仓库并在 values 中写完整 image 地址。
