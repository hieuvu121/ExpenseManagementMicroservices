# 3. Transactional outbox

## The problem

A service that writes to its database and then publishes an event is performing
two writes with no shared transaction. Either can succeed alone.

The worse orientation was live in this codebase. `ExpenseService.acceptExpense`
was `@Transactional`, sent `EXPENSE_APPROVED` to Kafka, and *then* ran three
Redis cache evictions — still inside the transaction:

```java
expenseRepo.save(expense);
expenseEventProducer.publish(expense, "EXPENSE_APPROVED");   // already on the broker
evictCacheForAiSuggestion(householdId);                      // Redis
evictExpenseInRangeCaches(householdId, PENDING);             // Redis
```

A Redis outage throws, the transaction rolls back to `PENDING`, and
settlement-service has already written settlement rows from an approval that
never committed. **Debt owed for something that did not happen, triggered by an
unrelated cache being down.**

The mirror failure existed too: `registerUser` saved the user and then published
inside a `try/catch` that printed to `System.err`. A broker outage left a user
in `auth_db` that `household_db.user_summary` never learned about — permanently,
since `UserEventConsumer` handles only `USER_REGISTERED` and nothing replays.

## The fix, and where each applies

Two mechanisms, chosen by what a lost event costs.

**Outbox** — the event is a row written in the same transaction as the state
change, and a poller publishes it afterwards. Used where losing an event is
unrecoverable:

| Path | Why |
|---|---|
| `expense-events` | A lost `EXPENSE_APPROVED` is an approved expense that never becomes debt |
| `user-events` | A lost `USER_REGISTERED` is a user who can never join a household |
| `email-events` | A lost activation mail is an account nobody can activate |
| `expense-reversal-replies` | The saga's pivot has no other record |

**After-commit** (`@TransactionalEventListener(AFTER_COMMIT)`) — build inside
the transaction, send once it commits. Used where a lost event is recoverable:

| Path | Why |
|---|---|
| `household-member-events` | Projection drifts until the member is next touched |
| `websocket-events` | A stale panel until the user refreshes |

After-commit removes the dangerous direction for nothing: an event can no longer
describe uncommitted state. It does not survive the process dying between
commit and send — which is a strictly better failure than the one it replaces.

## Details that matter

**Serialize inside the transaction.** `ExpenseEntity.splitDetails` is a lazy
`@OneToMany`. Building the event after commit, on a detached entity, throws
`LazyInitializationException`. The outbox stores JSON written while the entity
is still managed.

**Stop the batch on a refused send.** `OutboxPublisher` breaks rather than
skipping, because publishing row *n+1* after row *n* failed would reorder one
expense's events.

**`.get()` on the send.** An unresolved future would let the loop stamp
`publishedAt` for a record the broker never accepted.

**At-least-once by design.** `publishedAt` is stamped only after the broker
acknowledges, so a crash in between republishes. That is why every outboxed
event carries an `eventId` — see [note 4](04-idempotency-and-deduplication.md).

## Limits

One poller per service, draining strictly by id. Both services run
single-instance; scaling past one replica needs leader election or
claim-partitioning by `aggregateId`, documented on `OutboxRepository`.

The outbox classes are duplicated per service rather than shared through
`common/`, which carries no JPA dependency — adding one there would pull JPA
into ai-service and notification-service, neither of which has a datasource.

**Still outstanding:** `ForgotPasswordService` publishes directly and is not
transactional, so `email-events` is outboxed from registration but not from
password reset.
