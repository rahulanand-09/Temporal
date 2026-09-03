import asyncio
import os

import httpx
from temporalio import activity

# Both default to the values used for local, non-containerized dev (matching scripts/run.sh).
# Override for in-cluster runs -- load testing in particular must not point JSONPLACEHOLDER at
# the real https://jsonplaceholder.typicode.com: that's a shared free public API, not built to
# take load-test-volume traffic, so the load test points this at an in-cluster stand-in instead.
CALLBACK_BASE = os.environ.get("CALLBACK_BASE_URL", "http://localhost:4100")
JSONPLACEHOLDER = os.environ.get("JSONPLACEHOLDER_BASE_URL", "https://jsonplaceholder.typicode.com")


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
    activity.logger.info(f"picked up order {order_id}, simulating carrier lookup...")
    await asyncio.sleep(3)  # simulated async I/O (a carrier API call)
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
