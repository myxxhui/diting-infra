# config/ 配置说明

本目录存放环境与部署配置。**拉代码后**按下列步骤即可完成配置并运行。

## 应用侧环境变量（diting-core）

应用连接 L1/L2/Redis 等由 **diting-core** 的 `.env` 控制，**勿在本目录存放 .env**。

- 到 **diting-core** 仓库：`cp .env.template .env`，填写 `TIMESCALE_DSN`、`PG_L2_DSN`、`REDIS_URL` 等（完整键见 diting-core 根目录 `.env.template` 与 README「环境变量」小节）。

## Terraform 变量（tfvars）

- **dev**：可参考 `terraform-diting-dev.tfvars`（若需本地覆盖，复制后修改，注意勿提交含真实密码的文件）。
- **prod**：
  - **勿将含 `instance_password` 的 prod tfvars 提交到远程。**
  - 复制 `terraform-diting-prod.tfvars.example` 为 `terraform-diting-prod.tfvars`，在本地填写；
  - 密码请用环境变量注入：`export TF_VAR_instance_password='你的密码'`，再执行 `make deploy diting prod`。
  - `config/terraform-diting-prod.tfvars` 已加入 .gitignore，仅存在于本地。
  - **资源释放约定**：除 ECS 和 EIP 外，其它资源均在 `terraform-diting-prod.tfvars` 中固定；**make down diting prod 仅释放 ECS 与 EIP**，VPC、数据盘、NAS、OSS 等不会释放（详见 tfvars 内注释）。
  - **nas_existing_access_group_name 如何填写**：复用已有 NAS 权限组时填其**名称**（字符串）。查找方式：① 阿里云控制台 → 文件存储 NAS → 权限组，查看目标权限组名称；② 或在本仓库执行 `make deploy diting prod` 后，在 **diting-infra** 下执行 `cd deploy-engine/deploy/terraform/alicloud && terraform state show 'module.nas.alicloud_nas_access_group.main[0]'`，输出中的 `access_group_name` 即该值。prod 由 Terraform 新建时名称一般为 `diting_nas_group_prod` 或 `<project>_nas_group_prod`。
  - **固定资源后首次部署（state 与 tfvars 不一致时）**：若上次部署是「Terraform 创建」、本次改为「固定使用已有资源」（在 tfvars 中填写了 existing_* ID/名称），须先在 state 中移除对应资源，否则 apply 会计划**销毁** state 里那批旧资源。**有填 existing_* 即视为复用**，无需再设 use_existing_*。在 **diting-infra** 下执行（按需 rm）：  
    `cd deploy-engine/deploy/terraform/alicloud`  
    `terraform state rm 'module.vpc.alicloud_vpc.main[0]'`  
    `terraform state rm 'module.vpc.alicloud_vswitch.main[0]'`  
    `terraform state rm 'module.security.alicloud_security_group.main[0]'`  
    `terraform state rm 'module.nas.alicloud_nas_access_group.main[0]'`  
    `terraform state rm 'module.nas.alicloud_nas_file_system.main[0]'`  
    `terraform state rm 'alicloud_disk.prod_data[0]'`  
    完成后执行 `make deploy diting prod`。

## ACR 拉取凭证（prod 采集镜像）

- 归属 **charts/diting-stack**：**charts/diting-stack/manifests/acr-pull-secret.yaml** 为 K8s Secret，供本 Chart 的 ingest Job 从私有 ACR 拉取镜像。该文件含凭证，已加入 .gitignore。
- 示例：**charts/diting-stack/manifests/acr-pull-secret.yaml.example**；若无正式文件可据此复制并填写后重命名为 `acr-pull-secret.yaml`。
- 执行 **`make deploy diting prod`** 时，若存在该文件会先自动 apply，再部署 diting-stack；也可单独 **`make apply-acr-pull-secret`**（需 KUBECONFIG 指向 prod 集群）。部署类 manifest 仅放在 **charts/** 下，不放在 config/。

## Redis 部署覆盖（prod）

- **redis-values-prod.yaml**：Bitnami Redis Chart 的 values 覆盖文件；**服务暴露方式（NodePort/端口）由此文件控制**，Makefile 仅执行 `helm ... -f config/redis-values-prod.yaml`。修改 Redis 暴露或端口时只改本文件，符合「部署内容由配置与 Chart 控制」的系统规则。

## 其他

- `diting-prod.yaml` / `diting-dev.yaml`：部署控制（K3s、数据库等）。
- `deploy.yaml`：deploy-engine 入口配置。
