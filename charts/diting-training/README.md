# diting-training · L2 GPU 训练 Chart

> **状态**：占位骨架 · 真实 templates/ 由 P-step_04 完成（W4）。

## TRACEBACK
- L3 设计：[`01_平台拓扑设计.md §2`](../../../diting-doc/03_原子目标与规约/共享平台基础/stages/stage_1_启动期/01_平台拓扑设计.md)
- 业务对应：[D5 step_04 LLaMA-Factory 训练流水线](../../../diting-doc/03_原子目标与规约/05_维度五_演进飞轮/stages/stage_1_启动期/steps/step_04_C3_LLaMA_Factory训练流水线.md)
- 实践：[L4 实践记录_step_04_GPU训练组](../../../diting-doc/04_阶段规划与实践/共享平台基础/stage_1_启动期/实践记录_step_04_GPU训练组.md)

## 设计原则

- **任务态**：每次训练 helm install 一次 release（如 `diting-train-cryo`）· Job 跑完后 `make down-stack diting-training` 回收
- **可并行多 dim**：cryo / thrust / narrative 各起一个 release
- **NAS 共享**：权重输出 `/mnt/titan-data/lora/<dim>/` · 跨 stack（含 base + infer）可读

## 命令示例

```bash
# 起 train stack ECS
make up-stack diting-training

# install LoRA 训练 release（一个 dim）
helm install diting-train-cryo ./charts/diting-training -n train \
  --set training.dim=cryo --set training.maxSteps=500 \
  --set secrets.hfToken=$HF_TOKEN

# 等待训练完成（最长 2h）
kubectl wait --for=condition=complete job -l app=diting-train -n train --timeout=2h

# 销 train stack（含所有 train release 自动 uninstall）
make down-stack diting-training
```

## 待 P-step_04 补全

- `templates/job.yaml`：Job + initContainer（pull base model）+ container（train_lora.py）
- `templates/configmap.yaml`：训练超参从 values 渲染
- `templates/secret.yaml`：HF_TOKEN / WANDB_API_KEY
- `templates/pvc.yaml`（可选 · 若用 PVC 而非 hostPath NAS）
