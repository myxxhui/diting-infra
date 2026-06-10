{{- define "diting.executingT0JobEnqueue" -}}
{{- $root := index . 0 -}}
{{- $job := index . 1 -}}
{{- $jobId := $job.id -}}
{{- if hasKey $job "enqueue" -}}
{{- if $job.enqueue -}}true{{- else -}}false{{- end -}}
{{- else -}}
{{- $enqueue := false -}}
{{- range ($root.Values.copilot.executingT0Jobs.enqueueJobIdPrefixes | default (list "l3-")) -}}
{{- if hasPrefix . $jobId -}}
{{- $enqueue = true -}}
{{- end -}}
{{- end -}}
{{- if $enqueue -}}true{{- else -}}false{{- end -}}
{{- end -}}
{{- end }}

{{- define "diting.executingT0JobPod" -}}
{{- $root := index . 0 -}}
{{- $job := index . 1 -}}
{{- $jobId := $job.id -}}
{{- $useEnqueue := eq (include "diting.executingT0JobEnqueue" (list $root $job)) "true" -}}
restartPolicy: OnFailure
{{- with $root.Values.copilot.imagePullSecrets }}
imagePullSecrets:
{{- range . }}
- name: {{ if kindIs "string" . }}{{ . | quote }}{{ else }}{{ .name | default "" | quote }}{{ end }}
{{- end }}
{{- end }}
initContainers:
- name: wait-for-redis
  image: busybox:1.36
  command:
  - sh
  - -c
  - |
    until nc -z {{ $root.Values.copilot.redisHost }} {{ $root.Values.copilot.redisPort }}; do sleep 2; done
{{- if $root.Values.copilot.postgres.enabled }}
- name: wait-for-postgres
  image: busybox:1.36
  command:
  - sh
  - -c
  - |
    until nc -z {{ $root.Values.copilot.postgres.host }} {{ $root.Values.copilot.postgres.port }}; do sleep 2; done
{{- end }}
containers:
- name: executing-t0
  image: "{{ $root.Values.copilot.image.repository }}:{{ $root.Values.copilot.image.tag }}"
  imagePullPolicy: {{ $root.Values.copilot.image.pullPolicy }}
  {{- if $useEnqueue }}
  command: ["python", "-m", "apps.copilot.jobs.executing_t0", "--enqueue", {{ $jobId | quote }}]
  resources:
    requests:
      memory: "128Mi"
      cpu: "100m"
    limits:
      memory: "256Mi"
      cpu: "500m"
  {{- else }}
  command: ["python", "-m", "apps.copilot.jobs.executing_t0", {{ $jobId | quote }}]
  resources:
    requests:
      memory: "512Mi"
      cpu: "500m"
    limits:
      memory: "1Gi"
      cpu: "1000m"
  {{- end }}
  envFrom:
  - secretRef:
      name: diting-copilot-conn
  env:
  - name: DEPLOY_REGION
    value: "cn-hongkong"
{{- end }}
