// Same as orders-stage.js, but tags each order with search attributes so there's a real corpus
// to search over: OrderRegion (Keyword, exact-match jsonb_path_ops GIN) from a small fixed pool
// (skewed cardinality on purpose -- some regions common, one rare, to see how index
// effectiveness varies with selectivity), and OrderNotes (Text, tsvector GIN) built from a
// small pool of phrases so specific-word searches have a known, verifiable expected count.
import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://callback-service.order-fulfillment.svc.cluster.local:4000';
const TARGET_COUNT = Number(__ENV.TARGET_COUNT || 500);
const CONCURRENCY = Number(__ENV.CONCURRENCY || 100);
const STAGE = __ENV.STAGE || 'tagged';

// Deliberately skewed: US/EU dominate, APAC less common, IN rare -- selectivity varies by design.
const REGIONS = ['US', 'US', 'US', 'EU', 'EU', 'APAC', 'IN'];
const NOTES = [
  'expedited shipment delayed at customs warehouse',
  'standard delivery completed on time',
  'priority order fragile handling required',
  'customer requested delivery reschedule',
  'international shipment cleared customs quickly',
];

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
  const region = REGIONS[Math.floor(Math.random() * REGIONS.length)];
  const notes = NOTES[Math.floor(Math.random() * NOTES.length)];
  const payload = JSON.stringify({
    userId: (__VU % 10) + 1,
    orderDetails: `k6 tagged load test order ${idempotencyKey}`,
    paymentType: 'card',
    notificationChannels: ['email'],
    region,
    orderNotes: notes,
  });
  const res = http.post(`${BASE_URL}/orders`, payload, {
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    timeout: '30s',
  });
  check(res, { 'started or already_started': (r) => r.status === 201 || r.status === 200 });
}
