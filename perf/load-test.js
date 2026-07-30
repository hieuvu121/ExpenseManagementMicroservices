// Load test for the ExpenseManagement gateway.
//
//   ./perf/seed.sh                                  # once, to get a token
//   set -a && . ./perf/.env && set +a               # export JWT / HOUSEHOLD_ID
//   k6 run perf/load-test.js                        # fixed-RPS (default)
//   MODE=ramp k6 run perf/load-test.js              # concurrency ramp
//   RPS=200 k6 run perf/load-test.js                # override target rate
//
// MODE=rps  answers "can it sustain N requests/sec?" — an open model, so a
//           slow server can't throttle its own load. Watch dropped_iterations.
// MODE=ramp answers "how many concurrent users before latency breaks?"
import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';

const BASE = __ENV.BASE_URL || 'http://localhost:8080/app/v1';
const JWT = __ENV.JWT;
const HOUSEHOLD_ID = __ENV.HOUSEHOLD_ID;
const RPS = Number(__ENV.RPS || 100);
const MODE = __ENV.MODE || 'rps';

if (!JWT || !HOUSEHOLD_ID) {
  throw new Error('JWT and HOUSEHOLD_ID required — run ./perf/seed.sh, then: set -a && . ./perf/.env && set +a');
}

// Per-endpoint latency, so a slow one isn't hidden by the aggregate.
const expensesList = new Trend('ep_expenses_list', true);
const householdsMy = new Trend('ep_households_my', true);

const scenarios = {
  rps: {
    executor: 'constant-arrival-rate',
    rate: RPS,
    timeUnit: '1s',
    duration: '1m',
    preAllocatedVUs: Math.ceil(RPS / 2),
    maxVUs: RPS * 4,
    gracefulStop: '10s',
  },
  ramp: {
    executor: 'ramping-vus',
    startVUs: 1,
    stages: [
      { duration: '20s', target: 10 },
      { duration: '30s', target: 50 },
      { duration: '30s', target: 100 },
      { duration: '20s', target: 0 },
    ],
    gracefulRampDown: '10s',
  },
};

export const options = {
  scenarios: { [MODE]: scenarios[MODE] },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500', 'p(99)<1500'],
    ep_expenses_list: ['p(95)<500'],
    ep_households_my: ['p(95)<300'],
  },
  // JVM JIT + Hibernate pool fill make the first seconds meaningless.
  // Discard them rather than letting them poison the percentiles.
  discardResponseBodies: false,
};

const params = {
  headers: {
    Authorization: `Bearer ${JWT}`,
    'Content-Type': 'application/json',
  },
};

export default function () {
  // Weighted read mix — the expenses list is the hot path (cursor-paginated,
  // crosses the gateway into expense-service), so it gets most of the traffic.
  const roll = Math.random();

  if (roll < 0.75) {
    const res = http.get(
      `${BASE}/households/${HOUSEHOLD_ID}/expenses?limit=10`,
      { ...params, tags: { name: 'expenses_list' } },
    );
    expensesList.add(res.timings.duration);
    check(res, {
      'expenses 200': (r) => r.status === 200,
      'expenses has data array': (r) => {
        try { return Array.isArray(r.json('data')); } catch { return false; }
      },
    });
  } else {
    const res = http.get(`${BASE}/households/my`, {
      ...params,
      tags: { name: 'households_my' },
    });
    householdsMy.add(res.timings.duration);
    check(res, { 'households 200': (r) => r.status === 200 });
  }
}
