/**
 * DialCore — 1000 Concurrent Agent Load Test
 *
 * Stages:
 *   1. Ramp-up   : 0 → 1000 VUs over 60 s
 *   2. Sustained : 1000 VUs for 120 s
 *   3. Ramp-down : 1000 → 0 VUs over 30 s
 *
 * Each VU represents one agent:
 *   - POST /api/auth/login
 *   - GET  /api/agent-desktop/profile
 *   - GET  /api/agent-desktop/dial-options
 *   - GET  /api/agent-desktop/my-calls
 *   - GET  /api/agent-desktop/my-followups
 *   - WebSocket /hubs/agent  → SignalR handshake + SetState(READY)
 *   - Repeat API churn in loop
 */

import http from 'k6/http';
import ws   from 'k6/ws';
import { check, sleep }                  from 'k6';
import { Counter, Trend, Rate, Gauge }   from 'k6/metrics';

// ── Config ────────────────────────────────────────────────────────────────────
const BASE_URL    = __ENV.BASE_URL    || 'http://localhost:5006';
const WS_URL      = __ENV.WS_URL      || 'ws://localhost:5006';
const AGENT_COUNT = parseInt(__ENV.AGENT_COUNT || '1000');
const AGENT_PW    = __ENV.AGENT_PW    || 'LoadTest@123';

// ── Custom metrics ─────────────────────────────────────────────────────────────
const loginErrors    = new Counter('login_errors');
const wsErrors       = new Counter('ws_errors');
const loginDuration  = new Trend('login_duration_ms',   true);
const profileDuration= new Trend('profile_duration_ms', true);
const campaignDur    = new Trend('campaigns_duration_ms',true);
const callsDuration  = new Trend('my_calls_duration_ms', true);
const successRate    = new Rate('success_rate');
const activeAgents   = new Gauge('active_agents');

// ── Load profile ──────────────────────────────────────────────────────────────
export const options = {
  scenarios: {
    agents: {
      executor:        'ramping-vus',
      startVUs:        0,
      stages: [
        { duration: '60s',  target: AGENT_COUNT },
        { duration: '120s', target: AGENT_COUNT },
        { duration: '30s',  target: 0           },
      ],
      gracefulRampDown: '15s',
    },
  },
  thresholds: {
    http_req_failed:       ['rate<0.02'],
    http_req_duration:     ['p(95)<3000'],
    login_duration_ms:     ['p(95)<4000'],
    profile_duration_ms:   ['p(95)<1000'],
    campaigns_duration_ms: ['p(95)<1500'],
    my_calls_duration_ms:  ['p(95)<1500'],
    success_rate:          ['rate>0.98'],
    ws_errors:             ['count<100'],
  },
  noConnectionReuse: false,
};

// ── Helpers ───────────────────────────────────────────────────────────────────
function agentEmail(vuId) {
  const idx = ((vuId - 1) % AGENT_COUNT) + 1;
  return `loadagent${String(idx).padStart(4, '0')}@test.dialcore`;
}

function bearer(token) {
  return { headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' } };
}

function ms() { return Date.now(); }

function rndSleep(minMs, maxMs) {
  sleep((minMs + Math.random() * (maxMs - minMs)) / 1000);
}

// SignalR JSON protocol handshake + SetState invocation
function buildSignalRHandshake() {
  return '{"protocol":"json","version":1}\x1e';
}
function buildSetState(state) {
  return JSON.stringify({ type: 1, target: 'SetState', arguments: [state] }) + '\x1e';
}

// ── Main VU ───────────────────────────────────────────────────────────────────
export default function () {
  const email = agentEmail(__VU);

  // ─ 1. Login ──────────────────────────────────────────────────────────────
  const t0 = ms();
  const loginRes = http.post(
    `${BASE_URL}/api/auth/login`,
    JSON.stringify({ email, password: AGENT_PW }),
    { headers: { 'Content-Type': 'application/json' } }
  );
  loginDuration.add(ms() - t0);

  let body;
  try { body = JSON.parse(loginRes.body); } catch { body = {}; }

  const loginOk = check(loginRes, {
    'login 200':          r => r.status === 200,
    'has accessToken':    () => !!body.accessToken,
  });

  if (!loginOk) {
    loginErrors.add(1);
    successRate.add(false);
    sleep(3);
    return;
  }

  successRate.add(true);
  activeAgents.add(1);
  const token = body.accessToken;
  const auth  = bearer(token);

  rndSleep(50, 300);

  // ─ 2. Profile ─────────────────────────────────────────────────────────────
  const t1 = ms();
  const profRes = http.get(`${BASE_URL}/api/agent-desktop/profile`, auth);
  profileDuration.add(ms() - t1);
  check(profRes, { 'profile 200': r => r.status === 200 });

  rndSleep(50, 150);

  // ─ 3. Dial options ────────────────────────────────────────────────────────
  const dialRes = http.get(`${BASE_URL}/api/agent-desktop/dial-options`, auth);
  check(dialRes, { 'dial-options 200': r => r.status === 200 });

  rndSleep(50, 150);

  // ─ 4. My follow-ups (callbacks scheduled) ────────────────────────────────
  const t2 = ms();
  const campRes = http.get(`${BASE_URL}/api/agent-desktop/my-followups?page=1&pageSize=20`, auth);
  campaignDur.add(ms() - t2);
  check(campRes, { 'my-followups 200': r => r.status === 200 });

  rndSleep(100, 300);

  // ─ 5. My calls ────────────────────────────────────────────────────────────
  const t3 = ms();
  const callRes = http.get(`${BASE_URL}/api/agent-desktop/my-calls?page=1&pageSize=10`, auth);
  callsDuration.add(ms() - t3);
  check(callRes, { 'my-calls 200': r => r.status === 200 });

  rndSleep(100, 300);

  // ─ 6. SignalR connect + SetState READY ───────────────────────────────────
  const wsEndpoint = `${WS_URL}/hubs/agent?access_token=${token}`;
  let wsConnected = false;
  let wsHandshakeDone = false;

  try {
    const wsRes = ws.connect(wsEndpoint, {}, function (socket) {
      socket.on('open', () => {
        wsConnected = true;
        socket.send(buildSignalRHandshake());
      });

      socket.on('message', (data) => {
        const frames = data.split('\x1e').filter(f => f.trim());
        for (const frame of frames) {
          try {
            const msg = JSON.parse(frame);
            // Type 6 = ping, empty frame = handshake ack
            if (!wsHandshakeDone && (frame === '{}' || msg.type === undefined)) {
              wsHandshakeDone = true;
              // Send SetState READY via SignalR hub method
              socket.send(buildSetState('READY'));
            }
          } catch { /* incomplete frame */ }
        }
      });

      socket.on('error', () => wsErrors.add(1));
      // Hold connection open for realistic dwell time then disconnect
      socket.setTimeout(() => socket.close(), 4000);
    });

    check(wsRes, { 'WS 101 Switching Protocols': r => r && r.status === 101 });
    if (!wsConnected) wsErrors.add(1);
  } catch {
    wsErrors.add(1);
  }

  rndSleep(500, 1500);

  // ─ 7. Second API churn iteration (sustained load) ────────────────────────
  http.get(`${BASE_URL}/api/agent-desktop/profile`, auth);
  rndSleep(200, 600);
  http.get(`${BASE_URL}/api/agent-desktop/my-followups?page=1&pageSize=20`, auth);
  rndSleep(200, 500);
  http.get(`${BASE_URL}/api/agent-desktop/current-break`, auth);

  activeAgents.add(-1);
  rndSleep(300, 700);
}

// ── Summary ───────────────────────────────────────────────────────────────────
export function handleSummary(data) {
  const m = data.metrics;
  const p = (metric, pct) => {
    const v = m[metric]?.values?.[`p(${pct})`];
    return v != null ? `${v.toFixed(1)}ms` : 'N/A';
  };
  const cnt  = (k) => m[k]?.values?.count  ?? 0;
  const rate = (k) => ((m[k]?.values?.rate ?? 0) * 100).toFixed(2) + '%';
  const val  = (k) => m[k]?.values?.value  ?? m[k]?.values?.max ?? 'N/A';

  const lines = [
    '',
    '╔══════════════════════════════════════════════════════╗',
    '║     DialCore — 1000-Agent Load Test Results          ║',
    '╠══════════════════════════════════════════════════════╣',
    `║  Peak VUs              : ${String(val('vus_max')).padEnd(27)}║`,
    `║  Total HTTP requests   : ${String(cnt('http_reqs')).padEnd(27)}║`,
    `║  Throughput (RPS)      : ${String((m.http_reqs?.values?.rate??0).toFixed(1)+'/s').padEnd(27)}║`,
    `║  HTTP error rate       : ${rate('http_req_failed').padEnd(27)}║`,
    `║  Overall success rate  : ${rate('success_rate').padEnd(27)}║`,
    '╠══════════════════════════════════════════════════════╣',
    `║  Login        p50/p95  : ${(p('login_duration_ms',50)+' / '+p('login_duration_ms',95)).padEnd(27)}║`,
    `║  Profile      p50/p95  : ${(p('profile_duration_ms',50)+' / '+p('profile_duration_ms',95)).padEnd(27)}║`,
    `║  Campaigns    p50/p95  : ${(p('campaigns_duration_ms',50)+' / '+p('campaigns_duration_ms',95)).padEnd(27)}║`,
    `║  My Calls     p50/p95  : ${(p('my_calls_duration_ms',50)+' / '+p('my_calls_duration_ms',95)).padEnd(27)}║`,
    `║  HTTP overall p50/p95  : ${(p('http_req_duration',50)+' / '+p('http_req_duration',95)).padEnd(27)}║`,
    '╠══════════════════════════════════════════════════════╣',
    `║  Login errors          : ${String(cnt('login_errors')).padEnd(27)}║`,
    `║  WS connect errors     : ${String(cnt('ws_errors')).padEnd(27)}║`,
    '╚══════════════════════════════════════════════════════╝',
    '',
  ];

  lines.forEach(l => console.log(l));

  return { 'load-test-results.json': JSON.stringify(data, null, 2) };
}
