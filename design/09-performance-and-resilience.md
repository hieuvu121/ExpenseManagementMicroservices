# 9. Performance & resilience

## Measured baseline

Local docker-compose, M-series laptop, 11 CPUs, 8 GB to Docker. 75/25 read mix.
Full detail in [`perf/README.md`](../perf/README.md).

| Target RPS | Achieved | p95 | dropped | failed |
|---|---|---|---|---|
| 500 | 500.0 | 13.1 ms | 0 | 0% |
| 1000 | 999.9 | 9.0 ms | 0 | 0% |
| 1500 | 1496.4 | 159.0 ms | 207 | 0% |

**The knee is between 1000 and 1500 RPS**, and it degrades by getting slow, not
by failing — error rate stays 0% throughout, so latency percentiles are the
signal to watch, not status codes.

At 1500 the constraint is CPU contention between k6 and thirteen containers on
one machine, not MySQL, which sat under 1% CPU. A database optimisation cannot
raise a ceiling that is not database-bound.

## Admission control

`ConcurrencyLimitFilter` caps in-flight requests per gateway instance at 500 and
sheds the rest with 429. Without it, at 4000 RPS:

- heap 264 MiB → 1482 MiB, GC at 16% of wall time
- gateway p95 0.61s → 5.32s **while the services behind it moved only 0.13s →
  0.27s** — the latency was entirely gateway queueing
- ended in an OOM kill, with throughput *falling* from 2923 to 1814 req/s

It runs at order −1, before JWT verification, on the principle that **shedding
must be cheaper than serving** or it makes overload worse.

## Query shape

The expense list is the hot path and is built to stay O(page size):

- **Cursor pagination with `force index`.** The optimizer picked an index that
  looked cheap and then sorted; naming the index explicitly made the plan
  O(page) instead of O(household). At 10,000 expenses that is 10 rows scanned
  rather than 10,000. JPQL cannot express the hint, so those two queries are
  native.
- **`Object[]` rather than interface projections.** Spring Data backs a
  projection with a JDK proxy per row — 11 proxies and ~99 reflective calls per
  request on the service that is already CPU-bound.
- **Creator name resolved in the join**, not a second query per row.
- **`@Transactional(readOnly = true)`** on reads: p50 5.03ms → **1.73ms**, p95
  down 41% at 1000 RPS.

## Why the request path is one hop

Rendering an expense list touches expense-service and `expense_db` only. No
service calls another synchronously, because the data is already local
([note 1](01-service-boundaries-and-data.md)). There is no inter-service
round trip to optimise because there is no inter-service round trip.

## Resilience gaps

- **Nothing drains the DLT.** Every `@DltHandler` logs and stops. Since
  consumers are idempotent, a replay endpoint or scheduled drain would be safe
  and is roughly thirty lines.
- **Nothing alerts on DLT depth**, though Prometheus, Grafana and
  `kafka-exporter` are already scraping. Config, not code.
- **No reconciliation job** comparing approved expenses to settlement totals —
  the backstop that would catch whatever slips past the other two.
- **Single broker, single MySQL instance.** Both are single points of failure;
  the deployment trades that for cost.

## Observability

Prometheus scrapes each service's `/actuator/prometheus` on management port
9090, which compose never publishes — so actuator is reachable only from inside
the network. Targets are discovered through Eureka
(`eureka_sd_configs`); email-service and eureka-server are scraped statically
because neither registers. Server-side histogram buckets are enabled so Grafana
computes true p95/p99 rather than averaging pre-computed percentiles across
instances.
