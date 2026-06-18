{{- define "diting.z0T0JobPod" -}}
{{- $root := index . 0 -}}
{{- $job := index . 1 -}}
{{- $jobId := $job.id -}}
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
- name: z0-t0
  image: "{{ $root.Values.copilot.image.repository }}:{{ $root.Values.copilot.image.tag }}"
  imagePullPolicy: {{ $root.Values.copilot.image.pullPolicy }}
  command: ["python", "-m", "apps.copilot.jobs.z0_t0", "--enqueue", {{ $jobId | quote }}]
  resources:
    requests:
      memory: "128Mi"
      cpu: "100m"
    limits:
      memory: "512Mi"
      cpu: "500m"
  envFrom:
  - secretRef:
      name: diting-copilot-conn
  env:
  - name: DEPLOY_REGION
    value: "cn-hongkong"
  - name: RADAR_T0_EM_PUSH2_BASE
    value: {{ $root.Values.copilot.radarT0EmPush2Base | default "https://push2delay.eastmoney.com" | quote }}
{{- end }}
