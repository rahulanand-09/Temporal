#!/usr/bin/env bash
# Pulls a consistent bottleneck-relevant metrics snapshot from Prometheus + Temporal directly.
# Reuses one long-lived debug pod for all Prometheus queries instead of spawning one per query.
# Usage: ./snapshot.sh <label>
set -euo pipefail
LABEL="${1:-snapshot}"
PROM="http://kps-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
DEBUG_POD="snapshot-debug"

if ! kubectl get pod "$DEBUG_POD" -n monitoring >/dev/null 2>&1; then
  kubectl run "$DEBUG_POD" --image=curlimages/curl:latest --restart=Never -n monitoring \
    --command -- sleep 3600 >/dev/null
  kubectl wait --for=condition=Ready "pod/$DEBUG_POD" -n monitoring --timeout=30s >/dev/null
fi

q() {
  kubectl exec -n monitoring "$DEBUG_POD" -- curl -s --data-urlencode "query=$1" "$PROM/api/v1/query" \
    | python3 -c "
import json,sys
d = json.load(sys.stdin)
for r in d.get('data', {}).get('result', []):
    print(' ', r.get('metric', {}), '=', r.get('value', [None, '?'])[1])
if not d.get('data', {}).get('result'):
    print('  (no data)')
"
}

echo "=== [$LABEL] $(date -u +%FT%TZ) ==="

echo "--- Open OrderFulfillmentWorkflow executions ---"
kubectl exec -n temporal-system deploy/temporal-admintools -- temporal workflow count \
  --address temporal-frontend:7233 \
  --query "WorkflowType = 'OrderFulfillmentWorkflow' AND ExecutionStatus = 'Running'" 2>&1

echo "--- Postgres: current connections / max_connections ---"
q 'sum(pg_stat_activity_count)'
q 'pg_settings_max_connections'

echo "--- Temporal persistence latency p95 by operation (1m) ---"
# No "temporal_" prefix on server-side Go metrics -- confirmed against the real expr in
# temporalio/dashboards' own server-general.json, not guessed (SDK-side Python metrics below
# DO carry the temporal_ prefix -- two components, two conventions).
q 'histogram_quantile(0.95,sum(rate(persistence_latency_bucket[1m])) by (operation,le))'

echo "--- History CPU (cores, 1m avg) per pod ---"
q 'sum(rate(container_cpu_usage_seconds_total{namespace="temporal-system",pod=~"temporal-history.*",container="temporal-history"}[1m])) by (pod)'

echo "--- History memory working set (MiB) per pod ---"
q 'container_memory_working_set_bytes{namespace="temporal-system",pod=~"temporal-history.*",container="temporal-history"}/1048576'

echo "--- Postgres CPU (cores, 1m avg) + memory (MiB) ---"
q 'sum(rate(container_cpu_usage_seconds_total{namespace="temporal-system",pod=~"postgres.*",container="postgresql"}[1m]))'
q 'container_memory_working_set_bytes{namespace="temporal-system",pod=~"postgres.*",container="postgresql"}/1048576'

echo "--- worker-service: total activity poll-no-task count (rising fast = idle/underloaded) ---"
q 'sum(temporal_activity_poll_no_task)'

echo "--- worker-service CPU (cores, 1m avg) per pod ---"
q 'sum(rate(container_cpu_usage_seconds_total{namespace="order-fulfillment",pod=~"worker-service.*",container="worker-service"}[1m])) by (pod)'

echo "=== end [$LABEL] ==="
