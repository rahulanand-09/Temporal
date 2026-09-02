# Temporal on Kubernetes + Helm

Fallback plan only — the org is on Temporal Cloud (see `CLAUDE.md`). Use this if
compliance/data-residency ever forces self-hosting. Every port and default below is quoted
from the actual chart/repo source, not memory — see the Sources table at the bottom for the
exact line each claim comes from.

## Prerequisites

- Kubernetes cluster + `kubectl`, `helm` v3
- A managed PostgreSQL instance 
- Elasticsearch/OpenSearch
- Internal DNS/LB for the Frontend gRPC endpoint, TLS certs

## Steps

1. **Add the chart**
   ```bash
   helm repo add temporal https://go.temporal.io/helm-charts
   helm repo update
   ```
   [`temporalio/helm-charts`](https://github.com/temporalio/helm-charts) — chart version `1.6.0`, app version `1.31.2` ([`Chart.yaml`](https://github.com/temporalio/helm-charts/blob/main/charts/temporal/Chart.yaml)). No bundled Cassandra/ES/Prometheus/Grafana sub-charts in this version — nothing to disable if you're not using them.

2. **Create the namespace**
   ```bash
   kubectl create namespace temporal-system
   ```

3. **Decide the history shard count now — it cannot change later.**
   The chart's own default is `512`, with this comment directly above it:
   > "Important: numHistoryShards cannot be changed after the initial deployment."

   [values.yaml#L184-L185](https://github.com/temporalio/helm-charts/blob/main/charts/temporal/values.yaml#L184-L185)

4. **Point persistence at your Postgres, set replica counts** in `values.yaml` — `persistence.default.sql`, `persistence.visibility` (only if using Elasticsearch), `frontend/history/matching/worker.replicaCount`.

5. **Set up the schema — before the first server start.** Temporal does not auto-create it; skipping this is the #1 first-run failure. With this chart it normally happens for you: `helm install` runs a `pre-install` hook Job (`schema.useHelmHooks`, default `true`) that does this automatically. The manual equivalent, e.g. for the Docker Compose path:
   ```bash
   temporal-sql-tool --plugin postgres12 --ep <host> -p 5432 -u temporal create-database -db temporal
   temporal-sql-tool --plugin postgres12 --ep <host> -p 5432 -u temporal --db temporal setup-schema -v 0.0
   temporal-sql-tool --plugin postgres12 --ep <host> -p 5432 -u temporal --db temporal \
     update-schema -d schema/postgresql/v12/temporal/versioned
   ```
   Schema files: [`temporalio/temporal/schema/postgresql/v12`](https://github.com/temporalio/temporal/tree/main/schema/postgresql/v12). Compose equivalent for a non-k8s test run: [`docker-compose-postgres.yml`](https://github.com/temporalio/docker-compose/blob/main/docker-compose-postgres.yml).

6. **Install**
   ```bash
   helm install temporal temporal/temporal --namespace temporal-system -f values.yaml
   ```

7. **Expose Frontend internally** on a stable DNS name (e.g. `temporal.internal.company.com:7233`) via ClusterIP + internal LB — this is the only endpoint teams' workers talk to.

8. **Verify**
   ```bash
   temporal --address temporal.internal.company.com:7233 operator cluster health   # -> SERVING
   temporal operator namespace create --namespace team-a --retention 30d
   ```

9. **Put the Web UI behind SSO** (OAuth2 proxy) — it has no built-in login — and turn on mTLS per namespace before onboarding a second team.

## Ports — quoted from the chart, not memory

| Service | gRPC port | Membership port | Source |
|---|---|---|---|
| Frontend | `7233` (HTTP API `7243`) | `6933` | [values.yaml#L313-L321](https://github.com/temporalio/helm-charts/blob/main/charts/temporal/values.yaml#L313-L321) |
| Internal-frontend *(optional, disabled by default)* | `7236` (HTTP API `7246`) | `6936` | [values.yaml#L377-L385](https://github.com/temporalio/helm-charts/blob/main/charts/temporal/values.yaml#L377-L385) |
| History | `7234` | `6934` | [values.yaml#L421-L425](https://github.com/temporalio/helm-charts/blob/main/charts/temporal/values.yaml#L421-L425) |
| Matching | `7235` | `6935` | [values.yaml#L455-L459](https://github.com/temporalio/helm-charts/blob/main/charts/temporal/values.yaml#L455-L459) |
| Internal Worker | `7239` | `6939` | [values.yaml#L489-L493](https://github.com/temporalio/helm-charts/blob/main/charts/temporal/values.yaml#L489-L493) |
| Web UI | HTTP `8080` | — | [values.yaml#L579](https://github.com/temporalio/helm-charts/blob/main/charts/temporal/values.yaml#L579) |
| Metrics (every server pod) | `9090` | — | [values.yaml#L293](https://github.com/temporalio/helm-charts/blob/main/charts/temporal/values.yaml#L293) — `listenAddress: "0.0.0.0:9090"` |
| PostgreSQL | `5432` | — | Postgres default, not chart-specific |
| Elasticsearch/OpenSearch | `9200` | — | example in [values.yaml#L253-L257](https://github.com/temporalio/helm-charts/blob/main/charts/temporal/values.yaml#L253-L257) |

## Network diagram

```
   Team workers (mTLS) ──gRPC:7233──┐
   Web UI (behind SSO) ──gRPC:7233──┼──► Frontend :7233 (membership :6933, metrics :9090)
   temporal CLI ─────────gRPC:7233──┘         │
                                               ├──gRPC:7234──► History  :7234 (membership :6934, metrics :9090) ──► Postgres :5432
                                               └──gRPC:7235──► Matching :7235 (membership :6935, metrics :9090) ──► Postgres :5432

   History also queries ──► Elasticsearch/OpenSearch :9200   (only if visibility store = ES, not SQL)
   Internal Worker :7239 (membership :6939, metrics :9090) — system workflows only, not exposed to teams
   Prometheus scrapes :9090 on every pod above ──► Grafana
```

Only Frontend `:7233` (and Web UI `:8080`, behind SSO) should ever be reachable from outside
the cluster's own network segment. History, Matching, Internal Worker stay internal-only.

## Sources

- [`temporalio/helm-charts`](https://github.com/temporalio/helm-charts) — chart repo, `helm repo add` target
- [`values.yaml`](https://github.com/temporalio/helm-charts/blob/main/charts/temporal/values.yaml) — every port/default cited above
- [`temporalio/temporal` schema](https://github.com/temporalio/temporal/tree/main/schema/postgresql/v12) — `temporal-sql-tool` schema path
- [`temporalio/docker-compose`](https://github.com/temporalio/docker-compose) — non-k8s reference compose files
- [docs.temporal.io/references/configuration](https://docs.temporal.io/references/configuration) — full server config reference, for anything not covered above
