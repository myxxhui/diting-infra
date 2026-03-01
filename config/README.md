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

## 其他

- `diting-prod.yaml` / `diting-dev.yaml`：部署控制（K3s、数据库等）。
- `deploy.yaml`：deploy-engine 入口配置。
