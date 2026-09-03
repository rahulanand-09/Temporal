# Local Kubernetes + Helm Temporal cluster, with Postgres doing Elasticsearch's job

Hands-on run, not a template. Every claim below was verified live against the actual cluster on
2026-09-03 — commands, output, and the exact source lines that justified each config choice are
included so this doesn't need re-deriving later. Companion to `KUBERNETES_HELM_DEPLOYMENT.md`
(the generic self-hosted fallback playbook) — this doc is the specific "2 replicas of everything
+ Postgres full-text search instead of Elasticsearch" build, run on `kind` on a laptop.

## The ask

> host a kube cluster in local, host temporal using helm — 2 instances of frontend, matching,
> history, worker — a postgres instance, with full text search extension enabled, to serve the
> purpose of elastic search

## Result

Live, verified, all 3 layers proven end-to-end:

1. **Cluster topology** — `kubectl get pods -n temporal-system` shows 2 pods each for
   frontend/history/matching/worker (8 server pods), 1 web, 1 admintools, 1 schema Job
   (`Completed`), 1 Postgres. `temporal operator cluster describe` reports
   `PersistenceStore: postgres12`, `VisibilityStore: postgres12` — no Elasticsearch anywhere.
2. **Full-text search schema, confirmed by direct SQL inspection** — `btree_gin` extension
   installed, `Text01`/`Text02`/`Text03` columns are generated `TSVECTOR` columns, GIN indexes
   (`by_text_01`, etc.) exist on `executions_visibility` in `temporal_visibility`.
3. **Full-text search actually working, not just present** — registered a custom `Text`-type
   search attribute (`OrderNotes`), ran two workflows tagging each with different free text,
   queried `OrderNotes = 'customs'` and got back only the workflow whose text contained "customs
   warehouse"; queried `'delivery'` and got back only the other one. Real word-level search,
   Postgres doing what would otherwise need Elasticsearch.

## Decisions, in the order they were made — and why

### 1. Verify the core technical claim before building anything

"Postgres with full-text search instead of Elasticsearch" is a specific, checkable claim, not a
given — the project's own `CLAUDE.md` says not to trust an SDK/API claim from memory. So before
touching `kind` or `helm`, the actual Temporal source was read:

- [`docs.temporal.io/self-hosted-guide/visibility/postgresql`](https://docs.temporal.io/self-hosted-guide/visibility/postgresql) —
  Advanced Visibility (custom search attributes, real queries — the modern replacement for the
  old ES-only "advanced" vs. SQL-only "standard" split) has worked on Postgres 12+ since
  **Temporal Server v1.20**. Standard Visibility was deprecated in v1.21 and removed in v1.24.
  This chart deploys server `1.31.2` — well past that line.
- [`temporalio/temporal` schema, `schema/postgresql/v12/visibility/versioned/v1.2/advanced_visibility.sql`](https://github.com/temporalio/temporal/blob/main/schema/postgresql/v12/visibility/versioned/v1.2/advanced_visibility.sql) —
  read the actual migration. It does exactly three things relevant here: `CREATE EXTENSION
  btree_gin` if not already present, adds a `search_attributes JSONB` column plus ~30
  generated columns derived from it (`Keyword01..10`, `Int01..03`, `Text01..03 TSVECTOR
  GENERATED ALWAYS AS (...)`, etc.), then creates GIN indexes on the JSONB/tsvector ones. This
  *is* the "full text search extension enabled" the ask described — it's not manual, it's not
  optional configuration, it's what the schema migration does unconditionally for any
  `postgres12`-backed visibility store.
- [`temporalio/helm-charts`, `templates/server-job.yaml`](https://github.com/temporalio/helm-charts/blob/main/charts/temporal/templates/server-job.yaml) —
  confirmed the chart's schema `Job` (a Helm `pre-install` hook by default,
  `schema.useHelmHooks: true`) runs `temporal-sql-tool setup-schema -v 0.0 && temporal-sql-tool
  update-schema --schema-dir .../visibility/versioned` automatically when
  `sql.manageSchema: true` is set on the visibility datastore — i.e. the migration above applies
  itself on `helm install`, nothing to run by hand.

Decision: use Postgres as *both* the default store and the visibility store (`sql:` block in
both `persistence.datastores.default` and `.visibility`, same `pluginName: postgres12`). No
Elasticsearch, OpenSearch, or Cassandra sub-chart anywhere. Confirmed this is exactly what shipped
— see "Result" §2 above.

### 2. Local cluster tool: `kind`, not minikube or Docker Desktop's built-in Kubernetes

Neither was installed (checked `docker`, `kubectl`, `helm`, `kind`, `minikube`, `k3d` up front —
only Docker and the `kubectl` client existed). `kind` was the better fit specifically for a
Helm-chart-testing workload: it's just containers-as-nodes on the same Docker daemon already
running, has near-zero startup overhead compared to minikube's VM, and is the tool most
Kubernetes chart authors (including Temporal's own CI) actually test against. A single
control-plane node is enough — `kind` nodes are already containers on one Docker host, so a
multi-node kind "cluster" would add scheduling noise, not real distribution, for an 11-pod
workload. Installed via `brew install kind helm` (`kind` v0.33.0, `helm` v4.2.4).

### 3. One Postgres instance, two databases — not two instances

The ask said "a postgres instance" (singular). Temporal's default and visibility stores can be
different databases on the same server — there's no requirement they're separate instances — so
one `bitnami/postgresql` release backs both `temporal` (default/execution store) and
`temporal_visibility` (visibility store). The chart didn't pre-create the second database;
Temporal's own schema Job did (`sql.createDatabase: true` on the visibility datastore, which the
chart wires to a `temporal-sql-tool create-database` init container — read directly from
`server-job.yaml`, not assumed).

`bitnami/postgresql` (chart `18.8.15`, app `18.6.0`) over a hand-rolled `StatefulSet`: it gives
PVC-backed persistence, a managed `Secret`, and sane defaults for free, and it's the same chart
family already referenced as the placeholder in the existing `KUBERNETES_HELM_DEPLOYMENT.md`.
`architecture: standalone` (no read replicas) — this is a POC datastore, not an HA target.

### 4. Auth: connect as the `postgres` superuser — a deliberate, called-out simplification

Temporal's schema Job needs `CREATE DATABASE` (for `temporal_visibility`) and `CREATE EXTENSION
btree_gin`. `btree_gin` has been a "trusted" extension installable by a database owner without
superuser since Postgres 13, but wiring a scoped role with exactly `CREATEDB` + trusted-extension
rights ahead of time is extra setup that buys nothing for a throwaway local POC. Connected
Temporal's persistence config directly as `postgres` instead. **Not** what a real deployment
should do — a real one gets a least-privilege role pre-provisioned with exactly the grants it
needs. Flagged here so it isn't silently copied into a real config later.

Credentials: one `kubectl create secret generic postgres-credentials --from-literal=postgres-password=<openssl rand -base64 24>`
in `temporal-system`, referenced by both charts —
`bitnami/postgresql`'s `auth.existingSecret` / `auth.secretKeys.adminPasswordKey` and each
Temporal SQL datastore's `existingSecret` / `secretKey` — both pointed at the same
`postgres-password` key, so only one secret exists instead of two.

### 5. Replica counts: one values key, not four

Read `_helpers.tpl` in the chart source directly rather than guessing the key path:

```
{{- if $serviceValues.replicaCount }}
replicas: {{ $serviceValues.replicaCount }}
{{- else if $.Values.server.replicaCount }}
replicas: {{ $.Values.server.replicaCount }}
```

`server.<service>.replicaCount` overrides per-service; absent that, it falls back to the global
`server.replicaCount`. Frontend/history/matching/worker share one `server-deployment.yaml`
template (looped over those four service names — confirmed by reading it); `web` and
`admintools` are separate templates untouched by this key. So a single
`server.replicaCount: 2` in values gives exactly "2 instances of frontend, matching, history,
worker" with nothing else touched — verified post-install: `web`/`admintools` stayed at 1,
the other four at 2 (see "Result" §1).

### 6. `numHistoryShards`, resources, namespace creation

- `numHistoryShards: 512` — left at the chart's own default. The chart's comment above this
  field is explicit: "cannot be changed after the initial deployment." For a POC this doesn't
  matter (shard *count* is a logical partitioning number, not a per-shard resource cost at
  idle), but it's the one setting in this whole file that would be expensive to get wrong on a
  cluster meant to last, so it's called out rather than silently accepted.
- No `resources:` block set anywhere. The chart's own top-level comment recommends leaving
  requests/limits unset on resource-constrained environments (its own example: Minikube) so pods
  aren't held `Pending` waiting for requests a laptop-sized node can't satisfy. Right call for a
  POC; a real deployment would set these per service.
- `server.config.namespaces.create: true` with a `default` namespace, 3-day retention — so
  there's something to run a workflow against immediately after `helm install`, no extra
  `temporal operator namespace create` step needed.

## Steps actually run, with the real output

### Toolchain

```
brew install kind helm
# kind v0.33.0, helm v4.2.4 — kubectl client (v1.36.1) and docker (29.7.2) already present
```

### Cluster

`k8s-local/kind-config.yaml` — single control-plane node, no `extraPortMappings` (exposure is via
`kubectl port-forward`, not NodePort — no fixed ports to pre-plan):

```
kind create cluster --config k8s-local/kind-config.yaml
kubectl create namespace temporal-system
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add temporal https://go.temporal.io/helm-charts
```

### Postgres

```
kubectl create secret generic postgres-credentials -n temporal-system \
  --from-literal=postgres-password="$(openssl rand -base64 24)"
helm install postgres bitnami/postgresql --version 18.8.15 -n temporal-system \
  -f k8s-local/postgres-values.yaml
```

`k8s-local/postgres-values.yaml` — `auth.enablePostgresUser: true`, `auth.existingSecret:
postgres-credentials`, `auth.secretKeys.adminPasswordKey: postgres-password`,
`architecture: standalone`, 2Gi PVC.

Result: `postgres-postgresql-0` `1/1 Running` in ~30s, PVC `Bound`.

### Temporal

`k8s-local/temporal-values.yaml` — `server.replicaCount: 2`; `persistence.datastores.default`
and `.visibility` both `sql:` blocks against `postgres-postgresql.temporal-system.svc.cluster.local:5432`,
`pluginName: postgres12`, `databaseName: temporal` / `temporal_visibility`,
`createDatabase: true`, `manageSchema: true`, `user: postgres`, same `existingSecret`.

Sanity-checked before the real install, not after:

```
helm install temporal temporal/temporal --version 1.6.0 -n temporal-system \
  -f k8s-local/temporal-values.yaml --dry-run
helm template temporal temporal/temporal --version 1.6.0 -n temporal-system \
  -f k8s-local/temporal-values.yaml > /tmp/temporal-rendered.yaml
grep "replicas:" /tmp/temporal-rendered.yaml   # confirmed 2/2/2/2, 1 (web), 1 (admintools)
grep -A1 "manage-schema-visibility-store" /tmp/temporal-rendered.yaml
  # -> temporal-sql-tool setup-schema -v 0.0 && temporal-sql-tool update-schema
  #    --schema-dir /etc/temporal/schema/postgresql/v12/visibility/versioned
  # confirms the advanced_visibility.sql migration is on this exact path
```

Then the real install:

```
helm install temporal temporal/temporal --version 1.6.0 -n temporal-system \
  -f k8s-local/temporal-values.yaml
```

`STATUS: deployed` — meaning the `pre-install` schema Job (creates both databases, runs both
migration chains including `advanced_visibility.sql`) already succeeded by the time this
returned; Helm blocks on hook completion.

One transient, self-resolving hiccup: the post-install `temporal-namespace-*` Job hit
`Init:Error` on its first attempt (it raced Frontend's own startup — tried to create the
`default` namespace before Frontend was ready to accept the request). Job's `backoffLimit: 100`
retried it automatically; it reported `Complete` ~13s later once Frontend was `Ready`. No manual
intervention. `kubectl wait --for=condition=Ready pod --all -n temporal-system` then confirmed
every long-running pod healthy — the "timed out" lines it also printed are expected: they're for
the already-`Completed` namespace Job pod, which never reports the `Ready` condition by design.

### Verifying it's real, not just "Running"

**Cluster health and topology:**

```
kubectl exec -n temporal-system deploy/temporal-admintools -- temporal operator cluster health
# -> SERVING
kubectl exec -n temporal-system deploy/temporal-admintools -- temporal operator cluster describe
# -> PersistenceStore: postgres12   VisibilityStore: postgres12
```

**Full-text-search schema landed, by direct SQL — not by trusting the Job exited 0:**

```
psql -U postgres -d temporal_visibility -c "\dx"
#  btree_gin | 1.3 | ... | support for indexing common datatypes in GIN
psql -U postgres -d temporal_visibility -c "\d executions_visibility" | grep tsvector
#  text01 | tsvector | generated always as ((search_attributes ->> 'Text01')::tsvector) stored
#  text02 | tsvector | ...
#  text03 | tsvector | ...
psql -U postgres -d temporal_visibility -c \
  "select indexname from pg_indexes where tablename='executions_visibility' and indexdef ilike '%gin%'"
#  by_text_01, by_text_02, by_text_03, plus GIN indexes on every JSONB search attribute column
```

**A real workflow, through all 8 server pods:**

Used the project's existing `smoketest/hello_workflow.py` / `hello_worker.py` (already the
project's cross-environment smoke test — only env vars change between local dev server,
self-hosted, and Cloud). One real gotcha hit and resolved along the way: a leftover `temporal
server start-dev` process from earlier work in this project was still listening on
`127.0.0.1:7233` (per `CLAUDE.md`'s own warning that this may or may not still be running).
`kubectl port-forward ... 7233:7233` silently bound only the IPv6 `[::1]:7233` since IPv4 was
taken, so `localhost:7233` was resolving to *either* server depending on the call — explaining
both an initial `workflow not found` error and a stray 22-hours-old `OrderFulfillmentWorkflow`
appearing in `workflow list` (that workflow belonged to the old dev server's SQLite state, not
this cluster). Fixed by port-forwarding to distinct local ports instead of touching either
server:

```
kubectl port-forward -n temporal-system svc/temporal-frontend 17233:7233 --address 127.0.0.1 &
kubectl port-forward -n temporal-system svc/temporal-web 18080:8080 --address 127.0.0.1 &
TEMPORAL_ADDRESS=127.0.0.1:17233 .venv/bin/python -u smoketest/hello_worker.py &
temporal workflow execute --address 127.0.0.1:17233 --namespace default \
  --task-queue smoke-test-queue --type HelloWorkflow --workflow-id smoke-test-kind-final \
  --input '"World, from a local 2x-replica kind+Helm+Postgres-advanced-visibility cluster"'
```

Result: `Status COMPLETED`, `RunTime 60ms`, full event history
(`WorkflowExecutionStarted → ... → ActivityTaskCompleted → ... → WorkflowExecutionCompleted`).

**Full-text search, exercised end-to-end, not just present in the schema:**

```
temporal operator search-attribute create --address 127.0.0.1:17233 --namespace default \
  --name OrderNotes --type Text
# maps OrderNotes onto one of the pre-allocated Text01..03 tsvector columns

temporal workflow execute ... --workflow-id smoke-test-fts-1 \
  --search-attribute 'OrderNotes="expedited shipment delayed at customs warehouse"'
temporal workflow execute ... --workflow-id smoke-test-fts-2 \
  --search-attribute 'OrderNotes="standard delivery completed on time"'

temporal workflow list --address 127.0.0.1:17233 --namespace default --query "OrderNotes = 'customs'"
#  -> smoke-test-fts-1 only
temporal workflow list --address 127.0.0.1:17233 --namespace default --query "OrderNotes = 'delivery'"
#  -> smoke-test-fts-2 only
```

Real word-level matching against free text, on Postgres, with zero Elasticsearch involved.

## What's running right now

- `kind` cluster `temporal-local`, 1 control-plane node
- `temporal-system` namespace: `postgres` (bitnami/postgresql 18.8.15) + `temporal`
  (temporal/temporal 1.6.0 / server 1.31.2) Helm releases, both `STATUS: deployed`
- 8 Temporal server pods (2 each of frontend/history/matching/worker) + 1 web + 1 admintools,
  all `1/1 Running`
- Background on the host, started by this session: `kubectl port-forward` on `127.0.0.1:17233`
  (Frontend) and `127.0.0.1:18080` (Web UI), and the smoke-test worker
  (`smoketest/hello_worker.py`) polling `smoke-test-queue`. Kill with the PIDs printed when
  each was started, or just `pkill -f "port-forward -n temporal-system"` / `pkill -f
  hello_worker.py` — none of this is a systemd/launchd-managed service, it dies with the
  terminal/session unless re-forwarded.
- The pre-existing `temporal server start-dev` process on `127.0.0.1:7233` (`.temporal-dev.pid`
  in this directory) was left untouched — it's unrelated prior POC state, not part of this
  cluster.

## Tear-down

Not run — left live for further poking. When done:

```
helm uninstall temporal postgres -n temporal-system
kubectl delete namespace temporal-system
kind delete cluster --name temporal-local
```

## Files added

- `k8s-local/kind-config.yaml` — kind cluster definition
- `k8s-local/postgres-values.yaml` — bitnami/postgresql values
- `k8s-local/temporal-values.yaml` — temporal/temporal values

## Sources

- [`docs.temporal.io/self-hosted-guide/visibility/postgresql`](https://docs.temporal.io/self-hosted-guide/visibility/postgresql) —
  Advanced Visibility on Postgres 12+, Server v1.20+
- [`temporalio/temporal` — `schema/postgresql/v12/visibility/versioned/v1.2/advanced_visibility.sql`](https://github.com/temporalio/temporal/blob/main/schema/postgresql/v12/visibility/versioned/v1.2/advanced_visibility.sql) —
  the actual `btree_gin` + `TSVECTOR` + GIN-index migration, read verbatim via `gh api`
- [`temporalio/helm-charts` — `charts/temporal/templates/server-job.yaml`](https://github.com/temporalio/helm-charts/blob/main/charts/temporal/templates/server-job.yaml) —
  schema Job logic (`createDatabase`, `manageSchema`, the exact `temporal-sql-tool` invocation)
- [`temporalio/helm-charts` — `charts/temporal/templates/_helpers.tpl`](https://github.com/temporalio/helm-charts/blob/main/charts/temporal/templates/_helpers.tpl) —
  `replicaCount` resolution order
- [`temporalio/helm-charts` — `charts/temporal/values.yaml`](https://github.com/temporalio/helm-charts/blob/main/charts/temporal/values.yaml) — chart `1.6.0`, app `1.31.2`
- [`bitnami/postgresql` chart, version `18.8.15`](https://github.com/bitnami/charts/tree/main/bitnami/postgresql) — `auth.existingSecret` / `secretKeys` structure
