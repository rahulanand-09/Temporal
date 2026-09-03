// Load-tests the visibility store's search path (GET /search -> Temporal CountWorkflowExecutions
// -> a COUNT query against executions_visibility, using whichever index the planner picks) at a
// fixed concurrency, running for a fixed duration -- not a fixed iteration count, since the goal
// here is sustained query throughput/latency under concurrency, not "how fast can N queries
// fire" (that's the orders-stage.js shape; searches are naturally much cheaper per-call so a
// duration-based constant-VUs executor gives a cleaner throughput/latency reading).
//
// Three query shapes, cycled per-iteration, chosen to cover the three index types actually
// present in this schema (confirmed via \d+ executions_visibility -- there is no GiST index
// anywhere in it, only GIN and B-tree):
//   - exact  : OrderRegion = "US"        -> GIN, jsonb_path_ops, common value (low selectivity)
//   - rare   : OrderRegion = "IN"        -> same index, rare value (high selectivity)
//   - text   : OrderNotes  = "customs"   -> GIN, tsvector, full-text match
import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://callback-service.order-fulfillment.svc.cluster.local:4000';
const CONCURRENCY = Number(__ENV.CONCURRENCY || 50);
const DURATION = __ENV.DURATION || '30s';

const QUERIES = [
  { label: 'exact_common', q: "OrderRegion = 'US'" },
  { label: 'exact_rare', q: "OrderRegion = 'IN'" },
  { label: 'text_match', q: "OrderNotes = 'customs'" },
];

export const options = {
  scenarios: {
    search: {
      executor: 'constant-vus',
      vus: CONCURRENCY,
      duration: DURATION,
    },
  },
};

export default function () {
  const pick = QUERIES[__ITER % QUERIES.length];
  const res = http.get(`${BASE_URL}/search?query=${encodeURIComponent(pick.q)}`, {
    tags: { query_label: pick.label },
    timeout: '30s',
  });
  check(res, { 'search ok': (r) => r.status === 200 }, { query_label: pick.label });
}
