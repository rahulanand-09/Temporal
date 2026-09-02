# Temporal vs Conductor — POC Findings

Scope: evidence below is hands-on from `OrderFulfillmentWorkflow` running locally against
`temporal server start-dev` (embedded SQLite). Conductor entries are hands-on from the sibling
`conductor/` POC in this workspace (`conductoross/conductor:latest`, single container, SQLite) —
both engines were actually run, unlike the original Conductor-vs-Zeebe comparison where Zeebe was
documentation-only.

| Dimension | Temporal — hands-on evidence from this POC | Conductor — hands-on evidence (sibling POC) |
|---|---|---|
| Scalability | Single dev-server process observed; production topology (History/Matching/Frontend services behind Cassandra/Postgres) is documented, not load-tested here | Single stateless server container observed; scale-out via more server nodes behind shared persistence, not load-tested |
| Configurability | Retry policy and timeouts are set **per activity call, in workflow code** (`RetryPolicy(...)`, `start_to_close_timeout=...`) — no central task-definition file | `taskdefs/task_definitions.json` sets per-task retry/timeout/rate-limit independent of the workflow definition |
| Server management | One CLI binary (`temporal server start-dev`), embedded SQLite, built-in Web UI on `:8233` — no Docker required at all | One Docker container (`conductoross/conductor:latest`), SQLite-backed, built-in UI |
| Customization | Workflow *and* activities are both just Python functions/classes in `services/worker-service/` — any logic Python can express, no JSON schema to satisfy | Wrote a real worker in Python via `@worker_task`; the *workflow graph itself* stays JSON, only leaf `SIMPLE` tasks are custom code |
| Developer friendliness | Entire workflow authored as ordinary code with real control flow (`if`, `asyncio.gather`, exceptions) and a debugger attaches to it directly; no separate modeling language | Workflow authored as JSON, iterated via REST; task-level docs (SWITCH, WAIT, FORK_JOIN_DYNAMIC) sufficient to build without touching Java |
| Async nature | Directly observed: *every* Activity (not just one) is pulled by a worker polling a Task Queue — this is Temporal's only execution model, no separate "system task run by the server itself" concept | Directly observed: WAIT+signal for callbacks; only `SIMPLE` tasks are pulled by a worker — `HTTP`/`SWITCH`/etc. run inside the server itself |
| Backward compatibility | No JSON `version` field — new workflow *code* on a worker changes behavior for every execution using that Task Queue immediately; safe rollout of workflow logic changes requires explicit code-level versioning (`workflow.patched(...)`) or routing to a new Task Queue | Workflow defs are explicitly versioned (`version` field); a running instance keeps the version it started on even if a new version is registered |
| Dynamic design | Directly observed: payment branch and notification fan-out width are both *ordinary code* (`if/elif`, `asyncio.gather` over a runtime-length list) — no special task type exists or is needed | Directly observed: `SWITCH` branches per-instance on input; `FORK_JOIN_DYNAMIC` fans out to a task count decided at runtime |
| Deploying a new workflow | **No registration step.** Starting an execution (`temporal workflow start`) just needs a worker somewhere polling the right Task Queue with that workflow type registered — there is no metadata API to call first | `POST /metadata/workflow` (+ `/metadata/taskdefs`) must succeed before `POST /workflow/{name}` will do anything useful |
| Inspecting a live run | `temporal workflow query --type get_state` calls a **Query** handler defined in the workflow's own code — arbitrary computed state, not just persisted status | `GET /workflow/{id}?includeTasks=true` — persisted task-by-task status only; no equivalent of asking the running instance a custom question |

## Honest limitations of this POC

- No load test was run against either engine — scalability claims are architectural, not measured.
- Both dev setups (Temporal CLI dev-server, Conductor's single container) are explicitly
  non-production topologies; a real deployment of either looks different operationally.
- Only one Temporal SDK (Python) was exercised, matching the sibling POC's worker language —
  behavior/ergonomics of the Go, Java, or TypeScript SDKs weren't evaluated.

## Actual run results (2026-08-31, local Mac, Apple Silicon, Temporal CLI 1.8.2 / server 1.31.2)

Two end-to-end runs of `OrderFulfillmentWorkflow`, both reaching `COMPLETED`:

| Workflow ID | paymentType | notificationChannels | Branch taken (code path) | Fan-out size | Wall-clock | Result |
|---|---|---|---|---|---|---|
| `order-1788155959-13133` | card | `[email, sms]` | `initiate_payment(method="card")` | 2 | ~8.63s | `COMPLETED` |
| `order-1788156014-7450` | wallet | `[email, sms, push]` | `initiate_payment(method="wallet")` | 3 | ~8.76s | `COMPLETED` |

Same workflow *code*, two different runtime shapes — exactly the dynamic-design claim Conductor's
`FORK_JOIN_DYNAMIC` makes, produced here with a plain `asyncio.gather` over a Python list. Both
runs' wall-clock is within ~150ms of each other and closely tracks Conductor's ~7–10s per run
(same deliberate 4s auth delay + 3s simulated shipping delay baked into both POCs) — the
engines' own overhead is comparably small in both cases.

## One real bug hit and fixed during this POC (developer-friendliness data point)

**A worker restart is required for code changes to take effect, and nothing tells you that.**
`activities.py` was edited to fix a port number *after* the worker process had already started.
The already-running worker kept using the old value from when it was imported, silently called
the wrong local service (which happened to also expose a matching `/authorize` route and return
`202 Accepted`), and the workflow then sat parked at `wait_condition(...)` indefinitely — nothing
in the workflow status or the Web UI flagged this as an error, because from Temporal's point of
view the activity had genuinely succeeded. Caught it by noticing the *intended* callback-service
process had never logged the `/authorize` call. **Fix:** kill and restart the worker after any
code change. Lesson for the write-up: **a green "activity completed" does not mean it talked to
the service you think it did** — the same shape of lesson as the sibling POC's untyped-parameter
bug, just triggered by process lifecycle instead of a missing type hint.

Minor observability note, same flavor as the sibling POC's worker `print()` issue: under a burst
of 3 concurrent `notify_channel` activities, `callback-service`'s `console.log` only surfaced 1 of
3 `[notify]` lines in the captured terminal output, even though Temporal's own event history
confirmed all 3 activities were scheduled with distinct channel values and completed with
distinct per-channel results. The workflow history (`temporal workflow show --output json`) was
the reliable source of truth, not the service's console log — worth remembering when debugging
either engine.
