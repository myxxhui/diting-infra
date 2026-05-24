# diting-platform-base · L0 集群级基础设施 Chart

> **状态**：占位骨架 · 真实 templates/ 由 P-step_03 完成（W2）。
>
> 当前 `values.yaml` 描述「应有的能力清单」（namespace × 3 / ACR secret / device-plugin / RuntimeClass / storageclass-nas），templates/ 留空待补。

## TRACEBACK
- L3 设计：[`共享平台基础/.../01_平台拓扑设计.md §2`](../../../diting-doc/03_原子目标与规约/共享平台基础/stages/stage_1_启动期/01_平台拓扑设计.md)
- 实践：[L4 实践记录_step_03_CPU_Stack_按需Up](../../../diting-doc/04_阶段规划与实践/共享平台基础/stage_1_启动期/实践记录_step_03_CPU_Stack_按需Up.md)

## 设计原则

- **cluster-scoped**：不绑特定 namespace，含 ns 创建本身
- **一次装 · 长期不动**：业务迭代不动；仅 `make down-platform-base` 才 uninstall
- **GPU device-plugin nodeSelector**：仅在 `nvidia.com/gpu: present` 节点跑（train/infer stack）

## 命令

```bash
# 由 base ECS Up 后执行（kubeconfig 已就绪）
helm install diting-platform-base ./charts/diting-platform-base -n kube-system --create-namespace
```

## 待 P-step_03 补全

- `templates/namespaces.yaml`：按 values.namespaces 渲染
- `templates/acr-pull-secret.yaml`：按 copyToNamespaces 复制 Secret 到 3 ns
- `templates/nvidia-device-plugin.yaml`：DaemonSet + nodeSelector + toleration
- `templates/nvidia-runtime-class.yaml`：RuntimeClass
- `templates/storageclass-nas.yaml`（可选）
