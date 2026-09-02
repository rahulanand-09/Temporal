#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PIDFILE="$DIR/.temporal-dev.pid"

if [[ -f "$PIDFILE" ]]; then
  PID=$(cat "$PIDFILE")
  kill "$PID" 2>/dev/null || true
  rm -f "$PIDFILE"
  echo "Stopped Temporal dev server (pid $PID)."
else
  echo "No pidfile at $PIDFILE -- is it running? (Ctrl-C the callback-service/worker-service terminals separately.)"
fi
