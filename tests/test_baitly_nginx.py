"""Exercise the production nginx template against a local canary upstream; no Docker."""
import http.client
import http.server
import json
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
NGINX = os.environ.get('NGINX_BINARY', 'nginx')


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def remap_listener_ports(conf, http_port, https_port):
    # One pass: an assigned HTTP port beginning with 443 must not be remapped again.
    ports = {'80': http_port, '443': https_port}
    return re.sub(r'(?m)^(\s*listen\s+)(80|443)(?=\s|;)',
                  lambda match: match[1] + str(ports[match[2]]), conf)


class ListenerPortRemapping(unittest.TestCase):
    def test_http_port_starting_with_https_digits_is_not_rewritten_twice(self):
        conf = '    listen 80;\n    listen 443 ssl;\n'
        self.assertEqual(remap_listener_ports(conf, 44367, 59671),
                         '    listen 44367;\n    listen 59671 ssl;\n')

    def test_other_listener_ports_are_preserved(self):
        conf = 'listen 8080;\nlisten 44300 ssl;\nlisten 80 default_server;\n'
        self.assertEqual(remap_listener_ports(conf, 49152, 55000),
                         'listen 8080;\nlisten 44300 ssl;\nlisten 49152 default_server;\n')


class Upstream(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/api/baitly-proxy-transport-failure'):
            self.connection.shutdown(socket.SHUT_RDWR)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('X-Test-Forwarded-For', self.headers.get('X-Forwarded-For', ''))
        self.end_headers()
        self.wfile.write(b'canary upstream response')

    do_POST = do_GET

    def log_message(self, *_):
        pass


class NginxSecurity(unittest.TestCase):
    def start_nginx(self, lockdown=False, trusted=False, app_domain='app.baitly.test'):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        directory = Path(self.temp.name)
        (directory / 'logs').mkdir()
        self.log = directory / 'access.log'
        self.http_port, self.https_port = port(), port()
        upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        threading.Thread(target=upstream.serve_forever, daemon=True).start()
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        for source in (ROOT / 'nginx/baitly').glob('*.conf'):
            (directory / source.name).write_text(source.read_text().replace('/var/log/nginx/', str(directory) + '/'))
        if trusted:
            with (directory / 'cloudflare-networks.conf').open('a') as f:
                f.write('127.0.0.1/32 1;\n')  # Test transport peer only, never production.
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=baitly.test', '-keyout', str(directory / 'privkey.pem'),
                        '-out', str(directory / 'fullchain.pem')], check=True, capture_output=True)
        conf = (ROOT / 'nginx/nginx.conf.template').read_text()
        substitutions = dict(DOMAIN='baitly.test', APP_DOMAIN=app_domain, AUTH_DOMAIN='auth.baitly.test',
                             MONITORING_DOMAIN='monitoring.baitly.test', PROMETHEUS_DOMAIN='prometheus.baitly.test',
                             KAFKA_UI_DOMAIN='kafka.baitly.test', SITE_DOMAIN='site.baitly.test',
                             ROOT_SITE_SERVER='clenzy-landing', CERTBOT_CERT_NAME='baitly.test',
                             BAITLY_ORIGIN_LOCKDOWN='1' if lockdown else '0')
        for key, value in substitutions.items():
            conf = conf.replace('${' + key + '}', value)
        conf = conf.replace('worker_processes auto;', 'worker_processes 1;').replace('    use epoll;', '')
        conf = conf.replace('include /etc/nginx/mime.types;', '')
        conf = conf.replace('/etc/nginx/baitly/', str(directory) + '/')
        conf = conf.replace('/etc/letsencrypt/live/baitly.test/', str(directory) + '/')
        conf = conf.replace('/var/log/nginx/', str(directory) + '/')
        conf = conf.replace('/var/run/nginx.pid', str(directory / 'nginx.pid'))
        conf = conf.replace('/var/www/certbot', str(directory))
        conf = remap_listener_ports(conf, self.http_port, self.https_port)
        conf = re.sub(r'(clenzy-[a-z-]+|baitly-site|grafana|prometheus|kafka-ui):\d+',
                      f'127.0.0.1:{upstream.server_port}', conf)
        conf = conf.replace('http://baitly-site;', f'http://127.0.0.1:{upstream.server_port};')
        (directory / '.well-known/acme-challenge').mkdir(parents=True)
        (directory / '.well-known/acme-challenge/test-token').write_text('acme')
        path = directory / 'nginx.conf'
        path.write_text(conf)
        result = subprocess.run([NGINX, '-t', '-p', str(directory), '-c', str(path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        process = subprocess.Popen([NGINX, '-p', str(directory), '-c', str(path), '-g', 'daemon off;'],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        def stop():
            process.terminate()
            process.wait(timeout=5)
        self.addCleanup(stop)
        for _ in range(50):
            try:
                with socket.create_connection(('127.0.0.1', self.https_port), timeout=.1):
                    return
            except OSError:
                time.sleep(.05)
        self.fail('nginx did not start')

    def request(self, path, host='app.baitly.test', method='GET', headers=None, secure=True):
        connection = http.client.HTTPConnection('127.0.0.1', self.https_port if secure else self.http_port, timeout=3)
        connection.connect()
        if secure:
            connection.sock = ssl._create_unverified_context().wrap_socket(connection.sock, server_hostname=host)
        try:
            connection.request(method, path, headers={'Host': host, **(headers or {})})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def assert_pms_sentry_policy(self, domain):
        self.start_nginx(app_domain=domain)
        status, headers, _ = self.request('/', host=domain)
        self.assertEqual(status, 200)
        policy = headers['Content-Security-Policy']
        self.assertIn('https://o4512297046048768.ingest.de.sentry.io', policy)
        self.assertNotIn('https://*.sentry.io', policy)
        self.assertIn("object-src 'self' blob:", policy)
        status, headers, _ = self.request('/', host='site.baitly.test')
        self.assertEqual(status, 200)
        self.assertNotIn('ingest.de.sentry.io', headers['Content-Security-Policy'])

    def test_staging_sentry_ingestion_is_limited_to_one_eu_organization(self):
        self.assert_pms_sentry_policy('app.clenzy.fr')

    def test_production_sentry_ingestion_is_limited_to_one_eu_organization(self):
        self.assert_pms_sentry_policy('app.baitly.fr')

    def test_sensitive_paths_headers_discovery_and_limits(self):
        self.start_nginx()
        for host in ('baitly.test', 'app.baitly.test', 'site.baitly.test'):
            for path in ('/v1/.env', '/.env~', '/github/.env', '/.env.swp', '/app/.env.local',
                         '/.env.testing', '/.git/config', '/.git/leak.js', '/%2egit/leak.css', '/backup.sql'):
                status, headers, _ = self.request(path, host)
                self.assertEqual(status, 403, (host, path))
                self.assertEqual(headers['X-Content-Type-Options'], 'nosniff')
            for path in ('/', '/baitly-config.js', '/assets/app.js', '/health'):
                status, headers, _ = self.request(path, host)
                self.assertEqual(status, 200, (host, path))
                self.assertIn('Strict-Transport-Security', headers)
                self.assertIn('https://challenges.cloudflare.com', headers['Content-Security-Policy'])
                self.assertNotIn('ingest.de.sentry.io', headers['Content-Security-Policy'])
                self.assertNotIn('nginx/', headers.get('Server', ''))
                if path == '/baitly-config.js':
                    self.assertIn('no-store', headers['Cache-Control'])
        for path in ('/.well-known/api-catalog', '/.well-known/agent-skills/sample/SKILL.md'):
            self.assertEqual(self.request(path, 'baitly.test')[0], 200)
        self.assertEqual(self.request('/realms/clenzy/.well-known/openid-configuration', 'auth.baitly.test')[0], 200)
        self.assertEqual(self.request('/.well-known/.env')[0], 403)
        self.request('/api/documents/PRIVATE_TOKEN?ticket=SECRET_QUERY')
        self.request('/invite/PRIVATE_TOKEN?code=SECRET_QUERY')
        _, forwarded, _ = self.request('/api/test', headers={'X-Forwarded-For': '1.2.3.4', 'CF-Connecting-IP': '1.2.3.4'})
        self.assertEqual(forwarded['X-Test-Forwarded-For'], '127.0.0.1')
        statuses = [self.request('/api/auth/login', method='POST')[0] for _ in range(15)]
        self.assertIn(429, statuses)
        self.assertEqual(self.request('/api/auth/refresh', method='POST')[0], 200)
        text = self.log.read_text()
        self.assertNotIn('PRIVATE_TOKEN', text)
        self.assertNotIn('SECRET_QUERY', text)
        records = [json.loads(line) for line in text.splitlines()]
        self.assertTrue(any(row['status'] == 403 for row in records))
        self.assertTrue(any(row['status'] == 429 for row in records))

    def test_origin_gate_cannot_be_bypassed_with_forwarded_headers(self):
        self.start_nginx(lockdown=True)
        self.assertEqual(self.request('/', headers={'CF-Connecting-IP': '173.245.48.1',
                                                   'X-Forwarded-For': '173.245.48.1'})[0], 403)
        self.assertEqual(self.request('/.well-known/acme-challenge/test-token', secure=False)[0], 200)
        self.assertEqual(self.request('/api/auth/login', secure=False)[0], 403)
        with self.assertRaises(ssl.SSLError):
            self.request('/', host='unrecognized.example')

    def test_origin_gate_allows_a_trusted_transport_peer(self):
        self.start_nginx(lockdown=True, trusted=True)
        self.assertEqual(self.request('/')[0], 200)

    def test_private_requests_and_upstream_errors_only_emit_technical_fields(self):
        self.start_nginx(trusted=True)
        private = 'SYNTHETIC_PRIVATE_token_email_PIN'
        headers = {'Authorization': 'Bearer ' + private, 'Cookie': 'session=' + private,
                   'Referer': 'https://example.test/' + private, 'User-Agent': private,
                   'CF-Ray': private, 'CF-Connecting-IP': '198.51.100.42'}
        status, forwarded, _ = self.request('/api/documents/' + private + '?secret=' + private, headers=headers)
        self.assertEqual(status, 200)
        self.assertEqual(forwarded['X-Test-Forwarded-For'], '127.0.0.1')
        self.assertEqual(self.request('/api/baitly-proxy-transport-failure/' + private + '?secret=' + private,
                                      headers=headers)[0], 502)
        self.assertEqual(self.request('/api/test', method='PRIVATESECRET', headers=headers)[0], 501)
        text = self.log.read_text()
        for value in [private, 'PRIVATESECRET', '198.51.100.42', '127.0.0.1', 'Bearer', 'example.test', 'app.baitly.test']:
            self.assertNotIn(value, text)
        records = [json.loads(line) for line in text.splitlines()]
        self.assertEqual({row['status'] for row in records}, {200, 501, 502})
        for row in records:
            self.assertEqual(set(row), {'diagnostic', 'timestamp', 'method', 'path', 'status',
                                        'upstream_status', 'request_time'})
            self.assertEqual(row['diagnostic'], 'BAITLY_PROXY_ACCESS')
            self.assertEqual(row['path'], '/api/[redacted]')
        self.assertEqual(records[-1]['method'], 'OTHER')
        # Native nginx errors otherwise echo the request and transport IP. No raw file is created.
        self.assertFalse((Path(self.temp.name) / 'error.log').exists())

    def test_legacy_proxy_uses_the_same_private_logging_policy(self):
        legacy = (ROOT / 'nginx/nginx.conf').read_text()
        self.assertIn('include /etc/nginx/baitly/proxy-logging.conf;', legacy)
        self.assertIn('error_log /dev/null;', legacy)
        self.assertNotIn('log_format main', legacy)


if __name__ == '__main__':
    unittest.main()
