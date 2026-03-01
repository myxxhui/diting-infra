# ==============================================================================
# 生产环境（diting prod）Terraform 变量
# ==============================================================================
# 用于 make deploy diting prod / make down diting prod；与 06_生产级数据要求_设计 一致。
# 敏感项：instance_password 建议使用环境变量 TF_VAR_instance_password 注入
# ==============================================================================

env_id            = "prod"
region            = "cn-hongkong"
instance_type     = "ecs.u1-c1m4.xlarge"
instance_password = "ChangeMe123!!"
vpc_cidr          = "10.0.0.0/16"
vswitch_cidr      = "10.0.1.0/24"
enable_spot       = true
spot_strategy     = "SpotAsPriceGo"
spot_price_limit  = 0.5
eip_bandwidth     = 100
disk_category     = "cloud_essd"
# Stage2-06 前半部分：独立数据盘（Down 仅回收 ECS/EIP 时保留此盘，再次 Up 挂载同盘）
enable_prod_data_disk = true
data_disk_size        = 100
data_disk_category    = "cloud_essd"
# use_existing_data_disk_id 由 Make 在再次 Up 时从 prod.disk_id 注入（TF_VAR_use_existing_data_disk_id）
# prod 单独使用 prod NAS；Terraform 会创建 diting_nas_group_prod、prod 专用 File System 与 Mount Target
# 后续其他 diting 环境（如 prod2、staging）若需复用 prod NAS，在其 tfvars 中设置：
#   nas_use_existing_access_group = true
#   nas_existing_access_group_name = "diting_nas_group_prod"
# nas_use_existing_access_group = false  # 本环境默认即 false，可不写
# 生产环境 K3s 仍用与 dev 相同的 OSS 桶（复用已有脚本与权限）
oss_bucket_name               = "deploy-engine-k3s-storage"
# 尝试 bucket 公共读写 + object 公共读；若 apply 报错则改回 private + 配置 ram_role_name
oss_bucket_acl   = "public-read-write"
init_script_acl  = "public-read"
# 在控制台创建具 OSS 读权限的 RAM 角色并绑定到 ECS 后，在此填写角色名（如 diting-ecs-oss-read）
# ram_role_name   = "diting-ecs-oss-read"
