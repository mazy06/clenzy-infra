// ===========================================
// k6 Smoke Test — Clenzy PMS API
// ===========================================
// Test rapide pour verifier que l'API repond correctement.
// Usage : docker compose run --rm k6 run /scripts/smoke-test.js

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://clenzy-server:8080';

export const options = {
  vus: 1,
  duration: '10s',
  thresholds: {
    http_req_duration: ['p(95)<1000'],
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  // 1. Health check
  const health = http.get(`${BASE_URL}/actuator/health`);
  check(health, {
    'health: status 200': (r) => r.status === 200,
  });

  // 2. Prometheus metrics endpoint
  const metrics = http.get(`${BASE_URL}/actuator/prometheus`);
  check(metrics, {
    'prometheus: status 200': (r) => r.status === 200,
  });

  // 3. Info endpoint
  const info = http.get(`${BASE_URL}/actuator/info`);
  check(info, {
    'info: status 200': (r) => r.status === 200,
  });

  sleep(1);
}
