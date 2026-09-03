#!/usr/bin/env bash
# Controlled numHistoryShards comparison: 128 / 256 / 512, run one at a time, each against a
# fresh isolated Temporal release (own databases, same Postgres instance), same 3F/4H/3M/2W
# topology as every other result in this project. Unlike the earlier one-off 512-vs-2048 test,
# this one: (1) warms the cluster up before measuring, to remove the cold-start confound that
# was flagged as an open caveat last time, and (2) lets workflows actually COMPLETE via the real
# signal path (short AUTH_DELAY_MS) instead of parking them open and batch-terminating --
# exercises the full lifecycle (payment -> shipping -> fan-out notify -> finalize) end to end.
#
# Usage: ./shard-experiment.sh <shard_count>
set -euo pipefail
SHARDS="${1:?shard count required (128, 256, or 512)}"
RELEASE="temporal-shard${SHARDS}"
DB="temporal_shard${SHARDS}"
DIR="$(cd "$(dirname "$0")" && pwd)"
WARMUP_COUNT=100
MEASURE_COUNT=5000
CONCURRENCY=500
NS=shard-test

echo "##### numHistoryShards=${SHARDS}: starting #####"

# `helm uninstall` (used at the end of a run, or by hand after a failed one) never drops the
# Postgres databases it created -- only the k8s resources. Learned this the expensive way: a
# retry after a crashed first attempt silently inherited the first attempt's leftover data,
# including workflows permanently orphaned by that crash (their in-memory setTimeout signal
# callbacks died with the pods that held them), which then looked like a genuine shard-count
# stall in the SECOND, supposedly-clean run. Drop-and-recreate here, every time, so a re-run of
# this script is actually idempotent regardless of how the last attempt ended.
echo "--- 0. Ensure a clean slate: drop any pre-existing $DB / ${DB}_visibility databases ---"
helm uninstall "$RELEASE" -n temporal-system --wait --timeout 2m >/dev/null 2>&1 || true
kubectl delete namespace "$NS" --wait --timeout=60s >/dev/null 2>&1 || true
PGPW=$(kubectl get secret --namespace temporal-system postgres-credentials -o jsonpath="{.data.postgres-password}" | base64 -d)
kubectl exec -n temporal-system postgres-postgresql-0 -c postgresql -- env PGPASSWORD="$PGPW" \
  psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS ${DB} WITH (FORCE);" 2>&1
kubectl exec -n temporal-system postgres-postgresql-0 -c postgresql -- env PGPASSWORD="$PGPW" \
  psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS ${DB}_visibility WITH (FORCE);" 2>&1

echo "--- 1. Deploy isolated Temporal release ($RELEASE, db=$DB) ---"
helm install "$RELEASE" temporal/temporal --version 1.6.0 -n temporal-system \
  -f "$DIR/temporal-values.yaml" \
  --set server.config.persistence.numHistoryShards="$SHARDS" \
  --set server.config.persistence.datastores.default.sql.databaseName="${DB}" \
  --set server.config.persistence.datastores.visibility.sql.databaseName="${DB}_visibility" \
  --wait --timeout 5m

echo "--- 2. Deploy app tier (namespace=$NS), AUTH_DELAY_MS default so orders actually complete ---"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: callback-service, namespace: $NS, labels: {app: callback-service}}
spec:
  replicas: 3
  selector: {matchLabels: {app: callback-service}}
  template:
    metadata: {labels: {app: callback-service}}
    spec:
      containers:
        - name: callback-service
          image: callback-service:load-test
          imagePullPolicy: IfNotPresent
          ports: [{containerPort: 4000}]
          env:
            - {name: PORT, value: "4000"}
            - {name: TEMPORAL_ADDRESS, value: "${RELEASE}-frontend.temporal-system.svc.cluster.local:7233"}
            - {name: AUTH_DELAY_MS, value: "4000"}
          resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {memory: 256Mi}}
---
apiVersion: v1
kind: Service
metadata: {name: callback-service, namespace: $NS}
spec:
  selector: {app: callback-service}
  ports: [{port: 4000, targetPort: 4000}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: worker-service, namespace: $NS, labels: {app: worker-service}}
spec:
  replicas: 4
  selector: {matchLabels: {app: worker-service}}
  template:
    metadata: {labels: {app: worker-service}}
    spec:
      containers:
        - name: worker-service
          image: order-worker-service:load-test
          imagePullPolicy: IfNotPresent
          env:
            - {name: TEMPORAL_ADDRESS, value: "${RELEASE}-frontend.temporal-system.svc.cluster.local:7233"}
            - {name: TEMPORAL_NAMESPACE, value: "default"}
            - {name: TEMPORAL_TASK_QUEUE, value: "order-fulfillment-queue"}
            - {name: CALLBACK_BASE_URL, value: "http://callback-service.${NS}.svc.cluster.local:4000"}
            - {name: JSONPLACEHOLDER_BASE_URL, value: "http://callback-service.${NS}.svc.cluster.local:4000"}
            - {name: MAX_CONCURRENT_ACTIVITIES, value: "200"}
            - {name: MAX_CONCURRENT_WORKFLOW_TASKS, value: "200"}
            - {name: METRICS_BIND_ADDRESS, value: ""}
          resources: {requests: {cpu: 250m, memory: 256Mi}, limits: {memory: 512Mi}}
EOF
kubectl wait --for=condition=Ready pod --all -n "$NS" --timeout=90s

echo "--- 3. Register search attributes on this release's namespace (idempotent) ---"
kubectl exec -n temporal-system "deploy/${RELEASE}-admintools" -- \
  temporal operator search-attribute create --address "${RELEASE}-frontend:7233" --namespace default \
  --name OrderNotes --type Text 2>&1 | grep -v "already exists" || true

echo "--- 4. Warm-up batch: $WARMUP_COUNT orders, wait for full drain (removes cold-start confound) ---"
kubectl create configmap k6-orders-script -n "$NS" \
  --from-file="$DIR/load-test/orders-stage.js" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl delete job k6-warmup -n "$NS" --ignore-not-found >/dev/null 2>&1
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata: {name: k6-warmup, namespace: $NS}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: grafana/k6:latest
          args: ["run", "/scripts/orders-stage.js"]
          env:
            - {name: BASE_URL, value: "http://callback-service.${NS}.svc.cluster.local:4000"}
            - {name: TARGET_COUNT, value: "$WARMUP_COUNT"}
            - {name: CONCURRENCY, value: "50"}
            - {name: STAGE, value: "warmup"}
          resources: {requests: {cpu: 250m, memory: 128Mi}, limits: {memory: 256Mi}}
          volumeMounts: [{name: script, mountPath: /scripts}]
      volumes: [{name: script, configMap: {name: k6-orders-script}}]
EOF
kubectl wait --for=condition=complete --timeout=120s job/k6-warmup -n "$NS" 2>&1 || true

echo "waiting for warm-up batch to fully drain to 0 running..."
for i in $(seq 1 30); do
  RUNNING=$(kubectl exec -n temporal-system "deploy/${RELEASE}-admintools" -- \
    temporal workflow count --address "${RELEASE}-frontend:7233" --query "ExecutionStatus = 'Running'" 2>&1 | grep -oE '[0-9]+' | head -1 || echo "?")
  RUNNING="${RUNNING:-?}"
  echo "  running=$RUNNING (check $i/30)"
  [ "$RUNNING" = "0" ] && break
  sleep 5
done

echo "--- 5. MEASURED run: $MEASURE_COUNT orders, concurrency $CONCURRENCY ---"
START_EPOCH=$(date -u +%s)
START_ISO=$(date -u -r "$START_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$START_EPOCH" +%Y-%m-%dT%H:%M:%SZ)
echo "start: $START_ISO"

kubectl delete job k6-measure -n "$NS" --ignore-not-found >/dev/null 2>&1
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata: {name: k6-measure, namespace: $NS}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: grafana/k6:latest
          args: ["run", "--out", "experimental-prometheus-rw", "/scripts/orders-stage.js"]
          env:
            - {name: BASE_URL, value: "http://callback-service.${NS}.svc.cluster.local:4000"}
            - {name: TARGET_COUNT, value: "$MEASURE_COUNT"}
            - {name: CONCURRENCY, value: "$CONCURRENCY"}
            - {name: STAGE, value: "measure-${SHARDS}"}
            - {name: K6_PROMETHEUS_RW_SERVER_URL, value: "http://kps-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write"}
          resources: {requests: {cpu: 500m, memory: 256Mi}, limits: {memory: 512Mi}}
          volumeMounts: [{name: script, mountPath: /scripts}]
      volumes: [{name: script, configMap: {name: k6-orders-script}}]
EOF
kubectl wait --for=condition=complete --timeout=500s job/k6-measure -n "$NS" 2>&1 || true
kubectl logs job/k6-measure -n "$NS" --tail=25

echo "waiting for measured batch to fully drain to 0 running (this is the completion path, not termination)..."
for i in $(seq 1 240); do
  RUNNING=$(kubectl exec -n temporal-system "deploy/${RELEASE}-admintools" -- \
    temporal workflow count --address "${RELEASE}-frontend:7233" --query "ExecutionStatus = 'Running'" 2>&1 | grep -oE '[0-9]+' | head -1 || echo "?")
  RUNNING="${RUNNING:-?}"
  [ $((i % 6)) -eq 0 ] && echo "  running=$RUNNING (check $i/240, $((i*5))s elapsed)"
  [ "$RUNNING" = "0" ] && break
  sleep 5
done
END_EPOCH=$(date -u +%s)
END_ISO=$(date -u -r "$END_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$END_EPOCH" +%Y-%m-%dT%H:%M:%SZ)
echo "end: $END_ISO (drain took $((END_EPOCH - START_EPOCH))s total)"

echo "--- 6. Final status counts ---"
kubectl exec -n temporal-system "deploy/${RELEASE}-admintools" -- \
  temporal workflow count --address "${RELEASE}-frontend:7233" --query "WorkflowType = 'OrderFulfillmentWorkflow'" 2>&1
kubectl exec -n temporal-system "deploy/${RELEASE}-admintools" -- \
  temporal workflow count --address "${RELEASE}-frontend:7233" --query "ExecutionStatus = 'Completed'" 2>&1
kubectl exec -n temporal-system "deploy/${RELEASE}-admintools" -- \
  temporal workflow count --address "${RELEASE}-frontend:7233" --query "ExecutionStatus != 'Completed'" 2>&1

echo "$SHARDS $START_EPOCH $END_EPOCH $DB" >> "$DIR/shard-experiment-results.txt"
echo "##### numHistoryShards=${SHARDS}: measurement window recorded ($START_EPOCH -> $END_EPOCH) #####"
