# diting prod。make down 仅释放 ECS/EIP。instance_password 建议 TF_VAR_instance_password 注入。

env_id        = "prod"
region        = "cn-hongkong"
instance_type = "ecs.u1-c1m4.large"  # 2026-06-09 xlarge 售罄 · 按量 large 有库存
# instance_password 由 diting-infra/.env 的 TF_VAR_instance_password 注入（勿在此写明文）
vpc_cidr         = "10.0.0.0/16"
vswitch_cidr     = "10.0.1.0/24"
enable_spot      = false
spot_strategy    = "NoSpot"  # 香港 prod 按量付费，避免竞价回收
spot_price_limit = 0.5
eip_bandwidth    = 100
disk_category    = "cloud_essd"

# 安全组 SSH/6443：不通过本仓脚本/配置管理，由控制台或已有规则控制；Terraform 若需写规则则用 0.0.0.0/0 避免单 IP 限制
ssh_allowed_cidr = "0.0.0.0/0"

# 固定资源 ID（复用已有时填）
vpc_existing_id                = "vpc-j6cuhmska9vfwqa6my16q"
vswitch_existing_id            = "vsw-j6ct3ymab1lxeqz38lbwi"
security_group_existing_id     = "sg-j6cizfabvego0nem81c2"
nas_existing_file_system_id    = "12db2e48f90"
nas_existing_access_group_name = "deploy-engine_nas_group_prod"
# 复用已有挂载点（避免每文件系统 2 个上限）：从控制台 NAS→文件系统→挂载点 复制域名填入
nas_use_existing_mount_target = true

nas_existing_mount_target_domain = "12db2e48f90-hpy48.cn-hongkong.nas.aliyuncs.com"
# 数据盘由 Terraform alicloud_disk.prod_data 管理；Down 后 disk_id 写入 prod.disk_id 供下次 Up 复用
# 竞价实例回收后 Up 须复挂已有数据盘（与 prod.disk_id 一致）
use_existing_data_disk_id = "d-j6ce444m0p0kf0jwxhcu"

enable_prod_data_disk = true
data_disk_size        = 100
data_disk_category    = "cloud_essd"

# 权威数据盘自动快照：由 diting-infra/scripts/ensure-prod-data-snapshot-policy.sh 管理（读 diting-prod.yaml）
# 禁止与 Terraform 双写；若设为 true，deploy 时可能触发 TooManyAutoSnapshotPolicies
enable_prod_data_disk_snapshot     = false
prod_data_snapshot_time_points     = ["16"]
prod_data_snapshot_retention_days  = 7
prod_data_snapshot_repeat_weekdays = ["1", "2", "3", "4", "5", "6", "7"]

oss_bucket_name = "deploy-engine-k3s-storage"
oss_bucket_acl  = "public-read-write"
init_script_acl = "public-read"

# ============================================================================
# v2 多 stack（P 轨）— 启动期默认仅 base，count=1；train/infer count=0（按需起停）
# make up-stack diting prod STACK=train 时改为 1（或经 TF_VAR_stacks 覆盖）
# 注：本 stacks 配置覆盖根级 main.tf 的 legacy_base_stack 合成路径
# ============================================================================
stacks = {
  base = {
    instance_type        = "ecs.u1-c1m4.large"
    spot_strategy        = "NoSpot"  # 按量付费（PostPaid）
    spot_price_limit     = 0.6
    image_family         = "ubuntu_22_04"
    system_disk_gb       = 60
    system_disk_category = "cloud_essd"
    attach_data_disk     = true
    k3s_role             = "server"
    node_labels          = { "stack.diting/node" = "base" }
    enable_eip           = true
    count                = 1
  }
  train = {
    instance_type        = "ecs.gn6i-c4g1.xlarge"
    spot_strategy        = "NoSpot"  # 2026-05-26 Spot 三区 SoldOut · 临时改按量（cn-hongkong-b Available）
    spot_price_limit     = 3.0
    image_family         = "ubuntu_22_04_gpu"
    system_disk_gb       = 100
    system_disk_category = "cloud_essd"
    attach_data_disk     = false
    k3s_role             = "agent"
    node_labels          = { "stack.diting/node" = "train", "nvidia.com/gpu" = "present" }
    enable_eip           = false
    count                = 0
  }
  infer = {
    instance_type        = "ecs.gn6i-c4g1.xlarge"
    spot_strategy        = "NoSpot"  # Spot 三区 SoldOut · 临时按量（与 train 一致）
    spot_price_limit     = 3.0
    image_family         = "ubuntu_22_04_gpu"
    system_disk_gb       = 100
    system_disk_category = "cloud_essd"
    attach_data_disk     = false
    k3s_role             = "agent"
    node_labels          = { "stack.diting/node" = "infer", "nvidia.com/gpu" = "present" }
    enable_eip           = false
    count                = 0
  }
}
