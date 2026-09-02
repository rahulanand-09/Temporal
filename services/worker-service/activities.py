import asyncio

import httpx
from temporalio import activity

CALLBACK_BASE = "http://localhost:4100"
JSONPLACEHOLDER = "https://jsonplaceholder.typicode.com"


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
