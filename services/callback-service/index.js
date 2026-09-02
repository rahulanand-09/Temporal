import express from 'express';
import { Connection, Client } from '@temporalio/client';

const PORT = process.env.PORT || 4000;
const TEMPORAL_ADDRESS = process.env.TEMPORAL_ADDRESS || 'localhost:7233';
const AUTH_DELAY_MS = Number(process.env.AUTH_DELAY_MS || 4000);

const app = express();
app.use(express.json());

let client;

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

async function main() {
  const connection = await Connection.connect({ address: TEMPORAL_ADDRESS });
  client = new Client({ connection, namespace: 'default' });
  app.listen(PORT, () => {
    console.log(`callback-service listening on http://localhost:${PORT} (Temporal @ ${TEMPORAL_ADDRESS})`);
  });
}

main();
