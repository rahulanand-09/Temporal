#!/usr/bin/env bash
set -euo pipefail

# Override with e.g.: INPUT='{"paymentType":"wallet", ...}' ./scripts/start_workflow.sh
DEFAULT_INPUT='{"userId":1,"paymentType":"card","orderDetails":"2x Wireless Mouse, 1x USB-C Hub","notificationChannels":["email","sms"]}'
INPUT="${INPUT:-$DEFAULT_INPUT}"
WORKFLOW_ID="order-$(date +%s)-$RANDOM"

temporal workflow start \
  --task-queue order-fulfillment-queue \
  --type OrderFulfillmentWorkflow \
  --workflow-id "$WORKFLOW_ID" \
  --input "$INPUT"

echo
echo "Started workflow: $WORKFLOW_ID"
echo "Status:  temporal workflow describe --workflow-id $WORKFLOW_ID"
echo "UI:      http://localhost:8233/namespaces/default/workflows/$WORKFLOW_ID"
