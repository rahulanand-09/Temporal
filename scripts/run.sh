#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PIDFILE="$DIR/.temporal-dev.pid"

echo "Starting Temporal dev server (embedded SQLite + Web UI, no Docker needed)..."
nohup temporal server start-dev \
  --db-filename "$DIR/.temporal.db" \
  --ui-port 8233 \
  --port 7233 \
  > "$DIR/.temporal-dev.log" 2>&1 &
echo $! > "$PIDFILE"

echo "Waiting for Temporal Web UI on http://localhost:8233 ..."
until curl -sf http://localhost:8233 >/dev/null 2>&1; do
  sleep 1
done
echo "Temporal dev server is up."
echo "  gRPC frontend: localhost:7233"
echo "  Web UI:        http://localhost:8233"
echo
echo "Next steps (run each in its own terminal):"
echo "  1) cd services/callback-service && npm install && npm start"
echo "  2) cd services/worker-service && pip install -r requirements.txt && python worker.py"
echo "  3) ./scripts/start_workflow.sh"
