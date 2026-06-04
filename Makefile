# diting-infra Makefile
# [Ref: 03_原子目标与规约/开发与交付/02_基础设施与部署规约]
# Stage1-03：每次执行前先 update-deploy-engine，再 deploy-dev / down

# deploy-engine 从本仓扁平 config 读配置（与 deploy-engine 约定一致，无更深目录）
CONFIG_ROOT = $(CURDIR)/config
PROJECT ?= diting
ENV ?= dev
DEPLOY_ENGINE_DIR = deploy-engine

# Stage2-01 验证环境清理：无论验证是否完成都要执行，避免残留（release/namespace 与部署时一致）
STAGE2_01_NS ?= default

# 从 .env 加载阿里云 AKSK 等（若存在），供 Terraform / deploy-engine 使用
-include .env
export

.PHONY: update-deploy-engine deploy deploy-dev down stage2-01-down stage2-01-full-down diting prod sg-proxy
.PHONY: deploy-sg-anthropic-proxy down-sg-anthropic-proxy sync-anthropic-proxy-to-copilot deploy-anthropic-proxy-if-enabled down-anthropic-proxy-if-enabled
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

.PHONY: deploy-diting-prod down-diting-prod deploy-diting-prod-with-ingest prod-write-conn prod-sync-conn-secret deploy-ingest-job

# 兼容旧命令（推荐使用 make deploy diting prod / make down diting prod）
deploy-data-db-prod: deploy-diting-prod
down-data-db-prod: down-diting-prod

# make deploy diting prod 的实际执行 target。若 Terraform state 中 NAS 访问组仍为 dev 共享（diting_nas_group_dev），deploy 时会尝试 replace 并销毁该资源导致 InvalidAccessGroup.AlreadyAttached；Up 前先从 state 移除，让 Terraform 仅创建 prod 自有 NAS
deploy-diting-prod: update-deploy-engine
	@if [ ! -f "$(CONFIG_ROOT)/terraform-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).tfvars" ]; then \
		echo "错误: 请先创建 config/terraform-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).tfvars（可参考 config/terraform-diting-dev.tfvars）"; exit 1; \
	fi
	@{ \
		_LOG="/tmp/deploy-diting-prod-debug.log"; \
		_TF="$(CURDIR)/$(DEPLOY_ENGINE_DIR)/deploy/terraform/alicloud"; \
		_TF_STATE="$$_TF/terraform.tfstate"; \
		_EX=1; [ -f "$$_TF_STATE" ] && _EX=0; \
		echo "{\"sessionId\":\"9c44dd\",\"hypothesisId\":\"H1\",\"location\":\"Makefile:deploy-diting-prod\",\"message\":\"nas-pre\",\"data\":{\"tf_state_path\":\"$$_TF_STATE\",\"state_file_exists\":$$_EX},\"timestamp\":$$(date +%s000)}" >> "$$_LOG" 2>/dev/null || true; \
		if [ "$$_EX" = "0" ]; then \
			_SHOW_OUT=$$(cd "$$_TF" && terraform state show 'module.nas.alicloud_nas_access_group.main[0]' 2>&1); \
			_SHOW_EC=$$?; \
			_OUT_LEN=$$(echo "$$_SHOW_OUT" | wc -c | tr -d ' '); \
			echo "{\"sessionId\":\"9c44dd\",\"hypothesisId\":\"H2\",\"message\":\"state-show\",\"data\":{\"exit_code\":$$_SHOW_EC,\"out_len\":$$_OUT_LEN},\"timestamp\":$$(date +%s000)}" >> "$$_LOG" 2>/dev/null || true; \
			_GREP_MATCH=0; echo "$$_SHOW_OUT" | grep -q 'diting_nas_group_dev' && _GREP_MATCH=1; \
			echo "{\"sessionId\":\"9c44dd\",\"hypothesisId\":\"H3\",\"message\":\"grep-result\",\"data\":{\"grep_matched\":$$_GREP_MATCH},\"timestamp\":$$(date +%s000)}" >> "$$_LOG" 2>/dev/null || true; \
			if [ "$$_GREP_MATCH" = "1" ]; then \
				echo "[prod-up] state 中 NAS 为 dev 共享（diting_nas_group_dev），先从 state 移除再 deploy，避免 replace 时误删"; \
				echo "{\"sessionId\":\"9c44dd\",\"hypothesisId\":\"H4\",\"message\":\"entered-then-will-rm\",\"data\":{},\"timestamp\":$$(date +%s000)}" >> "$$_LOG" 2>/dev/null || true; \
				(cd "$$_TF" && terraform state rm 'module.nas.alicloud_nas_access_group.main[0]'); \
				_RM_EC=$$?; \
				echo "{\"sessionId\":\"9c44dd\",\"hypothesisId\":\"H5\",\"message\":\"state-rm-done\",\"data\":{\"exit_code\":$$_RM_EC},\"timestamp\":$$(date +%s000)}" >> "$$_LOG" 2>/dev/null || true; \
			fi; \
		fi; \
	}
	@if [ -f "$(DISK_ID_FILE)" ]; then \
		export TF_VAR_use_existing_data_disk_id=$$(cat "$(DISK_ID_FILE)"); \
		(cd $(DEPLOY_ENGINE_DIR)/deploy/terraform/alicloud && terraform state rm 'alicloud_disk.prod_data[0]' -state=terraform.tfstate 2>/dev/null) || true; \
	else \
		echo "[prod-up] 数据盘不存在，先创建数据盘..."; \
		_REGION=$$(grep -E '^\s*region\s*=' "$(CONFIG_ROOT)/terraform-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).tfvars" 2>/dev/null | head -1 | sed -E 's/^[^=]*=\s*"?([^"]+)"?.*/\1/' | tr -d ' '); \
		[ -z "$$_REGION" ] && _REGION=cn-hongkong; \
		export ALICLOUD_REGION="$$_REGION"; \
		(cd $(DEPLOY_ENGINE_DIR)/deploy/terraform/alicloud && \
			terraform init && \
			terraform apply -target=alicloud_disk.prod_data -auto-approve \
				-var-file="$(CONFIG_ROOT)/terraform-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).tfvars" \
				-var=env_id=$(PROD_DATA_ENV_ENV) \
				-var=project=$(PROD_DATA_ENV_PROJECT) \
				-var=region="$$_REGION" \
				-var=config_file="$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
		_DISK_ID=$$(cd $(DEPLOY_ENGINE_DIR)/deploy/terraform/alicloud && terraform output -raw data_disk_id 2>/dev/null); \
		if [ -n "$$_DISK_ID" ]; then \
			echo "$$_DISK_ID" > "$(DISK_ID_FILE)"; \
			echo "[prod-up] 数据盘已创建: $$_DISK_ID"; \
		fi; \
	fi
	@CONFIG_ROOT="$(CONFIG_ROOT)" $(MAKE) -C $(DEPLOY_ENGINE_DIR) deploy $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV)
	@$(MAKE) deploy-anthropic-proxy-if-enabled
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
	@$(MAKE) -f $(CURDIR)/Makefile prod-write-conn
	@echo ""
	@echo "=========================================="
	@echo "  执行 Schema 初始化与数据采集（远程 K3s Job）"
	@echo "=========================================="
	@INGEST_ENABLED=$$(yq eval '.data_ingestion.enabled // false' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
	USE_K3S_JOB=$$(yq eval '.data_ingestion.use_k3s_job // true' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
	if [ "$${SKIP_INGEST:-0}" = "1" ]; then \
		echo "SKIP_INGEST=1，跳过数据采集（persist / smoke 场景）"; \
	elif [ "$$INGEST_ENABLED" = "true" ]; then \
		if [ "$$USE_K3S_JOB" = "true" ]; then \
			$(MAKE) deploy-ingest-job WAIT=wait; \
		else \
			CORE_REPO=$$(yq eval '.data_ingestion.core_repo_path // ""' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
			[ -z "$$CORE_REPO" ] && CORE_REPO="$${REPO_I_ROOT:-}"; \
			if [ -n "$$CORE_REPO" ] && [ -d "$$CORE_REPO" ]; then \
				INGEST_TARGET=$$(yq eval '.data_ingestion.target // "ingest-test"' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
				echo "执行数据采集(宿主机): $$INGEST_TARGET"; cp "$(CONN_FILE)" "$$CORE_REPO/.env" && $(MAKE) -C "$$CORE_REPO" "$$INGEST_TARGET" && echo "✅ 数据采集完成"; \
			else echo "⚠️  core_repo_path/REPO_I_ROOT 未设置，跳过"; fi; \
		fi; \
	else echo "数据采集已禁用（data_ingestion.enabled=false），跳过"; fi
	@echo ""
	@echo "=========================================="
	@echo "  ✅ 部署完成！"
	@echo "=========================================="
	@echo ""
	@echo "kubecm 已合并 kubeconfig 并切换 context → $(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)"
	@echo "KUBECONFIG=$$HOME/.kube/config（已写入 ~/.bashrc / ~/.zshrc / ~/.profile）"
	@echo "当前终端: export KUBECONFIG=\"$$HOME/.kube/config\" 或 source ~/.bashrc"
	@echo "切换环境: kubecm switch <context> · 列表: kubecm ls"
	@echo ""
	@echo "验证: kubectl get nodes && kubectl get pods -A"
	@echo "=========================================="
	@echo ""

# 将连接信息写入 prod.conn（EIP 与 NodePort 从 deploy-engine 输出或 kubectl 获取）
prod-write-conn:
	@scripts/prod-write-conn.sh "$(CONFIG_ROOT)" "$(DEPLOY_ENGINE_DIR)" "$(CONN_FILE)" $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV) || true
	@echo "连接信息已写入 $(CONN_FILE)（若脚本未实现则需人工填写 EIP 与 NodePort）"

# 将 prod.conn 同步为 K8s Secret diting-db-connection（供 schema-init hook 与 ingest Job 使用）
# Job 在集群内运行，须使用集群内 Service 地址；prod.conn 仍为公网 NodePort 供本机 verify 使用
prod-sync-conn-secret:
	@STACK_NS=$$(yq eval '.stack.namespace // "platform"' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml" 2>/dev/null || echo platform); \
	export KUBECONFIG="$$HOME/.kube/config-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)"; \
	STACK_NS="$$STACK_NS" scripts/prod-sync-conn-secret.sh "$(CONFIG_ROOT)" "$(CONN_FILE)" $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV)

# 在远程 K3s 部署并运行采集 Job（helm upgrade diting-stack · ingest.enabled；Secret 由 prod-sync-conn-secret 提供）
# 用法: make deploy-ingest-job [WAIT=wait] [INGEST_TARGET=ingest-test-real|ingest-production]
# 步骤 3/7 默认 ingest-test-real；步骤 8 全量采集: make deploy-ingest-job INGEST_TARGET=ingest-production WAIT=wait
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
	@$(MAKE) down-anthropic-proxy-if-enabled
	@CONFIG_ROOT="$(CONFIG_ROOT)" $(MAKE) -C $(DEPLOY_ENGINE_DIR) down $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV)
	@bash scripts/kubecm-helpers.sh remove $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV) || true
	@echo "make down diting prod OK（香港 + 新加坡代理 ECS/EIP 已回收；kubecm 已移除；prod 数据盘与静态 PV 保留）"

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
	if [ -f "$(DISK_ID_FILE)" ]; then \
		export TF_VAR_use_existing_data_disk_id=$$(cat "$(DISK_ID_FILE)"); \
		echo "[up-stack] 复用数据盘 TF_VAR_use_existing_data_disk_id=$$TF_VAR_use_existing_data_disk_id"; \
	fi; \
	CONFIG_ROOT="$(CONFIG_ROOT)" $(MAKE) -C $(DEPLOY_ENGINE_DIR) up-stack $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV) STACK=$$_stack; \
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

# Copilot 部署加速：依赖层 Dockerfile · 仅推 sha · ACR 已有则跳过构建 · CI 构建 + 本地 helm-only
.PHONY: copilot-build-push copilot-build-push-if-needed copilot-helm-upgrade copilot-deploy-fast
.PHONY: copilot-smoke-url copilot-sync-smtp copilot-pg-deploy
copilot-sync-smtp:
	@bash scripts/copilot-sync-smtp-from-src-env.sh
copilot-build-push:
	@root="$$(dirname $(realpath $(firstword $(MAKEFILE_LIST))))"; \
	_tag="$${COPILOT_IMAGE_TAG:-$$(git -C "$$root/../diting-src" rev-parse --short HEAD 2>/dev/null || echo latest)}"; \
	$(MAKE) -C "$$root/../diting-src" push-copilot-image \
		DITING_ACR_PASSWORD="$${DITING_ACR_PASSWORD:-$$ACR_PASSWORD}" COPILOT_IMAGE_TAG="$$_tag"

# ACR 已有同 tag 且未设 COPILOT_FORCE_BUILD=1 时跳过 build/push
copilot-build-push-if-needed:
	@root="$$(dirname $(realpath $(firstword $(MAKEFILE_LIST))))"; \
	_tag="$${COPILOT_IMAGE_TAG:-$$(git -C "$$root/../diting-src" rev-parse --short HEAD 2>/dev/null || echo latest)}"; \
	if [ "$${COPILOT_FORCE_BUILD:-0}" = "1" ]; then \
	  echo "▶ [copilot] COPILOT_FORCE_BUILD=1 · 强制构建推送 $$_tag"; \
	  $(MAKE) copilot-build-push COPILOT_IMAGE_TAG="$$_tag"; \
	elif bash "$$root/scripts/copilot-acr-image-exists.sh" "$$_tag"; then \
	  echo "▶ [copilot] ACR 已有 $$_tag · 跳过构建推送"; \
	else \
	  echo "▶ [copilot] ACR 无 $$_tag · 构建并推送"; \
	  $(MAKE) copilot-build-push COPILOT_IMAGE_TAG="$$_tag"; \
	fi

# 仅 Helm + rollout（镜像已由 CI/此前 push 提供）
copilot-helm-upgrade:
	@chmod +x scripts/copilot-helm-upgrade.sh scripts/copilot-sync-ai-from-src-env.sh
	@KUBECONFIG="$${KUBECONFIG:-$$HOME/.kube/config-diting-prod}" \
	  COPILOT_IMAGE_TAG="$${COPILOT_IMAGE_TAG:-$$(git -C "$$(dirname $(realpath $(firstword $(MAKEFILE_LIST))))/../diting-src" rev-parse --short HEAD 2>/dev/null)}" \
	  bash scripts/copilot-helm-upgrade.sh

# 推荐日常：智能 build（如需）+ Helm；纯配置变更可 COPILOT_SKIP_BUILD=1 make copilot-deploy-fast
copilot-deploy-fast: copilot-build-push-if-needed copilot-helm-upgrade
	@echo "✅ [copilot-deploy-fast] 完成"

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
	@chmod +x scripts/deploy-sg-anthropic-proxy.sh scripts/down-sg-anthropic-proxy.sh scripts/sync-anthropic-proxy-to-copilot.sh
	@bash scripts/deploy-sg-anthropic-proxy.sh

down-sg-anthropic-proxy:
	@chmod +x scripts/down-sg-anthropic-proxy.sh
	@bash scripts/down-sg-anthropic-proxy.sh

sync-anthropic-proxy-to-copilot:
	@chmod +x scripts/sync-anthropic-proxy-to-copilot.sh
	@KUBECONFIG="$(KUBECONFIG)" bash scripts/sync-anthropic-proxy-to-copilot.sh

deploy-anthropic-proxy-if-enabled:
	@_en=$$(yq eval '.anthropic_proxy.enabled // false' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
	if [ "$$_en" = "true" ]; then \
		echo "▶ [prod-up] anthropic_proxy.enabled=true → 部署新加坡代理 ECS+EIP 并同步 HTTPS_PROXY"; \
		$(MAKE) deploy-sg-anthropic-proxy; \
		$(MAKE) sync-anthropic-proxy-to-copilot; \
	else \
		echo "ℹ️  anthropic_proxy.enabled=false，跳过新加坡代理"; \
	fi

down-anthropic-proxy-if-enabled:
	@_en=$$(yq eval '.anthropic_proxy.enabled // false' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
	if [ "$$_en" = "true" ]; then \
		echo "▶ [prod-down] anthropic_proxy.enabled=true → 回收新加坡代理 ECS+EIP"; \
		$(MAKE) down-sg-anthropic-proxy; \
	else \
		echo "ℹ️  anthropic_proxy.enabled=false，跳过新加坡代理 Down"; \
	fi

# 波次四：持久化 + 漏斗降级移除 + 采集数据页 + Opus 对话选模型（镜像正式部署，禁止仅热修）
.PHONY: copilot-wave4-deploy copilot-wave4-verify
copilot-wave4-deploy:
	@chmod +x scripts/copilot-wave4-prod-deploy.sh
	@KUBECONFIG="$(KUBECONFIG)" bash scripts/copilot-wave4-prod-deploy.sh

copilot-wave4-verify:
	@chmod +x scripts/copilot-wave4-verify.sh
	@KUBECONFIG="$(KUBECONFIG)" CONN_FILE="$(CONN_FILE)" bash scripts/copilot-wave4-verify.sh

.PHONY: copilot-radar-audit-hotfix-deploy
copilot-radar-audit-hotfix-deploy:
	@echo "⚠️  已弃用：请用 make copilot-wave4-deploy（镜像+Helm 正式部署）"
	@chmod +x scripts/copilot-radar-audit-hotfix-deploy.sh
	@KUBECONFIG="$(KUBECONFIG)" bash scripts/copilot-radar-audit-hotfix-deploy.sh

.PHONY: radar-t0-sync radar-t0-collect-prod
radar-t0-sync:
	@chmod +x scripts/radar-t0-sync-to-prod.sh
	@KUBECONFIG="$(KUBECONFIG)" bash scripts/radar-t0-sync-to-prod.sh

radar-t0-collect-prod:
	@chmod +x scripts/radar-t0-collect-prod.sh
	@KUBECONFIG="$(KUBECONFIG)" bash scripts/radar-t0-collect-prod.sh

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
