# Stage2 本地实践（无 K3s 时）

> 部署与编排归属 **diting-infra**，与 diting-core 严格区分（见 diting-doc 02_三位一体仓库规约）。  
> 实践文档（L4）：diting-doc `04_阶段规划与实践/Stage2_数据采集与存储/`。

## 1. 在 diting-infra 启动本地 L1/L2

在 **diting-infra 根目录** 执行：

```bash
make local-deps-up
make local-deps-init
```

- **local-deps-up**：使用 `compose/docker-compose.ingest.yaml` 启动 L1（端口 15432）、L2（端口 15433）。
- **local-deps-init**：执行 `scripts/local/` 下建表脚本（ohlcv、data_versions）。  
  若报错「network not found」：部分环境（如 podman-compose）可能使用不同网络名，可执行  
  `COMPOSE_NETWORK=compose_default make local-deps-init`（以实际网络名为准）。

## 2. 在 diting-core 配置并验证

在 **diting-core 根目录**：

1. 复制 **diting-core** 的 `.env.template` 为 `.env`，填写必填三项（完整键见 diting-core 根目录 `.env.template`）：
   - `TIMESCALE_DSN=postgresql://postgres:postgres@localhost:15432/postgres`
   - `PG_L2_DSN=postgresql://postgres:postgres@localhost:15433/diting_l2`
   - `REDIS_URL=redis://localhost:15479/0`
2. 安装依赖（可选，若在镜像内验证则不需要）：`pip install -r requirements-ingest.txt`
3. 执行：
   ```bash
   make verify-db-connection
   make ingest-test
   ```

**外网不可达时**：可设置 `DITING_INGEST_MOCK=1` 再执行 `make ingest-test`，写入 mock 数据以完成 V-INGEST/V-DATA 验证。

## 3. V-DATA：确认目标数据

执行 diting-core 中约定的 5 条 psql 验证查询，将结果填入 L4 实践文档「目标数据约定与真实结果」表。  
查询说明与通过标准见 **diting-core**：`docs/ingest-test-target.md`。

## 4. 回收本地资源

在 **diting-infra 根目录** 执行：

```bash
make local-deps-down
```

---

**有 Stage2-01 集群（K3s）时**：在 diting-core 配置 `.env` 指向集群 NodePort 后，直接执行 `make verify-db-connection`、`make ingest-test` 即可；无需本地的 local-deps。
