#!/usr/bin/env bash
# Generic in-cluster k6 runner -- underlies run-stage.sh's pattern, generalized so the same
# Job/ConfigMap plumbing works for orders-stage.js, orders-tagged-stage.js, and search-stage.js
# without three near-duplicate scripts.
# Usage: ./run-k6.sh <script.js> <job_name> [ENV_KEY=value ...]
set -euo pipefail

SCRIPT_FILE="${1:?script file required}"
JOB_NAME="k6-${2:?job_name required}"
shift 2
DIR="$(cd "$(dirname "$0")" && pwd)"
NS=order-fulfillment
PROM_RW_URL="http://kps-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write"
SCRIPT_BASENAME="$(basename "$SCRIPT_FILE")"

echo "=== Job '${JOB_NAME}' running ${SCRIPT_BASENAME} with: $* ==="

kubectl create configmap k6-scripts -n "$NS" \
  --from-file="$DIR/orders-stage.js" \
  --from-file="$DIR/orders-tagged-stage.js" \
  --from-file="$DIR/search-stage.js" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl delete job "$JOB_NAME" -n "$NS" --ignore-not-found >/dev/null 2>&1

ENV_YAML=""
for kv in "$@"; do
  key="${kv%%=*}"
  val="${kv#*=}"
  ENV_YAML="${ENV_YAML}
            - name: ${key}
              value: \"${val}\""
done

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
          args: ["run", "--out", "experimental-prometheus-rw", "/scripts/${SCRIPT_BASENAME}"]
          env:
            - name: BASE_URL
              value: "http://callback-service.order-fulfillment.svc.cluster.local:4000"
            - name: K6_PROMETHEUS_RW_SERVER_URL
              value: "${PROM_RW_URL}"
            - name: K6_PROMETHEUS_RW_TREND_STATS
              value: "p(95),p(99),min,max"${ENV_YAML}
          resources:
            requests:
              cpu: 500m
              memory: 256Mi
            limits:
              memory: 512Mi
          volumeMounts:
            - name: scripts
              mountPath: /scripts
      volumes:
        - name: scripts
          configMap:
            name: k6-scripts
EOF

echo "Waiting for job to complete..."
kubectl wait --for=condition=complete --timeout=600s "job/${JOB_NAME}" -n "$NS" 2>&1 || \
  kubectl wait --for=condition=failed --timeout=5s "job/${JOB_NAME}" -n "$NS" 2>&1 || true
kubectl logs "job/${JOB_NAME}" -n "$NS" --tail=200
