// k6 scenarios for the Bier vs PostgREST HTTP benchmark.
//
//   BASE_URL      target server, e.g. http://127.0.0.1:3001
//   SCENARIO      r1 | r2 | m1 | m2
//   STAGE         ceiling (closed-loop constant-vus, finds max RPS)
//                 | latency (open-loop constant-arrival-rate, reads p50/p90/p99)
//   DURATION      stage length, default 60s
//   RATE          arrival rate for STAGE=latency (req/s)
//   VUS           VU count for STAGE=ceiling, default 100
//   SUMMARY_PATH  when set, the full summary JSON is written there
//
// Any non-2xx response fails the http_req_failed threshold -> non-zero exit.
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL;
const SCENARIO = __ENV.SCENARIO;
const STAGE = __ENV.STAGE || 'latency';
const DURATION = __ENV.DURATION || '60s';
const WARMUP = __ENV.WARMUP || '10s'; // latency stage only (continuous stream)
const RATE = parseInt(__ENV.RATE || '100', 10);
const VUS = parseInt(__ENV.VUS || '100', 10);

const ITEMS = 100000;   // bench.items row count (fixtures.sql)
const EVENTS = 10000;   // bench.events baseline row count (bench.reset_events())
const CATEGORIES = 20;  // distinct bench.items.category values

const THRESHOLDS = { http_req_failed: ['rate==0'] };
// The latency stage is only valid open-loop: if the VU pool can't sustain the
// target arrival rate, k6 sheds load (dropped_iterations) and the stage
// silently degrades into closed-loop — abort instead (warmup drops included:
// they poison the measured window). The thresholds on the phase:measure
// sub-metrics exist to materialize them in the summary for report.exs. None
// of these metrics are registered by the ceiling stage's constant-vus
// executor, so all three are gated on stage.
if (STAGE !== 'ceiling') {
  THRESHOLDS.dropped_iterations = ['count==0'];
  THRESHOLDS['http_req_duration{phase:measure}'] = ['p(99)>=0'];
  THRESHOLDS['http_reqs{phase:measure}'] = ['count>=0'];
}

// Pre-allocate the full pool: mid-stage VU allocation adds latency noise
// exactly when a server starts struggling.
const ARRIVAL = {
  executor: 'constant-arrival-rate',
  rate: RATE,
  timeUnit: '1s',
  preAllocatedVUs: 1000,
  maxVUs: 1000,
};

export const options = {
  summaryTrendStats: ['med', 'p(90)', 'p(99)', 'max'],
  thresholds: THRESHOLDS,
  scenarios:
    STAGE === 'ceiling'
      ? { bench: { executor: 'constant-vus', vus: VUS, duration: DURATION } }
      : {
          // One continuous arrival stream: the warmup phase flows straight
          // into the measured window. Separate warmup/measure k6 runs leave
          // a ~1s idle gap that stalls PostgREST's GHC idle GC and collapses
          // the next window (observed: a fresh server sustains the rate, the
          // post-gap window drops thousands of iterations). The report reads
          // only phase:measure.
          // The warmup ramps from 10% to the full rate: a cold server hit
          // with the full rate at t=0 measures boot transients, not steady
          // state, and can queue-spiral before it ever warms up.
          warmup: {
            executor: 'ramping-arrival-rate',
            startRate: Math.max(1, Math.floor(RATE / 10)),
            timeUnit: '1s',
            preAllocatedVUs: 1000,
            maxVUs: 1000,
            stages: [{ target: RATE, duration: WARMUP }],
            tags: { phase: 'warmup' },
          },
          measure: Object.assign({}, ARRIVAL, {
            startTime: WARMUP,
            duration: DURATION,
            tags: { phase: 'measure' },
          }),
        },
};

// Deterministic per-iteration PRNG (xorshift32) so both servers see the same
// request-id distribution. k6's Math.random is not seedable.
function prng(n) {
  let x = (n + 0x9e3779b9) >>> 0;
  x ^= x << 13; x >>>= 0;
  x ^= x >>> 17;
  x ^= x << 5; x >>>= 0;
  return x / 4294967296;
}

const JSON_HEADERS = { 'Content-Type': 'application/json' };

export default function () {
  const r = prng(__VU * 1000003 + __ITER);
  let res;
  if (SCENARIO === 'r1') {
    const id = 1 + Math.floor(r * ITEMS);
    res = http.get(`${BASE}/items?id=eq.${id}`);
  } else if (SCENARIO === 'r2') {
    const cat = 'category-' + String(1 + Math.floor(r * CATEGORIES)).padStart(2, '0');
    res = http.get(`${BASE}/items?category=eq.${cat}&order=id.desc&limit=25`);
  } else if (SCENARIO === 'm1') {
    res = http.post(
      `${BASE}/events`,
      JSON.stringify({ payload: `bench-${__VU}-${__ITER}`, occurred_at: '2026-07-09T00:00:00Z' }),
      { headers: Object.assign({ Prefer: 'return=minimal' }, JSON_HEADERS) }
    );
  } else if (SCENARIO === 'm2') {
    const id = 1 + Math.floor(r * EVENTS);
    res = http.patch(
      `${BASE}/events?id=eq.${id}`,
      JSON.stringify({ payload: `patched-${__VU}-${__ITER}` }),
      { headers: JSON_HEADERS }
    );
  } else {
    throw new Error(`unknown SCENARIO: ${SCENARIO}`);
  }
  check(res, { '2xx': (x) => x.status >= 200 && x.status < 300 });
}

export function handleSummary(data) {
  const out = {};
  if (__ENV.SUMMARY_PATH) out[__ENV.SUMMARY_PATH] = JSON.stringify(data, null, 2);
  return out;
}
