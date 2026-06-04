#!/usr/bin/env bash
# 手动触发 radar-t0-bootstrap-sync Job（与 Helm post-upgrade Hook 同入口）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_ROOT="${CONFIG_ROOT:-$INFRA_ROOT/config}"
PROD_DATA_ENV_PROJECT="${PROD_DATA_ENV_PROJECT:-diting}"
PROD_DATA_ENV_ENV="${PROD_DATA_ENV_ENV:-prod}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
NS="${RADAR_T0_NS:-platform}"

DEPLOY="diting-copilot"
IMG="$(kubectl --kubeconfig="$KUBECONFIG" -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}')"
JOB="radar-t0-bootstrap-manual-$(date +%s)"

echo "▶ [radar-t0-bootstrap-sync] image=$IMG job=$JOB"

kubectl --kubeconfig="$KUBECONFIG" -n "$NS" delete job -l component=radar-t0-bootstrap-manual --ignore-not-found --field-selector status.successful=1 2>/dev/null || true

cat <<EOF | kubectl --kubeconfig="$KUBECONFIG" -n "$NS" apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  namespace: ${NS}
  labels:
    app: diting
    component: radar-t0-bootstrap-manual
spec:
  activeDeadlineSeconds: 3600
  backoffLimit: 1
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        app: diting
        component: radar-t0-bootstrap-manual
    spec:
      restartPolicy: Never
      imagePullSecrets:
      - name: acr-titan
      initContainers:
      - name: wait-for-redis
        image: busybox:1.36
        command: ["sh", "-c", "until nc -z redis-master.platform.svc.cluster.local 6379; do sleep 2; done"]
      containers:
      - name: bootstrap
        image: ${IMG}
        imagePullPolicy: Always
        command: ["python", "-m", "apps.copilot.jobs.radar_t0", "bootstrap-sync", "--force"]
        envFrom:
        - secretRef:
            name: diting-copilot-conn
        env:
        - name: RADAR_T0_CACHE_DIR
          value: "/data/radar_t0_cache"
        - name: RADAR_T0_AKSHARE_TIMEOUT_SEC
          value: "12"
        volumeMounts:
        - name: radar-t0-cache
          mountPath: /data/radar_t0_cache
        resources:
          requests:
            memory: 512Mi
            cpu: 500m
          limits:
            memory: 3Gi
            cpu: "2"
      volumes:
      - name: radar-t0-cache
        persistentVolumeClaim:
          claimName: diting-radar-t0-cache
EOF

kubectl --kubeconfig="$KUBECONFIG" -n "$NS" wait --for=condition=complete "job/${JOB}" --timeout=3600s
kubectl --kubeconfig="$KUBECONFIG" -n "$NS" logs "job/${JOB}" --tail=80
echo "✅ [radar-t0-bootstrap-sync] 完成"
