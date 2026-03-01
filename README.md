# Diting Infrastructure

## 目录结构与职责

```
diting-infra/
├── charts/                    # Helm Charts 目录（基础设施组件）
│   └── diting-stack/         # 仅静态存储 Chart（PV/PVC + init-job）
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── templates/storage/
│       │   ├── timescaledb-pv.yaml
│       │   ├── timescaledb-pvc.yaml
│       │   ├── postgresql-l2-pv.yaml
│       │   ├── postgresql-l2-pvc.yaml
│       │   └── init-job.yaml
│       └── README.md
│
├── config/                    # 配置文件目录（环境配置、部署控制）
│   ├── README.md              # 配置说明（拉代码后必读）
│   ├── terraform-diting-prod.tfvars.example  # 生产 tfvars 示例（复制为 terraform-diting-prod.tfvars 后本地填写，勿提交含密码的 tfvars）
│   ├── diting-prod.yaml       # 部署控制配置（K3s、数据库）
│   └── ...
│
├── scripts/                   # 脚本目录（辅助工具、连接信息）
│   ├── prod-write-conn.sh    # 生成连接信息文件
│   └── local/                # 本地开发脚本
│
├── deploy-engine/            # Git 子模块（Terraform + K3s 部署引擎）
│   └── ...                   # 不要直接修改此目录！
│
├── compose/                  # Docker Compose 配置（本地开发）
│   └── docker-compose.ingest.yaml
│
├── Makefile                  # 主要部署入口
├── README.md                 # 本文件
└── prod.conn                 # 生产环境连接信息（自动生成）
```

## 目录职责说明

### 📦 charts/ - Helm Charts

**用途**：存放 Diting 项目的基础设施 Helm Charts

**规则**：
- ✅ **可以**：创建和修改 Diting 自有的 Charts（如 `diting-stack`）
- ✅ **可以**：添加项目特定的 Kubernetes 资源模板
- ❌ **不要**：在这里存放第三方 Charts（使用 Helm repo）
- ❌ **不要**：在这里存放应用代码或业务逻辑

**示例**：
- `diting-stack`：仅创建静态 PV/PVC 与目录初始化 Job，数据库由 Makefile 调用官方 Bitnami Chart 部署（配置见 `config/diting-prod.yaml`）
- 未来可能添加：`diting-monitoring`、`diting-ingress` 等

### ⚙️ config/ - 配置文件

**用途**：存放环境配置和部署控制文件

**规则**：
- ✅ **可以**：修改环境配置（如 `diting-prod.yaml`）
- ✅ **可以**：添加新环境的配置文件
- ✅ **可以**：修改 Terraform 变量（如 `terraform-diting-prod.tfvars`）
- ❌ **不要**：在这里存放 Kubernetes 资源定义（应放在 `charts/`）
- ❌ **不要**：在这里存放脚本（应放在 `scripts/`）

**文件类型**：
- `terraform-*.tfvars`：Terraform 变量（云资源配置）。**生产环境**：勿提交含 `instance_password` 的 `terraform-diting-prod.tfvars`，请复制 `terraform-diting-prod.tfvars.example` 为同名文件后本地填写，并用 `export TF_VAR_instance_password='...'` 注入密码（详见 `config/README.md`）。
- `*-prod.yaml`、`*-dev.yaml`：部署控制配置（K3s、数据库）

### 🔧 scripts/ - 脚本

**用途**：存放辅助脚本和工具

**规则**：
- ✅ **可以**：添加辅助脚本（如连接信息生成、数据迁移）
- ✅ **可以**：添加本地开发工具脚本
- ❌ **不要**：在这里存放核心部署逻辑（应在 Makefile 或 Charts）
- ❌ **不要**：在这里存放配置文件（应放在 `config/`）

**推荐实践**：
- 脚本应该是幂等的（多次执行结果一致）
- 脚本应该有清晰的错误处理和日志输出
- 脚本应该在 Makefile 中被调用，而不是直接执行

### 🚫 deploy-engine/ - Git 子模块（只读）

**用途**：Terraform + K3s 部署引擎（独立仓库）

**严格规则**：
- ❌ **禁止**：在 `diting-infra/deploy-engine/` 下修改任何文件
- ❌ **禁止**：在 `diting-infra/deploy-engine/` 下执行 `git add/commit/push`
- ❌ **禁止**：在 `diting-infra/deploy-engine/` 下执行 `git stash`
- ✅ **正确做法**：
  1. 到 **deploy-engine 独立仓库**（与 diting-infra 平级）修改
  2. 在 deploy-engine 独立仓库提交并推送
  3. 在 diting-infra 执行 `make update-deploy-engine` 更新子模块

**违规后果**：
- 污染子模块工作树
- 影响 `make update-deploy-engine` 或 `git pull`
- 导致子模块状态不一致

### 🐳 compose/ - Docker Compose

**用途**：本地开发环境配置

**规则**：
- ✅ **可以**：修改本地开发的 Docker Compose 配置
- ❌ **不要**：在这里存放生产环境配置

## 核心工作流

### 部署生产环境

```bash
# 1. 更新 deploy-engine 子模块
make update-deploy-engine

# 2. 部署（包含 Terraform、K3s、diting-stack 静态存储、官方 Chart 数据库）
make deploy diting prod

# 3. 验证
export KUBECONFIG="$HOME/.kube/config-diting-prod"
kubectl get pods -A
helm list -A
```

### 回收生产环境

```bash
# 仅回收 ECS/K3s/EIP，保留数据盘和静态 PVC
make down diting prod

# 完全销毁（包括 VPC/NAS/OSS）
FULL_DESTROY=1 make down diting prod
```

### 本地开发

```bash
# 启动本地数据库
make local-deps-up

# 初始化数据库
make local-deps-init

# 停止本地数据库
make local-deps-down
```

## 常见问题

### Q: 为什么静态 PV/PVC 要放在 Chart 中？

**A**: 
1. **声明式管理**：Helm Chart 提供声明式的资源管理，版本化、可追溯
2. **依赖顺序**：Helm 确保 PV/PVC 在数据库之前创建
3. **自动化**：通过 Helm Hooks 自动初始化目录权限
4. **标准化**：符合 Kubernetes 生态的最佳实践
5. **避免脚本泛滥**：不需要为每个环境写脚本

### Q: 为什么不把 PV/PVC 配置放在 config/ 下？

**A**:
- `config/` 用于**配置**（变量、参数）
- `charts/` 用于**资源定义**（Kubernetes 对象）
- PV/PVC 是 Kubernetes 资源，应该用 Helm Chart 管理

### Q: 如何修改 deploy-engine？

**A**:
```bash
# 错误做法 ❌
cd diting-infra/deploy-engine
vim some-file.go
git add .
git commit -m "fix"

# 正确做法 ✅
cd ../deploy-engine  # 独立仓库
vim some-file.go
git add .
git commit -m "fix"
git push

cd ../diting-infra
make update-deploy-engine
```

### Q: 如何添加新的静态存储？

**A**:
1. 在 `config/diting-prod.yaml` 的 `stack.storage` 下增加对应存储项（与 Chart values 同构）
2. 在 `charts/diting-stack/templates/storage/` 增加 PV/PVC 模板（可参考现有 timescaledb/postgresql-l2）
3. 执行 `make deploy diting prod` 或单独 `helm upgrade diting-stack ./charts/diting-stack -n default -f <(yq eval '{"storage": .stack.storage}' config/diting-prod.yaml)`

## 参考文档

- [Helm Chart 开发指南](https://helm.sh/docs/chart_template_guide/)
- [Kubernetes PV/PVC 文档](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [06_生产级数据要求_设计](../diting-doc/03_原子目标与规约/Stage2_数据采集与存储/06_生产级数据要求_设计.md)
- [系统规则_通用项目协议](../diting-doc/00_系统规则_通用项目协议.md)
