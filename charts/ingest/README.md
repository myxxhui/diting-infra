# 已废弃：请使用 `charts/diting-stack`

独立目录 `charts/ingest` **不再**作为 Helm Chart 发布（缺少 `Chart.yaml`，会导致 `Chart.yaml file is missing`）。

采集 Job 由 **`charts/diting-stack`** 的 `templates/ingest/` 渲染，通过：

```bash
# 与 make deploy diting prod 后半段一致
make deploy-ingest-job WAIT=wait

# 或仅开启 stack.ingest.enabled 后 helm upgrade
yq '.stack.ingest.enabled = true' config/diting-prod.yaml
```

遗留的 `sql/`、`templates/schema-init-configmap.yaml` 仅作历史参考；建表以 `diting-stack/schema-init/` 为准。
