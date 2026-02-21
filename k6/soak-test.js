// ===========================================
// k6 Soak Test — Clenzy PMS API
// ===========================================
// Test d'endurance : charge moderee sur une longue duree
// pour detecter les fuites memoire, degradation progressive, etc.
//
// Usage : docker compose run --rm k6 run /scripts/soak-test.js
// Duree totale : ~35 minutes

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL || 'http://clenzy-server:8080';
const AUTH_TOKEN = __ENV.AUTH_TOKEN || '';
const errorRate = new Rate('errors');

export const options = {
  stages: [
    { duration: '2m', target: 20 },   // Ramp-up
    { duration: '30m', target: 20 },   // Soak
    { duration: '2m', target: 0 },     // Ramp-down
  ],
  thresholds: {
    http_req_duration: ['p(95)<800'],
    errors: ['rate<0.05'],
  },
};

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

export default function () {
  // Mix d'endpoints representatif de l'usage reel
  const endpoints = [
    '/actuator/health',
    '/api/properties',
    '/api/interventions',
    '/api/teams',
  ];

  const endpoint = endpoints[Math.floor(Math.random() * endpoints.length)];
  const res = http.get(`${BASE_URL}${endpoint}`, {
    headers: getHeaders(),
    tags: { endpoint: endpoint },
  });

  check(res, {
    'status < 500': (r) => r.status < 500,
  });

  errorRate.add(res.status >= 500);
  sleep(Math.random() * 2 + 0.5); // 0.5-2.5s entre requetes
}

export function handleSummary(data) {
  return {
    stdout: `\n=== SOAK TEST RESULTS ===\n` +
      `P95 latency: ${data.metrics.http_req_duration?.values['p(95)']?.toFixed(0)}ms\n` +
      `Error rate: ${(data.metrics.errors?.values.rate * 100)?.toFixed(2)}%\n` +
      `Total requests: ${data.metrics.http_reqs?.values.count}\n` +
      `RPS: ${data.metrics.http_reqs?.values.rate?.toFixed(1)}\n\n`,
    '/scripts/results/soak-summary.json': JSON.stringify(data, null, 2),
  };
}
