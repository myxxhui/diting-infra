# diting prod。make down 仅释放 ECS/EIP。instance_password 建议 TF_VAR_instance_password 注入。

env_id            = "prod"
region            = "cn-hongkong"
instance_type     = "ecs.u1-c1m4.xlarge"
instance_password = "Hui123123!!"
vpc_cidr          = "10.0.0.0/16"
vswitch_cidr      = "10.0.1.0/24"
enable_spot       = true
spot_strategy     = "SpotAsPriceGo"
spot_price_limit  = 0.5
eip_bandwidth     = 100
disk_category     = "cloud_essd"

# 固定资源 ID（复用已有时填）
vpc_existing_id                = "vpc-j6cuhmska9vfwqa6my16q"
vswitch_existing_id            = "vsw-j6ct3ymab1lxeqz38lbwi"
security_group_existing_id     = "sg-j6cizfabvego0nem81c2"
nas_existing_file_system_id    = "12db2e48f90"
nas_existing_access_group_name = "deploy-engine_nas_group_prod"
use_existing_data_disk_id      = "d-j6cc6ew2bqkfdlwaavit"

enable_prod_data_disk = true
data_disk_size        = 100
data_disk_category    = "cloud_essd"

oss_bucket_name = "deploy-engine-k3s-storage"
oss_bucket_acl  = "public-read-write"
init_script_acl = "public-read"
