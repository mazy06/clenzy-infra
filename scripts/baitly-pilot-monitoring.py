#!/usr/bin/env python3
"""Baitly internal monitoring checks. Never print payloads, labels or credentials."""
import argparse
import datetime as dt
import ipaddress
import json
import math
import pathlib
import subprocess
import time
import urllib.parse
import urllib.request

RULES = {
    "ClenzyDeployFailed", "ClenzyDeployStale", "ClenzyBackendDown", "ClenzyDocGenFailures",
    "BaitlyBackendHigh5xx", "BaitlyBackendSlow", "BaitlyDatabasePoolSaturated",
    "BaitlyJvmHeapPressure", "BaitlyBackendDiskLow", "BaitlyOperationalMetricsUnavailable",
    "BaitlyOperationalMetricsStale", "BaitlyOutboxExhausted", "BaitlyOutboxStalled",
    "BaitlyWebhookDeliveryStalled", "BaitlyWebhookDisabled", "BaitlyChannelSyncFailures",
    "BaitlyRecoveryMetricsUnavailable", "BaitlyRecoveryMetricsStale",
    "BaitlyAccountingExportStalled", "BaitlyAccountingExportUncertain",
    "BaitlyMinutRecoveryStalled", "BaitlyMinutRecoveryUncertain",
}

RECOVERY_METRICS = (
    "accounting_inflight", "accounting_unknown", "accounting_historical_review",
    "accounting_oldest_inflight_seconds", "accounting_oldest_unknown_seconds", "oauth_blocked_scopes",
    "minut_ready", "minut_uncertain", "minut_review", "minut_oldest_ready_seconds", "minut_oldest_uncertain_seconds",
)
RECOVERY_REQUIRED = ("snapshot_healthy", "snapshot_last_success_timestamp_seconds", *RECOVERY_METRICS)
RECOVERY_COVERAGE = (
    'count((up{job="clenzy-backend"} == 1) unless on(job,instance) '
    '(count by(job,instance) ({job="clenzy-backend",__name__=~"baitly_recovery_('
    + "|".join(RECOVERY_REQUIRED) + ')"}) == ' + str(len(RECOVERY_REQUIRED)) + ')) or vector(0)'
)


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError("Internal monitoring command failed (details withheld)")
    return result.stdout


def inspect(name):
    return json.loads(command("docker", "inspect", name))[0]


def endpoint(name, port):
    networks = inspect(name)["NetworkSettings"]["Networks"]
    addresses = [n["IPAddress"] for n in networks.values() if n.get("IPAddress")]
    if not addresses or not all(ipaddress.ip_address(a).is_private for a in addresses):
        raise RuntimeError("Expected a private Docker network address")
    return f"http://{addresses[0]}:{port}"


def request(base, path, payload=None):
    body = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(base + path, data=body,
                                 headers={"Content-Type": "application/json"} if body else {})
    # No cookies, token, proxy, external redirect or business request.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            raise RuntimeError("Monitoring redirects are refused")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(req, timeout=8) as response:
        return response.read().decode()


def query(base, expr):
    data = json.loads(request(base, "/api/v1/query?" + urllib.parse.urlencode({"query": expr})))
    if data.get("status") != "success":
        raise RuntimeError("Monitoring query failed")
    rows = data["data"]["result"]
    if len(rows) != 1:
        raise RuntimeError("Expected one aggregate monitoring sample")
    value = float(rows[0]["value"][1])
    if not math.isfinite(value):
        raise RuntimeError("Monitoring sample is not finite")
    return value


def wait_for(check, seconds=90):
    deadline = time.monotonic() + seconds
    while True:
        try:
            if check():
                return
        except (RuntimeError, OSError, ValueError, KeyError):
            pass
        if time.monotonic() >= deadline:
            raise RuntimeError("Monitoring validation timed out (details withheld)")
        time.sleep(5)


def reload_confirmed(base, prefix, started):
    names = (prefix + "_config_last_reload_successful", prefix + "_config_last_reload_success_timestamp_seconds")
    text = request(base, "/metrics")
    samples = dict(line.split(" ", 1) for line in text.splitlines()
                   if any(line.startswith(name + " ") for name in names))
    return float(samples.get(names[0], 0)) == 1 and float(samples.get(names[1], 0)) >= started


def reload_configuration(prometheus, alertmanager):
    # Official SIGHUP reload; neither stop, restart nor recreate containers.
    before = {name: inspect(name)["State"]["StartedAt"] for name in
              ("clenzy-prometheus-prod", "clenzy-alertmanager-prod")}
    command("docker", "exec", "clenzy-prometheus-prod", "promtool", "check", "rules",
            "/etc/prometheus/rules/clenzy-alerts.yml", "/etc/prometheus/rules/baitly-recovery.yml")
    command("docker", "exec", "clenzy-alertmanager-prod", "amtool", "check-config",
            "/etc/alertmanager/alertmanager.yml")
    started = time.time() - 1
    for name in before:
        command("docker", "kill", "--signal=HUP", name)
    wait_for(lambda: reload_confirmed(prometheus, "prometheus", started))
    wait_for(lambda: reload_confirmed(alertmanager, "alertmanager", started))
    if any(inspect(name)["State"]["StartedAt"] != value for name, value in before.items()):
        raise RuntimeError("Unexpected monitoring process restart")
    print("Monitoring configurations reloaded; container start times unchanged")


def validate_backend(prometheus):
    wait_for(lambda: query(prometheus, 'min(up{job="clenzy-backend"})') == 1
             and query(prometheus, 'min(baitly_ops_snapshot_healthy{job="clenzy-backend"})') == 1
             and query(prometheus, 'max(time() - baitly_ops_snapshot_last_success_timestamp_seconds{job="clenzy-backend"})') < 120
             and query(prometheus, RECOVERY_COVERAGE) == 0
             and query(prometheus, 'min(baitly_recovery_snapshot_healthy{job="clenzy-backend"})') == 1
             and query(prometheus, 'max(time() - baitly_recovery_snapshot_last_success_timestamp_seconds{job="clenzy-backend"})') < 180
             and all(query(prometheus, f'min(baitly_recovery_{metric}{{job="clenzy-backend"}})') >= 0
                     for metric in RECOVERY_METRICS))


def validate(prometheus):
    validate_backend(prometheus)
    def rules_ready():
        data = json.loads(request(prometheus, "/api/v1/rules?type=alert"))
        rules = {r["name"]: r for g in data["data"]["groups"] for r in g["rules"]}
        return RULES.issubset(rules) and all(rules[n].get("health") == "ok" for n in RULES)
    # A just-reloaded rule starts with unknown health until its first evaluation.
    wait_for(rules_ready)
    for metric in ("outbox_pending", "outbox_retryable", "outbox_exhausted", "outbox_oldest_age_seconds",
                   "webhooks_overdue", "webhooks_oldest_overdue_seconds", "webhooks_disabled"):
        value = query(prometheus, f'sum(baitly_ops_{metric}{{job="clenzy-backend"}})')
        if value < 0:
            raise RuntimeError("Invalid queue aggregate")
        print(f"baitly_ops_{metric}={value:g}")
    # Les répliques lisent le même journal plateforme : ne pas additionner leurs compteurs.
    for metric in RECOVERY_METRICS:
        value = query(prometheus, f'max(baitly_recovery_{metric}{{job="clenzy-backend"}})')
        if value < 0:
            raise RuntimeError("Invalid recovery aggregate")
        print(f"baitly_recovery_{metric}={value:g}")
    print(f"{len(RULES)} pilot rules loaded and healthy; backend and recovery snapshots fresh")


def notification_count(state, since):
    if state not in ("firing", "resolved") or type(since) is not int or since < 0:
        raise RuntimeError("Unexpected notification state")
    # Fixed aggregate SELECT only: no recipient, tenant ID or message is returned.
    sql = ("SELECT count(*) FROM notifications WHERE notification_key='OPS_ALERT' "
           "AND title='[" + state + "] MonitoringAlert' "
           f"AND created_at >= to_timestamp({since})")
    count = command("docker", "exec", "clenzy-postgres-prod", "sh", "-c",
                    'exec psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atqc "$1"', "sh", sql)
    return int(count.strip())


def canary(prometheus, alertmanager):
    # Staging-only fixture. No business action and no real outage.
    source = pathlib.Path(".env").read_text()
    domain = next((l.split("=", 1)[1].strip().strip("\"'") for l in source.splitlines()
                   if l.startswith("APP_DOMAIN=")), "")
    if domain != "app.clenzy.fr":
        raise RuntimeError("Canary is restricted to the staging domain")
    expr = lambda state: 'sum(baitly_ops_alerts_received_total{source="alertmanager",status="' + state + '"}) or vector(0)'
    baseline = {s: query(prometheus, expr(s)) for s in ("firing", "resolved")}
    since = int(time.time()) - 1
    persisted = {s: notification_count(s, since) for s in ("firing", "resolved")}
    now = dt.datetime.now(dt.timezone.utc)
    stamp = lambda value: value.isoformat().replace("+00:00", "Z")
    alert = {"labels": {"alertname": "BaitlyPilotCanary_" + str(time.time_ns()), "severity": "info", "job": "baitly-pilot-recipe"},
             "annotations": {"summary": "Synthetic staging monitoring recipe"},
             "startsAt": stamp(now), "endsAt": stamp(now + dt.timedelta(minutes=10))}
    try:
        request(alertmanager, "/api/v2/alerts", [alert])
        wait_for(lambda: query(prometheus, expr("firing")) > baseline["firing"]
                 and notification_count("firing", since) > persisted["firing"], 120)
        print("Synthetic firing batch accepted and staff notification persisted")
    finally:
        alert["endsAt"] = stamp(dt.datetime.now(dt.timezone.utc))
        request(alertmanager, "/api/v2/alerts", [alert])
    wait_for(lambda: query(prometheus, expr("resolved")) > baseline["resolved"]
             and notification_count("resolved", since) > persisted["resolved"], 360)
    print("Synthetic resolved batch persisted; this is not proof of an email being read")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--reload", action="store_true")
    parser.add_argument("--canary", action="store_true")
    args = parser.parse_args()
    prometheus = endpoint("clenzy-prometheus-prod", 9090)
    alertmanager = endpoint("clenzy-alertmanager-prod", 9093)
    if args.reload:
        # Do not activate rules requiring new gauges before the backend supplies them.
        validate_backend(prometheus)
        reload_configuration(prometheus, alertmanager)
    validate(prometheus)
    if args.canary:
        canary(prometheus, alertmanager)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        raise SystemExit("Baitly monitoring qualification failed; no private response or credential logged")
