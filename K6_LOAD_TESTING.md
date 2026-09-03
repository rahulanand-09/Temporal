# How k6 was used for this load test

Companion to `OBSERVABILITY_AND_LOAD_TEST.md` — that doc has the *findings*; this one is
specifically about the k6 tooling itself: why k6, how each script is built, how it runs
in-cluster, and how its metrics end up next to every other cluster metric in one Prometheus/
Grafana instance instead of a separate report to cross-reference by hand.

## Why k6

A first-pass custom Python load generator (`asyncio` + `httpx` + a semaphore) was built and
worked, before k6 was requested specifically. k6 turned out to be the better tool for this,
independent of the request, for three concrete reasons:

1. **Purpose-built executors** for exactly the two load shapes this test needed:
   `shared-iterations` (run exactly N total iterations across a bounded VU count — "start this
   many orders, bounded concurrency, then stop") and `constant-vus` (hold a fixed concurrency
   for a fixed duration — "sustain this many concurrent searches for 20 seconds"). Both are one
   config block in k6; both needed hand-rolled bookkeeping in the Python version.
2. **A built-in Prometheus remote-write output** (`--out experimental-prometheus-rw`) — shipped
   in core k6 as of 2026, no `xk6` custom build required. This is the single biggest reason k6
   won: it means k6's own request-rate/latency/failure metrics land in the *same* Prometheus as
   every Temporal server metric, every container's CPU/memory, and Postgres's exporter — one
   Grafana, one timeline, not "check the load tool's report, then separately check the
   dashboards and try to line up the timestamps by hand."
3. **Official `grafana/k6` Docker image** — runs as a plain Kubernetes Job with no build step,
   which matters because this load test runs *in-cluster* (see below), not from the host.

## Why in-cluster, not from the host

`kubectl port-forward` is a single-stream proxy. It's fine for the sanity checks and Grafana/
Prometheus access documented elsewhere in this repo, but it was never going to carry the
concurrency this test needed (hundreds of VUs, thousands of requests in single-digit seconds) —
the port-forward itself would have become the bottleneck, and the results would have measured
the laptop's proxy path instead of the cluster. Every k6 run in this test is a Kubernetes `Job`
in the `order-fulfillment` namespace, talking to `callback-service` over the in-cluster Service
DNS name (`http://callback-service.order-fulfillment.svc.cluster.local:4000`) — same network
path a real caller inside the cluster would use.

## The three scripts

All three live in `k8s-local/load-test/` and share one shape: read configuration from `__ENV`
(so the same script serves every stage, just called with different values), tag or query
against the real `OrderFulfillmentWorkflow`/its idempotency-keyed HTTP entry point, and let k6's
own summary + Prometheus export do the reporting — no custom result-parsing code.

### `orders-stage.js` — the write-path load, staged

```js
export const options = {
  scenarios: {
    orders: {
      executor: 'shared-iterations',
      vus: CONCURRENCY,
      iterations: TARGET_COUNT,
      maxDuration: __ENV.MAX_DURATION || '10m',
    },
  },
};

export default function () {
  const idempotencyKey = `${STAGE}-${__VU}-${__ITER}-${Date.now()}`;
  // ... POST to /orders with Idempotency-Key: idempotencyKey
}
```

Every iteration gets a fresh, deterministically-unique idempotency key
(`stage-VU-iteration-timestamp`), so re-running the same stage label never collides with a
previous run, and every VU's key stream is independent of every other VU's — no coordination
needed to guarantee uniqueness across hundreds of concurrent VUs. This is also what made the
idempotency behavior itself easy to verify: sending the *same* key twice (a separate, deliberate
test, not part of the staged ramp) reliably produced exactly one execution.

Run one stage at a time via `run-stage.sh <target_count> <concurrency> <stage_label>` —
deliberately not one k6 script with baked-in `stages: [...]` ramping automatically from 0 to
20,000. The point was to read Grafana/Prometheus *between* stages and let the next stage's size
be a real decision informed by what the last one showed (see `OBSERVABILITY_AND_LOAD_TEST.md`'s
staged results table) — an automated ramp would have removed exactly the checkpoint this test
was built around.

### `orders-tagged-stage.js` — building a searchable corpus

Same `shared-iterations` shape, but each order also carries randomized `OrderRegion` (from a
deliberately skewed pool — `US`×3, `EU`×2, `APAC`×1, `IN`×1 — so the resulting corpus has
uneven, realistic selectivity across regions) and `OrderNotes` (one of five fixed phrases, two
containing the word "customs") search attributes:

```js
const REGIONS = ['US', 'US', 'US', 'EU', 'EU', 'APAC', 'IN'];
const NOTES = [ /* five phrases, two mentioning "customs" */ ];

export default function () {
  const region = REGIONS[Math.floor(Math.random() * REGIONS.length)];
  const notes = NOTES[Math.floor(Math.random() * NOTES.length)];
  // ... POST to /orders with { region, orderNotes, ... } in the body
}
```

This exists purely to give the search load test (next) real data with a known, verifiable
expected distribution — after running it, `GET /search?query=OrderRegion='IN'` should return a
count matching the pool's weighting, which is exactly how the corpus was checked before trusting
any search-latency numbers.

### `search-stage.js` — the read-path load

Different executor on purpose: `constant-vus` for a fixed `duration`, not `shared-iterations`
for a fixed count. Searches are cheap per-call compared to starting a workflow, so "how many
total requests" is the wrong thing to hold constant here — what matters is sustained concurrent
query pressure over time, which `constant-vus` gives directly:

```js
const QUERIES = [
  { label: 'exact_common', q: "OrderRegion = 'US'" },   // B-tree, low selectivity
  { label: 'exact_rare',   q: "OrderRegion = 'IN'" },    // B-tree, high selectivity
  { label: 'text_match',   q: "OrderNotes = 'customs'" }, // GIN tsvector, full-text
];

export const options = {
  scenarios: { search: { executor: 'constant-vus', vus: CONCURRENCY, duration: DURATION } },
};

export default function () {
  const pick = QUERIES[__ITER % QUERIES.length];
  const res = http.get(`${BASE_URL}/search?query=${encodeURIComponent(pick.q)}`, {
    tags: { query_label: pick.label },
  });
  check(res, { 'search ok': (r) => r.status === 200 }, { query_label: pick.label });
}
```

The `tags: { query_label: pick.label }` on both the request and the `check` is what makes the
three query shapes separable *after* the run — k6's Prometheus remote-write output carries
custom tags through as Prometheus labels, so
`k6_http_req_duration_p95{query_label="text_match"}` and
`k6_http_req_duration_p95{query_label="exact_common"}` are independently queryable in Grafana/
Prometheus, not just a single blended number. This is what actually made the GIN-vs-B-tree
comparison possible — without per-query-type tagging, the aggregate summary alone couldn't have
told the tsvector path from the exact-match path.

## Running a stage

```bash
# write path, one stage
./run-stage.sh <target_count> <concurrency> <stage_label>

# write path (tagged) or read path, via the generic runner
./run-k6.sh orders-tagged-stage.js <job_name> TARGET_COUNT=6000 CONCURRENCY=500 STAGE=tagged
./run-k6.sh search-stage.js <job_name> CONCURRENCY=25 DURATION=20s
```

Both wrapper scripts do the same three things: sync the k6 script(s) into a ConfigMap (so the
Job always runs the current file, not a stale copy baked into an image), delete any previous Job
with the same name (Jobs are immutable once created — re-running a stage means deleting first),
and apply a `Job` manifest pointing at `grafana/k6:latest` with the script mounted in and
`K6_PROMETHEUS_RW_SERVER_URL` set to the in-cluster Prometheus. `run-k6.sh` generalizes this
across all three scripts instead of duplicating the same Job-management logic three times;
`run-stage.sh` predates it and still works identically for `orders-stage.js` — both are kept
since `OBSERVABILITY_AND_LOAD_TEST.md`'s write-path results already document `run-stage.sh` by
name.

## Wiring the Prometheus output

```yaml
env:
  - name: K6_PROMETHEUS_RW_SERVER_URL
    value: "http://kps-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write"
  - name: K6_PROMETHEUS_RW_TREND_STATS
    value: "p(95),p(99),min,max"
args: ["run", "--out", "experimental-prometheus-rw", "/scripts/<script>.js"]
```

Two things had to be true on the Prometheus side before this worked, neither of which is
Prometheus's default:

- **`enableRemoteWriteReceiver: true`** in `k8s-local/observability-values.yaml` — Prometheus
  doesn't accept remote-write pushes by default; this is the flag that turns the receiver on
  (`prometheus.prometheusSpec.enableRemoteWriteReceiver` in the `kube-prometheus-stack` chart).
- **`K6_PROMETHEUS_RW_TREND_STATS`** controls which percentiles/aggregates get exported as
  separate metrics (`k6_http_req_duration_p95`, `_p99`, `_min`, `_max`) rather than as a full
  histogram — checked directly via Prometheus's own series API
  (`match[]={__name__=~"k6_http_req_duration.*"}`) after the first run, since the metric *names*
  weren't obvious from the k6 docs alone and guessing wrong would have meant silently querying
  nothing.

Verified working end-to-end, not just configured: after the very first smoke-run (50 orders),
`k6_http_reqs_total` was queryable directly from Prometheus with the exact status code and
target URL as labels — confirmed before trusting it for anything at real scale.

## What this bought over the Python version

Beyond the executor/reporting wins above, one real methodological benefit showed up directly in
the search-test findings: because k6's per-request metrics carry through to Prometheus with
full label fidelity (`query_label`, status code, etc.), it was possible to notice that k6's
*client-observed* p95 latency (4.5-4.8s) didn't match Temporal's own *server-side* RPC latency
histogram for the same operation (6.6ms) during the same time window — a discrepancy that would
have been much easier to miss (or much more work to detect) with a load tool reporting only its
own aggregate numbers in isolation. See `OBSERVABILITY_AND_LOAD_TEST.md`'s search section for
what that discrepancy means and what wasn't chased down.
