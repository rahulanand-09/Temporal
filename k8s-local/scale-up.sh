#!/usr/bin/env bash
# Restores the exact load-tested topology from OBSERVABILITY_AND_LOAD_TEST.md: 3 Frontend /
# 4 History / 3 Matching / 2 (internal) Worker, Postgres at 1 CPU / 1Gi request, 4 worker-service
# + 3 callback-service replicas. Inverse of scale-down.sh -- just re-applies the values files
# as-is, since those files ARE the documented full-scale state (scale-down.sh's --set overrides
# don't persist anywhere, so there's nothing to "undo" beyond re-applying the base values).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Restoring diversified Temporal server topology (3/4/3/2) ==="
helm upgrade temporal temporal/temporal --version 1.6.0 -n temporal-system -f "$DIR/temporal-values.yaml"

echo "=== Restoring Postgres resources (1 CPU / 1Gi request, 2Gi limit) ==="
helm upgrade postgres bitnami/postgresql --version 18.8.15 -n temporal-system -f "$DIR/postgres-values.yaml"

echo "=== Restoring app service replicas (worker-service x4, callback-service x3) ==="
kubectl scale deployment/worker-service -n order-fulfillment --replicas=4
kubectl scale deployment/callback-service -n order-fulfillment --replicas=3

echo "=== Done. Re-run k8s-local/load-test/run-stage.sh (or run-k6.sh) to load test again. ==="
