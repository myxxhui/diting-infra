# diting 新加坡 Anthropic 出口代理（独立 state: diting/sg-proxy）
# make deploy-proxy diting sg-proxy · instance_password 由 TF_VAR_instance_password 注入

env_id  = "sg-proxy"
region  = "ap-southeast-1"
project = "diting"

instance_type    = "ecs.t6-c1m2.large"
enable_spot      = true
spot_strategy    = "SpotAsPriceGo"
spot_price_limit = 0.08
eip_bandwidth    = 50
disk_category    = "cloud_essd"
disk_size        = 40

vpc_cidr     = "10.1.0.0/16"
vswitch_cidr = "10.1.1.0/24"
ssh_allowed_cidr = "0.0.0.0/0"

# 新建新加坡 VPC（首次 deploy-proxy 自动创建）
vpc_existing_id            = ""
vswitch_existing_id        = ""
security_group_existing_id = ""

enable_prod_data_disk = false

oss_bucket_name = "diting-sg-proxy-storage"
oss_bucket_acl  = "private"
init_script_acl = "private"

enable_proxy_ingress   = true
anthropic_proxy_port   = 3128
anthropic_proxy_user   = "ditingproxy"
# anthropic_proxy_password 留空则复用 TF_VAR_instance_password

stacks = {
  proxy = {
    instance_type        = "ecs.t6-c1m2.large"
    spot_strategy        = "SpotAsPriceGo"
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
