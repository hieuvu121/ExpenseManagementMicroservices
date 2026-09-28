# 8. Schema management

## Current state

Every service runs `spring.jpa.hibernate.ddl-auto=update`. There is no Flyway,
no Liquibase, and no record anywhere of which database is at which schema
version.

## What `update` actually does

It **adds** missing tables and columns. It never **alters** an existing one.

That distinction is the single largest source of production bugs found in this
codebase, and it fails silently in both directions — the application starts
cleanly and then breaks at runtime.

## Three bugs, one root cause

**`@Lob String` became `TINYTEXT`.** Hibernate's MySQL dialect sizes a CLOB from
the column length, and the default is 255. The outbox payload column was
therefore 255 bytes, and registration returned *500 — "Data too long for column
'payload'"* on every attempt. Fixed with `length = Integer.MAX_VALUE`, which
selects `LONGTEXT`.

**`@Enumerated(EnumType.STRING)` became a native `enum(...)` column.** Adding a
value to the Java enum leaves the database rejecting it. `expense.status` was
still `enum('APPROVED','PENDING','REJECTED')` when `REVERSING` and `REVERSED`
were added, so every reversal failed on *"Data truncated for column 'status'"*.

**The same trap, years earlier.** `settlements.status` was
`enum('PAID','PENDING')` — generated before the Java enum was renamed and
extended. `COMPLETED` and `AWAITING_APPROVAL` had therefore been **silently
unwritable**, meaning settlement approval could not work at all in any database
created before that rename. Nobody noticed until the reversal saga needed a
`COMPLETED` settlement to exercise its refusal path.

Both status columns are now `columnDefinition = "varchar(32)"`, so the next
enum value needs no DDL at all.

## Why no test caught any of it

The `@DataJpaTest` slices run on **H2**, which makes an unbounded CLOB and a
plain varchar for an enum. Every unit test passed against a schema that could
not hold the data. Only running the real stack found them.

A second H2-versus-MySQL trap lives in the same tests: `application.properties`
sets `hibernate.connection.provider_disables_autocommit=true` (correct in
production, where Hikari runs with autocommit off), but `@DataJpaTest`
substitutes a datasource with autocommit **on**. Inheriting the production
value leaves every statement self-committing, and a rollback test proves
nothing. The outbox tests pin `false` explicitly with a comment.

## Migration burden today

Each of those fixes needs a manual `ALTER` on any database that already has the
tables — a fresh one is fine, because Hibernate now generates the right types.

Not everything needs help: adding `@Version` produced `bigint NOT NULL` and
MySQL backfilled existing rows with `0` unaided, verified against the live
stack.

## The recommendation

**Adopt Flyway and switch to `ddl-auto=validate`.** One dependency, a baseline
migration generated from the current schema, and thereafter every change is a
versioned file that either applies or fails loudly at startup.

All three bugs above would have been a failed boot with a clear message rather
than a runtime 500. Until that exists, every enum change and every column
widening is an undocumented manual step that only shows up in production.
