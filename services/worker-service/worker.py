import asyncio
import logging

from temporalio.client import Client
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

TASK_QUEUE = "order-fulfillment-queue"


async def main() -> None:
    logging.basicConfig(level=logging.INFO)
    client = await Client.connect("localhost:7233", namespace="default")
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
    )
    print(f"worker-service polling task queue '{TASK_QUEUE}'...")
    await worker.run()


if __name__ == "__main__":
    asyncio.run(main())
