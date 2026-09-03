#!/usr/bin/env bash
# Run one load-test stage in-cluster via k6, against callback-service's POST /orders.
# Usage: ./run-stage.sh <target_count> <concurrency> <stage_label>
set -euo pipefail

TARGET_COUNT="${1:?target_count required}"
CONCURRENCY="${2:?concurrency required}"
STAGE="${3:?stage_label required}"
DIR="$(cd "$(dirname "$0")" && pwd)"
JOB_NAME="k6-${STAGE}"
NS=order-fulfillment
PROM_RW_URL="http://kps-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write"

echo "=== Stage '${STAGE}': ${TARGET_COUNT} orders, concurrency ${CONCURRENCY} ==="

kubectl create configmap k6-orders-script -n "$NS" \
  --from-file=orders-stage.js="$DIR/orders-stage.js" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl delete job "$JOB_NAME" -n "$NS" --ignore-not-found >/dev/null 2>&1

cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NS}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: grafana/k6:latest
          args:
            - run
            - --out
            - experimental-prometheus-rw
            - /scripts/orders-stage.js
          env:
            - name: BASE_URL
              value: "http://callback-service.order-fulfillment.svc.cluster.local:4000"
            - name: TARGET_COUNT
              value: "${TARGET_COUNT}"
            - name: CONCURRENCY
              value: "${CONCURRENCY}"
            - name: STAGE
              value: "${STAGE}"
            - name: K6_PROMETHEUS_RW_SERVER_URL
              value: "${PROM_RW_URL}"
            - name: K6_PROMETHEUS_RW_TREND_STATS
              value: "p(95),p(99),min,max"
          resources:
            requests:
              cpu: 500m
              memory: 256Mi
            limits:
              memory: 512Mi
          volumeMounts:
            - name: script
              mountPath: /scripts
      volumes:
        - name: script
          configMap:
            name: k6-orders-script
EOF

echo "Waiting for job to complete..."
kubectl wait --for=condition=complete --timeout=600s "job/${JOB_NAME}" -n "$NS" 2>&1 || true
kubectl logs "job/${JOB_NAME}" -n "$NS" --tail=100
