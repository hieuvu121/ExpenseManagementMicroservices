# 2. Messaging

## Decision

Kafka for everything between services. No service calls another over HTTP.

`grep -r "FeignClient\|WebClient\|RestTemplate"` across all nine services
returns exactly one hit: ai-service's OpenAI client. That is the whole point —
rendering an expense list needs no call to household-service, because
`expense_db` already holds the projection it needs.

## Topics

| Topic | Producer | Consumer | Purpose |
|---|---|---|---|
| `user-events` | auth-service | household-service | `USER_REGISTERED` → `user_summary` |
| `email-events` | auth-service | email-service | Activation and password-reset mail |
| `household-member-events` | household-service | expense-service, settlement-service | `MEMBER_JOINED` / `MEMBER_LEFT` → projections |
| `expense-events` | expense-service | settlement-service | `EXPENSE_APPROVED` → settlements |
| `websocket-events` | expense-service, settlement-service | notification-service | Pushes to connected clients |
| `ai-request-events` / `ai-response-events` | expense-service ↔ ai-service | | Request/reply via `ReplyingKafkaTemplate` |
| `expense-reversal-requests` / `-replies` | expense-service ↔ settlement-service | | The saga — see [note 5](05-saga-expense-reversal.md) |

## Why Kafka, honestly

Partly because it was already provisioned, and partly as a demonstration goal —
the original design spec lists "show three distinct communication patterns" as
an objective. At this volume RabbitMQ or Redis Streams would do the job.

Two things do genuinely earn it:

**Consumer groups used two ways on one topic.** `expense-service` consumes
`household-member-events` once under a shared group (so exactly one replica
performs the database write) and previously fanned the same event to every
replica under per-JVM groups for cache invalidation. That second use has since
moved to Redis pub/sub ([note 6](06-caching.md)), but the shared-group
semantics still matter.

**Per-key ordering.** `MEMBER_JOINED` then `MEMBER_LEFT` for one member must not
reorder or the tombstone logic corrupts. Partition-by-key gives that free.

## Where it is under-configured

- Single broker, `replicas(1)`, `KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1`.
  The durability story Kafka is usually chosen for is not actually bought.
- Only `email-events` and `user-events` declare partitions (3). The rest
  auto-create with one.
- Producer configs set bootstrap servers and serializers and nothing else — no
  explicit `acks` or `enable.idempotence`. Modern clients default both on, so
  it works, but by accident rather than declaration.
- **No DLT is ever drained.** Every `@DltHandler` logs and stops. A permanently
  failed message is lost silently, and nothing alerts on DLT depth.

## Why Eureka still exists

Kafka addresses by topic name — a constant. Eureka addresses by host and port,
and a browser POSTing `/auth/login` needs a reply on its open socket, which
Kafka cannot provide.

Exactly two things consume the registry: `api-gateway`'s `lb://` routes, and
Prometheus's `eureka_sd_configs`. No Java code calls `DiscoveryClient`.

The clearest proof of the division: **email-service is not a Eureka client at
all** — no dependency, no config. It is purely Kafka-driven and nothing ever
calls it over HTTP, so it does not need to be findable. Prometheus scrapes it
statically.
