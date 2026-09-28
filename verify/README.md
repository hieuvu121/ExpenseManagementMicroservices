# verify/

Correctness checks that span services. `perf/` answers *how fast*; this answers
*is it right under duplication, crashes and races*.

Everything runs against a live stack and reaches into the databases, because
the interesting failures are ones no single service can see.

## Running

```bash
docker compose up -d --build              # or add -f verify/compose.local.yml
./verify/reconcile.sh                     # is the ledger self-consistent?
./verify/e2e-reversal.sh                  # the saga, 21 assertions
./verify/e2e-platform.sh                  # everything else, 20 assertions
N=50 ./verify/divergence-ab.sh after      # measure edit-induced divergence
```

`compose.local.yml` drops host port publishing for mysql and redis, which a dev
machine often already has bound. Only the gateway on 8080 is needed from the
host.

## What each one is for

| Script | Answers |
|---|---|
| `reconcile.sql` / `.sh` | **The oracle.** For every approved expense, do its settlements equal its non-creator splits? Every row returned is money the two services disagree on. Exits non-zero on drift, so it works in CI. |
| `e2e-reversal.sh` | The reversal saga: accepted path, refused path (the compensation — unit tests cannot reach it, since it needs a real `COMPLETED` settlement), and the four guards. Ends by running the oracle. |
| `e2e-platform.sh` | Outbox contract, email dedup, JWT revocation over pub/sub, the settlement authorization matrix, membership removal reaching both projections. |
| `divergence-ab.sh` | Measures how many ledgers an edit-after-approval corrupts. Run once with the `updateExpense` status guard removed and once with it in place. |
| `lib.sh` | Shared provisioning, plus `divergent_count` scoped to one household. Sourced, not run. |

## Measured results

### Ledger divergence from editing approved expenses

`N=50 ./verify/divergence-ab.sh`, same seed and volume, only the
`updateExpense` status guard differing:

| | edits accepted | divergent ledgers | total drift |
|---|---|---|---|
| **guard removed** | 50 / 50 | **50 / 50** | **5000.00** |
| **guard in place** | 0 / 50 | **0 / 50** | **0.00** |

Every accepted edit corrupted its ledger — a 100% divergence rate, silent in
both services. Neither `expense_db` nor `settlement_db` can detect it alone,
which is why the oracle has to read across both.

### Suites

41 assertions total, all passing: 21 in `e2e-reversal.sh`, 20 in
`e2e-platform.sh`.

## Things that will trip you up

**Two users are required.** `createSettlementsForExpense` skips splits
belonging to the expense creator, so a single-member household produces no
debts and there is nothing to measure.

**Expenses must be created by a member, not the admin.**
`ExpenseService.createExpense` marks an admin's own expense `APPROVED`
immediately and publishes only `EXPENSE_CREATED` — it never reaches
settlement-service, so no debt exists. A member's expense starts `PENDING`, and
the admin's approval is what publishes `EXPENSE_APPROVED`.

**Wait for both membership projections.** expense-service validates splits
against its copy and settlement-service authorizes against its own. `lib.sh`'s
`await_projections` covers this.

**Consumer groups rebalance after a restart.** Running a suite within ~30s of
restarting expense-service or settlement-service produces spurious failures
while `EXPENSE_APPROVED` goes unconsumed. Re-run rather than debug.

**`divergence-ab.sh` leaves corruption behind on purpose.** Its unguarded arm
is *supposed* to produce divergent ledgers — that is the measurement. So
`reconcile.sh`, which reads the whole database, will keep reporting them
afterwards. The suites use `divergent_count "$HOUSEHOLD"` to scope to their own
data. Clear the evidence with `docker compose down -v`.

### The approve-versus-reverse race — attempted, not landed

`race-approve-vs-reverse.sh` drives an approval into the window between
`ReversalDecisionService`'s read and its write. Across **175 races** at aim
points from 110ms to 1500ms, with the window widened two ways (an expense with
40 settlements, and a deliberate `Thread.sleep` inserted between the read and
the write), it produced:

| | |
|---|---|
| races run | 175 |
| optimistic-lock conflicts observed | **0** |
| violations (paid debt voided) | **0** |
| ledger divergence | **0** |

**Zero violations, but also zero conflicts — so this does not yet demonstrate
that `@Version` is what prevented them.** Every race resolved cleanly one side
or the other: either the approval committed first and the reversal correctly
refused, or the reversal voided first and the approval was correctly rejected.
The script is committed because the harness is sound and the calibration is
worth keeping, not because the number proves anything yet.

Two things make the window hard to hit from outside:

- **The outbox poll interval (500ms) dominates the timing.** The reversal
  travels HTTP → outbox poll → Kafka → `decide()`, so the read lands anywhere
  in a ~500ms band. A fixed aim cannot sit inside a window whose start jitters
  further than the window is wide.
- **Process launch jitter is ~100ms.** Asking for an approval at 500ms fires it
  at ~600ms, which is coarser than the natural window.

Calibration note for anyone continuing: measuring latency by polling MySQL
through `docker exec` adds ~150ms per query and badly inflates the numbers.
The first several aim points were chosen from polluted measurements and all
landed outside the window as a result.

**The claim is currently supported at the unit level, not end to end.**
`settlement-service`'s `SettlementConcurrencyTest` drives two real transactions
and proves both directions of the lost update, verified honestly: remove
`@Version` and both race tests fail, restore it and they pass. Reproducing that
through the full pipeline is unfinished.

## Not built yet

The rest of the fault-injection matrix: duplicate delivery, crash at the saga
pivot, and broker outage.
