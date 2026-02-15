# diting-infra

Chart 与配置，部署由 deploy-engine 执行。 [Ref: 02_三位一体仓库规约]

## 目录结构

- `charts/` - diting 项目 Helm Chart
- `config/` - 符合 deploy-engine 的 DeploymentConfig
- `observability/` - 监控配置（Prometheus/Grafana/Loki 等）
- `secrets/` - Sealed-Secrets 加密 YAML（不含明文密钥）

## deploy-engine

- **版本要求**：>= 0.1.0（见 global_const.trinity_repos.repo_a.deploy_engine_version）
- **调用方式**：在 diting-infra 目录下通过 deploy-engine CLI 或 `make deploy-dev` 完成 Up/Down
- **配置契约**：见 deploy-engine `pkg/config/spec.go` DeploymentConfig
