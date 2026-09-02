from datetime import timedelta

from temporalio import activity, workflow


@activity.defn
async def say_hello(name: str) -> str:
    info = activity.info()
    return f"Hello, {name}! Activity ran via task queue '{info.task_queue}' (attempt {info.attempt})"


@workflow.defn
class HelloWorkflow:
    @workflow.run
    async def run(self, name: str) -> str:
        return await workflow.execute_activity(
            say_hello,
            name,
            start_to_close_timeout=timedelta(seconds=10),
        )
