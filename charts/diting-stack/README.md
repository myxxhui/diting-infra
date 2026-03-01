# Diting Stack Helm Chart（仅静态存储）

## 定位

本 Chart **只负责**为数据继承创建**静态 PV/PVC** 及**存储目录初始化 Job**，不部署数据库 workload。

- **存储**：TimescaleDB、PostgreSQL L2 使用的固定路径 PV/PVC（`ReclaimPolicy: Retain`），便于 Down 后再次 Up 挂载同盘、数据继承。
- **数据库**：由 `scripts/deploy-stack.sh` 使用**官方 Bitnami Chart**（`bitnami/postgresql`、`bitnami/redis`）部署，并引用本 Chart 创建的 PVC（`existingClaim`）。

## 目录结构

```
diting-stack/
├── Chart.yaml
├── values.yaml
├── README.md
└── templates/
    └── storage/           # 仅存储相关
        ├── timescaledb-pv.yaml
        ├── timescaledb-pvc.yaml
        ├── postgresql-l2-pv.yaml
        ├── postgresql-l2-pvc.yaml
        └── init-job.yaml   # hostPath 目录创建与权限
```

## 部署流程（Make 直接调用 Helm，无脚本）

1. **make deploy diting prod** 在 Makefile 中依次：
   - 用 `yq eval '{"storage": .stack.storage}' config/diting-prod.yaml` 生成 values，执行 `helm install/upgrade diting-stack`（仅静态 PV/PVC + init-job）。
   - 执行 `helm repo add/update bitnami`，再按配置对 timescaledb / postgresql-l2 / redis 分别执行 `helm upgrade --install ... bitnami/postgresql` 或 `bitnami/redis`，并通过 `--set primary.persistence.existingClaim=...` 引用本 Chart 创建的 PVC。

2. 配置来源：`config/diting-prod.yaml` 的 `stack.storage`、`stack.databases`，声明式驱动，无需额外脚本。

## 配置

与 Chart 同构的配置写在 `config/diting-prod.yaml` 的 `stack.storage` 下，例如：

```yaml
stack:
  storage:
    dataPath: /mnt/titan-data/postgres
    timescaledb:
      enabled: true
      pv: { name, capacity, subPath, reclaimPolicy }
      pvc: { name, namespace, accessMode, storageRequest }
    postgresL2:
      enabled: true
      pv: { ... }
      pvc: { ... }
```

## 卸载

- **make down diting prod** 会先卸载数据库 Release（timescaledb、postgresql-l2、redis），再删除 Redis 动态 PVC，最后卸载本 Chart。
- 静态 PV/PVC 在 Helm 卸载时会被删除；数据实际在数据盘 hostPath 上，再次 Up 时新集群会重新创建同名 PV/PVC 并挂载同盘，实现数据继承。
