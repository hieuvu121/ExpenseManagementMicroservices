# Design Notes

Why this system is built the way it is.

Each note records a decision, the reasoning behind it, what it costs, and where
the code lives. They are written to be read by someone deciding whether to keep
a design, not to advertise it — so the trade-offs and the known gaps are in
here too.

| # | Note | What it covers |
|---|---|---|
| 1 | [Service boundaries & data ownership](01-service-boundaries-and-data.md) | Database per service, local read projections, why no query crosses a schema |
| 2 | [Messaging](02-messaging.md) | Kafka topics and event contracts, why Eureka still exists alongside it |
| 3 | [Transactional outbox](03-transactional-outbox.md) | The dual-write problem, and where an outbox is warranted versus after-commit |
| 4 | [Idempotency & deduplication](04-idempotency-and-deduplication.md) | `eventId`, business-key idempotency, the one consumer that needs a dedup table |
| 5 | [Saga: expense reversal](05-saga-expense-reversal.md) | Compensation, the pivot, and why silence must never trigger a rollback |
| 6 | [Caching](06-caching.md) | Caffeine versus Redis, measured, and invalidation over pub/sub |
| 7 | [Security](07-security.md) | Edge JWT validation, identity propagation, per-service authorization |
| 8 | [Schema management](08-schema-management.md) | What `ddl-auto=update` will and will not do, and the bugs that came from it |
| 9 | [Performance & resilience](09-performance-and-resilience.md) | Admission control, query shape, the measured baseline |

## The shape of the system in one paragraph

Nine Spring Boot services behind one gateway. Each owns a private schema and
never reads another's. Where a service needs foreign data it keeps a local copy
fed by Kafka, so every query stays inside one database and one connection.
Requests are one hop deep — the gateway routes to exactly one service, which
answers from its own data. Everything cross-service is asynchronous, and the
only flow that coordinates two services is the expense reversal saga.

## Reading order

Notes 1 and 2 describe the architecture. Notes 3, 4 and 5 are a sequence: the
outbox makes publishing reliable, which creates duplicates, which idempotency
absorbs, and the saga is built on all three. Notes 6 to 9 are cross-cutting.
