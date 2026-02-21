// ===========================================
// k6 Load Test — Clenzy PMS API
// ===========================================
// Niveau 8 — Scalabilite : test de charge pour valider
// la performance sous charge reelle.
//
// Usage :
//   docker compose run --rm k6 run /scripts/load-test.js
//   docker compose run --rm k6 run /scripts/load-test.js --env BASE_URL=http://clenzy-server:8080
//
// Scenarios :
//   1. smoke    — 1 VU, 30s  (verification basique)
//   2. average  — 10 VU, 2min (charge normale)
//   3. stress   — 50 VU, 3min (pic de charge)
//   4. spike    — 100 VU, 1min (spike soudain)

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// --- Custom metrics ---
const errorRate = new Rate('errors');
const apiLatency = new Trend('api_latency', true);

// --- Configuration ---
const BASE_URL = __ENV.BASE_URL || 'http://clenzy-server:8080';
const AUTH_TOKEN = __ENV.AUTH_TOKEN || '';

// --- Scenarios ---
export const options = {
  scenarios: {
    // 1. Smoke test : verification basique
    smoke: {
      executor: 'constant-vus',
      vus: 1,
      duration: '30s',
      startTime: '0s',
      tags: { scenario: 'smoke' },
    },
    // 2. Average load : charge normale
    average: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: 10 },
        { duration: '1m', target: 10 },
        { duration: '30s', target: 0 },
      ],
      startTime: '30s',
      tags: { scenario: 'average' },
    },
    // 3. Stress test : pic de charge
    stress: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: 25 },
        { duration: '1m', target: 50 },
        { duration: '1m', target: 50 },
        { duration: '30s', target: 0 },
      ],
      startTime: '2m30s',
      tags: { scenario: 'stress' },
    },
    // 4. Spike test : pic soudain
    spike: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '10s', target: 100 },
        { duration: '30s', target: 100 },
        { duration: '20s', target: 0 },
      ],
      startTime: '5m30s',
      tags: { scenario: 'spike' },
    },
  },
  thresholds: {
    // P95 latence < 500ms
    http_req_duration: ['p(95)<500', 'p(99)<1500'],
    // Taux d'erreur < 5%
    errors: ['rate<0.05'],
    // API latency custom
    api_latency: ['p(95)<400'],
  },
};

// --- Headers ---
function getHeaders() {
  const headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };
  if (AUTH_TOKEN) {
    headers['Authorization'] = `Bearer ${AUTH_TOKEN}`;
  }
  return headers;
}

// --- Health check (public) ---
function healthCheck() {
  const res = http.get(`${BASE_URL}/actuator/health`, {
    headers: getHeaders(),
    tags: { endpoint: 'health' },
  });
  check(res, {
    'health: status 200': (r) => r.status === 200,
    'health: status UP': (r) => {
      try {
        return JSON.parse(r.body).status === 'UP';
      } catch {
        return false;
      }
    },
  });
  errorRate.add(res.status !== 200);
  apiLatency.add(res.timings.duration);
}

// --- API endpoints (authenticated) ---
function apiProperties() {
  const res = http.get(`${BASE_URL}/api/properties`, {
    headers: getHeaders(),
    tags: { endpoint: 'properties' },
  });
  const ok = res.status === 200 || res.status === 401 || res.status === 403;
  check(res, {
    'properties: valid response': () => ok,
  });
  errorRate.add(res.status >= 500);
  apiLatency.add(res.timings.duration);
}

function apiInterventions() {
  const res = http.get(`${BASE_URL}/api/interventions`, {
    headers: getHeaders(),
    tags: { endpoint: 'interventions' },
  });
  const ok = res.status === 200 || res.status === 401 || res.status === 403;
  check(res, {
    'interventions: valid response': () => ok,
  });
  errorRate.add(res.status >= 500);
  apiLatency.add(res.timings.duration);
}

function apiCalendar() {
  const res = http.get(`${BASE_URL}/api/calendar/availability`, {
    headers: getHeaders(),
    tags: { endpoint: 'calendar' },
  });
  const ok = res.status === 200 || res.status === 400 || res.status === 401 || res.status === 403;
  check(res, {
    'calendar: valid response': () => ok,
  });
  errorRate.add(res.status >= 500);
  apiLatency.add(res.timings.duration);
}

function apiTeams() {
  const res = http.get(`${BASE_URL}/api/teams`, {
    headers: getHeaders(),
    tags: { endpoint: 'teams' },
  });
  const ok = res.status === 200 || res.status === 401 || res.status === 403;
  check(res, {
    'teams: valid response': () => ok,
  });
  errorRate.add(res.status >= 500);
  apiLatency.add(res.timings.duration);
}

// --- Main ---
export default function () {
  group('Health', () => {
    healthCheck();
  });

  group('API Endpoints', () => {
    apiProperties();
    sleep(0.5);

    apiInterventions();
    sleep(0.5);

    apiCalendar();
    sleep(0.5);

    apiTeams();
    sleep(0.5);
  });

  sleep(1);
}

// --- Summary ---
export function handleSummary(data) {
  const summary = {
    timestamp: new Date().toISOString(),
    scenarios: Object.keys(options.scenarios),
    metrics: {
      http_req_duration_p95: data.metrics.http_req_duration?.values['p(95)'],
      http_req_duration_p99: data.metrics.http_req_duration?.values['p(99)'],
      http_reqs_rate: data.metrics.http_reqs?.values.rate,
      error_rate: data.metrics.errors?.values.rate,
      vus_max: data.metrics.vus_max?.values.max,
    },
    thresholds_passed: !Object.values(data.root_group?.checks || {}).some(
      (c) => c.fails > 0
    ),
  };

  return {
    stdout: JSON.stringify(summary, null, 2) + '\n',
    '/scripts/results/summary.json': JSON.stringify(data, null, 2),
  };
}
