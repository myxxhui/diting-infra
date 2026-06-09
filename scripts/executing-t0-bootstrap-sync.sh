#!/usr/bin/env bash
# 手动触发 executing-t0-bootstrap-sync Job（与 Helm post-upgrade Hook 同入口）
# [Ref: 28_ §4.6]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"
NS="${EXECUTING_T0_NS:-platform}"

DEPLOY="diting-copilot"
IMG="$(kubectl --kubeconfig="$KUBECONFIG" -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}')"
JOB="executing-t0-bootstrap-manual-$(date +%s)"

echo "▶ [executing-t0-bootstrap-sync] image=$IMG job=$JOB"

kubectl --kubeconfig="$KUBECONFIG" -n "$NS" delete job -l component=executing-t0-bootstrap-manual --ignore-not-found 2>/dev/null || true

cat <<EOF | kubectl --kubeconfig="$KUBECONFIG" -n "$NS" apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  namespace: ${NS}
  labels:
    app: diting
    component: executing-t0-bootstrap-manual
spec:
  activeDeadlineSeconds: 3600
  backoffLimit: 1
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        app: diting
        component: executing-t0-bootstrap-manual
    spec:
      restartPolicy: Never
      imagePullSecrets:
      - name: acr-titan
      initContainers:
      - name: wait-for-redis
        image: busybox:1.36
        command: ["sh", "-c", "until nc -z redis-master.platform.svc.cluster.local 6379; do sleep 2; done"]
      - name: wait-for-postgres
        image: busybox:1.36
        command: ["sh", "-c", "until nc -z postgresql-l2.platform.svc.cluster.local 5432; do sleep 2; done"]
      containers:
      - name: bootstrap
        image: ${IMG}
        imagePullPolicy: Always
        command: ["python", "-m", "apps.copilot.jobs.executing_t0", "bootstrap-sync"]
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

WAIT="${EXECUTING_T0_WAIT:-0}"
TIMEOUT="${EXECUTING_T0_WAIT_TIMEOUT:-900s}"

if [ "$WAIT" = "0" ]; then
  echo "▶ [executing-t0-bootstrap-sync] 异步提交（EXECUTING_T0_WAIT=0）· 跟踪: kubectl -n $NS logs -f job/${JOB}"
  echo "✅ [executing-t0-bootstrap-sync] Job 已创建 · 不阻塞等待"
  exit 0
fi

echo "▶ [executing-t0-bootstrap-sync] 同步等待 · timeout=${TIMEOUT}（改 EXECUTING_T0_WAIT=0 可异步）"
kubectl --kubeconfig="$KUBECONFIG" -n "$NS" wait --for=condition=complete "job/${JOB}" --timeout="${TIMEOUT}"
kubectl --kubeconfig="$KUBECONFIG" -n "$NS" logs "job/${JOB}" --tail=80
echo "✅ [executing-t0-bootstrap-sync] 完成"
