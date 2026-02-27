# Stage2 本地 L1/L2（Docker Compose）

部署与编排归属 **diting-infra**，与 diting-core 严格区分（见 diting-doc 02_三位一体仓库规约）。

- **docker-compose.ingest.yaml**：本地 PostgreSQL 作为 L1/L2，端口 15432（L1）、15433（L2）。
- **启动/建表/回收**：在 **diting-infra 根目录** 执行 `make local-deps-up`、`make local-deps-init`、`make local-deps-down`；建表脚本见 `scripts/local/`。
- **diting-core**：仅配置 `.env` 指向 localhost:15432/15433 后执行 `make verify-db-connection`、`make ingest-test`。

**完整流程**（含 infra 与 core 步骤顺序）：见本仓 [docs/Stage2-本地实践.md](../docs/Stage2-本地实践.md)。
