# Load testing

Measures request throughput and latency through the API gateway with [k6](https://k6.io/) (`brew install k6`).

## Run it

```bash
docker compose up -d                    # stack must be running
./perf/seed.sh                          # one-off: makes a user + household + 200 expenses
set -a && . ./perf/.env && set +a        # export JWT / HOUSEHOLD_ID

RPS=1000 k6 run perf/load-test.js        # "can it sustain N req/s?"
MODE=ramp k6 run perf/load-test.js       # "how many concurrent users before it breaks?"
```

`perf/.env` holds a real JWT (~10h lifetime). Re-run `seed.sh` when it expires.

## The two modes, and why it matters which you pick

`MODE=rps` (default) uses k6's `constant-arrival-rate`: it fires at a fixed rate
no matter how slow responses get. This is the right model for "requests per
second" questions — it keeps pressure on even as the server degrades.

`MODE=ramp` uses `ramping-vus`: each virtual user waits for its response before
sending the next. A slow server therefore *reduces its own load*, which hides
saturation. Use it for concurrency questions only.

The metric that tells you you've exceeded capacity in `rps` mode is
**`dropped_iterations`** — nonzero means k6 couldn't even issue the requested
rate. Watch that before you look at latency.

## Baseline (2026-07-29)

Measured on the local docker-compose stack, M-series laptop, 11 CPUs, 8 GB
allotted to Docker. 75/25 read mix: `GET /households/{id}/expenses?limit=10`
and `GET /households/my`. 1-minute runs.

| Target RPS | Achieved | p95 | max | dropped | failed |
|---|---|---|---|---|---|
| 50 | 50.0 | 12.1 ms | 152 ms | 0 | 0% |
| 500 | 500.0 | 13.1 ms | 718 ms | 0 | 0% |
| 1000 | 999.9 | 9.0 ms | 660 ms | 0 | 0% |
| 1500 | 1496.4 | 159.0 ms | 1.59 s | 207 | 0% |

**The knee is between 1000 and 1500 RPS.** Up to 1000 the stack is flat and
comfortable (p95 under 15 ms). At 1500 p95 jumps ~17x, tail hits 1.6 s, and k6
starts dropping iterations. Notably the error rate stays at 0% throughout — it
degrades by getting slow, not by failing, so latency percentiles are the signal
to watch, not status codes.

### After the `@Transactional(readOnly = true)` fix

| Target RPS | metric | before | after |
|---|---|---|---|
| 1000 | p50 | 5.03 ms | **1.73 ms** |
| 1000 | p95 | 9.04 ms | **5.33 ms** |
| 1500 | p50 | 6.45 ms | **1.84 ms** |
| 1500 | p95 | 159.0 ms | 159.2 ms |
| 1500 | dropped | 207 | 198 |

Below saturation the win is large — p95 down 41%, median down 2.9x. **The knee
did not move**, because at 1500 RPS the constraint is CPU contention between k6
and thirteen containers, not MySQL (which sat under 1% CPU throughout). Fixing a
database inefficiency cannot raise a ceiling that isn't database-bound; it makes
every request under that ceiling cheaper.

## Caveats — read before trusting these numbers

- **The load generator shares the machine with the stack.** k6 on the same 11
  cores as 13 containers distorts results at high rates. Some of the 1500-RPS
  degradation is contention, not application limit.
- **Docker has 8 GB for 13 containers**, seven of them JVMs. You are partly
  measuring memory pressure. Treat these figures as useful for *relative*
  comparisons (before/after a query change), not as production capacity.
- **Warm up first.** The initial seconds after container start are JIT
  compilation, Eureka registration and Hibernate pool fill. Every table above
  came from a stack that had already been serving traffic.
- The `max` column being ~50x the p95 at every rate is the JVM GC signature,
  expected here.

## Tracing where the time goes

There is **no actuator, micrometer, or tracing dependency** on any business
service (only `eureka-server` has actuator), and the service images are
`eclipse-temurin:21-jre` with no `jcmd`/`jstack`. So attribution comes from
these four layers, cheapest first — no code changes needed for 1-3.

**1. k6 itself — is it the network or the server?**
Run without `--quiet` and read `http_req_waiting` (server think time) against
`http_req_connecting` / `http_req_sending` / `http_req_receiving`. If waiting
dominates, it's the app; if connecting grows, you're exhausting sockets.
Per-endpoint `Trend` metrics (`ep_expenses_list`, `ep_households_my`) are
already in the script so one slow route can't hide inside the aggregate.

**2. `docker stats` — which container?**
```bash
docker stats --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
```
Run it in a second terminal during the test. Tells you gateway vs. service vs.
MySQL in about ten seconds of watching.

**3. MySQL `performance_schema` — which query?** This is the highest-value one.
```bash
# reset counters immediately before the run
docker exec mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
  -e "truncate performance_schema.events_statements_summary_by_digest;"'

# ... run k6 ...

docker exec mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "
select count_star, round(sum_timer_wait/1e9,1) total_ms, round(avg_timer_wait/1e6,3) avg_us,
       left(digest_text,90) query
from performance_schema.events_statements_summary_by_digest
where schema_name=\"expense_db\" order by sum_timer_wait desc limit 10;"'
```
Divide `count_star` by your request count. Anything landing on a round multiple
of the page size is an N+1.

**4. Hibernate SQL logging** — only when 3 has already pointed at a suspect,
since it's far too noisy under load. Add to the service's
`application.properties` and restart that container:
```properties
spring.jpa.show-sql=true
spring.jpa.properties.hibernate.format_sql=true
logging.level.org.hibernate.orm.jdbc.bind=trace
```

### Worked example: what this found (2026-07-29)

Digest table after ~137k `GET /households/{id}/expenses?limit=10` calls:

| statement | count | total |
|---|---|---|
| `SET autocommit=?` | 2,743,660 | 62.3 s |
| `SELECT ee1_0...` (the actual data) | 137,291 | 37.5 s |
| `SET SESSION TRANSACTION READ WRITE` | 1,372,151 | 33.2 s |
| `SET SESSION TRANSACTION READ ONLY` | 1,372,150 | 30.3 s |
| `COMMIT` | 1,372,394 | 27.3 s |

Exactly **10 transactions per request** — the page size. Cause:
`ExpenseService.toDTO()` calls `householdMemberSummaryRepo.findById()` once per
row, and `getExpense()` has no `@Transactional`, so each of those opens and
commits its own transaction. Only one `SELECT` actually reaches disk (open-in-view
keeps a persistence context alive so the rest hit the first-level cache), but the
transaction bookkeeping is real: **~153 s of round-trips versus 37.5 s for the
query itself — 4x more time on transaction management than on data.**

Fixed by one annotation on `ExpenseService.getExpense` (applied 2026-07-29).
Note the file's import had to move from `jakarta.transaction.Transactional`,
which has no `readOnly` attribute, to `org.springframework.transaction.annotation.Transactional`.

Same digest query re-run afterwards, over 67,228 requests:

| statement | before (per request) | after (per request) |
|---|---|---|
| `SET SESSION TRANSACTION READ WRITE` | 10.0 | **1.0** |
| transaction overhead in MySQL time | 1.11 ms | **0.16 ms** |

10 transactions per request collapsed to exactly 1, a 7x cut in transaction
bookkeeping. See the latency table above for what that was worth end to end.

## Extending it

The default mix is read-only on purpose — writes grow the DB every run and
publish to Kafka, so repeated runs aren't comparable. To load-test the write
path, add a `POST /households/{id}/expenses` branch using `MEMBER_ID` from
`perf/.env`, and reset the DB between runs. Note that splits must sum exactly
to the expense amount, and for `method: EQUAL` every split must be equal
(`ExpenseValidation.java:44-66`).
