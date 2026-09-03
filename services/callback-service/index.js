import express from 'express';
import { Connection, Client, WorkflowExecutionAlreadyStartedError } from '@temporalio/client';

const PORT = process.env.PORT || 4000;
const TEMPORAL_ADDRESS = process.env.TEMPORAL_ADDRESS || 'localhost:7233';
const AUTH_DELAY_MS = Number(process.env.AUTH_DELAY_MS || 4000);
const ORDER_TASK_QUEUE = process.env.ORDER_TASK_QUEUE || 'order-fulfillment-queue';

const app = express();
app.use(express.json());

let client;

// The production-shaped entry point: start an OrderFulfillmentWorkflow over HTTP, keyed by a
// caller-supplied idempotency key instead of a caller-supplied workflow ID. Two requests with
// the same key are the same logical order -- a retried request (client timeout, load-generator
// retry, etc.) must never create a second workflow execution. Temporal's own workflow ID is the
// idempotency mechanism: the key becomes the workflow ID, and `REJECT_DUPLICATE` makes a second
// start with that ID a no-op that returns the original execution instead of erroring or
// double-starting. This replaces starting workflows via ad hoc `temporal workflow start` CLI
// calls from a script -- a load generator (or any real caller) hits this endpoint directly.
app.post('/orders', async (req, res) => {
  const idempotencyKey = req.get('Idempotency-Key') || req.body.idempotencyKey;
  if (!idempotencyKey) {
    return res.status(400).json({ error: 'Idempotency-Key header (or body.idempotencyKey) is required' });
  }
  const { userId, orderDetails, paymentType, notificationChannels, orderNotes, region } = req.body;
  const workflowId = `order-${idempotencyKey}`;

  // Optional: tag the execution with custom search attributes at start time, so it's findable
  // via the search endpoint below. orderNotes -> OrderNotes (Text, tsvector+GIN); region ->
  // OrderRegion (Keyword, jsonb_path_ops GIN). Both registered via `temporal operator
  // search-attribute create` before this endpoint is useful -- not auto-registered here.
  const searchAttributes = {};
  if (orderNotes) searchAttributes.OrderNotes = [orderNotes];
  if (region) searchAttributes.OrderRegion = [region];

  try {
    const handle = await client.workflow.start('OrderFulfillmentWorkflow', {
      taskQueue: ORDER_TASK_QUEUE,
      workflowId,
      workflowIdReusePolicy: 'REJECT_DUPLICATE',
      args: [{ userId, orderDetails, paymentType, notificationChannels }],
      ...(Object.keys(searchAttributes).length ? { searchAttributes } : {}),
    });
    return res.status(201).json({
      status: 'started',
      workflowId: handle.workflowId,
      runId: handle.firstExecutionRunId,
      idempotencyKey,
    });
  } catch (err) {
    if (err instanceof WorkflowExecutionAlreadyStartedError) {
      // Same idempotency key seen before -- not an error, this *is* the idempotent behavior.
      console.log(`[orders] idempotent replay for key=${idempotencyKey}, workflowId=${workflowId} already started`);
      return res.status(200).json({ status: 'already_started', workflowId, idempotencyKey });
    }
    console.error(`[orders] failed to start workflow for key=${idempotencyKey}`, err.message);
    return res.status(500).json({ status: 'error', error: err.message });
  }
});

// Exercises the visibility store's search path directly (Temporal's CountWorkflowExecutions,
// which maps to a COUNT query against executions_visibility using whichever index the query
// planner picks) -- how the GIN-index load test measures search performance, as opposed to the
// order-starting path above. `query` is a raw Temporal visibility query string, e.g.
// `OrderRegion = "APAC"` (exact match, jsonb_path_ops GIN) or `OrderNotes = "customs"`
// (full-text match, tsvector GIN).
app.get('/search', async (req, res) => {
  const { query } = req.query;
  if (!query) {
    return res.status(400).json({ error: 'query string param is required' });
  }
  const startedAt = process.hrtime.bigint();
  try {
    const result = await client.workflow.count(String(query));
    const elapsedMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
    return res.json({ query, count: Number(result.count), elapsedMs });
  } catch (err) {
    const elapsedMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
    console.error(`[search] query failed: ${query}`, err.message);
    return res.status(500).json({ query, error: err.message, elapsedMs });
  }
});

// Stand-in for a third-party payment processor. Acknowledges immediately,
// then "settles" asynchronously and delivers a real Temporal *signal* to
// resume the paused workflow -- this is the POC's callback block, built on
// Temporal's native signal mechanism instead of a REST "complete task" call.
app.post('/authorize', (req, res) => {
  const { workflowId, orderId, paymentMethod } = req.body;
  console.log(
    `[authorize] workflowId=${workflowId} orderId=${orderId} method=${paymentMethod} -- accepted, confirming in ${AUTH_DELAY_MS}ms`
  );
  res.status(202).json({ accepted: true });

  setTimeout(async () => {
    try {
      const handle = client.workflow.getHandle(workflowId);
      await handle.signal('confirm_payment', {
        paymentStatus: 'AUTHORIZED',
        paymentMethod,
        authorizedAt: new Date().toISOString(),
      });
      console.log(`[authorize] signaled workflow ${workflowId} -> 'confirm_payment' delivered`);
    } catch (err) {
      console.error(`[authorize] failed to signal workflow ${workflowId}`, err.message);
    }
  }, AUTH_DELAY_MS);
});

// Manual override for demoing the pause/resume boundary by hand -- delivers
// the confirm_payment signal immediately, with no timer. The direct analog
// of curling Conductor's `POST /tasks/{id}/signal` to complete a WAIT task.
app.post('/confirm', async (req, res) => {
  const { workflowId, paymentMethod } = req.body;
  try {
    const handle = client.workflow.getHandle(workflowId);
    await handle.signal('confirm_payment', {
      paymentStatus: 'AUTHORIZED',
      paymentMethod: paymentMethod || 'manual',
      authorizedAt: new Date().toISOString(),
    });
    console.log(`[confirm] signaled workflow ${workflowId} -> 'confirm_payment' delivered manually`);
    res.json({ signaled: true, workflowId });
  } catch (err) {
    console.error(`[confirm] failed to signal workflow ${workflowId}`, err.message);
    res.status(500).json({ signaled: false, error: err.message });
  }
});

// Stand-in notification channel used by the workflow's dynamic fan-out.
app.post('/notify', (req, res) => {
  console.log('[notify]', req.body);
  res.json({ delivered: true, channel: req.body.channel });
});

// Stand-ins for jsonplaceholder.typicode.com, which the real activities (get_user,
// create_order, finalize_order) call by default. At load-test volume that's real traffic
// against a shared free public API that isn't built to take it, so worker-service is pointed
// at this in-cluster substitute instead (JSONPLACEHOLDER_BASE_URL env var) -- everything the
// load test does stays inside the cluster network. Shapes only what the workflow actually
// reads off the response (user.name, order.id); nothing else about jsonplaceholder is modeled.
let nextPostId = 101; // jsonplaceholder's own fake-create convention starts new posts at 101
app.get('/users/:id', (req, res) => {
  const id = Number(req.params.id);
  res.json({ id, name: `Load Test User ${id}`, email: `user${id}@load-test.local` });
});
app.post('/posts', (req, res) => {
  const { title, body, userId } = req.body;
  res.status(201).json({ id: nextPostId++, title, body, userId });
});
app.patch('/posts/:id', (req, res) => {
  res.json({ id: Number(req.params.id), ...req.body });
});

async function main() {
  const connection = await Connection.connect({ address: TEMPORAL_ADDRESS });
  client = new Client({ connection, namespace: 'default' });
  app.listen(PORT, () => {
    console.log(`callback-service listening on http://localhost:${PORT} (Temporal @ ${TEMPORAL_ADDRESS})`);
  });
}

main();
