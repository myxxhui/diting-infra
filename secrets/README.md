# secrets 加密流程与案例（实践文档）

> 设计规约见 **diting-doc** 仓库：`03_原子目标与规约/Stage1_仓库与骨架/04_密钥与配置模板设计.md`。  
> **Chart 约定**：Sealed-Secrets Chart 须下载到本地（如 `charts/dependencies/sealed-secrets`），不引用远程 Helm 仓库；部署与验证均使用本地路径。

---

## 一、前置条件

- **kubeseal CLI**：安装与 Chart 内控制器兼容的 kubeseal 版本（见 dna_stage1_04 或本仓 README 推荐版本，如 v0.24.x）。
- **集群访问**：加密时仅需**公钥证书**，可从本仓 `secrets/certs/` 读取；无需集群私钥。
- **公钥路径**：单环境使用 `secrets/certs/sealed-secrets-public.pem`；多环境使用 `secrets/certs/sealed-secrets-public-<env>.pem`（如 dev、prod）。

---

## 二、加密步骤

1. **编写明文 Secret YAML**（仅本地，不提交）  
   示例：
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: diting-akshare-secrets
     namespace: default
   type: Opaque
   stringData:
     API_KEY: "your-api-key-here"
   ```

2. **使用公钥加密**  
   ```bash
   kubeseal --cert=secrets/certs/sealed-secrets-public.pem \
     --format=yaml < secret.yaml > sealed-secret.yaml
   ```

3. **提交 SealedSecret**  
   将生成的 `sealed-secret.yaml` 放入 `secrets/` 下并按约定命名（如 `secrets/akshare-sealed.yaml`），提交到 Git。**禁止提交明文 secret.yaml**。

4. **部署与引用**  
   Helm values 或 deploy-engine 配置中通过 `secretRef.name`、`secretRef.keys` 引用该 Secret；部署后由 Sealed-Secrets 控制器在集群内解密为 Secret。

5. **验收**  
   ```bash
   kubectl get secret diting-akshare-secrets -o yaml
   kubectl exec <pod> -- env | grep API_KEY
   ```  
   确认 Secret 存在且 Pod 内可读取、非占位符。

---

## 三、典型用例

| 用例 | Secret 名（示例） | 用途 |
|------|-------------------|------|
| 数据源 API Key（Stage2 采集） | diting-akshare-secrets | AkShare/OpenBB 等 API Key |
| Module F Broker 凭证 | diting-broker-secrets | CTP/券商 API 密钥 |

Secret 命名与 Key 与设计文档「组件引用契约」及 .env.template 占位符一致。

---

## 四、可复现示例（可选）

- **输入**：上述明文 Secret 示例 YAML 保存为 `secret.yaml`。
- **命令**：`kubeseal --cert=secrets/certs/sealed-secrets-public.pem --format=yaml < secret.yaml`。
- **预期**：输出为 SealedSecret 资源 YAML，可安全提交；部署到对应集群后控制器解密为 Secret。

---

## 五、灾备与轮换

- **公钥轮换**：轮换时更新 `secrets/certs/` 下对应 `.pem` 文件，并在本 README 或 DNA 中注明生效环境与时间。
- **Sealing key 备份/恢复**：见 diting-doc 中 02_基础设施与部署规约 §六、10_运营治理与灾备规约。
