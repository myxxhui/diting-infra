# diting-infra Makefile
# [Ref: 03_原子目标与规约/开发与交付/02_基础设施与部署规约]
# Stage1-03：每次执行前先 update-deploy-engine，再 deploy-dev / down

# deploy-engine 从本仓扁平 config 读配置（与 deploy-engine 约定一致，无更深目录）
CONFIG_ROOT = $(CURDIR)/config
PROJECT ?= diting
ENV ?= dev
DEPLOY_ENGINE_DIR = deploy-engine

.PHONY: update-deploy-engine deploy-dev down

# 每次执行 Stage1-03 前必做：更新 deploy-engine 代码（submodule）
update-deploy-engine:
	@git submodule update --init --remote $(DEPLOY_ENGINE_DIR) && echo "[OK] deploy-engine 已更新"

# 调用 deploy-engine Up（需 Terraform 与云凭证）
deploy-dev: update-deploy-engine
	@CONFIG_ROOT="$(CONFIG_ROOT)" $(MAKE) -C $(DEPLOY_ENGINE_DIR) deploy $(PROJECT) $(ENV)

# 准出前必做：回收资源（仅 ECS；FULL_DESTROY=1 则完整销毁）
down:
	@CONFIG_ROOT="$(CONFIG_ROOT)" $(MAKE) -C $(DEPLOY_ENGINE_DIR) down $(PROJECT) $(ENV)
