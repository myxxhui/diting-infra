# config/ 配置说明

本目录存放环境与部署配置。**拉代码后**按下列步骤即可完成配置并运行。

## 前置依赖（make deploy diting prod）

部署 Diting Stack 与数据库（PG/Redis/TimescaleDB）依赖 **yq** 解析 `diting-prod.yaml`。未安装时部署会报错并提示安装方式。

- **yq**：`apt install yq`（Debian/Ubuntu）或 `pip install yq` 或 [mikefarah/yq](https://github.com/mikefarah/yq#install)
- **helm**：由 deploy-engine 使用，需已安装
- **kubectl**：需在 PATH 中

## 云凭证（AKSK）

阿里云 Access Key / Secret Key **不要写进 config 目录任何文件**。推荐在 **diting-infra 根目录** 创建 `.env`（复制 `.env.template`），填写：

```bash
ALICLOUD_ACCESS_KEY=你的 AccessKey ID
ALICLOUD_SECRET_KEY=你的 AccessKey Secret
```

执行 `make deploy` / `make deploy diting prod` 时会自动加载该 `.env`。也可在当次终端中手动 `export ALICLOUD_ACCESS_KEY=...` 与 `ALICLOUD_SECRET_KEY=...`。还可使用阿里云 CLI 配置文件 `~/.alicloud/config.json`。详见 deploy-engine 文档。

## 端口与连接变量（固定暴露端口）

**单一来源**：`Makefile` 部署 Helm（TimescaleDB/L2）与 `scripts/prod-write-conn.sh` 写入 `prod.conn` 使用**同一套解析逻辑**，避免「集群 NodePort」与「连接串端口」不一致：

1. **L1/L2**：优先 `stack.databases.timescaledb.service.nodePort` / `stack.databases.postgres_l2.service.nodePort`；若未设则用顶层 **`ports.timescaledb`** / **`ports.postgres_l2`**；若仍未设则默认 **30432 / 30433**。  
2. **Redis**：优先 **`config/redis-values-prod.yaml`** 内 `master.service.nodePorts.redis`；若无该文件则回退 **`ports.redis`**（默认 **30379**）。

换环境时请将 **`diting-prod.yaml.example`**、**`redis-values-prod.yaml.example`** 复制为同名文件（去掉 `.example`）并按需修改端口与存储。

| 组件 | 环境 | 默认端口（未覆盖 stack/ports 时） | 说明 | 连接变量 / 用途 |
|------|------|------|------|------------------|
| TimescaleDB (L1) | 本地 Compose | 15432 | 映射容器 5432 | `TIMESCALE_DSN` host 端口 |
| PostgreSQL L2 | 本地 Compose | 15433 | 映射容器 5432 | `PG_L2_DSN` host 端口 |
| Redis | 本地 Compose | 15479 | 映射容器 6379 | `REDIS_URL` host 端口 |
| TimescaleDB (L1) | 远程 K3s NodePort | **30432**（可改为 stack 内 nodePort） | NodePort | `TIMESCALE_DSN` = `postgresql://…@<EIP>:<端口>/postgres` |
| PostgreSQL L2 | 远程 K3s NodePort | **30433**（可改为 stack 内 nodePort） | NodePort | `PG_L2_DSN` = `postgresql://…@<EIP>:<端口>/diting_l2` |
| Redis | 远程 K3s NodePort | **30379**（以 redis-values 为准） | NodePort | `REDIS_URL` = `redis://<EIP>:<端口>/0` |
| SSH | ECS 主机 | **22** | 安全组 / get-kubeconfig | 登录 ECS |
| K3s API | ECS 主机 | **6443** | 安全组 / kubeconfig server | `KUBECONFIG` 中 server 端口 |

- **修改端口**：改 `stack.databases.*.service.nodePort` 与/或顶层 `ports.*`，并同步 **`redis-values-prod.yaml`**；勿在 Makefile 中写死。
- **prod.conn**：Up 后由 `scripts/prod-write-conn.sh` 生成，含 `TIMESCALE_DSN`、`PG_L2_DSN`、`REDIS_URL`、`KUBECONFIG`、`PUBLIC_IP`（EIP + 上表 NodePort）。

## 应用侧环境变量（diting-src）

应用连接 L1/L2/Redis 等由 **diting-src** 的 `.env` 控制，**勿在本目录存放 .env**。

- 到 **diting-src** 仓库：`cp .env.template .env`，填写 `TIMESCALE_DSN`、`PG_L2_DSN`、`REDIS_URL` 等（完整键见 diting-src 根目录 `.env.template` 与 README「环境变量」小节）。**远程 K3s** 时 host 为 EIP、端口见上表 NodePort。

## Terraform 变量（tfvars）

- **dev**：可参考 `terraform-diting-dev.tfvars`（若需本地覆盖，复制后修改，注意勿提交含真实密码的文件）。
- **prod**：
  - **勿将含 `instance_password` 的 prod tfvars 提交到远程。**
  - 复制 `terraform-diting-prod.tfvars.example` 为 `terraform-diting-prod.tfvars`，在本地填写；
  - 密码请用环境变量注入：`export TF_VAR_instance_password='你的密码'`，再执行 `make deploy diting prod`。
  - `config/terraform-diting-prod.tfvars` 已加入 .gitignore，仅存在于本地。

## OSS 桶（K3s 初始化脚本）

- **当前 prod/dev 使用的桶**：tfvars 中 `oss_bucket_name`（示例与默认均为 **`deploy-engine-k3s-storage`**）。
- 脚本对象：`scripts/k3s-init.sh`；下载 URL 形如：`https://deploy-engine-k3s-storage.oss-<region>.aliyuncs.com/scripts/k3s-init.sh`。
- 若报「OSS 初始化脚本上传失败」，多半是 **同一次 Terraform apply 里** VPC/NAS 报错导致整次 apply 失败，而不是桶权限问题。请看下方「故障排查」。

## 故障排查（Terraform state 与 NAS）

若 `make deploy diting prod` 报 **「OSS 初始化脚本上传失败」**，且终端里有：

- **IncorrectVSwitchId / 404**：state 里的 vSwitch 在云上已不存在或属错误地域（例如曾在北京区创建）。
- **InvalidAccessGroup.AlreadyExisted**：要创建的 NAS Access Group 在云上已存在。

在 **diting-infra 根目录** 执行一次性修复后重试部署：

```bash
make fix-terraform-state-diting-prod
make deploy diting prod
```

修复会从 state **删除** VPC、vSwitch 的旧记录（不删云上资源，只清 state），下次 deploy 会按 tfvars 中的 `region` 在正确地域重新创建。prod 数据盘与 deploy 的 `region` 均从 **tfvars 读取并显式传入**，避免被环境变量覆盖。

**复用 NAS 文件系统时**：若该 NAS 此前由 Terraform 创建且仍在 state 中，必须先执行  
`cd deploy-engine/deploy/terraform/alicloud && terraform state rm 'module.nas.alicloud_nas_file_system.main[0]'`  
再在 tfvars 中设置 `nas_use_existing_file_system = true` 和 `nas_existing_file_system_id`。否则 Terraform 会先**销毁**该文件系统再“复用”，导致云上 NAS 被删、后续挂载点报 InvalidFileSystem.NotFound。

**复用安全组时 SSH/6443 连不上**：若子模块未更新，复用安全组时 Terraform 不会自动添加 SSH(22)/K8s API(6443) 规则，会导致 SSH 或 `kubectl`/local-path 部署超时。处理方式：
- **推荐**：在 diting-infra 执行 `make update-deploy-engine` 拉取已含“复用安全组时也管理 22/6443 规则”的 deploy-engine，再执行一次 `make deploy diting prod`（或先 `terraform apply` 再继续），使安全组规则生效。
- **临时**：在阿里云控制台为该安全组入方向手动添加 TCP 22、6443，授权对象为执行 deploy 机器的公网 IP/32 或 `0.0.0.0/0`。

若导入 NAS 时报「找不到资源」，说明云上可能是旧名 `deploy-engine_nas_group_prod`。在 `config/terraform-diting-prod.tfvars` 中增加：

```hcl
nas_use_existing_access_group = true
nas_existing_access_group_name = "deploy-engine_nas_group_prod"
```

再执行 `make deploy diting prod`。

## 配置文件与示例（换环境可复制）

| 正式文件（勿提交密钥） | 示例模板（可提交 Git） |
|------------------------|-------------------------|
| `diting-prod.yaml` | **`diting-prod.yaml.example`** |
| `terraform-diting-prod.tfvars`（已在 .gitignore） | **`terraform-diting-prod.tfvars.example`** |
| `redis-values-prod.yaml` | **`redis-values-prod.yaml.example`** |
| `deploy.yaml` | 见文件头注释；与 **deploy-engine** 示例一致时可参考 `deploy-engine/config/deploy.yaml` |

拉代码后：复制 `.example` 为正式文件名，按注释填写；**prod** 的 Terraform 变量务必复制 **terraform-diting-prod.tfvars.example** → **terraform-diting-prod.tfvars**。

## 其他

- **diting-prod.yaml**：生产部署配置。是否安装 TimescaleDB / PostgreSQL L2 / Redis 由 **deploy_control**（`enable_timescaledb`、`enable_postgres_l2`、`enable_redis`）控制；**端口**见上文「单一来源」。**数据继承与静态存储**：`stack.storage`、`stack.databases`，Chart 见 `charts/diting-stack`。采集 Job、`data_ingestion` 键说明见 **`diting-prod.yaml.example`** 与文档仓 [06_生产级数据要求_实践](../../diting-doc/04_阶段规划与实践/Stage2_数据采集与存储/06_生产级数据要求_实践.md)。
- **diting-dev.yaml**：本仓未随附时，可参考 **deploy-engine** 的 `config/myapp-dev.yaml` 或从 **`diting-prod.yaml.example`** 精简出 dev 专用配置。
- **deploy.yaml**：deploy-engine 入口配置（本仓 `config/deploy.yaml` 为占位示例，可按项目改名或覆盖）。
