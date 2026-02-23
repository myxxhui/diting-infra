# Stage2-01 基础设施与依赖部署 — 部署与验证说明

> 实践文档：diting-doc 中 `04_阶段规划与实践/Stage2_数据采集与存储/01_基础设施与依赖部署.md`  
> DNA：`dna_stage2_01`，工作目录：**diting-infra**

## 前置输入

| 变量 | 说明 |
|------|------|
| **REPO_A_ROOT** | diting-infra 仓库路径（本仓） |
| **KUBECONFIG** | 已就绪的 K3s 集群（如 Stage1-03/04 产出） |
| **REPO_I_ROOT** | diting-core 路径（V7 下游验证时必填） |

## 1. Chart 与版本（V1）

- Chart 已缓存于 `charts/dependencies/`：**timescaledb**（0.33.2）、**redis**（18.0.0）、**postgresql**（13.2.0）、**sealed-secrets**（已有）。
- 镜像 tag 通过 `charts/values/values-*.yaml` 固定，禁止 `latest`。
- **校验**：`test -d charts/dependencies/timescaledb && grep -E '^version:' charts/dependencies/timescaledb/Chart.yaml`（redis、postgresql 同理）。

## 2. 部署中间件（V2～V4）

在 KUBECONFIG 已设置、集群可用的前提下，从 **diting-infra 根目录** 使用本地 Chart 部署（示例，namespace 以实际为准，如 `default`）：

```bash
# TimescaleDB（示例：release 名 timescaledb，namespace default）
helm upgrade --install timescaledb charts/dependencies/timescaledb \
  -n default -f charts/values/values-timescaledb.yaml \
  --set secrets.credentials.PATRONI_SUPERUSER_PASSWORD="your-secure-password" \
  --set replicaCount=1

# Redis
helm upgrade --install redis charts/dependencies/redis \
  -n default -f charts/values/values-redis.yaml \
  --set auth.password="your-redis-password"

# PostgreSQL (L2)
helm upgrade --install postgresql-l2 charts/dependencies/postgresql \
  -n default -f charts/values/values-postgresql-l2.yaml \
  --set auth.password="your-pg-password" --set auth.database=diting_l2
```

暴露 NodePort 或 Ingress 后，本地可用 `TIMESCALE_DSN`、`REDIS_URL`、`PG_L2_DSN` 连接。

## 3. Schema init Job（V5）

- 建表脚本：`schemas/sql/01_l1_ohlcv.sql`（TimescaleDB）、`schemas/sql/02_l2_data_versions.sql`（L2 PostgreSQL）。
- 创建 ConfigMap 并运行 Job：见 **jobs/README.md**。
- 需先提供 Secret **diting-db-connection**（键 `TIMESCALE_DSN`、`PG_L2_DSN`），可由 Sealed-Secrets 注入。

## 4. Sealed-Secrets（V6）

- 控制器部署于 kube-system（或项目约定 namespace）；Stage1-04 已就绪。
- 验收：`kubectl get pods -n kube-system -l app.kubernetes.io/name=sealed-secrets`；部署示例 SealedSecret 后确认 Secret 可解密。

## 5. 下游连接与 V7

- **配置位置**：diting-core 的 `.env.template` 已注明 `TIMESCALE_DSN`、`REDIS_URL`、`PG_L2_DSN`；复制为 `.env` 后填写与 diting-infra 部署对应的连接串。
- **验证命令**：在 **diting-core** 根目录执行 `make verify-db-connection`（连接 TimescaleDB，执行 `SELECT 1` 并检查 `ohlcv` 表存在）；退出码 0 表示 V7 通过。

## 验证项汇总

| 项 | 验证方式 |
|----|----------|
| V1 | Chart 在 charts/dependencies/ 下，version 与 DNA 一致；values 中镜像 tag 固定 |
| V2 | TimescaleDB Pod Running；psql $TIMESCALE_DSN -c 'SELECT 1' 成功 |
| V3 | Redis Pod Running；redis-cli -u $REDIS_URL PING 返回 PONG |
| V4 | PostgreSQL Pod Running；psql $PG_L2_DSN -c 'SELECT 1' 成功 |
| V5 | Job diting-schema-init 完成；约定表存在且可查 |
| V6 | Sealed-Secrets 控制器 Running；示例 Secret 可解密 |
| V7 | 在 diting-core 配置连接并执行 make verify-db-connection，退出码 0 |

全部符合后方可准出，并更新 L5 验收标准（diting-doc `05_成功标识与验证/02_验收标准.md` 锚点 l5-stage-stage2_01）。

---

## 清除验证环境（必做）

**清除验证环境 = K3s 上的本步资源 + ECS 集群本身。无论验证是否完成、是否通过，本步结束后均须执行，避免残留资源与费用。**

在 **diting-infra 根目录** 执行：

```bash
# 方式一：使用 Make（推荐）— 先清 K3s 再回收 ECS
make stage2-01-down   # 卸载本步中间件、Job、ConfigMap
make down             # 回收 ECS/K3s（deploy-engine）

# 方式二：一条命令完成 K3s + ECS 清理
make stage2-01-full-down
```

**分步说明**：

| 顺序 | 动作 | 说明 |
|------|------|------|
| 1 | `make stage2-01-down` | 卸载 timescaledb、redis、postgresql-l2 release；删除 Job、ConfigMap（namespace 与部署时一致，默认 default） |
| 2 | `make down` | 调用 deploy-engine 回收 ECS 与 K3s 集群（与 Stage1-03 一致；FULL_DESTROY=1 可完整销毁） |

若仅做仓内产出、未真正起过集群，则无需执行 `make down`；只要起过 ECS/K3s，**必须**执行 `make down` 回收。

**说明**：Sealed-Secrets 控制器随 K3s 一起在 `make down` 时回收；若集群长期保留仅做本步中间件清理，执行 `make stage2-01-down` 即可。
