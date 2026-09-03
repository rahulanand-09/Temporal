#!/usr/bin/env bash
# Scales the whole stack down to a minimal idle footprint after a load test, without losing the
# load-tested configuration: temporal-values.yaml / postgres-values.yaml stay as-is (the
# documented "full scale" state from OBSERVABILITY_AND_LOAD_TEST.md) -- this script layers
# `--set` overrides on top via helm, and `kubectl scale` for the two plain-manifest app
# Deployments. Run scale-up.sh to reverse this exactly.
#
# Does NOT touch: Postgres data (databases/schema/rows untouched, only CPU/mem requests
# shrink), max_connections (left at 500 -- harmless headroom, no reason to revert),
# ServiceMonitors/observability (Prometheus+Grafana are cheap and stay up for visibility).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Scaling Temporal server down to 1 replica per service ==="
helm upgrade temporal temporal/temporal --version 1.6.0 -n temporal-system \
  -f "$DIR/temporal-values.yaml" \
  --set server.frontend.replicaCount=1 \
  --set server.frontend.resources.requests.cpu=100m \
  --set server.frontend.resources.requests.memory=128Mi \
  --set server.history.replicaCount=1 \
  --set server.history.resources.requests.cpu=100m \
  --set server.history.resources.requests.memory=256Mi \
  --set server.matching.replicaCount=1 \
  --set server.matching.resources.requests.cpu=100m \
  --set server.matching.resources.requests.memory=128Mi \
  --set server.worker.replicaCount=1 \
  --set server.worker.resources.requests.cpu=100m \
  --set server.worker.resources.requests.memory=128Mi

echo "=== Scaling Postgres resources down (schema/data untouched) ==="
helm upgrade postgres bitnami/postgresql --version 18.8.15 -n temporal-system \
  -f "$DIR/postgres-values.yaml" \
  --set primary.resources.requests.cpu=250m \
  --set primary.resources.requests.memory=256Mi \
  --set primary.resources.limits.memory=512Mi

echo "=== Scaling app services down to 1 replica each ==="
kubectl scale deployment/callback-service -n order-fulfillment --replicas=1
kubectl scale deployment/worker-service -n order-fulfillment --replicas=1

echo "=== Done. Run scale-up.sh to restore the load-tested topology. ==="
