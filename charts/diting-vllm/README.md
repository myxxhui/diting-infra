# diting-vllm · L3 GPU 推理 Chart

> **状态**：占位骨架 · 真实 templates/ 由 P-step_05 完成（W5+）。

## TRACEBACK
- L3 设计：[`01_平台拓扑设计.md §2`](../../../diting-doc/03_原子目标与规约/共享平台基础/stages/stage_1_启动期/01_平台拓扑设计.md)
- 业务对应：[D5 step_05 Holdout 守门评测](../../../diting-doc/03_原子目标与规约/05_维度五_演进飞轮/stages/stage_1_启动期/steps/step_05_C4_Holdout守门评测.md)
- 实践：[L4 实践记录_step_05_GPU推理组](../../../diting-doc/04_阶段规划与实践/共享平台基础/stage_1_启动期/实践记录_step_05_GPU推理组.md)

## 设计原则

- **长服务态**：评测周期 helm install 一次，多 dim Holdout 连跑共享 GPU
- **LoRA hot-swap**：vLLM `--enable-lora` + 多 adapter 路径 · 按 dim 动态切换
- **NAS RO 挂载**：`/mnt/titan-data/lora/<dim>/` 只读
- **service 内部 DNS**：`http://diting-infer.infer.svc.cluster.local:8000/v1`

## 命令示例

```bash
# 起 infer stack ECS
make up-stack diting-vllm

# install vLLM Deployment
helm install diting-infer ./charts/diting-vllm -n infer

# 等就绪后跑 D5 Holdout
for dim in cryo thrust narrative; do
  make -C ../diting-src holdout DIM=$dim VLLM_URL=http://diting-infer.infer.svc.cluster.local:8000/v1
done

# 销 infer stack
make down-stack diting-vllm
```

## 待 P-step_05 补全

- `templates/deployment.yaml`：vLLM container + lora-modules 启动参数
- `templates/service.yaml`：ClusterIP :8000
- `templates/configmap.yaml`：模型与 lora 路径
- `templates/pvc.yaml`（可选）
