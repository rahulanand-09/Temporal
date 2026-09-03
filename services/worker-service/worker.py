import asyncio
import logging
import os

from temporalio.client import Client
from temporalio.runtime import PrometheusConfig, Runtime, TelemetryConfig
from temporalio.worker import Worker

from activities import (
    create_order,
    finalize_order,
    get_user,
    initiate_payment,
    notify_channel,
    process_shipping,
)
from workflows import OrderFulfillmentWorkflow

TEMPORAL_ADDRESS = os.environ.get("TEMPORAL_ADDRESS", "localhost:7233")
TEMPORAL_NAMESPACE = os.environ.get("TEMPORAL_NAMESPACE", "default")
TASK_QUEUE = os.environ.get("TEMPORAL_TASK_QUEUE", "order-fulfillment-queue")
# Bounds how many activity/workflow tasks this one worker process executes concurrently --
# the thing that actually limits how much of a burst a single replica can absorb before tasks
# queue up in Matching. Scale via MAX_CONCURRENT_ACTIVITIES + replica count, not one or the other.
MAX_CONCURRENT_ACTIVITIES = int(os.environ.get("MAX_CONCURRENT_ACTIVITIES", "100"))
MAX_CONCURRENT_WORKFLOW_TASKS = int(os.environ.get("MAX_CONCURRENT_WORKFLOW_TASKS", "100"))
# Poller/task-slot utilization and activity/workflow-task latency, straight from the SDK -- the
# piece cAdvisor's container CPU/mem alone can't show: whether this worker is actually keeping
# up with Matching's dispatch rate, or backlogged. Set to "" to disable (bind fails loudly if
# the port's already taken, rather than silently running without metrics).
METRICS_BIND_ADDRESS = os.environ.get("METRICS_BIND_ADDRESS", "0.0.0.0:9464")


async def main() -> None:
    logging.basicConfig(level=logging.INFO)
    runtime = None
    if METRICS_BIND_ADDRESS:
        runtime = Runtime(
            telemetry=TelemetryConfig(metrics=PrometheusConfig(bind_address=METRICS_BIND_ADDRESS))
        )
    client = await Client.connect(TEMPORAL_ADDRESS, namespace=TEMPORAL_NAMESPACE, runtime=runtime)
    worker = Worker(
        client,
        task_queue=TASK_QUEUE,
        workflows=[OrderFulfillmentWorkflow],
        activities=[
            get_user,
            create_order,
            initiate_payment,
            process_shipping,
            notify_channel,
            finalize_order,
        ],
        max_concurrent_activities=MAX_CONCURRENT_ACTIVITIES,
        max_concurrent_workflow_tasks=MAX_CONCURRENT_WORKFLOW_TASKS,
    )
    print(
        f"worker-service polling task queue '{TASK_QUEUE}' on namespace '{TEMPORAL_NAMESPACE}' "
        f"@ {TEMPORAL_ADDRESS} (max_concurrent_activities={MAX_CONCURRENT_ACTIVITIES}, "
        f"max_concurrent_workflow_tasks={MAX_CONCURRENT_WORKFLOW_TASKS})"
    )
    await worker.run()


if __name__ == "__main__":
    asyncio.run(main())
