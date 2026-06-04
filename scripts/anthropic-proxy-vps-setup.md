# Anthropic 出口代理（B 路径）— VPS 最小搭建

香港阿里云 ECS 访问 `api.anthropic.com` 返回 **403 Request not allowed**（地域封锁）。  
A 路径（本机 `--with-t2` + `make radar-t0-sync`）可覆盖日常扫描；**B 路径**供生产缓存 miss 时 live 调 Opus。

## 0. 自动化（推荐 · deploy-engine 新加坡竞价 ECS）

`diting-infra/config/diting-prod.yaml` 中 `anthropic_proxy.enabled: true` 时，`make deploy diting prod` 会自动：

1. `make deploy-sg-anthropic-proxy` → deploy-engine `deploy-proxy diting sg-proxy`（Terraform 新建新加坡 VPC + 竞价 ECS + 3proxy）
2. `make sync-anthropic-proxy-to-copilot` → 写入 `diting-src/.env` 的 `HTTPS_PROXY` 并 helm 注入 Copilot

独立操作：

```bash
cd diting-infra
# 需 diting-infra/.env 中 TF_VAR_instance_password（可与 proxy 密码相同）
make deploy-sg-anthropic-proxy
make sync-anthropic-proxy-to-copilot
```

配置：`config/terraform-diting-sg-proxy.tfvars`（region=ap-southeast-1，stack `proxy`，`bootstrap_mode=proxy`）。

**注意**：deploy-engine 子模块改动须在独立仓库 `https://github.com/myxxhui/deploy-engine.git` push 后，在本仓执行 `make update-deploy-engine`。

## 1. 租 VPS

| 项 | 建议 |
|---|---|
| 地域 | 美国 / 新加坡（非中国大陆） |
| 规格 | 1C1G 即可 |
| 费用 | 约 ¥25–40/月 |
| 协议 | HTTP CONNECT 或 SOCKS5（推荐 3proxy / tinyproxy） |

## 2. 3proxy 示例（Ubuntu）

```bash
sudo apt update && sudo apt install -y 3proxy
sudo tee /etc/3proxy/3proxy.cfg <<'EOF'
auth strong
users proxyuser:CL:请替换强密码
proxy -p3128
EOF
sudo systemctl enable --now 3proxy
sudo ufw allow 3128/tcp
```

## 3. 写入 diting-src/.env

```bash
HTTPS_PROXY=http://proxyuser:请替换强密码@你的VPS公网IP:3128
HTTP_PROXY=http://proxyuser:请替换强密码@你的VPS公网IP:3128
NO_PROXY=localhost,127.0.0.1,.svc,.svc.cluster.local,.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
```

`NO_PROXY` 确保集群内 Redis/Postgres 不走代理；**Anthropic 会走 HTTPS_PROXY**。

## 4. 同步到生产

```bash
# diting-infra
make copilot-sync-ai-from-src-env   # 或项目内等价 target，将 HTTPS_PROXY 写入 values
make copilot-modec-deploy           # helm upgrade 后 pod 重启生效
```

## 5. 验证

```bash
kubectl -n platform exec deploy/diting-copilot -- python3 -c "
import os, urllib.request
print('HTTPS_PROXY=', os.getenv('HTTPS_PROXY'))
req = urllib.request.Request('https://api.anthropic.com/v1/messages', method='POST')
try:
    urllib.request.urlopen(req, timeout=10)
except Exception as e:
    print('reachable (expect 401/403 body, not connection reset):', type(e).__name__)
"
```

期望：经代理能建立 TLS（401/405 正常）；无代理则 `URLError` / 403。

## 6. 与 A 路径配合

| 场景 | 行为 |
|---|---|
| 缓存含 `t2_verdict.status=ok` | 生产 **跳过 live Opus**（零 API 费） |
| 缓存仅 T0 / T2 过期 | 生产 **live Opus 经 B 代理** |
| 缓存 miss + `RADAR_T0_LIVE_FALLBACK=false` | 不 live 拉东财，提示先 sync |

[Ref: step_14 · L4 实践记录_ModeC深度研报重构]
