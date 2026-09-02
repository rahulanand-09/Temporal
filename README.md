# Temporal Durable Execution POC

Local-only proof of concept for [Temporal](https://github.com/temporalio/temporal) as a durable
execution engine — the direct counterpart to the `conductor/` POC in this workspace, built to the
same brief: scalability, configurability, server-management overhead, customization, developer
friendliness, and a functional comparison vs Conductor.

Same business scenario as the Conductor POC (`order_fulfillment`), reimplemented as Temporal's
actual programming model instead of a JSON graph:

1. `get_user` / `create_order` — two real HTTP integrations (JSONPlaceholder), as Activities
2. A payment-method branch — a plain `if/elif` in workflow code (no special task type)
3. `initiate_payment` calls `callback-service`, then the workflow calls
   `workflow.wait_condition(...)`, parking until `callback-service` delivers a real **Signal**
   (`confirm_payment`) — the callback block
4. `process_shipping` — an Activity executed by the same polling Python worker (the async block —
   and in Temporal, *every* Activity works this way, not just this one)
5. `notify_channel` × N — `asyncio.gather` over the workflow's `notificationChannels` input,
   fanned out to however many channels the input contains — the dynamic block
6. `finalize_order` — a terminal HTTP call

## Prerequisites

- [Temporal CLI](https://docs.temporal.io/cli) (`brew install temporal`) — runs the dev server
  locally with an embedded SQLite store and a Web UI, no Docker/Postgres/Elasticsearch needed
- Python 3.9+
- Node.js
- `curl`

## Run it

Terminal 1 — start the Temporal dev server:
```bash
./scripts/run.sh
```
Starts `temporal server start-dev` in the background (gRPC frontend on `:7233`, Web UI on
`:8233`), waits until the UI responds.

Terminal 2 — callback-service (stand-in payment processor + notification channels):
```bash
cd services/callback-service
npm install
PORT=4100 npm start
```
(`PORT=4100` avoids clashing with the sibling Conductor POC's callback-service, which also
defaults to `4000` — the two POCs can run side by side.)

Terminal 3 — the worker (runs *both* the workflow orchestration code and its Activities):
```bash
cd services/worker-service
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python worker.py
```

Back in terminal 1 (or a 4th) — start a run:
```bash
./scripts/start_workflow.sh
```

Open `http://localhost:8233` and find the run by workflow ID, or:
```bash
temporal workflow describe --workflow-id <id>
temporal workflow query --workflow-id <id> --type get_state   # ask the running workflow its stage
```

## What to look for

- No `register.sh` — there is no separate metadata-registration step. The workflow *is* the
  Python code in `services/worker-service/workflows.py`; it becomes runnable the moment a worker
  polling `order-fulfillment-queue` is alive.
- `await_payment_confirmation`'s Conductor analog is `workflow.wait_condition(...)` — watch
  `callback-service`'s terminal log the `/authorize` call, then ~4s later the
  `handle.signal('confirm_payment', ...)` call that resumes the workflow.
- Re-run with different input to see the dynamic fan-out change shape:
  ```bash
  INPUT='{"userId":2,"paymentType":"wallet","orderDetails":"1x Keyboard","notificationChannels":["email","sms","push"]}' \
    ./scripts/start_workflow.sh
  ```

## Gotcha found while building this

A running worker process has the workflow/activity code loaded **in memory from when it
started** — editing `activities.py` (e.g. changing a URL) does nothing to an already-running
worker; it has to be restarted to pick up the change. We hit this directly: the worker was
started before a port fix landed in `activities.py`, so its first run silently called the wrong
service (which happened to also expose a `/authorize` route and return `202`, masking the
mistake until the workflow sat parked forever waiting for a signal nothing was configured to
send). Killing and restarting the worker fixed it immediately. This isn't Temporal-specific —
every worker-poll system (including `conductor-python` in the sibling POC) has the same property
— but it bit us here because there's no server-side "workflow definition" to redeploy against;
the *worker* is the only place the logic lives.

## Stopping

```bash
./scripts/stop.sh
```
(Ctrl-C the callback-service/worker-service terminals.) Persistence is ephemeral by design (a
local SQLite file next to this README) — delete it for a clean slate.

## Evaluation write-up

See `COMPARISON.md` for the same six dimensions evaluated for Conductor, now measured against
this Temporal run, plus a direct side-by-side of the two POCs.
