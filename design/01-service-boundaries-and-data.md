# 1. Service boundaries & data ownership

## Decision

Every service owns a private schema and no query ever crosses one. Where a
service needs another's data it keeps a **local read projection** fed by Kafka.

| Service | Schema | Owns |
|---|---|---|
| auth-service | `auth_db` | `tbl_users`, `tbl_forgot_password` |
| household-service | `household_db` | `household`, `household_member` |
| expense-service | `expense_db` | `expense`, `expense_split_details` |
| settlement-service | `settlement_db` | `settlements` |
| email-service | `email_db` | `processed_event` |

ai-service, notification-service and api-gateway hold no state at all.

## Why no cross-schema joins

They would be technically possible — all five schemas live in **one MySQL
instance** and every service connects as the same `root` user. That makes the
boundary a convention rather than something enforced, and joining across it
would be the fastest way to lose the ability to deploy services independently.

Instead, a service that needs foreign data keeps a narrow copy of it:

| Projection | Lives in | Fed by |
|---|---|---|
| `user_summary` | `household_db` | `user-events` |
| `household_member_summary` | `expense_db` | `household-member-events` |
| `household_member_summary` | `settlement_db` | `household-member-events` |

Each is a handful of columns — enough to answer a specific question, never a
mirror of the source table. `expense_db.household_member_summary` exists so the
expense list can resolve a creator's name in the same SQL statement that reads
the expenses; `settlement_db`'s copy exists so settlement-service can map the
caller's `userId` to a `memberId` and authorize them.

## Tombstones, not deletes

`MEMBER_LEFT` stamps `removed_at` rather than deleting the projection row. Two
reasons, and they pull in different directions:

- An expense keeps the name of whoever created it, even after they leave.
  Deleting the row turns their history into "Unknown".
- A departed member keeps their outstanding debts and must still be able to
  settle them. Delete the row in `settlement_db` and the debt becomes
  unauthorizable, therefore uncollectable.

The consequence is that every lookup has to be deliberate about `removed_at`.
Authorization for *your own* debts ignores it; the household-wide view requires
current membership. That asymmetry is load-bearing, not an oversight — see
[note 7](07-security.md).

## What this costs

**Eventual consistency.** A projection lags its source by however long Kafka
delivery takes. For membership that window is bounded further by a cache TTL
(see [note 6](06-caching.md)).

**Known gap:** `UserEventConsumer` handles only `USER_REGISTERED`. A user who
changes their name never propagates, because no `USER_UPDATED` is published.

## Where the code lives

- `expense-service/.../consumer/HouseholdMemberEventConsumer.java`
- `settlement-service/.../consumer/HouseholdMemberEventConsumer.java`
- `household-service/.../consumer/UserEventConsumer.java`
- `init-db.sql` — creates the five databases
