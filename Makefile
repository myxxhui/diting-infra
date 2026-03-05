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

.PHONY: update-deploy-engine deploy deploy-dev down stage2-01-down stage2-01-full-down diting prod

# 占位目标：make deploy diting prod / make down diting prod 时不被当作文件
diting:
	@true
prod:
	@true

# 每次执行 Stage1-03 前必做：更新 deploy-engine 代码（submodule）
update-deploy-engine:
	@git submodule update --init --remote $(DEPLOY_ENGINE_DIR) && echo "[OK] deploy-engine 已更新"

# make deploy [project] [env]：无参数时用 PROJECT/ENV；make deploy diting prod = 生产数据环境 Up
deploy: update-deploy-engine
	@_p=$(word 2,$(MAKECMDGOALS)); _e=$(word 3,$(MAKECMDGOALS)); \
	if [ "$$_p" = "diting" ] && [ "$$_e" = "prod" ]; then $(MAKE) deploy-diting-prod; else CONFIG_ROOT="$(CONFIG_ROOT)" $(MAKE) -C $(DEPLOY_ENGINE_DIR) deploy "$${_p:-$(PROJECT)}" "$${_e:-$(ENV)}"; fi

# 调用 deploy-engine Up（需 Terraform 与云凭证）；等价 make deploy $(PROJECT) $(ENV)
deploy-dev: update-deploy-engine
	@CONFIG_ROOT="$(CONFIG_ROOT)" $(MAKE) -C $(DEPLOY_ENGINE_DIR) deploy $(PROJECT) $(ENV)

# make down [project] [env]：无参数时用 PROJECT/ENV；make down diting prod = 生产数据环境 Down（回收且磁盘保留）
down:
	@_p=$(word 2,$(MAKECMDGOALS)); _e=$(word 3,$(MAKECMDGOALS)); \
	if [ "$$_p" = "diting" ] && [ "$$_e" = "prod" ]; then $(MAKE) down-diting-prod; else CONFIG_ROOT="$(CONFIG_ROOT)" $(MAKE) -C $(DEPLOY_ENGINE_DIR) down "$${_p:-$(PROJECT)}" "$${_e:-$(ENV)}"; fi

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
# 在 diting-infra 执行 up/init 后，在 diting-core 配置 .env 指向 localhost:15432/15433/15479（L1/L2/Redis）并执行 make verify diting prod、ingest-test
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
	@echo "local-deps-init OK（请在 diting-core 配置 .env：TIMESCALE_DSN、PG_L2_DSN、REDIS_URL=redis://localhost:15479/0 后执行 make verify diting prod、make ingest-test）"

# ---------- Stage2-06 生产环境（Up/Down 与 prod.conn 输出）----------
# 见 04_阶段规划与实践/Stage2_数据采集与存储/06_生产级数据要求_实践.md
# 配置：config/terraform-diting-prod.tfvars、config/diting-prod.yaml（部署 PG/Redis、K3s 存储等由 YAML 控制）
# Down 仅回收 ECS/K3s/EIP、保留独立数据盘（再次 Up 挂载同盘）；disk_id 持久化于 prod.disk_id
PROD_DATA_ENV_PROJECT = diting
PROD_DATA_ENV_ENV     = prod
CONN_FILE             = $(CURDIR)/prod.conn
DISK_ID_FILE          = $(CURDIR)/prod.disk_id

.PHONY: deploy-diting-prod down-diting-prod fix-diting-prod-stale-eip deploy-diting-prod-with-ingest prod-write-conn apply-acr-pull-secret print-kubeconfig

# 兼容旧命令（推荐使用 make deploy diting prod / make down diting prod）
deploy-data-db-prod: deploy-diting-prod
down-data-db-prod: down-diting-prod

# make deploy diting prod 的实际执行 target。若 Terraform state 中 NAS 访问组仍为 dev 共享（diting_nas_group_dev），deploy 时会尝试 replace 并销毁该资源导致 InvalidAccessGroup.AlreadyAttached；Up 前先从 state 移除，让 Terraform 仅创建 prod 自有 NAS
deploy-diting-prod: update-deploy-engine
	@if [ ! -f "$(CONFIG_ROOT)/terraform-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).tfvars" ]; then \
		echo "错误: 请先创建 config/terraform-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).tfvars（可参考 config/terraform-diting-dev.tfvars）"; exit 1; \
	fi
	@{ \
		_LOG="/Users/huishaoqi/Desktop/workspace/.cursor/debug-9c44dd.log"; \
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
		(cd $(DEPLOY_ENGINE_DIR)/deploy/terraform/alicloud && \
			terraform init && \
			terraform apply -target=alicloud_disk.prod_data -auto-approve \
				-var-file="$(CONFIG_ROOT)/terraform-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).tfvars" \
				-var=env_id=$(PROD_DATA_ENV_ENV) \
				-var=project=$(PROD_DATA_ENV_PROJECT) \
				-var=config_file="$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
		_DISK_ID=$$(cd $(DEPLOY_ENGINE_DIR)/deploy/terraform/alicloud && terraform output -raw data_disk_id 2>/dev/null); \
		if [ -n "$$_DISK_ID" ]; then \
			echo "$$_DISK_ID" > "$(DISK_ID_FILE)"; \
			echo "[prod-up] 数据盘已创建: $$_DISK_ID"; \
		fi; \
	fi
	CONFIG_ROOT="$(CONFIG_ROOT)" $(MAKE) -C $(DEPLOY_ENGINE_DIR) deploy $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV)
	@echo ""
	@echo "=========================================="
	@echo "  部署 Diting Stack（静态 PV/PVC + 采集 Job，Job 内 init 等待 DB 就绪）"
	@echo "=========================================="
	@export KUBECONFIG="$$HOME/.kube/config-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)"; \
	ACR_SECRET="$(CURDIR)/charts/diting-stack/manifests/acr-pull-secret.yaml"; \
	if [ -f "$$ACR_SECRET" ]; then \
		echo "应用 ACR 拉取凭证 Secret..."; \
		kubectl apply -f "$$ACR_SECRET"; \
	fi; \
	CFG="$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"; \
	STACK_ENABLED=$$(yq eval '.stack.enabled // true' "$$CFG"); \
	if [ "$$STACK_ENABLED" = "true" ]; then \
		TMP=$$(mktemp); \
		yq eval '{"storage": .stack.storage, "ingest": (.stack.ingest // {})}' "$$CFG" > "$$TMP"; \
		if helm list -n default | grep -q diting-stack; then \
			helm upgrade diting-stack $(CURDIR)/charts/diting-stack -n default -f "$$TMP" --wait --timeout=5m; \
		else \
			helm install diting-stack $(CURDIR)/charts/diting-stack -n default -f "$$TMP" --wait --timeout=5m; \
		fi; \
		rm -f "$$TMP"; \
		echo "✅ Diting Stack 部署完成（ingest Job 由 init 容器等待 DB 就绪后执行）"; \
	fi
	@echo ""
	@echo "=========================================="
	@echo "  部署数据库（官方 Bitnami Chart）"
	@echo "=========================================="
	@export KUBECONFIG="$$HOME/.kube/config-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)"; \
	CFG="$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"; \
	helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true; \
	helm repo update bitnami; \
	if [ "$$(yq eval '.stack.databases.timescaledb.enabled // true' "$$CFG")" = "true" ]; then \
		echo "部署 TimescaleDB..."; \
		_SVC=$$(yq eval '.stack.databases.timescaledb.service.type // "ClusterIP"' "$$CFG"); \
		_NP=$$(yq eval '.stack.databases.timescaledb.service.nodePort // ""' "$$CFG"); \
		_EXTRA=""; [ "$$_SVC" = "NodePort" ] && [ -n "$$_NP" ] && _EXTRA="--set primary.service.type=NodePort --set primary.service.nodePorts.postgresql=$$_NP"; \
		helm upgrade --install timescaledb bitnami/postgresql -n default \
			--set auth.username=$$(yq eval '.stack.databases.timescaledb.auth.username // "postgres"' "$$CFG") \
			--set auth.password=$$(yq eval '.stack.databases.timescaledb.auth.password // "postgres"' "$$CFG") \
			--set auth.database=$$(yq eval '.stack.databases.timescaledb.auth.database // "postgres"' "$$CFG") \
			--set primary.persistence.enabled=true \
			--set primary.persistence.existingClaim=$$(yq eval '.stack.databases.timescaledb.persistence.existing_claim // "data-timescaledb-postgresql-0"' "$$CFG") \
			$$_EXTRA \
			--wait --timeout=5m; \
		echo "✅ TimescaleDB 完成"; \
	fi; \
	if [ "$$(yq eval '.stack.databases.postgres_l2.enabled // true' "$$CFG")" = "true" ]; then \
		echo "部署 PostgreSQL L2..."; \
		_SVC=$$(yq eval '.stack.databases.postgres_l2.service.type // "ClusterIP"' "$$CFG"); \
		_NP=$$(yq eval '.stack.databases.postgres_l2.service.nodePort // ""' "$$CFG"); \
		_EXTRA=""; [ "$$_SVC" = "NodePort" ] && [ -n "$$_NP" ] && _EXTRA="--set primary.service.type=NodePort --set primary.service.nodePorts.postgresql=$$_NP"; \
		helm upgrade --install postgresql-l2 bitnami/postgresql -n default \
			--set auth.username=$$(yq eval '.stack.databases.postgres_l2.auth.username // "postgres"' "$$CFG") \
			--set auth.password=$$(yq eval '.stack.databases.postgres_l2.auth.password // "postgres"' "$$CFG") \
			--set auth.database=$$(yq eval '.stack.databases.postgres_l2.auth.database // "diting_l2"' "$$CFG") \
			--set primary.persistence.enabled=true \
			--set primary.persistence.existingClaim=$$(yq eval '.stack.databases.postgres_l2.persistence.existing_claim // "data-postgresql-l2-0"' "$$CFG") \
			$$_EXTRA \
			--wait --timeout=5m; \
		echo "✅ PostgreSQL L2 完成"; \
	fi; \
	if [ "$$(yq eval '.stack.databases.redis.enabled // true' "$$CFG")" = "true" ]; then \
		echo "部署 Redis..."; \
		helm upgrade --install redis bitnami/redis -n default \
			-f "$(CONFIG_ROOT)/redis-values-prod.yaml" \
			--wait --timeout=5m; \
		echo "✅ Redis 完成"; \
	fi
	@$(MAKE) -f $(CURDIR)/Makefile prod-write-conn
	@echo ""
	@echo "=========================================="
	@echo "  数据采集（K3s Job / 本机可选）"
	@echo "=========================================="
	@STACK_INGEST=$$(yq eval '.stack.ingest.enabled // false' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
	if [ "$$STACK_INGEST" = "true" ]; then \
		echo "✅ 数据采集已由 diting-stack 的 K3s Job 在部署时触发（stack.ingest.enabled=true），无需本机 REPO_I_ROOT"; \
	else \
		INGEST_ENABLED=$$(yq eval '.data_ingestion.enabled // false' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
		if [ "$$INGEST_ENABLED" = "true" ]; then \
			INGEST_TARGET=$$(yq eval '.data_ingestion.target // "ingest-test"' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
			CORE_REPO=$$(yq eval '.data_ingestion.core_repo_path // ""' "$(CONFIG_ROOT)/$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV).yaml"); \
			if [ -z "$$CORE_REPO" ]; then CORE_REPO="$${REPO_I_ROOT:-}"; fi; \
			if [ -n "$$CORE_REPO" ] && [ -d "$$CORE_REPO" ]; then \
				echo "执行数据采集: $$INGEST_TARGET (工作目录: $$CORE_REPO)"; \
				cp "$(CONN_FILE)" "$$CORE_REPO/.env" && $(MAKE) -C "$$CORE_REPO" "$$INGEST_TARGET" && echo "✅ 数据采集完成"; \
			else \
				echo "⚠️  REPO_I_ROOT 未设置或目录不存在，跳过本机数据采集"; \
				echo "   设置方法: export REPO_I_ROOT=/path/to/diting-core"; \
			fi; \
		else \
			echo "数据采集已禁用（data_ingestion.enabled=false），跳过"; \
		fi; \
	fi
	@echo ""
	@echo "=========================================="
	@echo "  ✅ 部署完成！"
	@echo "=========================================="
	@export KUBECONFIG="$$HOME/.kube/config-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)"; \
	if [ -f "$$KUBECONFIG" ] && kubectl cluster-info --request-timeout=5s &>/dev/null; then \
		echo ""; echo "kubectl get nodes:"; kubectl get nodes 2>/dev/null || true; \
		echo ""; echo "kubectl get pods -A:"; kubectl get pods -A 2>/dev/null || true; \
	fi
	@echo ""
	@echo "当前终端立即生效 KUBECONFIG（复制执行）："
	@echo "    eval \$$(make -C $(CURDIR) print-kubeconfig)"
	@echo ""
	@echo "或手动： export KUBECONFIG=\"$$HOME/.kube/config-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)\""
	@echo "（新终端会自动生效，因 get-kubeconfig 已写入 shell 配置文件）"
	@echo "=========================================="
	@echo ""

# 将连接信息写入 prod.conn（EIP 与 NodePort 从 deploy-engine 输出或 kubectl 获取）
prod-write-conn:
	@scripts/prod-write-conn.sh "$(CONFIG_ROOT)" "$(DEPLOY_ENGINE_DIR)" "$(CONN_FILE)" $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV) || true
	@echo "连接信息已写入 $(CONN_FILE)（若脚本未实现则需人工填写 EIP 与 NodePort）"

# 输出 export KUBECONFIG=... 供当前终端生效：eval $(make -C diting-infra print-kubeconfig)
print-kubeconfig:
	@echo "export KUBECONFIG=\"$$HOME/.kube/config-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)\""

# 将 ACR 拉取凭证 Secret 应用到当前 KUBECONFIG 指向的集群（default 命名空间）
# 需存在 charts/diting-stack/manifests/acr-pull-secret.yaml；make deploy diting prod 时若存在该文件会自动 apply
apply-acr-pull-secret:
	@ACR_SECRET="$(CURDIR)/charts/diting-stack/manifests/acr-pull-secret.yaml"; \
	if [ ! -f "$$ACR_SECRET" ]; then \
		echo "错误: 不存在 $$ACR_SECRET，请从同目录 acr-pull-secret.yaml.example 复制并填写或使用项目提供的凭证文件"; exit 1; \
	fi; \
	kubectl apply -f "$$ACR_SECRET" && echo "✅ ACR 拉取凭证已应用（Secret acr-titan）"

# 后半部分：Up 后执行采集落库（C3）。需设置 REPO_I_ROOT 指向 diting-core 根目录
deploy-diting-prod-with-ingest: deploy-diting-prod
	@if [ -n "$$REPO_I_ROOT" ] && [ -f "$(CONN_FILE)" ]; then \
		cp "$(CONN_FILE)" "$$REPO_I_ROOT/.env" && \
		$(MAKE) -C "$$REPO_I_ROOT" ingest-test && echo "[OK] ingest-test 已执行"; \
	else \
		echo "跳过 ingest-test（设置 REPO_I_ROOT 指向 diting-core 可自动执行）"; \
	fi

# 控制台已释放 ECS/EIP 但 Terraform state 仍认为存在时，从 state 移除 ECS + EIP + 盘挂载 + 安全组规则残留，下次 make deploy 会重新创建。
# 适用：手动在控制台释放了实例、或 apply 报 RuleNotExist/DependencyViolation。enable_spot=true 时用 spot[0]，否则需改 on_demand[0]。
fix-diting-prod-stale-ecs:
	@_TF="$(CURDIR)/$(DEPLOY_ENGINE_DIR)/deploy/terraform/alicloud"; \
	echo "[fix] 从 state 移除 ECS + EIP + 盘挂载 + 安全组规则残留（控制台已释放或规则已删时使用）..."; \
	(cd "$$_TF" && terraform state rm 'module.ecs.alicloud_eip_association.spot[0]' 2>/dev/null) || true; \
	(cd "$$_TF" && terraform state rm 'module.ecs.alicloud_eip_address.spot[0]' 2>/dev/null) || true; \
	(cd "$$_TF" && terraform state rm 'module.ecs.alicloud_instance.spot[0]' 2>/dev/null) || true; \
	(cd "$$_TF" && terraform state rm 'module.ecs.alicloud_disk_attachment.spot[0]' 2>/dev/null) || true; \
	(cd "$$_TF" && terraform state rm 'module.security.alicloud_security_group_rule.ssh[0]' 2>/dev/null) || true; \
	(cd "$$_TF" && terraform state rm 'module.security.alicloud_security_group_rule.k8s_api[0]' 2>/dev/null) || true; \
	echo "[OK] 已从 state 移除；请执行: make deploy diting prod"

# 兼容旧命令（仅移除 EIP，不包含 ECS）
fix-diting-prod-stale-eip: fix-diting-prod-stale-ecs

# Down 仅释放 ECS 与 EIP（-target=module.ecs），其它资源（VPC、数据盘、NAS、OSS 等）均在 tfvars 中固定且不释放；prod.disk_id 保留供再次 Up 挂载同盘。
# 约定：ECS 和 EIP 资源必须释放；固定资源见 config/terraform-diting-prod.tfvars 内注释。
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
		for r in timescaledb postgresql-l2 redis; do helm uninstall "$$r" -n default 2>/dev/null || true; done; \
		echo "等待 Pod 终止..."; sleep 10; \
		echo "✅ 数据库 Release 已卸载"; \
	else \
		echo "⚠️  集群不可访问，跳过"; \
	fi
	@echo ""
	@echo "=========================================="
	@echo "  清理动态 PVC（保留静态 PVC）"
	@echo "=========================================="
	@export KUBECONFIG="$$HOME/.kube/config-$(PROD_DATA_ENV_PROJECT)-$(PROD_DATA_ENV_ENV)"; \
	if kubectl cluster-info &>/dev/null; then \
		echo "删除 Redis 动态 PVC..."; \
		kubectl delete pvc -n default -l app.kubernetes.io/instance=redis --ignore-not-found=true || true; \
		echo "✅ 动态 PVC 已清理"; \
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
	@CONFIG_ROOT="$(CONFIG_ROOT)" $(MAKE) -C $(DEPLOY_ENGINE_DIR) down $(PROD_DATA_ENV_PROJECT) $(PROD_DATA_ENV_ENV)
	@echo "make down diting prod OK（ECS/EIP 已释放；固定资源 VPC/数据盘/NAS/OSS 已保留，再次执行 make deploy diting prod 将挂载同盘）"
