# diting-infra Makefile
# [Ref: 03_原子目标与规约/开发与交付/02_基础设施与部署规约]
# Stage1-03：每次执行前先 update-deploy-engine，再 deploy-dev / down

# deploy-engine 从本仓扁平 config 读配置（与 deploy-engine 约定一致，无更深目录）
CONFIG_ROOT = $(CURDIR)/config
PROJECT ?= diting
ENV ?= dev
DEPLOY_ENGINE_DIR = deploy-engine

# 子 make 递归时不打印 Entering/Leaving directory（避免 deploy 日志刷屏）
MAKEFLAGS += --no-print-directory

# Stage2-01 验证环境清理：无论验证是否完成都要执行，避免残留（release/namespace 与部署时一致）
STAGE2_01_NS ?= default

# 从 .env 加载阿里云 AKSK 等（若存在），供 Terraform / deploy-engine 使用
-include .env
export

.PHONY: update-deploy-engine init-local-config check-deploy-prereqs deploy deploy-dev down stage2-01-down stage2-01-full-down diting prod sg-proxy
.PHONY: spot-prefer-on-deploy cluster-spot-watch spot-billing-status switch-stack-billing \
	spot-intent-mark spot-guard-sync-secret spot-guard-cron-run-now \
	redeploy-prod-spot-prefer redeploy-prod-ondemand-fallback
.PHONY: deploy-sg-anthropic-proxy verify-sg-anthropic-proxy down-sg-anthropic-proxy sync-anthropic-proxy-to-copilot \
	deploy-sg-anthropic-proxy-if-enabled sync-anthropic-proxy-if-enabled fix-sg-3proxy-systemd \
	deploy-anthropic-proxy-if-enabled down-anthropic-proxy-if-enabled
.PHONY: ensure-kubecm kubecm-add-switch kubecm-remove kubeconfig-sync kubeconfig-restore-state

# 占位目标：make deploy diting prod / make down diting prod 时不被当作文件
diting:
	@true
prod:
	@true
sg-proxy:
	@true

# 每次执行 Stage1-03 前必做：更新 deploy-engine 代码（submodule）
update-deploy-engine:
	@git submodule update --init --remote $(DEPLOY_ENGINE_DIR) && echo "[OK] deploy-engine 已更新"

# 新机器首次：从 template 复制 .env 与 prod tfvars（不覆盖已有文件）
init-local-config:
	@if [ ! -f .env ]; then cp .env.template .env && echo "[init] 已创建 .env · 请填写 ALICLOUD_ACCESS_KEY / ALICLOUD_SECRET_KEY / TF_VAR_instance_password"; \
	else echo "[init] .env 已存在，跳过"; fi
	@if [ ! -f "$(CONFIG_ROOT)/terraform-diting-prod.tfvars" ]; then \
		cp "$(CONFIG_ROOT)/terraform-diting-prod.tfvars.example" "$(CONFIG_ROOT)/terraform-diting-prod.tfvars" && \
		echo "[init] 已创建 config/terraform-diting-prod.tfvars · 密码请用 TF_VAR_instance_password 注入"; \
	else echo "[init] terraform-diting-prod.tfvars 已存在，跳过"; fi
	@echo "[init] sg-proxy tfvars 已随仓提交（config/terraform-diting-sg-proxy.tfvars）"
	@echo "[init] 下一步: 编辑 .env 后执行 make check-deploy-prereqs"

# 换机 / 新目录拉仓后自检（不发起云 API）
check-deploy-prereqs:
	@bash scripts/check-deploy-prereqs.sh

# kubecm 多 kubeconfig 管理（P 轨 / deploy-engine 配套）
ensure-kubecm:
	@bash scripts/kubecm-helpers.sh ensure

kubecm-add-switch:
	@bash scripts/kubecm-helpers.sh add-and-switch $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV)

kubecm-remove:
	@bash scripts/kubecm-helpers.sh remove $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV)

# 从 deploy-engine state 恢复 kubeconfig 并注册 kubecm
kubeconfig-restore-state:
	@bash scripts/kubeconfig-restore-state.sh $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV)

# 拉取 kubeconfig 并注册到 kubecm：make kubeconfig-sync [env] [project]
kubeconfig-sync:
	@_e=$(word 2,$(MAKECMDGOALS)); _p=$(word 3,$(MAKECMDGOALS)); \
	CONFIG_ROOT="$(CONFIG_ROOT)" bash scripts/kubeconfig-fetch.sh "$${_e:-prod}" "$${_p:-diting}"

# make deploy [project] [env]：无参数时用 PROJECT/ENV；make deploy diting prod = 生产数据环境 Up
deploy: update-deploy-engine
	@_p=$(word 2,$(MAKECMDGOALS)); _e=$(word 3,$(MAKECMDGOALS)); \
	if [ "$$_p" = "diting" ] && [ "$$_e" = "prod" ]; then $(MAKE) deploy-diting-prod; else \
		CONFIG_ROOT="$(CONFIG_ROOT)" $(MAKE) -C $(DEPLOY_ENGINE_DIR) deploy "$${_p:-$(PROJECT)}" "$${_e:-$(ENV)}"; \
		bash scripts/kubecm-helpers.sh add-and-switch "$${_p:-$(PROJECT)}" "$${_e:-$(ENV)}" || true; \
	fi

# 调用 deploy-engine Up（需 Terraform 与云凭证）；等价 make deploy $(PROJECT) $(ENV)
deploy-dev: update-deploy-engine
	@CONFIG_ROOT="$(CONFIG_ROOT)" $(MAKE) -C $(DEPLOY_ENGINE_DIR) deploy $(PROJECT) $(ENV)

# make down [project] [env]：无参数时用 PROJECT/ENV；make down diting prod = 生产数据环境 Down（回收且磁盘保留）
down:
	@_p=$(word 2,$(MAKECMDGOALS)); _e=$(word 3,$(MAKECMDGOALS)); \
	if [ "$$_p" = "diting" ] && [ "$$_e" = "prod" ]; then $(MAKE) down-diting-prod; else \
		CONFIG_ROOT="$(CONFIG_ROOT)" $(MAKE) -C $(DEPLOY_ENGINE_DIR) down "$${_p:-$(PROJECT)}" "$${_e:-$(ENV)}"; \
		bash scripts/kubecm-helpers.sh remove "$${_p:-$(PROJECT)}" "$${_e:-$(ENV)}" || true; \
	fi

# Stage2-01 仅清理 K3s 上本步资源（中间件、Job、ConfigMap）
stage2-01-down:
	@echo "[Stage2-01] 清理 K3s 资源 (namespace=$(STAGE2_01_NS))..."
	@helm uninstall timescaledb -n $(STAGE2_01_NS) 2>/dev/null || true
	@helm uninstall redis -n $(STAGE2_01_NS) 2>/dev/null || true
	@helm uninstall postgresql-l2 -n $(STAGE2_01_NS) 2>/dev/null || true
	@kubectl delete job diting-schema-init -n $(STAGE2_01_NS) 2>/dev/null || true
	@kubectl delete configmap diting-schema-init-sql -n $(STAGE2_01_NS) 2>/dev/null || true
	@echo "[Stage2-01] K3s 资源清理完成"

# Stage2-01 完整清除：K3s 本步资源 + ECS 集群（验证环境必须彻底回收时使用）
stage2-01-full-down: stage2-01-down
	@echo "[Stage2-01] 回收 ECS/K3s..."
	@$(MAKE) down
	@echo "[Stage2-01] 完整清理完成（K3s + ECS）"

# ---------- Stage2 本地实践：Docker Compose 提供 L1/L2/Redis（02_三位一体：部署归属 infra）----------
# 在 diting-infra 执行 up/init 后，在 diting-src 配置 .env 指向 localhost:15432/15433/15479（L1/L2/Redis）并执行 make verify diting prod、ingest-test
# 网络名随 compose 驱动不同可能为 diting-infra_default（docker compose 从本仓根目录 up）或 compose_default（部分 podman-compose）；若 init 报错可覆盖 COMPOSE_NETWORK=compose_default make local-deps-init
COMPOSE_INGEST = docker compose -f compose/docker-compose.ingest.yaml
COMPOSE_NETWORK = diting-infra_default
LOCAL_SCRIPTS = $(CURDIR)/scripts/local

.PHONY: local-deps-up local-deps-down local-deps-init

local-deps-up:
	@$(COMPOSE_INGEST) up -d && echo "等待 L1/L2/Redis 就绪..." && sleep 6

local-deps-down:
	@$(COMPOSE_INGEST) down
	@echo "local-deps-down OK（L1/L2/Redis 已回收）"

local-deps-init:
	@echo "初始化 L1 ohlcv 表..."
	@docker run --rm --network $(COMPOSE_NETWORK) -v "$(LOCAL_SCRIPTS):/scripts" postgres:15-alpine \
		psql "postgresql://postgres:postgres@l1:5432/postgres" -v ON_ERROR_STOP=1 -f /scripts/init_l1_ohlcv_local.sql
	@echo "初始化 L2 data_versions 表..."
	@docker run --rm --network $(COMPOSE_NETWORK) -v "$(LOCAL_SCRIPTS):/scripts" postgres:15-alpine \
		psql "postgresql://postgres:postgres@l2:5432/diting_l2" -v ON_ERROR_STOP=1 -f /scripts/init_l2_data_versions_local.sql
	@echo "local-deps-init OK（请在 diting-src 配置 .env：TIMESCALE_DSN、PG_L2_DSN、REDIS_URL=redis://localhost:15479/0 后执行 make verify diting prod、make ingest-test）"

# ---------- Stage2-06 生产环境（Up/Down 与 prod.conn 输出）----------
# 见 04_阶段规划与实践/Stage2_数据采集与存储/06_生产级数据要求_实践.md
# 配置：config/terraform-diting-prod.tfvars、config/diting-prod.yaml（部署 PG/Redis、K3s 存储等由 YAML 控制）
# Down 仅回收 ECS/K3s/EIP、保留独立数据盘（再次 Up 挂载同盘）；disk_id 持久化于 prod.disk_id
PROD_DATA_ENV_PROJECT = diting
PROD_DATA_ENV_ENV     = prod
CONN_FILE             = $(CURDIR)/prod.conn
DISK_ID_FILE          = $(CURDIR)/prod.disk_id

.PHONY: deploy-diting-prod down-diting-prod deploy-diting-prod-with-ingest prod-write-conn prod-sync-conn-secret deploy-ingest-job prod-deploy-summary

# 兼容旧命令（推荐使用 make deploy diting prod / make down diting prod）
deploy-data-db-prod: deploy-diting-prod
down-data-db-prod: down-diting-prod

# make deploy diting prod 的实际执行 target。若 Terraform state 中 NAS 访问组仍为 dev 共享（diting_nas_group_dev），deploy 时会尝试 replace 并销毁该资源导致 InvalidAccessGroup.AlreadyAttached；Up 前先从 state 移除，让 Terraform 仅创建 prod 自有 NAS
deploy-diting-prod: update-deploy-engine check-deploy-prereqs
	@if [ "$${SKIP_SPOT_PREFER:-0}" != "1" ]; then \
		chmod +x scripts/spot-prefer-on-deploy.sh scripts/lib/spot-billing-lib.sh; \
		bash scripts/spot-prefer-on-deploy.sh; \
	fi
	@echo ""
	@echo "=========================================="
	@echo "  双环境 Up：①新加坡代理(sg-proxy) ②香港 prod"
	@echo "=========================================="
	@{ \
		_TF="$(CURDIR)/$(DEPLOY_ENGINE_DIR)/deploy/terraform/alicloud"; \
		_TF_STATE="$$_TF/terraform.tfstate"; \
		if [ -f "$$_TF_STATE" ] && [ ! -s "$$_TF_STATE" ]; then rm -f "$$_TF_STATE"; fi; \
		if [ -f "$$_TF_STATE" ]; then \
			_SHOW_OUT=$$(cd "$$_TF" && terraform state show 'module.nas.alicloud_nas_access_group.main[0]' 2>&1) || true; \
			if echo "$$_SHOW_OUT" | grep -q 'diting_nas_group_dev'; then \
				echo "[prod-up] state 中 NAS 为 dev 共享（diting_nas_group_dev），先从 state 移除再 deploy，避免 replace 时误删"; \
				(cd "$$_TF" && terraform state rm 'module.nas.alicloud_nas_access_group.main[0]'); \
			fi; \
		fi; \
	}
	@if scripts/terraform-output-safe.sh read-disk-id "$(DISK_ID_FILE)" >/dev/null 2>&1; then \
		export TF_VAR_use_existing_data_disk_id=$$(scripts/terraform-output-safe.sh read-disk-id "$(DISK_ID_FILE)"); \
		echo "[prod-up] 复用本地 prod.disk_id: $$TF_VAR_use_existing_data_disk_id"; \
		CONFIG_ROOT="$(CONFIG_ROOT)" bash scripts/prod-disk-state-handoff.sh $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV); \
	else \
		_REGION=$$(grep -E '^\s*region\s*=' "$(CONFIG_ROOT)/terraform-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).tfvars" 2>/dev/null | head -1 | sed -E 's/^[^=]*=\s*"?([^"]+)"?.*/\1/' | tr -d ' '); \
		[ -z "$$_REGION" ] && _REGION=cn-hongkong; \
		export ALICLOUD_REGION="$$_REGION"; \
		_TF="$(CURDIR)/$(DEPLOY_ENGINE_DIR)/deploy/terraform/alicloud"; \
		if [ -f "$$_TF/terraform.tfstate" ] && [ ! -s "$$_TF/terraform.tfstate" ]; then rm -f "$$_TF/terraform.tfstate"; fi; \
		(cd "$$_TF" && terraform init -backend-config="prefix=$(PROD_DATA_ENV_PROJECT)/$(PROD_DATA_ENV_ENV)" -reconfigure -input=false -no-color > /dev/null) || true; \
		_DISK_ID=$$(scripts/terraform-output-safe.sh resolve-disk-id "$$_TF" "$(DISK_ID_FILE)" 2>/dev/null || true); \
		if [ -n "$$_DISK_ID" ] && echo "$$_DISK_ID" | grep -qE '^d-[a-z0-9]+$$'; then \
			printf '%s' "$$_DISK_ID" > "$(DISK_ID_FILE)"; \
			export TF_VAR_use_existing_data_disk_id="$$_DISK_ID"; \
			echo "[prod-up] 从 OSS remote state 复用数据盘: $$_DISK_ID（已写入 prod.disk_id）"; \
			CONFIG_ROOT="$(CONFIG_ROOT)" TF_VAR_use_existing_data_disk_id="$$_DISK_ID" bash scripts/prod-disk-state-handoff.sh $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV); \
		else \
			echo "[prod-up] remote state 无数据盘，创建新盘..."; \
			(cd "$$_TF" && \
				terraform apply -target=alicloud_disk.prod_data -auto-approve \
					-var-file="$(CONFIG_ROOT)/terraform-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).tfvars" \
					-var=env_id=$(PROD_DATA_ENV_ENV) \
					-var=project=$(PROD_DATA_ENV_PROJECT) \
					-var=region="$$_REGION" \
					-var=config_file="$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
			_DISK_ID=$$(scripts/terraform-output-safe.sh output data_disk_id "$$_TF"); \
			if [ -n "$$_DISK_ID" ] && echo "$$_DISK_ID" | grep -qE '^d-[a-z0-9]+$$'; then \
				printf '%s' "$$_DISK_ID" > "$(DISK_ID_FILE)"; \
				echo "[prod-up] 数据盘已创建: $$_DISK_ID"; \
			fi; \
		fi; \
	fi
	@chmod +x scripts/ensure-prod-data-snapshot-policy.sh scripts/terraform-output-safe.sh scripts/prod-disk-state-handoff.sh
	@bash scripts/ensure-prod-data-snapshot-policy.sh
	@CONFIG_ROOT="$(CONFIG_ROOT)" bash scripts/prod-disk-state-handoff.sh $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV) || true
	@echo ""
	@echo "=========================================="
	@echo "  [1/2] 新加坡 Anthropic 代理（env=sg-proxy · STACK=proxy）"
	@echo "=========================================="
	@$(MAKE) deploy-sg-anthropic-proxy
	@echo ""
	@echo "=========================================="
	@echo "  [2/2] 香港 prod K3s 集群（env=prod · STACK=base）"
	@echo "=========================================="
	@_spot_cfg="$(CURDIR)/config/.spot-active"; \
	_deploy_cfg="$(CONFIG_ROOT)"; \
	if [ -f "$$_spot_cfg/terraform-diting-prod.tfvars" ]; then _deploy_cfg="$$_spot_cfg"; fi; \
	CONFIG_ROOT="$$_deploy_cfg" $(MAKE) -C $(DEPLOY_ENGINE_DIR) deploy $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV)
	@echo ""
	@echo "=========================================="
	@echo "  注册 kubeconfig 到 kubecm 并切换当前 context"
	@echo "=========================================="
	@bash scripts/kubecm-helpers.sh add-and-switch $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV)
	@echo ""
	@echo "=========================================="
	@echo "  部署 Platform Stack（P-step_03 · platform-base + diting-stack + DB）"
	@echo "=========================================="
	@CONFIG_ROOT="$(CONFIG_ROOT)" PROJECT=$(PROD_DATA_ENV_PROJECT) ENV=$(PROD_DATA_ENV_ENV) \
		CONN_FILE="$(CONN_FILE)" bash "$(CURDIR)/scripts/platform-step03-deploy-stack.sh"
	@echo ""
	@echo "=========================================="
	@echo "  同步 Anthropic 代理到 Copilot 并验收双环境"
	@echo "=========================================="
	@$(MAKE) sync-anthropic-proxy-to-copilot
	@$(MAKE) verify-sg-anthropic-proxy
	@$(MAKE) -f $(CURDIR)/Makefile prod-write-conn
	@echo ""
	@echo "=========================================="
	@echo "  触发采集 Job（异步 · 不阻塞部署收尾）"
	@echo "=========================================="
	@INGEST_ENABLED=$$(yq eval '.data_ingestion.enabled // false' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
	USE_K3S_JOB=$$(yq eval '.data_ingestion.use_k3s_job // true' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
	if [ "$${SKIP_INGEST:-0}" = "1" ]; then \
		echo "SKIP_INGEST=1，跳过采集 Job 触发"; \
	elif [ "$$INGEST_ENABLED" = "true" ]; then \
		if [ "$$USE_K3S_JOB" = "true" ]; then \
			$(MAKE) deploy-ingest-job; \
		else \
			CORE_REPO=$$(yq eval '.data_ingestion.core_repo_path // ""' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
			[ -z "$$CORE_REPO" ] && CORE_REPO="$${REPO_I_ROOT:-}"; \
			if [ -n "$$CORE_REPO" ] && [ -d "$$CORE_REPO" ]; then \
				INGEST_TARGET=$$(yq eval '.data_ingestion.target // "ingest-test"' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
				echo "执行数据采集(宿主机): $$INGEST_TARGET"; cp "$(CONN_FILE)" "$$CORE_REPO/.env" && $(MAKE) -C "$$CORE_REPO" "$$INGEST_TARGET" && echo "✅ 数据采集完成"; \
			else echo "⚠️  core_repo_path/REPO_I_ROOT 未设置，跳过"; fi; \
		fi; \
	else echo "数据采集已禁用（data_ingestion.enabled=false），跳过"; fi
	@chmod +x scripts/spot-intent-mark.sh scripts/lib/spot-billing-lib.sh
	@bash scripts/spot-intent-mark.sh up
	@$(MAKE) prod-deploy-summary

# 部署收尾：业务访问地址与验收指引
prod-deploy-summary:
	@chmod +x scripts/prod-deploy-summary.sh
	@KUBECONFIG="$$HOME/.kube/config-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)" \
		scripts/prod-deploy-summary.sh "$(CONFIG_ROOT)" "$(CONN_FILE)" $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV)

# 将连接信息写入 prod.conn（EIP 与 NodePort 从 deploy-engine 输出或 kubectl 获取）
prod-write-conn:
	@scripts/prod-write-conn.sh "$(CONFIG_ROOT)" "$(DEPLOY_ENGINE_DIR)" "$(CONN_FILE)" $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV) || true
	@echo "连接信息已写入 $(CONN_FILE)（若脚本未实现则需人工填写 EIP 与 NodePort）"

# 将 prod.conn 同步为 K8s Secret diting-db-connection（供 schema-init hook 与 ingest Job 使用）
# Job 在集群内运行，须使用集群内 Service 地址；prod.conn 仍为公网 NodePort 供本机 verify 使用
prod-sync-conn-secret:
	@STACK_NS=$$(yq eval '.stack.namespace // "platform"' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml" 2>/dev/null || echo platform); \
	export KUBECONFIG="$$HOME/.kube/config-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)"; \
	STACK_NS="$$STACK_NS" scripts/prod-sync-conn-secret.sh "$(CONFIG_ROOT)" "$(CONN_FILE)" $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV); \
	STACK_NS="$$STACK_NS" bash scripts/spot-guard-sync-k8s-secret.sh "$(CONFIG_ROOT)"

# 在远程 K3s 提交采集 Job（helm upgrade diting-stack · ingest.enabled；默认不等待 Job 完成，由 K8s 监管）
# 用法: make deploy-ingest-job [INGEST_TARGET=ingest-test-real|ingest-production]
# 需同步等待完成（验收/phase2）: make deploy-ingest-job WAIT=wait
# 支持 INGEST_IMAGE 覆盖（如已推送至 registry：INGEST_IMAGE=registry.cn-hongkong.aliyuncs.com/ns/diting-ingest:test）
deploy-ingest-job: prod-sync-conn-secret
	@export KUBECONFIG="$$HOME/.kube/config-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)"; export INGEST_TARGET; export INGEST_IMAGE; \
	scripts/prod-apply-ingest-job.sh "$(CONFIG_ROOT)" "$(CONN_FILE)" $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV) $(WAIT)

# 后半部分：Up 后执行采集落库（C3）；默认在 K3s Job 内执行，见 data_ingestion.use_k3s_job
deploy-diting-prod-with-ingest: deploy-diting-prod
	@if [ -n "$$REPO_I_ROOT" ] && [ -f "$(CONN_FILE)" ]; then \
		cp "$(CONN_FILE)" "$$REPO_I_ROOT/.env" && \
		$(MAKE) -C "$$REPO_I_ROOT" ingest-test && echo "[OK] ingest-test 已执行"; \
	else \
		echo "跳过 ingest-test（设置 REPO_I_ROOT 指向 diting-src 可自动执行）"; \
	fi

# 修复 Terraform state（vSwitch 404 + NAS AccessGroup AlreadyExisted 导致「OSS 初始化脚本上传失败」时使用）
# 原因：state 中 vSwitch/VPC 在云上已不存在或属错误地域；或 NAS Access Group 在云上已存在但 state 中无记录。
# 会从 state 删除 VPC/vSwitch 的「记录」，下次 deploy 将在 tfvars 指定地域重新创建。
# 若要从「Terraform 创建」改为「复用已有」NAS 文件系统，须先 state rm 再改 tfvars，否则 Terraform 会先销毁再复用导致 InvalidFileSystem.NotFound（见 config/README.md）。
fix-terraform-state-diting-prod:
	@_TF="$(CURDIR)/$(DEPLOY_ENGINE_DIR)/deploy/terraform/alicloud"; \
	_TFVARS="$(CONFIG_ROOT)/terraform-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).tfvars"; \
	_CFG="$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"; \
	echo "修复 Terraform state（删除错误地域/已不存在的 VPC/vSwitch 记录 + NAS Access Group 导入）..."; \
	(cd "$$_TF" && terraform state rm 'module.vpc.alicloud_vswitch.main[0]' 2>/dev/null) && echo "  [OK] 已从 state 移除 vSwitch 记录" || echo "  [--] vSwitch 不在 state 中，跳过"; \
	(cd "$$_TF" && terraform state rm 'module.vpc.alicloud_vpc.main[0]' 2>/dev/null) && echo "  [OK] 已从 state 移除 VPC 记录" || echo "  [--] VPC 不在 state 中，跳过"; \
	(cd "$$_TF" && terraform state rm 'module.nas.alicloud_nas_access_group.main' 2>/dev/null) && echo "  [OK] 已从 state 移除 NAS access group" || echo "  [--] NAS access group 不在 state 中，跳过"; \
	echo "  尝试导入已存在的 NAS Access Group（diting_nas_group_prod）..."; \
	(cd "$$_TF" && terraform import -var-file="$$_TFVARS" -var=env_id=$(PROD_DATA_ENV_ENV) -var=project=$(PROD_DATA_ENV_PROJECT) -var=config_file="$$_CFG" 'module.nas.alicloud_nas_access_group.main[0]' 'diting_nas_group_prod:standard') && echo "  [OK] NAS 导入成功" || { \
	  echo "  [--] 云上不存在 diting_nas_group_prod，跳过导入（下次 deploy 将新建）；若云上实为 deploy-engine_nas_group_prod，请在 config/terraform-diting-prod.tfvars 中增加:"; \
	  echo "    nas_use_existing_access_group = true"; \
	  echo "    nas_existing_access_group_name = \"deploy-engine_nas_group_prod\""; \
	  true; \
	}; \
	echo "修复完成。请执行: make deploy diting prod"

# Down 仅回收 ECS/K3s/EIP，保留独立数据盘（-target=module.ecs）；prod.disk_id 保留供再次 Up 挂载同盘
# FULL_DESTROY=1 时：若 Terraform state 中 NAS 访问组为 dev 共享（diting_nas_group_dev）或 tfvars 中非注释行 nas_use_existing_access_group = true，先从 Terraform state 移除该资源，避免误删导致 InvalidAccessGroup.AlreadyAttached
# 注意：deploy-engine 的 -state= 指向的是编排用 JSON，Terraform 实际使用 deploy/terraform/alicloud/terraform.tfstate（backend local）
# make down diting prod 的实际执行 target
down-diting-prod:
	@echo ""
	@echo "=========================================="
	@echo "  卸载数据库 Release（官方 Chart）"
	@echo "=========================================="
	@export KUBECONFIG="$$HOME/.kube/config-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)"; \
	if kubectl cluster-info &>/dev/null; then \
		STACK_NS=$$(yq eval '.stack.namespace // "platform"' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
		for r in timescaledb postgresql-l2 redis; do helm uninstall "$$r" -n "$$STACK_NS" 2>/dev/null || true; done; \
		for r in timescaledb postgresql-l2 redis; do helm uninstall "$$r" -n default 2>/dev/null || true; done; \
		echo "等待 Pod 终止..."; sleep 10; \
		echo "✅ 数据库 Release 已卸载 (@ $$STACK_NS)"; \
	else \
		echo "⚠️  集群不可访问，跳过"; \
	fi
	@echo ""
	@echo "=========================================="
	@echo "  清理 Redis 动态 PVC（保留静态 Retain PVC）"
	@echo "=========================================="
	@export KUBECONFIG="$$HOME/.kube/config-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)"; \
	if kubectl cluster-info &>/dev/null; then \
		STACK_NS=$$(yq eval '.stack.namespace // "platform"' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
		kubectl delete pvc -n "$$STACK_NS" redis-data-redis-master-0 --ignore-not-found=true || true; \
		kubectl delete pvc -n default -l app.kubernetes.io/instance=redis --ignore-not-found=true || true; \
		echo "✅ 已删 legacy 动态卷；保留 data-redis-master-0 等静态 PVC"; \
	fi
	@echo ""
	@echo "=========================================="
	@echo "  卸载 Diting Stack（仅静态 PV/PVC）"
	@echo "=========================================="
	@export KUBECONFIG="$$HOME/.kube/config-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)"; \
	if kubectl cluster-info &>/dev/null; then \
		STACK_RELEASE=$$(yq eval '.stack.release_name // "diting-stack"' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
		STACK_NS=$$(yq eval '.stack.namespace // "default"' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
		helm uninstall "$$STACK_RELEASE" -n "$$STACK_NS" 2>/dev/null || true; \
		echo "✅ Diting Stack 已卸载"; \
	fi
	@if [ "$${FULL_DESTROY:-0}" = "1" ]; then \
		_TF="$(CURDIR)/$(DEPLOY_ENGINE_DIR)/deploy/terraform/alicloud"; \
		_TF_STATE="$$_TF/terraform.tfstate"; \
		_RM_NAS=0; \
		if [ -f "$$_TF_STATE" ] && (cd "$$_TF" && terraform state show 'module.nas.alicloud_nas_access_group.main[0]' -state=terraform.tfstate 2>/dev/null | grep -q 'diting_nas_group_dev'); then \
			_RM_NAS=1; echo "[prod-down] FULL_DESTROY=1 且 Terraform state 中 NAS 为 dev 共享（diting_nas_group_dev），先从 state 移除"; \
		elif [ -f "$(CONFIG_ROOT)/terraform-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).tfvars" ] && (grep -v '^\s*#' "$(CONFIG_ROOT)/terraform-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).tfvars" 2>/dev/null | grep -qE 'nas_use_existing_access_group\s*=\s*true'); then \
			_RM_NAS=1; echo "[prod-down] FULL_DESTROY=1 且 tfvars 使用共享 NAS，先从 state 移除 NAS 访问组"; \
		fi; \
		if [ "$$_RM_NAS" = "1" ]; then \
			(cd "$$_TF" && terraform state rm 'module.nas.alicloud_nas_access_group.main[0]' -state=terraform.tfstate) || true; \
		fi; \
	fi
	@echo ""
	@echo "=========================================="
	@echo "  双环境 Down：①新加坡代理 ②香港 prod（各失败仍继续，末步汇总）"
	@echo "=========================================="
	@_proxy_down=0; _hk_down=0; \
	echo "▶ [1/2] 回收新加坡代理 ECS+EIP（diting/sg-proxy · STACK=proxy）"; \
	$(MAKE) down-sg-anthropic-proxy || { echo "❌ 新加坡代理 Down 失败"; _proxy_down=1; }; \
	echo "▶ [2/2] 回收香港 prod ECS+EIP（diting/prod · STACK=base）"; \
	CONFIG_ROOT="$(CONFIG_ROOT)" $(MAKE) -C $(DEPLOY_ENGINE_DIR) down $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV) || { echo "❌ 香港 prod Down 失败"; _hk_down=1; }; \
	if [ "$$_proxy_down" = "1" ] || [ "$$_hk_down" = "1" ]; then \
		echo "❌ make down diting prod 未完全成功（proxy=$$_proxy_down hk=$$_hk_down）"; exit 1; \
	fi
	@bash scripts/kubecm-helpers.sh remove $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV) || true
	@chmod +x scripts/spot-intent-mark.sh scripts/lib/spot-billing-lib.sh
	@bash scripts/spot-intent-mark.sh down
	@echo "make down diting prod OK（新加坡代理 + 香港 prod ECS/EIP 已回收；kubecm 已移除；prod 数据盘与静态 PV 保留）"

# ============================================================================
# v2 多 stack（P 轨）— diting-infra 壳调 deploy-engine 新 target
# ============================================================================
# 用法：make up-stack <chart-name> · make down-stack <chart-name>
# chart-name ↔ stack_id 映射：
#   diting-stack    → base
#   diting-training → train
#   diting-vllm     → infer
# 详见 03_/共享平台基础/.../02_deploy-engine扩展规约.md §3
# ============================================================================

# chart_name → stack_id / namespace 映射在 recipe 内用 shell case 完成
# 不在 Make 层定义 $(if ...) 宏（避免 line 16 export 触发 $(error) 副作用）

# 占位 target：捕获 "diting-stack" / "diting-training" / "diting-vllm" 作为参数而非 file target
.PHONY: diting-stack diting-training diting-vllm up-stack down-stack down-platform-base down-all platform-status
diting-stack diting-training diting-vllm:
	@true

up-stack: update-deploy-engine
	@_chart=$(word 2,$(MAKECMDGOALS)); \
	if [ -z "$$_chart" ]; then \
		echo "用法: make up-stack <chart-name>"; \
		echo "  chart-name ∈ {diting-stack, diting-training, diting-vllm}"; exit 1; \
	fi; \
	case "$$_chart" in \
	  diting-stack)    _stack=base ;; \
	  diting-training) _stack=train ;; \
	  diting-vllm)     _stack=infer ;; \
	  *) echo "未知 chart: $$_chart · 支持: diting-stack/diting-training/diting-vllm"; exit 1 ;; \
	esac; \
	echo "[up-stack] chart=$$_chart → stack=$$_stack"; \
	if scripts/terraform-output-safe.sh read-disk-id "$(DISK_ID_FILE)" >/dev/null 2>&1; then \
		export TF_VAR_use_existing_data_disk_id=$$(scripts/terraform-output-safe.sh read-disk-id "$(DISK_ID_FILE)"); \
		echo "[up-stack] 复用数据盘 TF_VAR_use_existing_data_disk_id=$$TF_VAR_use_existing_data_disk_id"; \
	fi; \
	CONFIG_ROOT="$(CONFIG_ROOT)" bash scripts/prod-disk-state-handoff.sh $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV) || true; \
	if ! CONFIG_ROOT="$(CONFIG_ROOT)" $(MAKE) -C $(DEPLOY_ENGINE_DIR) up-stack $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV) STACK=$$_stack; then \
		echo ""; \
		echo "=========================================="; \
		echo "  [up-stack] Terraform apply 失败，已中止后续步骤"; \
		echo "=========================================="; \
		echo "常见原因："; \
		echo "  · InvalidAccountStatus.NotEnoughBalance — 阿里云账户余额不足，无法创建按量 ECS"; \
		echo "  · Spot 库存不足 — 可临时将 stacks.base.spot_strategy 改为 NoSpot 或调高 spot_price_limit"; \
		echo "  · state 漂移 — ECS 已销毁但 EIP 仍在，充值后重试 make up-stack diting-stack 即可重建"; \
		exit 1; \
	fi; \
	bash scripts/eip-association-guard.sh "$$_stack" || echo "[up-stack] ⚠️ EIP/端口守门未通过（ECS/K3s 可能仍在启动，稍后 make kubeconfig-sync prod diting）"; \
	CONFIG_ROOT="$(CONFIG_ROOT)" bash scripts/kubeconfig-fetch.sh prod diting || true

down-stack: update-deploy-engine
	@_chart=$(word 2,$(MAKECMDGOALS)); \
	if [ -z "$$_chart" ]; then \
		echo "用法: make down-stack <chart-name>"; exit 1; \
	fi; \
	case "$$_chart" in \
	  diting-stack)    _stack=base; _ns=platform ;; \
	  diting-training) _stack=train; _ns=train ;; \
	  diting-vllm)     _stack=infer; _ns=infer ;; \
	  *) echo "未知 chart: $$_chart"; exit 1 ;; \
	esac; \
	echo "[down-stack] chart=$$_chart → stack=$$_stack ns=$$_ns"; \
	_kubecfg="$$HOME/.kube/config-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)"; \
	if [ -f "$$_kubecfg" ]; then \
		KUBECONFIG="$$_kubecfg" helm uninstall $$_chart -n $$_ns 2>/dev/null || true; \
		if [ "$$_chart" = "diting-training" ]; then \
			for r in $$(KUBECONFIG="$$_kubecfg" helm list -n train -q 2>/dev/null | grep '^diting-train-'); do \
				KUBECONFIG="$$_kubecfg" helm uninstall $$r -n train; \
			done; \
		fi; \
	else \
		echo "（kubeconfig 不存在，跳过 helm uninstall）"; \
	fi; \
	CONFIG_ROOT="$(CONFIG_ROOT)" $(MAKE) -C $(DEPLOY_ENGINE_DIR) down-stack $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV) STACK=$$_stack; \
	if [ "$$_chart" = "diting-stack" ]; then \
		bash scripts/kubecm-helpers.sh remove $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV) || true; \
	fi

down-platform-base: update-deploy-engine
	@echo "[down-platform-base] 销所有 ECS+EIP + 集群级 K8s · 保留永驻 10 项"
	@if [ -f "$$HOME/.kube/config-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)" ]; then \
		KUBECONFIG="$$HOME/.kube/config-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)" \
			helm uninstall diting-platform-base -n kube-system 2>/dev/null || true; \
	fi
	@CONFIG_ROOT="$(CONFIG_ROOT)" $(MAKE) -C $(DEPLOY_ENGINE_DIR) down-platform-base $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV)
	@bash scripts/kubecm-helpers.sh remove $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV) || true

down-all:
	@if [ "$(FULL_DESTROY)" != "1" ]; then \
		echo "错误: tier-3 完全销毁需 FULL_DESTROY=1"; \
		echo "用法: make down-all FULL_DESTROY=1"; exit 1; \
	fi
	@CONFIG_ROOT="$(CONFIG_ROOT)" FULL_DESTROY=1 $(MAKE) -C $(DEPLOY_ENGINE_DIR) down-all $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV)
	@bash scripts/kubecm-helpers.sh remove $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV) || true

platform-status:
	@CONFIG_ROOT="$(CONFIG_ROOT)" $(MAKE) -C $(DEPLOY_ENGINE_DIR) platform-status $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV)

# ============================================================================
# Spot Guard · 竞价感知启动 + 日常巡检（Phase 1 · diting-infra）
# [Ref: diting-doc/03_/_共享规约/31_Spot计费感知与巡检规约.md]
# ============================================================================
spot-prefer-on-deploy:
	@chmod +x scripts/spot-prefer-on-deploy.sh scripts/lib/spot-billing-lib.sh
	@bash scripts/spot-prefer-on-deploy.sh

spot-billing-status:
	@chmod +x scripts/lib/spot-billing-lib.sh scripts/spot-intent-mark.sh
	@bash -c 'source scripts/lib/spot-billing-lib.sh; spot_load_env "$(CURDIR)"; \
		echo "=== 运行意图 ==="; bash scripts/spot-intent-mark.sh status; echo ""; \
		echo "=== Spot 计费 / 云快照 ==="; \
		for s in proxy base; do \
		  b=$$(spot_read_state_field "$(CURDIR)" $$s billing); \
		  z=$$(spot_read_state_field "$(CURDIR)" $$s resolved_zone); \
		  i=$$(spot_read_state_field "$(CURDIR)" $$s instance_id); \
		  e=$$(spot_read_state_field "$(CURDIR)" $$s eip_address); \
		  echo "  $$s: billing=$${b:-未知} zone=$${z:-} instance=$${i:-} eip=$${e:-}"; \
		done; \
		r="$(CURDIR)/config/.spot-watch-last-report.json"; \
		if [ -f "$$r" ]; then echo ""; echo "最近巡检:"; cat "$$r"; fi'

spot-intent-mark:
	@chmod +x scripts/spot-intent-mark.sh scripts/lib/spot-billing-lib.sh
	@bash scripts/spot-intent-mark.sh "$(OP)"

cluster-spot-watch:
	@chmod +x scripts/cluster-spot-watch.sh scripts/lib/spot-billing-lib.sh scripts/sg-anthropic-proxy-helpers.sh scripts/spot-watch-send-email.py
	@CRON="$(CRON)" INTERACTIVE="$(INTERACTIVE)" bash scripts/cluster-spot-watch.sh

# 集群内 Spot Guard：同步 AK/SK Secret（deploy / prod-sync-conn-secret 也会调用）
spot-guard-sync-secret:
	@chmod +x scripts/spot-guard-sync-k8s-secret.sh
	@STACK_NS=$$(yq eval '.stack.namespace // "platform"' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml" 2>/dev/null || echo platform); \
	export KUBECONFIG="$$HOME/.kube/config-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)"; \
	STACK_NS="$$STACK_NS" bash scripts/spot-guard-sync-k8s-secret.sh "$(CONFIG_ROOT)"

# 立即触发一次集群内 CronJob（验收用）
spot-guard-cron-run-now:
	@export KUBECONFIG="$$HOME/.kube/config-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)"; \
	STACK_NS=$$(yq eval '.stack.namespace // "platform"' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml" 2>/dev/null || echo platform); \
	kubectl create job -n "$$STACK_NS" --from=cronjob/diting-spot-guard-watch "spot-guard-manual-$$(date +%s)"; \
	echo "✅ 已创建一次性 Job · 查看: kubectl get jobs -n $$STACK_NS -l component=spot-guard"

switch-stack-billing:
	@chmod +x scripts/spot-switch-stack-billing.sh scripts/lib/spot-billing-lib.sh
	@STACK="$(STACK)" BILLING="$(BILLING)" INTERACTIVE="$(INTERACTIVE)" bash scripts/spot-switch-stack-billing.sh

redeploy-prod-spot-prefer:
	@$(MAKE) spot-prefer-on-deploy
	@SKIP_SPOT_PREFER=1 $(MAKE) deploy-diting-prod

redeploy-prod-ondemand-fallback:
	@SPOT_FORCE_BILLING=ondemand $(MAKE) spot-prefer-on-deploy
	@SKIP_SPOT_PREFER=1 $(MAKE) deploy-diting-prod

# ─── P-step_03 Makefile 合约（L3 §7.2）────────────────────────────────────
.PHONY: platform-step03-prep platform-step03-up platform-step03-smoke platform-step03-test-persist platform-step03-all platform-persist-status

platform-step03-prep:
	@bash scripts/kubecm-helpers.sh ensure; \
	command -v yq >/dev/null || { echo "❌ 需要 yq"; exit 1; }; \
	command -v helm >/dev/null || { echo "❌ 需要 helm"; exit 1; }; \
	command -v kubectl >/dev/null || { echo "❌ 需要 kubectl"; exit 1; }; \
	if command -v psql >/dev/null 2>&1 || [ -x /opt/homebrew/opt/libpq/bin/psql ]; then \
	  echo "✅ psql 可用（S6/B1）"; \
	else \
	  echo "⚠️  无 psql · S6/B1 将跳过（macOS: brew install libpq && export PATH=/opt/homebrew/opt/libpq/bin:\$$PATH）"; \
	fi; \
	echo "✅ [platform-step03-prep] 工具链就绪"

platform-step03-up: platform-step03-prep
	@CONFIG_ROOT="$(CONFIG_ROOT)" PROJECT=$(PROD_DATA_ENV_PROJECT) ENV=$(PROD_DATA_ENV_ENV) \
		CONN_FILE="$(CONN_FILE)" bash scripts/platform-step03-deploy-stack.sh

platform-step03-smoke: platform-step03-prep
	@CONFIG_ROOT="$(CONFIG_ROOT)" PROJECT=$(PROD_DATA_ENV_PROJECT) ENV=$(PROD_DATA_ENV_ENV) \
		CONN_FILE="$(CONN_FILE)" bash scripts/platform-step03-smoke.sh

platform-persist-status:
	@CONFIG_ROOT="$(CONFIG_ROOT)" PROJECT=$(PROD_DATA_ENV_PROJECT) ENV=$(PROD_DATA_ENV_ENV) \
		bash scripts/platform-persist-status.sh

platform-step03-test-persist: platform-step03-prep
	@ROUNDS=$${ROUNDS:-3} CONFIG_ROOT="$(CONFIG_ROOT)" PROJECT=$(PROD_DATA_ENV_PROJECT) ENV=$(PROD_DATA_ENV_ENV) \
		CONN_FILE="$(CONN_FILE)" bash scripts/test-data-persistence.sh

platform-step03-all: platform-step03-up platform-step03-smoke platform-step03-test-persist
	@echo "✅ [platform-step03-all] up + smoke + persist 完成"

# ── Copilot 统一部署（日常唯一入口: make copilot-deploy）────────────────────
# 改 diting-src → make copilot-deploy（自动 tag / build / push / helm / rollout）
# 仅改 config/diting-prod.yaml 非镜像项 → make copilot-deploy-rollout
# 禁止为每次功能新增 *-deploy target；见 .cursorrules「Copilot 统一部署」
.PHONY: copilot-build-push copilot-build-push-if-needed copilot-push-local copilot-helm-upgrade
.PHONY: copilot-deploy copilot-deploy-rollout copilot-deploy-push copilot-deploy-full copilot-deploy-fast
.PHONY: copilot-smoke-url copilot-sync-smtp copilot-pg-deploy copilot-sync-tag-from-cluster
copilot-sync-smtp:
	@bash scripts/copilot-sync-smtp-from-src-env.sh

copilot-sync-tag-from-cluster:
	@chmod +x scripts/copilot-image-tag.sh
	@KUBECONFIG="$${KUBECONFIG:-$$HOME/.kube/config-diting-prod}" bash scripts/copilot-image-tag.sh from-cluster

copilot-build-push:
	@root="$$(dirname $(realpath $(firstword $(MAKEFILE_LIST))))"; \
	chmod +x "$$root/scripts/copilot-image-tag.sh"; \
	_tag="$${COPILOT_IMAGE_TAG:-$$(bash "$$root/scripts/copilot-image-tag.sh" resolve)}"; \
	echo "▶ [copilot-build-push] tag=$$_tag"; \
	$(MAKE) -C "$$root/../diting-src" push-copilot-image \
		DITING_ACR_PASSWORD="$${DITING_ACR_PASSWORD:-$$ACR_PASSWORD}" COPILOT_IMAGE_TAG="$$_tag"

# 内容寻址 tag：ACR 已有同 tag 才跳过；脏工作区自动 -d<hash>，避免旧镜像被同名覆盖
copilot-build-push-if-needed:
	@root="$$(dirname $(realpath $(firstword $(MAKEFILE_LIST))))"; \
	chmod +x "$$root/scripts/copilot-image-tag.sh" "$$root/scripts/copilot-push-local-if-needed.sh"; \
	_tag="$${COPILOT_IMAGE_TAG:-$$(bash "$$root/scripts/copilot-image-tag.sh" resolve)}"; \
	export COPILOT_IMAGE_TAG="$$_tag"; \
	if [ "$${COPILOT_FORCE_BUILD:-0}" = "1" ]; then \
	  echo "▶ [copilot] COPILOT_FORCE_BUILD=1 · 强制构建推送 $$_tag"; \
	  $(MAKE) copilot-build-push COPILOT_IMAGE_TAG="$$_tag"; \
	elif [ "$${COPILOT_SKIP_BUILD:-0}" = "1" ]; then \
	  echo "▶ [copilot] COPILOT_SKIP_BUILD=1 · 跳过构建（tag=$$_tag）"; \
	elif bash "$$root/scripts/copilot-acr-image-exists.sh" "$$_tag"; then \
	  echo "▶ [copilot] ACR 已有 $$_tag · 跳过构建推送"; \
	elif bash "$$root/scripts/copilot-push-local-if-needed.sh" "$$_tag"; then \
	  echo "▶ [copilot] 本地镜像已 push · 跳过 docker build"; \
	else \
	  echo "▶ [copilot] ACR 无 $$_tag 且本地无缓存 · 构建并推送（约 5–10min）"; \
	  $(MAKE) copilot-build-push COPILOT_IMAGE_TAG="$$_tag"; \
	fi

copilot-push-local:
	@chmod +x scripts/copilot-push-local-if-needed.sh scripts/copilot-image-tag.sh
	@KUBECONFIG="$${KUBECONFIG:-$$HOME/.kube/config-diting-prod}" bash scripts/copilot-push-local-if-needed.sh

copilot-helm-upgrade:
	@chmod +x scripts/copilot-helm-upgrade.sh scripts/copilot-sync-ai-from-src-env.sh scripts/copilot-image-tag.sh
	@KUBECONFIG="$${KUBECONFIG:-$$HOME/.kube/config-diting-prod}" \
	  bash scripts/copilot-helm-upgrade.sh

copilot-deploy-rollout: copilot-helm-upgrade
	@echo "✅ [copilot-deploy-rollout] 档位 A 完成 · tag=$${COPILOT_IMAGE_TAG:-$$(bash scripts/copilot-image-tag.sh resolve)}"

copilot-deploy-push: copilot-build-push-if-needed copilot-helm-upgrade
	@echo "✅ [copilot-deploy-push] 档位 B 完成 · tag=$${COPILOT_IMAGE_TAG:-$$(bash scripts/copilot-image-tag.sh resolve)}"

copilot-deploy-full:
	@chmod +x scripts/copilot-image-tag.sh
	@_tag="$${COPILOT_IMAGE_TAG:-$$(bash scripts/copilot-image-tag.sh resolve)}"; \
	$(MAKE) copilot-build-push COPILOT_IMAGE_TAG="$$_tag" && \
	$(MAKE) copilot-helm-upgrade && \
	echo "✅ [copilot-deploy-full] 档位 C 完成 · tag=$$_tag"

copilot-deploy:
	@chmod +x scripts/copilot-deploy.sh
	@KUBECONFIG="$${KUBECONFIG:-$$HOME/.kube/config-diting-prod}" bash scripts/copilot-deploy.sh smart

# 向后兼容别名（等同 copilot-deploy smart）
copilot-deploy-fast: copilot-deploy
	@:

copilot-pg-deploy:
	@chmod +x scripts/copilot-ensure-pg-db.sh scripts/copilot-pg-prod-deploy.sh \
	  scripts/copilot-acr-image-exists.sh scripts/copilot-helm-upgrade.sh
	@KUBECONFIG="$${KUBECONFIG:-$$HOME/.kube/config-diting-prod}" bash scripts/copilot-pg-prod-deploy.sh

# step_12 · 推镜像 + 滚动重启 Copilot + tier-2 HTTP 验收（①~④）
.PHONY: copilot-step12-deploy
copilot-step12-deploy: copilot-build-push-if-needed
	@echo "▶ [copilot-step12-deploy] rollout restart diting-copilot @ platform"
	@KUBECONFIG="$(KUBECONFIG)" kubectl rollout restart deployment/diting-copilot -n platform
	@KUBECONFIG="$(KUBECONFIG)" kubectl rollout status deployment/diting-copilot -n platform --timeout=300s
	@$(MAKE) -C "$$(dirname $(realpath $(firstword $(MAKEFILE_LIST))))/../diting-src" copilot-step12-tier2-verify

.PHONY: copilot-step14-deploy
copilot-step14-deploy: copilot-build-push-if-needed
	@echo "▶ [copilot-step14-deploy] rollout restart diting-copilot @ platform · step14 验收"
	@KUBECONFIG="$(KUBECONFIG)" kubectl rollout restart deployment/diting-copilot -n platform
	@KUBECONFIG="$(KUBECONFIG)" kubectl rollout status deployment/diting-copilot -n platform --timeout=300s
	@$(MAKE) -C "$$(dirname $(realpath $(firstword $(MAKEFILE_LIST))))/../diting-src" copilot-step14-tier2-verify

.PHONY: copilot-step15-deploy
copilot-step15-deploy: copilot-build-push-if-needed
	@echo "▶ [copilot-step15-deploy] rollout restart diting-copilot @ platform · step15 验收"
	@KUBECONFIG="$(KUBECONFIG)" kubectl rollout restart deployment/diting-copilot -n platform
	@KUBECONFIG="$(KUBECONFIG)" kubectl rollout status deployment/diting-copilot -n platform --timeout=300s
	@$(MAKE) -C "$$(dirname $(realpath $(firstword $(MAKEFILE_LIST))))/../diting-src" copilot-step15-tier2-verify

.PHONY: copilot-step16-deploy
copilot-step16-deploy: copilot-build-push-if-needed
	@echo "▶ [copilot-step16-deploy] rollout restart diting-copilot @ platform · step16 验收"
	@KUBECONFIG="$(KUBECONFIG)" kubectl rollout restart deployment/diting-copilot -n platform
	@KUBECONFIG="$(KUBECONFIG)" kubectl rollout status deployment/diting-copilot -n platform --timeout=300s
	@$(MAKE) -C "$$(dirname $(realpath $(firstword $(MAKEFILE_LIST))))/../diting-src" copilot-step16-tier2-verify

.PHONY: copilot-step17-deploy
copilot-funnel-deploy: copilot-build-push-if-needed
	@echo "▶ [copilot-funnel-deploy] rollout restart diting-copilot @ platform · 四区漏斗标的级重构"
	@KUBECONFIG="$(KUBECONFIG)" kubectl rollout restart deployment/diting-copilot -n platform
	@KUBECONFIG="$(KUBECONFIG)" kubectl rollout status deployment/diting-copilot -n platform --timeout=300s
	@echo "▶ [copilot-funnel-deploy] 生产清空重建（保留 holdings_sot）"
	@KUBECONFIG="$(KUBECONFIG)" kubectl exec -n platform deployment/diting-copilot -- \
		python3 scripts/copilot_funnel_cleanup.py
	@echo "✅ [copilot-funnel-deploy] 漏斗重构生产部署完成"

# 模式 C 深度研报：推镜像 + 注入 Opus env(从 diting-src/.env) + rollout + 601138 真扫验收
.PHONY: copilot-modec-deploy copilot-modec-verify
copilot-modec-deploy: copilot-build-push-if-needed
	@echo "▶ [copilot-modec-deploy] 注入 ANTHROPIC_API_KEY + RADAR_T2_ENABLED 并 helm upgrade"
	@KUBECONFIG="$(KUBECONFIG)" bash scripts/copilot-sync-ai-from-src-env.sh
	@echo "▶ [copilot-modec-deploy] rollout restart diting-copilot @ platform · 模式 C 深度研报"
	@KUBECONFIG="$(KUBECONFIG)" kubectl rollout restart deployment/diting-copilot -n platform
	@KUBECONFIG="$(KUBECONFIG)" kubectl rollout status deployment/diting-copilot -n platform --timeout=300s
	@$(MAKE) copilot-modec-verify
	@echo "✅ [copilot-modec-deploy] 模式 C 深度研报生产部署完成"

copilot-modec-verify:
	@chmod +x scripts/copilot-modec-verify.sh
	@KUBECONFIG="$(KUBECONFIG)" bash scripts/copilot-modec-verify.sh

# 新加坡 Anthropic 出口代理（deploy-engine · terraform-diting-sg-proxy.tfvars）
deploy-sg-anthropic-proxy:
	@chmod +x scripts/deploy-sg-anthropic-proxy.sh scripts/down-sg-anthropic-proxy.sh \
		scripts/sync-anthropic-proxy-to-copilot.sh scripts/sg-anthropic-proxy-helpers.sh \
		scripts/fix-sg-3proxy-systemd.sh
	@bash scripts/deploy-sg-anthropic-proxy.sh

fix-sg-3proxy-systemd:
	@chmod +x scripts/fix-sg-3proxy-systemd.sh scripts/sg-anthropic-proxy-helpers.sh
	@bash scripts/fix-sg-3proxy-systemd.sh

# 仅探测新加坡代理是否可用（不创建 ECS/EIP）
verify-sg-anthropic-proxy:
	@chmod +x scripts/sg-anthropic-proxy-helpers.sh
	@bash -c '\
		source scripts/sg-anthropic-proxy-helpers.sh; \
		INFRA="$(CURDIR)"; CONN="$$INFRA/sg-proxy.conn"; PROJ=diting; \
		ENV=$$(yq eval ".anthropic_proxy.deploy_engine_env // \"sg-proxy\"" "$(CONFIG_ROOT)/diting-prod.yaml"); \
		USER=$$(yq eval ".anthropic_proxy.user // \"ditingproxy\"" "$(CONFIG_ROOT)/diting-prod.yaml"); \
		PORT=$$(yq eval ".anthropic_proxy.port // 3128" "$(CONFIG_ROOT)/diting-prod.yaml"); \
		sg_proxy_load_env "$$INFRA"; PW=$$(sg_proxy_resolve_password "$$INFRA"); \
		sg_proxy_resolve_endpoint "$$INFRA" $$PROJ $$ENV "$$CONN" "$$PORT" || { echo "❌ 无 proxy output/conn"; exit 1; }; \
		sg_proxy_health_check "$$PROXY_IP" "$${PROXY_PORT:-$$PORT}" "$$USER" "$$PW" 1 1 \
			&& echo "✅ sg-proxy 健康 ip=$$PROXY_IP port=$${PROXY_PORT:-$$PORT}" \
			|| { echo "❌ sg-proxy 不可用 ip=$$PROXY_IP"; exit 1; }'

down-sg-anthropic-proxy:
	@chmod +x scripts/down-sg-anthropic-proxy.sh
	@bash scripts/down-sg-anthropic-proxy.sh

# 修复新加坡 proxy 上 3proxy systemd 重启循环
.PHONY: fix-sg-proxy-3proxy
fix-sg-proxy-3proxy:
	@chmod +x scripts/sg-anthropic-proxy-helpers.sh
	@bash -c 'source scripts/sg-anthropic-proxy-helpers.sh; sg_proxy_fix_3proxy_systemd "$(CURDIR)"'

# 审计香港 prod 独立数据盘（canonical=prod.disk_id）；--apply 删除孤儿盘
.PHONY: audit-prod-disks
audit-prod-disks:
	@chmod +x scripts/audit-prod-disks.sh scripts/terraform-output-safe.sh
	@bash scripts/audit-prod-disks.sh $(AUDIT_DISK_ARGS)

.PHONY: ensure-prod-data-snapshot
ensure-prod-data-snapshot:
	@chmod +x scripts/ensure-prod-data-snapshot-policy.sh scripts/terraform-output-safe.sh
	@bash scripts/ensure-prod-data-snapshot-policy.sh

sync-anthropic-proxy-to-copilot:
	@chmod +x scripts/sync-anthropic-proxy-to-copilot.sh
	@bash scripts/sync-anthropic-proxy-to-copilot.sh

# 非 prod 路径可选开关；make deploy diting prod 直接调用 deploy-sg-anthropic-proxy（强制双环境）
deploy-sg-anthropic-proxy-if-enabled:
	@_en=$$(yq eval '.anthropic_proxy.enabled // false' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
	if [ "$$_en" = "true" ]; then \
		echo "▶ [prod-up] anthropic_proxy.enabled=true → 确保新加坡代理可用（健康则复用）"; \
		$(MAKE) deploy-sg-anthropic-proxy; \
	else \
		echo "ℹ️  anthropic_proxy.enabled=false，跳过新加坡代理 ECS"; \
	fi

sync-anthropic-proxy-if-enabled:
	@_en=$$(yq eval '.anthropic_proxy.enabled // false' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
	if [ "$$_en" = "true" ]; then \
		echo "▶ [prod-up] platform-stack 已部署 → 同步 ANTHROPIC_HTTPS_PROXY 到 Copilot"; \
		$(MAKE) sync-anthropic-proxy-to-copilot; \
	else \
		echo "ℹ️  anthropic_proxy.enabled=false，跳过代理 helm 注入"; \
	fi

# 兼容旧 target 名
deploy-anthropic-proxy-if-enabled: deploy-sg-anthropic-proxy-if-enabled sync-anthropic-proxy-if-enabled

# 非 prod 路径可选开关；make down diting prod 直接调用 down-sg-anthropic-proxy（强制双环境）
down-anthropic-proxy-if-enabled:
	@_en=$$(yq eval '.anthropic_proxy.enabled // false' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
	if [ "$$_en" = "true" ]; then \
		echo "▶ [prod-down] anthropic_proxy.enabled=true → 回收新加坡代理 ECS+EIP"; \
		$(MAKE) down-sg-anthropic-proxy; \
	else \
		echo "ℹ️  anthropic_proxy.enabled=false，跳过新加坡代理 Down（make down diting prod 不受此开关影响）"; \
	fi

# 波次四：持久化 + 漏斗降级移除 + 采集数据页 + Opus 对话选模型（镜像正式部署，禁止仅热修）
.PHONY: copilot-wave4-deploy copilot-wave4-verify
copilot-wave4-deploy:
	@chmod +x scripts/copilot-wave4-prod-deploy.sh
	@KUBECONFIG="$(KUBECONFIG)" bash scripts/copilot-wave4-prod-deploy.sh

copilot-wave4-verify:
	@chmod +x scripts/copilot-wave4-verify.sh
	@KUBECONFIG="$(KUBECONFIG)" CONN_FILE="$(CONN_FILE)" bash scripts/copilot-wave4-verify.sh

.PHONY: radar-t0-sync radar-t0-collect-prod
radar-t0-sync:
	@chmod +x scripts/radar-t0-sync-to-prod.sh
	@KUBECONFIG="$(KUBECONFIG)" bash scripts/radar-t0-sync-to-prod.sh

radar-t0-collect-prod:
	@chmod +x scripts/radar-t0-collect-prod.sh
	@KUBECONFIG="$(KUBECONFIG)" bash scripts/radar-t0-collect-prod.sh

.PHONY: radar-t0-cron-install radar-t0-bootstrap-sync radar-t0-job-status
radar-t0-cron-install: copilot-helm-upgrade
	@echo "✅ [radar-t0-cron-install] Helm 已含 §2.8 CronJob（copilot.radarT0Jobs.enabled=true）"

radar-t0-bootstrap-sync:
	@chmod +x scripts/radar-t0-bootstrap-sync.sh
	@KUBECONFIG="$(KUBECONFIG)" bash scripts/radar-t0-bootstrap-sync.sh

radar-t0-job-status:
	@KUBECONFIG="$(KUBECONFIG)" kubectl -n platform exec deploy/diting-copilot -- \
		python -m apps.copilot.jobs.radar_t0 --status

# 28_ 执行中工作区 · T0 Cron + bootstrap
.PHONY: executing-t0-cron-install executing-t0-bootstrap-sync executing-t0-job-status
.PHONY: executing-bars250-bootstrap executing-bars250-verify executing-bars250-deploy
.PHONY: copilot-executing-workspace-deploy infra-middleware-verify executing-daily-status

executing-t0-cron-install: copilot-helm-upgrade
	@echo "✅ [executing-t0-cron-install] Helm 已含 copilot.executingT0Jobs（见 diting-prod.yaml）"
	@KUBECONFIG="$(KUBECONFIG)" kubectl -n platform get cronjob -l component=executing-t0 2>/dev/null || \
	  echo "ℹ️  无 executing-t0 CronJob（定时采集已关闭时为预期）"

executing-t0-bootstrap-sync:
	@chmod +x scripts/executing-t0-bootstrap-sync.sh
	@EXECUTING_T0_WAIT="$${EXECUTING_T0_WAIT:-0}" EXECUTING_T0_WAIT_TIMEOUT="$${EXECUTING_T0_WAIT_TIMEOUT:-900s}" \
	  KUBECONFIG="$(KUBECONFIG)" bash scripts/executing-t0-bootstrap-sync.sh

# 同步等待 bootstrap（显式阻塞 · 默认 timeout 15min）
executing-t0-bootstrap-sync-wait:
	@chmod +x scripts/executing-t0-bootstrap-sync.sh
	@EXECUTING_T0_WAIT=1 EXECUTING_T0_WAIT_TIMEOUT="$${EXECUTING_T0_WAIT_TIMEOUT:-900s}" \
	  KUBECONFIG="$(KUBECONFIG)" bash scripts/executing-t0-bootstrap-sync.sh

executing-t0-catchup-eod:
	@chmod +x scripts/executing-t0-catchup-eod.sh
	@KUBECONFIG="$(KUBECONFIG)" bash scripts/executing-t0-catchup-eod.sh

executing-bars250-bootstrap:
	@chmod +x scripts/executing-bars250-bootstrap.sh
	@KUBECONFIG="$(KUBECONFIG)" MIN_BARS="$(MIN_BARS)" bash scripts/executing-bars250-bootstrap.sh

executing-bars250-verify:
	@chmod +x scripts/executing-bars250-verify.sh
	@KUBECONFIG="$(KUBECONFIG)" MIN_BARS="$(MIN_BARS)" bash scripts/executing-bars250-verify.sh

# 推镜像 + 关 Cron + 一次性 250 日底库采集 + DB 验收
executing-bars250-deploy: copilot-deploy-fast
	@$(MAKE) executing-bars250-bootstrap
	@$(MAKE) executing-bars250-verify

executing-t0-job-status:
	@KUBECONFIG="$(KUBECONFIG)" kubectl -n platform exec deploy/diting-copilot -- \
		python -m apps.copilot.jobs.executing_t0 --status

# 29_ §9 · 基础设施中间件验收（Redis / ARQ / OpenSearch / Cron enqueue）
infra-middleware-verify:
	@chmod +x scripts/infra-middleware-verify.sh
	@KUBECONFIG="$${KUBECONFIG:-$$HOME/.kube/config-diting-prod}" bash scripts/infra-middleware-verify.sh

# 29_ §9 #8 别名 · 执行区 pipeline 状态
executing-daily-status: executing-t0-job-status

copilot-executing-workspace-deploy: copilot-deploy-fast
	@echo "▶ [copilot-executing-workspace-deploy] Pod 内 migrate + 导入持仓（失败时见 rollout 内存 limit≥1536Mi）"
	@KUBECONFIG="$(KUBECONFIG)" kubectl -n platform rollout status deployment/diting-copilot -n platform --timeout=300s
	@KUBECONFIG="$(KUBECONFIG)" kubectl -n platform exec deploy/diting-copilot -- \
		python -c "import asyncio; from apps.copilot.db.database import init_db; asyncio.run(init_db()); print('✅ executing migrate ok')" \
		|| (echo "⚠️  migrate exec 失败(常见137 OOM) · 可改由 executing-t0-bootstrap-sync Job 补跑" && false)
	@KUBECONFIG="$(KUBECONFIG)" kubectl -n platform exec deploy/diting-copilot -- \
		python scripts/executing_import_positions.py || true
	@echo "ℹ️  [copilot-executing-workspace-deploy] 定时采集已关闭 · 250 日底库请 make executing-bars250-deploy"
	@chmod +x scripts/copilot-executing-tier2-verify-k8s.sh
	@EXECUTING_SYMBOL="$${EXECUTING_SYMBOL:-601138}" bash scripts/copilot-executing-tier2-verify-k8s.sh

.PHONY: copilot-step17-deploy
copilot-step17-deploy: copilot-build-push-if-needed
	@echo "▶ [copilot-step17-deploy] rollout restart diting-copilot @ platform · step17 执行仓位指导验收"
	@KUBECONFIG="$(KUBECONFIG)" kubectl rollout restart deployment/diting-copilot -n platform
	@KUBECONFIG="$(KUBECONFIG)" kubectl rollout status deployment/diting-copilot -n platform --timeout=300s
	@$(MAKE) -C "$$(dirname $(realpath $(firstword $(MAKEFILE_LIST))))/../diting-src" copilot-step17-test

copilot-smoke-url:
	@_ip=$$(grep '^PUBLIC_IP=' "$(CONN_FILE)" 2>/dev/null | cut -d= -f2-); \
	_port=$$(yq eval '.stack.copilot.service.nodePort // 30080' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
	echo "Copilot 前端: http://$$_ip:$$_port/health-dashboard"; \
	echo "工业富联详情: http://$$_ip:$$_port/health-detail/601138"

# P-step_04 · Spot 无库存时定时重试 up-stack diting-training（默认 2h 一次）
.PHONY: retry-up-stack-training retry-up-stack-training-once retry-up-stack-training-status retry-up-stack-training-stop
retry-up-stack-training:
	@bash scripts/retry-up-stack-training.sh

retry-up-stack-training-once:
	@RETRY_ONCE=1 bash scripts/retry-up-stack-training.sh

retry-up-stack-training-status:
	@if [ -f logs/retry-up-stack-training.state ]; then cat logs/retry-up-stack-training.state; else echo "（无 state 文件 · 重试循环未运行或未启动）"; fi
	@if [ -f logs/retry-up-stack-training.pid ] && kill -0 "$$(cat logs/retry-up-stack-training.pid)" 2>/dev/null; then echo "pid=$$(cat logs/retry-up-stack-training.pid) running=1"; else echo "running=0"; fi
	@if [ -f logs/retry-up-stack-training.log ]; then echo "--- tail log ---"; tail -5 logs/retry-up-stack-training.log; fi

retry-up-stack-training-stop:
	@if [ -f logs/retry-up-stack-training.pid ]; then \
		pid=$$(cat logs/retry-up-stack-training.pid); \
		if kill -0 "$$pid" 2>/dev/null; then kill "$$pid" && echo "已停止 retry 循环 pid=$$pid"; else echo "pid=$$pid 已不在运行"; fi; \
		rm -f logs/retry-up-stack-training.pid; \
	else echo "无 pid 文件"; fi

# ===========================================================================
# D5 P-step_04 GPU 训练 targets（W5）
# [Ref: 03_/05_维度五/stages/stage_1_启动期/steps/step_04_C3_LLaMA_Factory训练流水线.md §7.2]
# ===========================================================================
TRAIN_NS        ?= train
TRAIN_MAX_STEPS ?= 500
TRAIN_IMAGE_TAG ?= latest
KUBECONFIG      ?= $(HOME)/.kube/config-diting-prod

.PHONY: evo-step04-prep evo-step04-train-cryo evo-step04-train-thrust evo-step04-train-narrative \
        evo-step04-status evo-step04-clean evo-step04-all

evo-step04-prep:
	@echo "[evo-step04-prep] 检查 GPU 节点与 NAS..."
	@KUBECONFIG=$(KUBECONFIG) kubectl get node -l nvidia.com/gpu=present 2>&1 | grep -q "Ready" \
		&& echo "✅ GPU 节点 Ready" \
		|| { echo "❌ 无 Ready GPU 节点，请先 make up-stack diting-training"; exit 1; }
	@KUBECONFIG=$(KUBECONFIG) kubectl get ns $(TRAIN_NS) 2>/dev/null || \
		KUBECONFIG=$(KUBECONFIG) kubectl create ns $(TRAIN_NS)
	@echo "✅ [evo-step04-prep] 就绪"

# 各维度训练 Job（helm install · 幂等：同 release 已存在则 upgrade）
evo-step04-train-cryo: evo-step04-prep
	@echo "[evo-step04-train-cryo] 安装训练 Job dim=cryo maxSteps=$(TRAIN_MAX_STEPS)"
	@KUBECONFIG=$(KUBECONFIG) helm upgrade --install diting-train-cryo ./charts/diting-training \
		--namespace $(TRAIN_NS) \
		--set training.dim=cryo \
		--set training.maxSteps=$(TRAIN_MAX_STEPS) \
		--set image.tag=$(TRAIN_IMAGE_TAG) \
		--wait --timeout 180m
	@echo "✅ [evo-step04-train-cryo] 完成"

evo-step04-train-thrust: evo-step04-prep
	@echo "[evo-step04-train-thrust] 安装训练 Job dim=thrust maxSteps=$(TRAIN_MAX_STEPS)"
	@KUBECONFIG=$(KUBECONFIG) helm upgrade --install diting-train-thrust ./charts/diting-training \
		--namespace $(TRAIN_NS) \
		--set training.dim=thrust \
		--set training.maxSteps=$(TRAIN_MAX_STEPS) \
		--set image.tag=$(TRAIN_IMAGE_TAG) \
		--wait --timeout 180m
	@echo "✅ [evo-step04-train-thrust] 完成"

evo-step04-train-narrative: evo-step04-prep
	@echo "[evo-step04-train-narrative] 安装训练 Job dim=narrative maxSteps=$(TRAIN_MAX_STEPS)"
	@KUBECONFIG=$(KUBECONFIG) helm upgrade --install diting-train-narrative ./charts/diting-training \
		--namespace $(TRAIN_NS) \
		--set training.dim=narrative \
		--set training.maxSteps=$(TRAIN_MAX_STEPS) \
		--set image.tag=$(TRAIN_IMAGE_TAG) \
		--wait --timeout 180m
	@echo "✅ [evo-step04-train-narrative] 完成"

evo-step04-status:
	@echo "[evo-step04-status] 训练 Job 状态（namespace: $(TRAIN_NS)）"
	@KUBECONFIG=$(KUBECONFIG) kubectl get jobs,pods -n $(TRAIN_NS) -l app=diting-train \
		-o wide 2>/dev/null || echo "（无训练 Job）"

evo-step04-clean:
	@echo "[evo-step04-clean] 清理训练 releases..."
	@for dim in cryo thrust narrative; do \
		KUBECONFIG=$(KUBECONFIG) helm uninstall diting-train-$$dim -n $(TRAIN_NS) 2>/dev/null \
			&& echo "  已删除 diting-train-$$dim" || true; \
	done
	@echo "✅ [evo-step04-clean] 完成"

evo-step04-all: evo-step04-train-cryo
	@echo "✅ [evo-step04-all] 至少 1 维（cryo）训练完成"

# ===========================================================================
# P-step_05 · GPU 推理组（diting-vllm）
# ===========================================================================
INFER_NS ?= infer

.PHONY: platform-step05-prep platform-step05-install-infer platform-step05-status platform-step05-all

platform-step05-prep:
	@echo "[platform-step05-prep] 检查 infer GPU 节点..."
	@KUBECONFIG=$(KUBECONFIG) kubectl get node -l stack.diting/node=infer 2>&1 | grep -q "Ready" \
		&& echo "✅ infer GPU 节点 Ready" \
		|| { echo "❌ 无 Ready infer 节点，请先 make up-stack diting-vllm"; exit 1; }
	@KUBECONFIG=$(KUBECONFIG) kubectl get ns $(INFER_NS) 2>/dev/null || \
		KUBECONFIG=$(KUBECONFIG) kubectl create ns $(INFER_NS)
	@echo "✅ [platform-step05-prep] 就绪"

platform-step05-install-infer: platform-step05-prep
	@echo "[platform-step05-install-infer] 部署 vLLM Deployment..."
	@KUBECONFIG=$(KUBECONFIG) helm upgrade --install diting-infer ./charts/diting-vllm \
		--namespace $(INFER_NS) \
		--wait --timeout 5m
	@echo "✅ [platform-step05-install-infer] vLLM 就绪"

platform-step05-status:
	@echo "[platform-step05-status] infer namespace 状态"
	@KUBECONFIG=$(KUBECONFIG) kubectl get nodes -l stack.diting/node=infer -o wide 2>/dev/null || true
	@KUBECONFIG=$(KUBECONFIG) kubectl get deploy,pods,svc -n $(INFER_NS) -l app=diting-infer 2>/dev/null || \
		KUBECONFIG=$(KUBECONFIG) kubectl get all -n $(INFER_NS) 2>/dev/null || echo "（infer ns 空）"

platform-step05-all: platform-step05-install-infer
	@KUBECONFIG=$(KUBECONFIG) kubectl exec -n $(INFER_NS) deploy/diting-infer -- \
		curl -s localhost:8000/v1/models 2>/dev/null | head -c 500 || \
		echo "（探活待 Pod Ready 后重试）"
	@echo "✅ [platform-step05-all] infer 部署完成"
