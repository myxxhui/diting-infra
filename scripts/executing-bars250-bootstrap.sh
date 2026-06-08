#!/usr/bin/env bash
# 一次性 Job：按 executing_collect_symbols 采集腾讯 250 日日线 → executing_daily_bars
# [Ref: 28_ §2.2.2]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
NS="${EXECUTING_T0_NS:-platform}"

DEPLOY="diting-copilot"
IMG="$(kubectl --kubeconfig="$KUBECONFIG" -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}')"
JOB="executing-bars250-bootstrap-$(date +%s)"

echo "▶ [executing-bars250-bootstrap] image=$IMG job=$JOB"

kubectl --kubeconfig="$KUBECONFIG" -n "$NS" delete job -l component=executing-bars250-bootstrap --ignore-not-found 2>/dev/null || true

cat <<EOF | kubectl --kubeconfig="$KUBECONFIG" -n "$NS" apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  namespace: ${NS}
  labels:
    app: diting
    component: executing-bars250-bootstrap
spec:
  activeDeadlineSeconds: 3600
  backoffLimit: 1
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        app: diting
        component: executing-bars250-bootstrap
    spec:
      restartPolicy: Never
      imagePullSecrets:
      - name: acr-titan
      initContainers:
      - name: wait-for-postgres
        image: busybox:1.36
        command: ["sh", "-c", "until nc -z postgresql-l2.platform.svc.cluster.local 5432; do sleep 2; done"]
      containers:
      - name: bars250
        image: ${IMG}
        imagePullPolicy: Always
        command: ["python", "-m", "apps.copilot.jobs.executing_t0", "executing-bars250-bootstrap"]
        envFrom:
        - secretRef:
            name: diting-copilot-conn
        env:
        - name: DEPLOY_REGION
          value: "cn-hongkong"
        resources:
          requests:
            memory: 512Mi
            cpu: 500m
          limits:
            memory: 1Gi
            cpu: "1"
EOF

echo "▶ 等待 Job 完成（最长 3600s）…"
kubectl --kubeconfig="$KUBECONFIG" -n "$NS" wait --for=condition=complete "job/${JOB}" --timeout=3600s
kubectl --kubeconfig="$KUBECONFIG" -n "$NS" logs "job/${JOB}" --tail=120
echo "✅ [executing-bars250-bootstrap] 完成"
