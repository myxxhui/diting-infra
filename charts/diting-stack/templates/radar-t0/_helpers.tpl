{{- define "diting.radarT0JobPod" -}}
{{- $root := index . 0 -}}
{{- $jobId := index . 1 -}}
{{- $deadline := index . 2 -}}
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
    echo "等待 Redis..."
    until nc -z {{ $root.Values.copilot.redisHost }} {{ $root.Values.copilot.redisPort }}; do sleep 2; done
    echo "Redis 就绪"
{{- if $root.Values.copilot.postgres.enabled }}
- name: wait-for-postgres
  image: busybox:1.36
  command:
  - sh
  - -c
  - |
    echo "等待 PostgreSQL..."
    until nc -z {{ $root.Values.copilot.postgres.host }} {{ $root.Values.copilot.postgres.port }}; do sleep 2; done
{{- end }}
containers:
- name: radar-t0
  image: "{{ $root.Values.copilot.image.repository }}:{{ $root.Values.copilot.image.tag }}"
  imagePullPolicy: {{ $root.Values.copilot.image.pullPolicy }}
  command: ["python", "-m", "apps.copilot.jobs.radar_t0", {{ $jobId | quote }}]
  envFrom:
  - secretRef:
      name: diting-copilot-conn
  env:
  - name: RADAR_T0_CACHE_DIR
    value: {{ $root.Values.copilot.radarT0CacheDir | default "/data/radar_t0_cache" | quote }}
  - name: RADAR_T0_CACHE_MAX_AGE_HOURS
    value: {{ $root.Values.copilot.radarT0CacheMaxAgeHours | default "24" | quote }}
  - name: RADAR_T0_RETENTION_DAYS
    value: {{ $root.Values.copilot.radarT0RetentionDays | default "1" | quote }}
  - name: RADAR_T0_AKSHARE_TIMEOUT_SEC
    value: {{ $root.Values.copilot.radarT0AkshareTimeoutSec | default "12" | quote }}
  volumeMounts:
  {{- if $root.Values.storage.radarT0Cache.enabled }}
  - name: radar-t0-cache
    mountPath: /data/radar_t0_cache
  {{- end }}
  resources:
    requests:
      memory: "512Mi"
      cpu: "500m"
    limits:
      memory: "1Gi"
      cpu: "1000m"
volumes:
{{- if $root.Values.storage.radarT0Cache.enabled }}
- name: radar-t0-cache
  persistentVolumeClaim:
    claimName: {{ $root.Values.storage.radarT0Cache.pvc.name }}
{{- end }}
{{- end }}
