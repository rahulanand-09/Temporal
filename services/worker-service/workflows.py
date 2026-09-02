import asyncio
from datetime import timedelta

from temporalio import workflow
from temporalio.common import RetryPolicy

with workflow.unsafe.imports_passed_through():
    from activities import (
        create_order,
        finalize_order,
        get_user,
        initiate_payment,
        notify_channel,
        process_shipping,
    )

DEFAULT_RETRY = RetryPolicy(maximum_attempts=3)


@workflow.defn
class OrderFulfillmentWorkflow:
    def __init__(self) -> None:
        self._payment_confirmed = False
        self._payment_payload: dict = {}
        self._stage = "started"

    @workflow.signal
    async def confirm_payment(self, payload: dict) -> None:
        self._payment_payload = payload
        self._payment_confirmed = True

    @workflow.query
    def get_state(self) -> dict:
        return {"stage": self._stage, "paymentConfirmed": self._payment_confirmed}

    @workflow.run
    async def run(self, input: dict) -> dict:
        self._stage = "fetching_user"
        user = await workflow.execute_activity(
            get_user,
            input["userId"],
            start_to_close_timeout=timedelta(seconds=10),
            retry_policy=DEFAULT_RETRY,
        )

        self._stage = "creating_order"
        order = await workflow.execute_activity(
            create_order,
            {
                "title": f"Order for {user['name']}",
                "body": input["orderDetails"],
                "userId": input["userId"],
            },
            start_to_close_timeout=timedelta(seconds=10),
            retry_policy=DEFAULT_RETRY,
        )
        order_id = order["id"]

        self._stage = "awaiting_payment"
        payment_type = input.get("paymentType", "unspecified")
        await workflow.execute_activity(
            initiate_payment,
            {
                "workflowId": workflow.info().workflow_id,
                "orderId": order_id,
                "paymentMethod": payment_type,
            },
            start_to_close_timeout=timedelta(seconds=10),
            retry_policy=DEFAULT_RETRY,
        )

        # Direct analog of Conductor's WAIT task + POST /tasks/{id}/signal --
        # parks here at zero cost until callback-service delivers the
        # 'confirm_payment' signal. No special task type; just a coroutine
        # suspended on a condition.
        await workflow.wait_condition(lambda: self._payment_confirmed)

        self._stage = "shipping"
        shipping = await workflow.execute_activity(
            process_shipping,
            order_id,
            start_to_close_timeout=timedelta(seconds=60),
            retry_policy=RetryPolicy(maximum_attempts=3, backoff_coefficient=2.0),
        )

        self._stage = "notifying"
        channels = input.get("notificationChannels", ["email"])
        # Direct analog of Conductor's FORK_JOIN_DYNAMIC -- fan-out width
        # decided at runtime by len(channels), expressed as plain code
        # instead of a special dynamic-fork task type.
        await asyncio.gather(
            *[
                workflow.execute_activity(
                    notify_channel,
                    {"channel": ch, "orderId": order_id},
                    start_to_close_timeout=timedelta(seconds=10),
                    retry_policy=DEFAULT_RETRY,
                )
                for ch in channels
            ]
        )

        self._stage = "finalizing"
        final = await workflow.execute_activity(
            finalize_order,
            {"orderId": order_id, "shippingCarrier": shipping["carrier"]},
            start_to_close_timeout=timedelta(seconds=10),
            retry_policy=DEFAULT_RETRY,
        )

        self._stage = "completed"
        return {
            "orderId": order_id,
            "paymentStatus": self._payment_payload.get("paymentStatus"),
            "shippingStatus": shipping["status"],
            "finalOrder": final,
        }
