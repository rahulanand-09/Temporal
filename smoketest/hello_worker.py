import asyncio
import os

from temporalio.client import Client, TLSConfig
from temporalio.worker import Worker

from hello_workflow import HelloWorkflow, say_hello

# One file, three environments -- only env vars change:
#   local dev server:    nothing set, defaults below just work
#   self-hosted + mTLS:  set TEMPORAL_TLS_CERT / TEMPORAL_TLS_KEY
#   Temporal Cloud:      set TEMPORAL_API_KEY (namespace looks like "myns.a2dd6")
TEMPORAL_ADDRESS = os.environ.get("TEMPORAL_ADDRESS", "localhost:7233")
TEMPORAL_NAMESPACE = os.environ.get("TEMPORAL_NAMESPACE", "default")
TASK_QUEUE = os.environ.get("TEMPORAL_TASK_QUEUE", "smoke-test-queue")
TLS_CERT = os.environ.get("TEMPORAL_TLS_CERT")
TLS_KEY = os.environ.get("TEMPORAL_TLS_KEY")
API_KEY = os.environ.get("TEMPORAL_API_KEY")


def build_tls_config():
    if API_KEY:
        return True  # Cloud with an API key still requires TLS, just not a client cert
    if not TLS_CERT or not TLS_KEY:
        return False
    with open(TLS_CERT, "rb") as f:
        cert = f.read()
    with open(TLS_KEY, "rb") as f:
        key = f.read()
    return TLSConfig(client_cert=cert, client_private_key=key)


async def main() -> None:
    client = await Client.connect(
        TEMPORAL_ADDRESS,
        namespace=TEMPORAL_NAMESPACE,
        tls=build_tls_config(),
        api_key=API_KEY,
    )
    worker = Worker(
        client,
        task_queue=TASK_QUEUE,
        workflows=[HelloWorkflow],
        activities=[say_hello],
    )
    print(f"smoke-test worker polling '{TASK_QUEUE}' on namespace '{TEMPORAL_NAMESPACE}' @ {TEMPORAL_ADDRESS}")
    await worker.run()


if __name__ == "__main__":
    asyncio.run(main())
