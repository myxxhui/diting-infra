#!/usr/bin/env bash
# 将 Redis 从 Bitnami 动态 PVC（redis-data-redis-master-0 · local-path）迁到静态 data-redis-master-0。
# 工作目录：diting-infra；须在 platform-step03 安装/升级 Redis 之前执行。
set -euo pipefail

STACK_NS="${STACK_NS:-platform}"
LEGACY_PVC="redis-data-redis-master-0"
STATIC_PVC="data-redis-master-0"
REDIS_RELEASE="${REDIS_RELEASE:-redis}"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-diting-prod}"

_redis_uses_static() {
  local vol
  vol="$(kubectl get pod -n "$STACK_NS" -l app.kubernetes.io/name=redis,app.kubernetes.io/component=master \
    -o jsonpath='{.items[0].spec.volumes[?(@.persistentVolumeClaim)].persistentVolumeClaim.claimName}' 2>/dev/null || true)"
  [ "$vol" = "$STATIC_PVC" ]
}

if _redis_uses_static; then
  echo "  [redis-migrate] Redis master 已挂载 ${STATIC_PVC}，跳过"
  exit 0
fi

if kubectl get pvc -n "$STACK_NS" "$STATIC_PVC" &>/dev/null \
  && ! kubectl get pvc -n "$STACK_NS" "$LEGACY_PVC" &>/dev/null \
  && ! kubectl get sts -n "$STACK_NS" redis-master &>/dev/null; then
  echo "  [redis-migrate] 静态 PVC 就绪且无 legacy Release，跳过"
  exit 0
fi

if ! kubectl get pvc -n "$STACK_NS" "$LEGACY_PVC" &>/dev/null; then
  if kubectl get sts -n "$STACK_NS" redis-master &>/dev/null; then
    echo "  [redis-migrate] 检测到 Redis StatefulSet 但未使用静态卷，卸载后重装 ..."
    helm uninstall "$REDIS_RELEASE" -n "$STACK_NS" 2>/dev/null || true
    sleep 10
    kubectl delete sts -n "$STACK_NS" redis-master redis-replicas --ignore-not-found=true
    kubectl delete pvc -n "$STACK_NS" -l app.kubernetes.io/instance=redis --ignore-not-found=true --wait=true
    echo "  [redis-migrate] 完成（请 helm upgrade redis -f redis-values-prod.yaml）"
    exit 0
  fi
  echo "  [redis-migrate] 无 legacy PVC / Redis STS，跳过"
  exit 0
fi

echo "  [redis-migrate] 发现 legacy PVC，卸载 Redis 并尝试保留 RDB ..."
helm uninstall "$REDIS_RELEASE" -n "$STACK_NS" 2>/dev/null || true
sleep 8

DATA_ROOT="${REDIS_DATA_ROOT:-/mnt/titan-data/postgres/redis}"
MIGRATE_JOB="redis-legacy-to-static-$(date +%s)"
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${MIGRATE_JOB}
  namespace: ${STACK_NS}
spec:
  ttlSecondsAfterFinished: 120
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: copy
        image: busybox:1.36
        command:
        - sh
        - -c
        - |
          set -e
          LEG=/legacy
          DST=/host${DATA_ROOT}
          mkdir -p "\$DST"
          if [ -f "\$LEG/dump.rdb" ]; then
            cp -a "\$LEG/dump.rdb" "\$DST/dump.rdb"
            echo "copied dump.rdb"
          elif [ -d "\$LEG" ]; then
            cp -a "\$LEG"/. "\$DST"/ 2>/dev/null || true
            echo "copied legacy dir contents"
          else
            echo "no legacy data files"
          fi
          ls -la "\$DST" || true
        volumeMounts:
        - name: legacy
          mountPath: /legacy
        - name: host-root
          mountPath: /host
      volumes:
      - name: legacy
        persistentVolumeClaim:
          claimName: ${LEGACY_PVC}
      - name: host-root
        hostPath:
          path: /
          type: Directory
EOF

kubectl wait --for=condition=complete "job/${MIGRATE_JOB}" -n "$STACK_NS" --timeout=120s 2>/dev/null || true
kubectl delete job "$MIGRATE_JOB" -n "$STACK_NS" --ignore-not-found=true

echo "  [redis-migrate] 删除 legacy 动态 PVC ..."
kubectl delete pvc -n "$STACK_NS" "$LEGACY_PVC" \
  redis-data-redis-replicas-0 redis-data-redis-replicas-1 redis-data-redis-replicas-2 \
  --ignore-not-found=true --wait=true
kubectl delete sts -n "$STACK_NS" redis-replicas --ignore-not-found=true
echo "  [redis-migrate] 完成（请 helm upgrade redis -f redis-values-prod.yaml）"
