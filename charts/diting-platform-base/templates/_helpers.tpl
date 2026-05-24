{{/*
diting-platform-base helpers
[Ref: 03_原子目标与规约/共享平台基础/stages/stage_1_启动期/step_03]
*/}}

{{- define "diting-platform-base.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
