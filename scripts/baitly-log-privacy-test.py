#!/usr/bin/env python3
"""Exercise the real Promtail pipeline offline. No Loki, Docker or business data."""
import argparse
from pathlib import Path
import subprocess
import tempfile
import os
import select
import time

ROOT = Path(__file__).resolve().parents[1]


def verify(binary):
    text = (ROOT / 'monitoring/promtail/promtail-config.yml').read_text()
    _, found, stages = text.partition('    pipeline_stages:\n')
    if not found:
        raise AssertionError('Missing production pipeline')
    private = 'SYNTHETIC_PRIVATE_email@example.test_token_PIN_92841'
    safe = {
        'kafka': '{"diagnostic":"BAITLY_BROKER","level":"ERROR","timestamp":"2026-10-24T11:00:00.123Z"}',
        'nginx': '{"diagnostic":"BAITLY_PROXY_ACCESS","timestamp":"2026-10-24T11:00:00+00:00","method":"OTHER","path":"/api/[redacted]","status":502,"upstream_status":"502","request_time":0.001}',
    }
    for service in ('pms-client', 'baitly-site', 'landing'):
        safe[service] = safe['nginx']
    with tempfile.TemporaryDirectory(prefix='baitly-log-contract-') as directory:
        for service, record in safe.items():
            config = Path(directory) / (service + '.yml')
            config.write_text('server:\n  disable: true\npositions:\n  filename: ' + directory + '/positions.yml\n'
                              'clients:\n  - url: http://127.0.0.1:1/loki/api/v1/push\n'
                              'scrape_configs:\n  - job_name: stdin\n'
                              '    static_configs:\n      - targets: [localhost]\n'
                              '        labels:\n          service: ' + service + '\n'
                              '    pipeline_stages:\n' + stages)
            variants = [private, '{"message":"' + private + '"}', record[:-1] + ',"payload":"' + private + '"}',
                        record + private, private + record, 'Caused by: ' + private]
            # Promtail's stdin target can exit on EOF before its pipeline drains. Keep stdin
            # open until a final safe sentinel traverses the real pipeline after all canaries.
            with tempfile.TemporaryFile() as errors:
                process = subprocess.Popen([str(binary), '-config.file=' + str(config), '-stdin', '-dry-run',
                                            '-log.level=error', '-server.disable'],
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
                output = b''
                try:
                    process.stdin.write(('\n'.join([record, *variants, record]) + '\n').encode())
                    process.stdin.flush()
                    deadline = time.monotonic() + 10
                    while output.count(record.encode()) < 2 and time.monotonic() < deadline:
                        if select.select([process.stdout], [], [], .1)[0]:
                            chunk = os.read(process.stdout.fileno(), 65536)
                            if not chunk:
                                break
                            output += chunk
                    process.stdin.close()
                    process.stdin = None
                    remaining, _ = process.communicate(timeout=10)
                    output += remaining
                    errors.seek(0)
                    output += errors.read()
                    decoded = output.decode(errors='replace')
                    if process.returncode or private in decoded or decoded.count(record) != 2:
                        raise AssertionError('Promtail privacy contract failed for ' + service + ' (output withheld)')
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)
    print('Baitly collector contract: 10 safe records retained, 30 unsafe records rejected; no Loki connection')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--promtail', required=True, type=Path)
    verify(parser.parse_args().promtail)
