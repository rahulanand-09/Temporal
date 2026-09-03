// Staged load test against callback-service's POST /orders (idempotency-keyed HTTP entry
// point for OrderFulfillmentWorkflow). Run once per ramp stage with a bigger TARGET_COUNT and a
// fresh STAGE prefix each time -- deliberately NOT one big automated ramp with baked-in stages,
// so metrics get read in Grafana between stages and the next stage's size is a real decision,
// not a pre-committed schedule (per "10000+ is arbitrary, start with less, keep bumping").
//
// Each VU sends exactly one POST per iteration; k6's shared-iterations executor spreads
// TARGET_COUNT total iterations across CONCURRENCY VUs, so this is a burst-start-rate test
// bounded by CONCURRENCY in-flight requests -- not one request at a time, not unbounded either.
import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://callback-service.order-fulfillment.svc.cluster.local:4000';
const TARGET_COUNT = Number(__ENV.TARGET_COUNT || 500);
const CONCURRENCY = Number(__ENV.CONCURRENCY || 100);
const STAGE = __ENV.STAGE || 'stage';

export const options = {
  scenarios: {
    orders: {
      executor: 'shared-iterations',
      vus: CONCURRENCY,
      iterations: TARGET_COUNT,
      maxDuration: __ENV.MAX_DURATION || '10m',
    },
  },
  thresholds: {
    // Don't fail the run on threshold breach -- the point of this test IS to find where it
    // breaks. Recorded, not enforced.
    http_req_duration: ['max>=0'],
  },
};

export default function () {
  const idempotencyKey = `${STAGE}-${__VU}-${__ITER}-${Date.now()}`;
  const payload = JSON.stringify({
    userId: (__VU % 10) + 1,
    orderDetails: `k6 load test order ${idempotencyKey}`,
    paymentType: 'card',
    notificationChannels: ['email', 'sms'],
  });
  const res = http.post(`${BASE_URL}/orders`, payload, {
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    timeout: '30s',
  });
  check(res, {
    'started or already_started': (r) => r.status === 201 || r.status === 200,
  });
}
