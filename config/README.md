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

## ACR 拉取凭证（prod 采集镜像）

- 归属 **charts/diting-stack**：**charts/diting-stack/manifests/acr-pull-secret.yaml** 为 K8s Secret，供本 Chart 的 ingest Job 从私有 ACR 拉取镜像。该文件含凭证，已加入 .gitignore。
- 示例：**charts/diting-stack/manifests/acr-pull-secret.yaml.example**；若无正式文件可据此复制并填写后重命名为 `acr-pull-secret.yaml`。
- 执行 **`make deploy diting prod`** 时，若存在该文件会先自动 apply，再部署 diting-stack；也可单独 **`make apply-acr-pull-secret`**（需 KUBECONFIG 指向 prod 集群）。部署类 manifest 仅放在 **charts/** 下，不放在 config/。

## 其他

- `diting-prod.yaml` / `diting-dev.yaml`：部署控制（K3s、数据库等）。
- `deploy.yaml`：deploy-engine 入口配置。
