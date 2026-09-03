import asyncio
import os
import random

import httpx
from temporalio import activity

# Both default to the values used for local, non-containerized dev (matching scripts/run.sh).
# Override for in-cluster runs -- load testing in particular must not point JSONPLACEHOLDER at
# the real https://jsonplaceholder.typicode.com: that's a shared free public API, not built to
# take load-test-volume traffic, so the load test points this at an in-cluster stand-in instead.
CALLBACK_BASE = os.environ.get("CALLBACK_BASE_URL", "http://localhost:4100")
JSONPLACEHOLDER = os.environ.get("JSONPLACEHOLDER_BASE_URL", "https://jsonplaceholder.typicode.com")

# A real carrier-lookup call doesn't take exactly 3.000s every time -- fixed delay flattened
# whatever effect real variance has on queueing/concurrency under load. Default range is a
# plausible real carrier-API spread, not just "the old constant plus noise"; override via env.
SHIPPING_DELAY_MIN_S = float(os.environ.get("SHIPPING_DELAY_MIN_S", "1.5"))
SHIPPING_DELAY_MAX_S = float(os.environ.get("SHIPPING_DELAY_MAX_S", "5.0"))


@activity.defn
async def get_user(user_id: int) -> dict:
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(f"{JSONPLACEHOLDER}/users/{user_id}")
        resp.raise_for_status()
        return resp.json()


@activity.defn
async def create_order(params: dict) -> dict:
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.post(
            f"{JSONPLACEHOLDER}/posts",
            json={
                "title": params["title"],
                "body": params["body"],
                "userId": params["userId"],
            },
        )
        resp.raise_for_status()
        return resp.json()


@activity.defn
async def initiate_payment(params: dict) -> dict:
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.post(f"{CALLBACK_BASE}/authorize", json=params)
        resp.raise_for_status()
        return {"accepted": True}


@activity.defn
async def process_shipping(order_id: int) -> dict:
    delay = random.uniform(SHIPPING_DELAY_MIN_S, SHIPPING_DELAY_MAX_S)
    activity.logger.info(f"picked up order {order_id}, simulating carrier lookup ({delay:.2f}s)...")
    await asyncio.sleep(delay)  # simulated async I/O (a carrier API call), jittered not fixed
    return {"status": "SHIPPED", "orderId": order_id, "carrier": "local-sim-carrier"}


@activity.defn
async def notify_channel(params: dict) -> dict:
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.post(f"{CALLBACK_BASE}/notify", json=params)
        resp.raise_for_status()
        return resp.json()


@activity.defn
async def finalize_order(params: dict) -> dict:
    order_id = params["orderId"]
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.patch(
            f"{JSONPLACEHOLDER}/posts/{order_id}",
            json={"status": "FULFILLED", "shippingCarrier": params["shippingCarrier"]},
        )
        resp.raise_for_status()
        return resp.json()
