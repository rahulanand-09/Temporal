# Temporal Capacity Plan

Built from the actual Zeebe production baseline (191-day metrics scrape, both brokers) — not the
generic illustrative numbers used earlier in this evaluation. Everything below traces back to that
data or a cited external source.

## 1. Real throughput baseline (STPS)

Anchored on the raw measured job-completion totals, not the 20-steps/workflow assumption used
earlier — that assumption understated the payments-broker side once workflows with 50+ steps are
accounted for. Broker 1: 9.25M ÷ 191 days = 48,430/day. Payments broker: 7,074,064 ÷ 191 days =
37,037/day (an exact count in the source data). **Combined: 85,467 job completions/day ≈ 0.99
steps/sec — the committed current-scale figure, not a range.** This is *average*, not peak — the
payments broker's backpressure collapse (limit dropped from 256 to 11, 273M dropped requests) tells
us peak load is materially higher; that peak figure isn't in the source data and still needs pulling
from real time-series metrics, not cumulative totals.

| Scenario | STPS (average) | Steps/day | Est. Temporal Actions/mo (steps × 1.15–1.3 buffer) |
|---|---|---|---|
| Current scale | 0.99 (~1) | 85,467 | ~2.95M–3.33M |
| 10× current scale | 9.9 (~10) | 854,670 | ~29.5M–33.3M |

## 2. Out-of-the-box capacity check

Compared against real, cited benchmarks — not vendor marketing — both current scale and 10× current
scale sit far inside what a small, *untuned* Temporal deployment already handles.

| Benchmark | Hardware | Throughput achieved | Headroom vs. 10× load (~10 STPS) |
|---|---|---|---|
| Temporal's own scaling blog — untuned starting point | 4-core / 32GB MySQL | 150 state-transitions/sec | ~15× |
| Temporal's own scaling blog — tuned | same, shard/DB-tuned | 1,350 state-transitions/sec | ~135× |
| Independent benchmark, tuned further | Postgres, 512→2,048 shards | 4,500 state-transitions/sec | ~450× |
| Community-reported small deployment | Single 4 vCPU/16GB box, all 4 services combined | up to ~100 workflow executions/sec | far beyond current need |

> **The headline finding.** Even at 10× current scale, real load sits 15×–450× below throughput
> figures Temporal has already demonstrated on hardware smaller than what's currently running for
> Zeebe. Sizing this deployment is not a scaling problem — it's a reliability/HA problem, which is
> exactly the framing the 2-replica plan below already reflects.

Sources: [temporal.io — Scaling Temporal: the basics](https://temporal.io/blog/scaling-temporal-the-basics);
independent Postgres-tuned benchmark (piotrmucha.blog, 2025); community-reported small-deployment
figure (third-party guide, not an official Temporal number — treat as directional, not guaranteed).

## 3. Proposed infrastructure — 2 replicas, unified, no per-workload split

Two nodes, purely for **eliminating the single point of failure** the current payments broker
represents — not for extra capacity, given §2. Both nodes run the same, full set of Temporal server
components (Frontend/History/Matching/Worker), each service's `replicaCount` set to span both nodes.
No dedicated node for payments, LOS, or POS — see §4 for why that's architecturally sound here, unlike
the current Zeebe topology.

### Exact replica count, per service

| Service | replicaCount | Why |
|---|---|---|
| **Frontend** | **2** | Client-facing gRPC entry point — survives a node loss; trivial connection load at ~1 STPS |
| **History** | **2** | The stateful one — owns shards, persists event history. 2 is the practical minimum so a node failure doesn't strand shard ownership until failover completes. Gets the larger memory allocation of the four per pod, not more replicas, at this scale |
| **Matching** | **2** | Task-queue matching — negligible load here; replicated purely for HA |
| **Worker** | **2** | Runs internal system workflows (archival, etc.) — same HA logic |

Every service gets `replicaCount: 2` — uniformly, not weighted toward any one service. At ~1 STPS
against a documented 150–4,500 state-transitions/sec range on comparable or smaller hardware, no
service here is remotely close to its own individual ceiling, so there's no throughput argument for
giving one service more replicas than another. That's 8 pods total (4 services × 2 replicas) landing
on the 2 physical nodes below — each node runs one pod of each service.

### Which hardware hosts them

| | c5.2xlarge | t3a.large |
|---|---|---|
| Specs | 8 vCPU / 16 GB — fixed, non-burstable | 2 vCPU / 8 GB — burstable (CPU credits) |
| Est. cost, ap-south-1 (c5.2xlarge reuses your own quoted rate; t3a.large extrapolated from your t3a.xlarge quote — verify both) | ~$297/mo each → ~$594/mo for 2 | ~$68/mo each (est.) → ~$136/mo for 2 |
| Real-load fit | Per-service load-testing configs in Temporal's own benchmarks allocate ~2 vCPU/service — 4 services × 2 vCPU = 8 vCPU maps almost exactly onto one c5.2xlarge, with the second node purely for HA | 2 total vCPUs is tight for 4 services with headroom, even though real load is light — burst capacity depends on unspent CPU credits |
| Relevant risk given history | None specific — fixed performance regardless of burst | **CPU-credit exhaustion under a real traffic spike** — structurally the same failure shape as the backpressure collapse being migrated away from, just at the instance level instead of the broker level |

> **Recommendation: c5.2xlarge**, despite the higher cost, specifically because the current incident
> is a burst-capacity failure. Putting the payments-adjacent workload back on burstable,
> CPU-credit-limited hardware re-introduces the same failure shape being left behind, just relocated.
> If cost pressure is real, t3a.large is workable given how light the actual load is — but that
> trade-off should be a deliberate choice, not a default.

## 4. Why "no per-workload split" is safe here

The current Zeebe topology dedicates an entire broker to payments — and that's the one that
collapsed. Temporal doesn't need the equivalent split, because workload separation in Temporal
happens at the **Task Queue** level, not the server level:

- **Server stays unified.** Frontend/History/Matching/Worker serve every workflow type — payments,
  LOS, POS — through the same shared infrastructure, spread across both replica nodes.
- **Logical separation is still available if wanted.** Each business line can run its own worker
  fleet polling its own Task Queue (e.g. `payments-tq`, `los-tq`) — so a runaway payments workload
  can't starve LOS workers, without needing a dedicated *server* per line.
- **This directly targets the root-cause gap.** The payments broker's problem wasn't "too much
  payments traffic" in absolute terms (§2 shows the whole org's real load is tiny) — it was a single,
  unreplicated broker with no failover. Two unified, replicated nodes fix the actual failure mode
  instead of just relocating it to a new dedicated box.

## 5. Full cost comparison

| Option | Current scale | 10× scale | Notes |
|---|---|---|---|
| Current Zeebe (as-is) | ~$786–921/mo | — | List price, not yet AWS-verified; excludes the incident-handling cost of the payments backpressure collapse |
| Self-hosted Temporal, 2× c5.2xlarge | ~$917–1,067/mo | same infra — headroom absorbs 10× per §2 | 2×$297 compute + ~$73 EKS control plane + ~$250–400 RDS Postgres (Multi-AZ) — **no cheaper than current Zeebe**, but fixes the SPOF |
| Self-hosted Temporal, 2× t3a.large | ~$459–609/mo | same infra — headroom absorbs 10× per §2 | Cheaper than current Zeebe, carries the burst-risk trade-off from §3 |
| **Temporal Cloud** | **~$198–217/mo** | ~$1,258–1,391/mo | Cheapest option at current scale by a wide margin — but note the 10× figure below |

> **The honest catch at 10× scale.** Temporal Cloud's pay-as-you-go pricing stops being the automatic
> cheapest option once you're near 10× current volume — at ~$1,258–1,391/mo it lands at or above what
> self-hosted Temporal (either instance option) or even current Zeebe already costs. This is the one
> place where "just use Cloud" needs revisiting: if 10× growth is a realistic near-term trajectory
> rather than a stress-test hypothetical, get a real Enterprise quote from Temporal at that volume —
> negotiated Enterprise pricing very likely beats the published Essentials-tier overage math used
> here, but that's not a number this analysis can produce without Temporal's own sales team.

## 6. What's still needed before this is final

- **Real peak STPS**, not just the average — pull a time-series view (Prometheus/CloudWatch) around
  the payments broker's known backpressure windows.
- **AWS Pricing Calculator verification** for both instance options in `ap-south-1`, the EKS
  control-plane fee, and RDS Postgres sizing — every dollar figure above is still list-price/extrapolated.
- **A real Temporal Actions estimate from Temporal's sales/SE team**, using this throughput data
  directly — replaces the job-completion-based approximation used throughout §1.
- **A 10×-scale Enterprise quote from Temporal**, given §5's finding that published Essentials
  pricing loses its advantage at that volume.
- **Confirm `ap-south-1` availability** as an actual Temporal Cloud namespace region before
  committing to either path.

---

**Bottom line: 2× c5.2xlarge, unified, no workload split** — sized for reliability, not capacity.
Temporal Cloud stays the cheaper near-term path, but get a real Enterprise quote before assuming it
stays cheapest at 10× growth.

*Built from the real Zeebe production metrics baseline shared 2026-09-01. Companion to the
"Conductor vs. Temporal vs. Zeebe" and "Durable Execution Scorecard" artifacts published earlier in
this evaluation.*
