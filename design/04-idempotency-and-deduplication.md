# 4. Idempotency & deduplication

## Why duplicates are routine, not exceptional

Kafka is at-least-once, and this system adds two more sources on top:

- `@RetryableTopic` republishes a failed message, so a handler that partially
  succeeded before throwing runs again.
- The outbox republishes anything it could not confirm ([note 3](03-transactional-outbox.md)).

The outbox in particular means duplicates are *manufactured* by the design.
Handling them is not optional.

## The default: be idempotent on a business key

Wherever a natural key exists, the handler is written so running twice is
harmless. No dedup table, no retention policy, and — crucially — no race
between "record processed" and "do the work".

| Consumer | Mechanism |
|---|---|
| `SettlementService.createSettlementsForExpense` | `existsByExpenseIdAndFromMemberId` guard |
| `HouseholdMemberEventConsumer` (expense, settlement) | Upsert by `memberId`, which is the primary key |
| `UserEventConsumer` | "already exists, nothing to do" |
| `MembershipInvalidationListener` | Cache eviction is inherently repeatable |

The rule worth writing down: **a consumer must be safe to run twice on the same
message.**

That settlement guard turns out to be load-bearing beyond its original purpose.
Because it does not filter on status, a redelivered `EXPENSE_APPROVED` cannot
resurrect settlements a reversal has voided — the `VOIDED` rows still satisfy
`existsBy`, so creation is skipped. That protection is currently accidental and
deserves a test pinning it.

## `eventId`: for the one case with no natural key

Sending an email is not repeatable and leaves no row that means "already sent".
So the producer stamps an identity and email-service remembers it.

`DomainEvent` exists so `OutboxWriter` can set the id **on the payload**, not
just on the outbox row:

```java
String eventId = UUID.randomUUID().toString();
event.setEventId(eventId);                       // consumers can see it
outboxRepository.save(... .eventId(eventId) ...) // the same value on a republish
```

Before that, the id lived in `outbox_event` and nowhere else, so nothing
reaching Kafka carried one. `write()` takes `DomainEvent` rather than `Object`
to make "everything leaving through the outbox is identifiable" a compile-time
guarantee.

Note `eventId` and `sagaId` are different things: `eventId` identifies a
message and drives dedup, `sagaId` identifies a process instance and drives
correlation. The saga needs both.

## email-service's dedup table

```java
if (processedEventRepository.existsById(eventId)) return;
emailService.sendEmail(...);
processedEventRepository.save(new ProcessedEvent(eventId, Instant.now()));
```

**Record after sending, never before.** A crash in that window re-sends on
redelivery; recording first would lose the mail entirely in the same window,
and an account whose activation email never arrives cannot be activated at all.
A duplicate is an annoyance, a missing one is a dead account.

An event with no `eventId` is sent **without** dedup, with a warning, for the
same reason — and the warning is how a producer that was missed gets noticed.

`ProcessedEventPurge` trims the table nightly. The window only has to outlive
redelivery, so a row older than that can never be matched again.

## Which events carry an id

Only the four that travel through an outbox: `ExpenseEvent`, `UserEvent`,
`EmailEvent`, `WebSocketEvent`, plus the two saga messages.
`HouseholdMemberEvent` and the AI events deliberately do not — nothing would
ever set their id, and a field that is always null reads as a bug.

## Naming caveat

`DomainEvent` is a loose name for what it is: a marker that the outbox may
stamp a payload. Two of its implementors are not domain events in any DDD
sense — `EmailEvent` is a command ("send this"), `WebSocketEvent` is a delivery
instruction. `IdentifiableEvent` would be more honest.

## Gap

`ai-service` has no dedup. A redelivered `ai-request-events` is a second OpenAI
call, billed.
