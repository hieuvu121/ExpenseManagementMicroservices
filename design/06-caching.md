# 6. Caching

## The rule this system learned the hard way

**A network cache in front of a cheap local lookup makes things slower.**

Two caches were originally put in Redis and both were reverted:

| Cache | Redis result | Now |
|---|---|---|
| Household membership check | p95 **4.69ms → 12.46ms** | Caffeine, in-process |
| Gateway JWT blacklist | ~1178 ops/sec → **~1** | Caffeine, in-process |

The membership lookup costs roughly 256µs against a small table on an
already-open pooled connection. A Redis round trip is ~280µs. Caching it in
Redis swapped an equal-cost operation for a second serial tail dependency and
made every read worse.

Caffeine has no network hop, so that trade does not apply.

## Where Redis still earns its place

Redis is kept where the hop is cheap relative to the work behind it:

- `@Cacheable` on `getExpenseByPeriod` — a real aggregate query
- `@Cacheable` on `ai_suggestion` — otherwise an OpenAI call
- The JWT blacklist itself (the source of truth, not the cache in front of it)
- **Pub/sub for invalidation** — see below

## Invalidation: TTL is the backstop, push is the fast path

An in-process cache on N replicas has N copies. Something has to reach all of
them.

**JWT revocation.** Logout writes `blacklist:<token>` to Redis and publishes on
`jwt-revoked`. Each gateway subscribes and evicts immediately. Before this,
nothing told the gateways at all — a revoked token stayed usable until each
replica's entry aged out independently.

The obvious alternative, shortening the TTL, is exactly wrong: it buys
freshness by reintroducing the Redis hop that was deliberately removed. With
push handling the common case the TTL could instead be *raised* from 10s to
60s, cutting lookups roughly six-fold.

**Membership invalidation.** Originally a second Kafka listener on a per-JVM
UUID group id. That worked but cost two things: a dead consumer group left in
the broker after every restart, and — worse — the group was independent of the
one owning the database write, so a replica could invalidate *before* the row
was stamped and a read in the gap would re-cache the stale value.

Now `HouseholdMemberEventConsumer` publishes on Redis **after** the commit, and
every replica applies it. That is the post-commit ordering the race needed, and
the throwaway groups are gone.

## Why pub/sub is acceptable here

Redis pub/sub is at-most-once with no persistence — a disconnected subscriber
misses the message entirely. That is only tolerable because **both caches are
TTL-backed**: a missed message degrades to the previous behaviour rather than
to permanent divergence. The message is an optimisation, never the correctness
mechanism.

This is why the same pattern is *not* used for `user_summary` or
`household_member_summary`, where a missed message means lasting divergence.
Those stay on Kafka.

## Ordering rules worth keeping

- **Invalidate after the write, never before.** A read arriving between an early
  invalidate and the commit re-caches the stale value and holds it for the full
  TTL — worse than not invalidating at all.
- **Publish outside the "found" branch.** A redelivery, or an event for an
  already-tombstoned row, must still drop whatever the replicas cached.

## Residual staleness

Bounded by `app.membership-cache-ttl-seconds` (30s) and
`app.jwt.blacklist-cache-ttl-seconds`. Both can be set to `0` to disable the
cache and always consult the source.

## Where the code lives

- `expense-service/.../service/HouseholdMembershipCache.java`
- `expense-service/.../listener/MembershipInvalidationListener.java`
- `api-gateway/.../filter/JwtAuthenticationFilter.java`
- `api-gateway/.../listener/JwtRevocationListener.java`
