# 5. Saga: expense reversal

## Why this flow, and only this flow

A saga is warranted when a later step can fail for a **business** reason that
invalidates an earlier committed decision, and undoing is the only recovery.

Applied across this system, almost nothing qualifies. `EXPENSE_APPROVED` →
settlements is arithmetic over data the event already carries; it cannot be
*declined*, only delayed. Projection updates are upserts. For those,
retry-until-success strictly beats undo — reverting a household's approved
expense because settlement-service was restarting would be the worse outcome.

Expense reversal is different. Reversing an expense whose debts someone has
already paid is refused for a reason that no amount of retrying will change.
That refusal comes from real data, not a simulated failure.

## What it replaces

`updateExpense` had no status guard and published nothing, so an admin could
edit an **approved** expense while the settlements derived from it kept the old
figures. Approve £100 split 50/50 → `settlement_db` records £50; edit to £300 →
`expense_db` says £300 and `settlement_db` still says £50, permanently.

Publishing a correction would not have helped: `createSettlementsForExpense`
guards on `existsByExpenseIdAndFromMemberId` and would skip it. Dedup-by-key
and correct-in-place are in direct conflict, and the guard wins.

The domain answer is the ledger answer — **reverse and re-post, never mutate a
posted entry**. `updateExpense` is now `PENDING`-only and `REVERSED` is
terminal, so a correction is a new expense.

## The flow

```
admin: POST /households/{h}/expenses/{e}/reversal
  expense:    APPROVED → REVERSING, insert expense_reversal
              ⇢ ExpenseReversalRequested                    [outbox]
  ──▶ 202 {sagaId, state}   ← "reversing", never "reversed"

  settlement: [ONE transaction]
              any COMPLETED?  → REFUSED, nothing written
              otherwise       → all open rows VOIDED
              ⇢ ExpenseReversalDecided                      ← THE PIVOT

  expense:    ACCEPTED → REVERSED, saga COMPLETED
              REFUSED  → APPROVED, saga CANCELLED + reason  ← COMPENSATION
              expense not REVERSING → saga FAILED + reason   ← needs a human
```

`FAILED` is for a reply that can never apply: the saga is open but the expense
has already left `REVERSING`. Throwing would only redeliver the same reply
forever, so the saga is closed instead and the reason records what
settlement-service answered — for `ACCEPTED`, which settlements are already
voided; for `REFUSED`, its own reason — next to the aggregate's explanation.
The expense is left untouched, and nothing re-requests a `FAILED` saga.

## The three things that make it correct

**1. The intermediate state is honest.** The admin sees `REVERSING` and a `202`,
never a `200` saying "reversed". That is what makes compensation acceptable —
nothing already promised has to be retracted. The general test:

> If compensating would force you to retract something you already told the
> user was done, you have picked the wrong pattern.

**2. Silence never compensates.** If settlement-service voided the debts and the
reply was lost, rolling back to `APPROVED` would leave an approved expense with
`VOIDED` settlements — the exact divergence the saga exists to prevent, caused
by the saga. expense-service cannot distinguish "refused" from "accepted but
the reply vanished", and unlike a payment provider there is nothing to query.
So `ReversalReRequestSweep` **re-requests with the same `sagaId`** and never
cancels. Only an explicit `REFUSED` compensates. Past the attempt ceiling it
stops publishing, leaves the saga open and logs at ERROR — `REVERSING` is
visible and recoverable, a state contradicting `settlement_db` is not.

**3. The pivot is idempotent.** `ReversalDecisionService` recognises its own
`sagaId` on already-voided rows and re-confirms `ACCEPTED`. Without that branch
a re-request would be refused for the saga's own work, and the sweep would be
unusable. `voidingSagaId` exists for this — not for compensation bookkeeping,
since nothing un-voids.

## Concurrency

Three races, all closed the same way — a `@Version` column, so the later commit
of two that read the same row fails instead of overwriting.

**Settlement side: check-then-void.** `@Transactional` does **not** make check-then-void atomic. Under InnoDB
REPEATABLE READ the `SELECT` is a consistent non-locking read while the `UPDATE`
is a current read, so an approval committing in the gap is silently
overwritten — a paid debt becomes `VOIDED`. Symmetric, too: `approveSettlement`
can stamp `COMPLETED` over a freshly voided row.

`SettlementEntity.version` closes both directions. Optimistic rather than
`SELECT … FOR UPDATE` because a pessimistic lock works only if every mutator
remembers to take one, and a path added later that forgets reopens the hole
silently. The loser needs no handling: a conflict rolls back the decision and
its outbox reply together, which looks exactly like a lost reply, so the sweep
retries into the correct `REFUSED`.

**Expense side: two admins reversing at once.** `startReversal()` checks
`APPROVED` on the copy each transaction loaded, so two requests that both read
`APPROVED` both pass it — an in-memory check cannot see the other transaction.
`ExpenseEntity.version` makes the second commit fail, and the saga row and
outbox request it wrote roll back with it. A request arriving after the first
committed reads `REVERSING` and is refused by the aggregate itself, or returns
the saga already in flight.

**Expense side: the sweep against the reply.** `ReversalReRequestSweep` and the
reply consumer both write the same `expense_reversal` row while the saga is
open, from different threads. Hibernate updates every column, so a sweep
committing after the reply would write its stale `AWAITING_SETTLEMENT` over
`COMPLETED` and reopen a finished saga. Rare in steady state — a reply normally
lands long before the 60-second timeout — but most likely exactly when the
system is recovering: after a restart the consumer replays its backlog from
`earliest` while the first sweep finds the same sagas overdue.
`ExpenseReversal.version` closes it. A losing sweep rolls back its whole batch
and the next one no longer selects the saga; a losing reply is retried.

**Retrying the loser.** The reply listener's error handler backs off
exponentially (200 ms doubling to 5 s, five retries) on optimistic-lock
conflicts, and does not retry `InvalidExpenseStatusException`, which gives the
same answer every time. A record dropped after the last retry is not lost: the
saga is still open, so the sweep asks again and settlement-service replays its
decision. Spring's default — ten attempts with no pause — would have spent
every retry inside the conflicting transaction's lifetime.

## State machines

```
PENDING ──▶ APPROVED ──▶ REVERSING ──▶ REVERSED   (terminal)
   │             ▲            │
   │             └────────────┘  REFUSED = compensation
   └──▶ REJECTED (terminal)

AWAITING_SETTLEMENT ──▶ COMPLETED   (terminal)
                    ──▶ CANCELLED   (terminal, keeps settlement's reason)
                    ──▶ FAILED      (terminal, needs a human)

PENDING / AWAITING_APPROVAL ──▶ VOIDED   (terminal)
COMPLETED ──▶ (no transition)            ← THE VETO
```

## Guards this required

- `toggleStatus` / `approveSettlement` / `rejectSettlement` reject `VOIDED` —
  otherwise a member pays a debt the reversal removed
- `requestReversal` is `APPROVED`-only and idempotent — two sagas racing over
  the same settlements means one is refused for the other's work
- `updateExpense` is `PENDING`-only

On the expense side these are no longer `if` statements in the service. Every
transition is a method on the aggregate that checks its precondition —
`startReversal`, `completeReversal`, `cancelReversal`, `approve`, `reject`,
`updateExpense` on `ExpenseEntity`; `complete`, `cancel`, `markFailed`,
`recordReRequest` on `ExpenseReversal` — and neither entity has setters, so
there is no other way to change state. A refused transition is
`InvalidExpenseStatusException`, returned as **409**: the request is valid, it
conflicts with the current state. See [note 10](10-aggregates.md).

## Not done

Clients have no Reverse button and no rendering for `REVERSING` / `REVERSED`.
Nothing alerts on a saga stuck in `AWAITING_SETTLEMENT`, or on one closed as
`FAILED` — today both are an ERROR log line and a row to query for.

The sweep runs every saga it selects in one transaction, so a single conflict
rolls back the whole batch's re-requests until the next pass. Harmless at this
volume. With more than one expense-service instance, every instance sweeps the
same rows; the version keeps that correct but not cheap, and
`FOR UPDATE SKIP LOCKED` or a scheduler lock would be the fix.

## Where the code lives

- `expense-service/.../service/ExpenseReversalService.java`
- `expense-service/.../reversal/ReversalReRequestSweep.java`
- `expense-service/.../entity/ExpenseEntity.java`, `ExpenseReversal.java` — the transitions and both versions
- `expense-service/.../config/KafkaConsumerConfig.java` — the reply listener's error handler
- `expense-service/.../entity/ExpenseConcurrencyTest.java`, `ExpenseReversalConcurrencyTest.java`, `config/ReversalReplyErrorHandlerTest.java`
- `settlement-service/.../service/ReversalDecisionService.java`
- `settlement-service/.../entity/SettlementConcurrencyTest.java`
