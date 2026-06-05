# diting 新加坡 Anthropic 出口代理（独立 state: diting/sg-proxy）
# make deploy-proxy diting sg-proxy · instance_password 由 TF_VAR_instance_password 注入

env_id  = "sg-proxy"
region  = "ap-southeast-1"
project = "diting"

# 新加坡 1a Spot 常无库存：按量 + 经济型 e 系列
instance_type    = "ecs.e-c1m2.large"
enable_spot      = false
spot_strategy    = "NoSpot"
spot_price_limit = 0.08
eip_bandwidth    = 50
disk_category    = "cloud_essd"
disk_size        = 40

vpc_cidr     = "10.1.0.0/16"
vswitch_cidr = "10.1.1.0/24"
ssh_allowed_cidr = "0.0.0.0/0"

# 复用首次 apply 已创建的 VPC/VSwitch/SG（state 已 rm 托管后仅引用 ID）
vpc_existing_id            = "vpc-t4nj7m2pbdkb656dv4k39"
vswitch_existing_id        = "vsw-t4n6jfvolu20jq119liea"
security_group_existing_id = "sg-t4nbaqrk3ffvdz2qkmsj"

enable_prod_data_disk = false

# 复用 2026-06-04 首次 deploy-proxy 已创建的 NAS（state 重建时避免 InvalidAccessGroup.AlreadyExisted）
nas_existing_file_system_id      = "071y8idoeu52mroi0fk"
nas_existing_access_group_name   = "deploy-engine_nas_group_sg-proxy"
nas_use_existing_mount_target  = true
nas_existing_mount_target_domain = "071y8idoeu52mroi0fk-xqg58.ap-southeast-1.nas.aliyuncs.com"

oss_bucket_name = "diting-sg-proxy-storage"
oss_bucket_acl  = "private"
init_script_acl = "private"

enable_proxy_ingress   = true
anthropic_proxy_port   = 3128
anthropic_proxy_user   = "ditingproxy"
# anthropic_proxy_password 留空则复用 TF_VAR_instance_password

stacks = {
  proxy = {
    instance_type        = "ecs.e-c1m2.large"
    spot_strategy        = "NoSpot"
    spot_price_limit     = 0.08
    image_family         = "ubuntu_22_04"
    system_disk_gb       = 40
    system_disk_category = "cloud_essd"
    attach_data_disk     = false
    k3s_role             = "server"
    node_labels          = { "stack.diting/node" = "proxy" }
    enable_eip           = true
    bootstrap_mode       = "proxy"
    count                = 1
  }
}
