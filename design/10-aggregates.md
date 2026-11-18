# 10. Aggregates

## Decision

`ExpenseEntity` is an aggregate root. Its splits are part of it, every change
to either goes through a method on the root, and the root refuses any change
that would leave it invalid. `ExpenseReversal` is a second, smaller aggregate
for the saga's own state.

## What it replaced

The rules used to live in the service, split between `ExpenseValidation` and
`if` statements before each `setStatus`. Creation was checked; nothing else
was:

- `updateExpense` set the amount and merged splits row by row with no checks
  at all. Change a £100 expense split 50/50 to £120 and it saved as £120 with
  splits summing to £100. Send `{A: 100}` for an A/B expense and B's old £50
  survived, summing to £150. Approval would then turn the wrong numbers into
  debt, after which the expense can no longer be edited.
- A split for a member who had left the household was accepted on edit.
- A duplicate member in one request reached the unique key
  `(expense_id, member_id)` and came back as a raw constraint-violation message.

## Invariants and preconditions

Two different kinds of rule, and the distinction is what makes create and edit
share one implementation:

| | Holds | Examples |
|---|---|---|
| **Invariant** | Always, after every operation | amount > 0; splits sum to the amount (`compareTo`, so 100.0 = 100.00); `EQUAL` splits are equal; no member twice; currency, category, method and date present |
| **Precondition** | Before one particular operation | edit, approve, reject need `PENDING`; `startReversal` needs `APPROVED`; complete/cancel need `REVERSING` |

`createExpense` **establishes** the invariants; `updateExpense` must **keep**
them. So both end in the same `requireValid(...)`. Edit merges the request onto
the current values first and validates the result, which is what stops
"change only the amount". Edit additionally checks its precondition, as every
other transition does.

A broken invariant is `IllegalArgumentException` → 400. A broken precondition is
`InvalidExpenseStatusException` → 409.

## Creation is a static factory

`ExpenseEntity.createExpense(...)` validates and only then constructs, so a
half-built expense never exists. An instance method on a `new ExpenseEntity()`
would leave an empty object around for anyone to save. The factory also picks
the initial status — an admin's own expense is born `APPROVED` — so that rule
has one home; the service reads the status back rather than computing it.

## What crosses the boundary, and how

**Inside the aggregate, by object.** The root holds its
`ExpenseSplitDetailsEntity` children, creates them, and points them back at
itself. The sum rule needs the expense and every split at once, which is only
possible if the root has them.

Editing splits replaces the list by member: an existing member's row is updated
in place, a new member gets a row, a member left out loses theirs through
`orphanRemoval`. Rows are updated rather than cleared and re-added because
Hibernate flushes inserts before deletes, and re-adding a member's split would
hit the unique key before the old row was gone.

There is no `ExpenseSplitDetailsRepository`. A repository for a child is a way
round the root.

**Between aggregates, by id.** The expense holds `createdByMemberId`,
`reviewedByMemberId` and `householdId`, never the objects. Settlements, in
another service, hold `expenseId`. `ExpenseReversal` holds `expenseId`, not a
`@ManyToOne`. Each aggregate is its own transaction and lock boundary, and a
reference by object would let a change to one reach into another.

That is also why one creation rule stays in the service:
`ExpenseValidation` checks that every split's member is still in the household.
That needs the repository and another aggregate's data, so it cannot be on the
entity. Everything about the expense's own data moved off it.

## Closing the side doors

Neither entity has setters, and `ExpenseEntity` has no builder; the no-arg
constructor is `protected`, for Hibernate. Without that, the methods above are
a convention any caller can skip.

Tests still need an expense already in `REVERSING` or `REJECTED`, as if loaded
from the database. `ExpenseFixtures` builds a valid one through `createExpense`
and forces `id` and `status` by reflection — in test code only.
`ExpenseReversal` keeps its builder, because a saga is created in one piece.

## Costs

- `createExpense` takes eleven arguments. A parameter object would read better;
  not done yet.
- Error messages changed when the rules moved: "Sum of split amounts must equal
  total amount" is now "Sum of splits is 100.00 but amount is 120.00". No client
  matches on message text today. If one ever needs to, give the error a stable
  code rather than matching the sentence.
- `ExpenseSplitDetailsEntity` still has setters and a builder. Only the root
  calls them, but nothing enforces that.

## Where the code lives

- `expense-service/.../entity/ExpenseEntity.java` — factory, transitions, invariants
- `expense-service/.../entity/ExpenseReversal.java` — the saga's transitions
- `expense-service/.../validation/ExpenseValidation.java` — the cross-aggregate member check
- `expense-service/.../entity/ExpenseEntityTest.java`, `ExpenseReversalTest.java` — plain JUnit, no Spring
