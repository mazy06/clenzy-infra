"""Targeted, auditable role repair for admin on app.baitly.fr through CI only."""

import argparse
import hashlib
import json
import os
import shlex
import subprocess
import uuid


DOMAIN = "app.baitly.fr"
USERNAME = "admin"
REALM = "clenzy"
ROLE = "SUPER_ADMIN"
BUSINESS_ROLES = {
    "SUPER_ADMIN", "SUPER_MANAGER", "HOST", "PROPERTY_OWNER", "TECHNICIAN",
    "HOUSEKEEPER", "SUPERVISOR", "LAUNDRY", "EXTERIOR_TECH",
}
COMPOSE = ["docker", "compose", "-f", "docker-compose.prod.yml", "--env-file", ".env"]


class RepairError(RuntimeError):
    pass


def run(args, content=None, env=None):
    result = subprocess.run(args, input=content, text=True, capture_output=True,
                            check=False, timeout=90, env=env)
    if result.returncode:
        # Never forward command output: it may contain identity data or credentials.
        raise RepairError(f"Administration command failed (exit {result.returncode}); no credentials logged")
    return result.stdout.strip()


class Production:
    def keycloak(self, args, body=None):
        script = """set -eu
set +x
umask 077
CONFIG=$(mktemp)
BODY=$(mktemp)
trap 'rm -f "$CONFIG" "$BODY"' EXIT
KCADM=/opt/keycloak/bin/kcadm.sh
$KCADM config credentials --config "$CONFIG" --server http://localhost:8080 \\
  --realm master --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null
"""
        if body is not None:
            script += "printf '%s' " + shlex.quote(json.dumps(body)) + ' > "$BODY"\n'
        script += '$KCADM ' + shlex.join(args) + ' --config "$CONFIG"'
        if body is not None:
            script += ' -f "$BODY"'
        output = run(COMPOSE + ["exec", "-T", "keycloak", "sh", "-s"], script + "\n")
        return json.loads(output) if args[0] == "get" and output else None

    def sql(self, query, **variables):
        args = ["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1"]
        for key, value in variables.items():
            args += ["-v", f"{key}={value}"]
        command = shlex.join(args) + ' -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
        output = run(COMPOSE + ["exec", "-T", "postgres", "sh", "-c", "exec " + command], query)
        return json.loads(output) if output else None

    def profile(self, subject, email_hash):
        return self.sql("""BEGIN READ ONLY;
SELECT json_build_object(
  'users', (SELECT coalesce(json_agg(json_build_object(
    'id', id, 'role', role, 'status', status, 'emailHash', email_hash)), '[]'::json)
    FROM users WHERE keycloak_id = :'subject'),
  'emailConflicts', (SELECT count(*) FROM users WHERE email_hash = :'email_hash'
    AND keycloak_id IS DISTINCT FROM :'subject'));
COMMIT;
""", subject=subject, email_hash=email_hash)

    def promote_profile(self, subject, profile):
        # Compare-and-set: a concurrent change must never be overwritten.
        changed = self.sql("""BEGIN;
SET LOCAL lock_timeout = '5s';
WITH changed AS (
  UPDATE users SET role = 'SUPER_ADMIN', updated_at = CURRENT_TIMESTAMP
  WHERE id = :'user_id'::bigint AND keycloak_id = :'subject'
    AND role = :'previous_role' AND status = 'ACTIVE'
  RETURNING id)
SELECT coalesce(json_agg(id), '[]'::json) FROM changed;
COMMIT;
""", subject=subject, user_id=profile["id"], previous_role=profile["role"])
        if changed != [profile["id"]]:
            raise RepairError("PMS profile changed concurrently; rerun the read-only diagnosis")

    def clear_user_cache(self, subject):
        env = dict(os.environ, REDISCLI_AUTH=os.environ.get("REDIS_PASSWORD", ""))
        result = run(COMPOSE + ["exec", "-T", "-e", "REDISCLI_AUTH", "redis", "redis-cli",
                     "--raw", "DEL", f"tenant:{subject}", f"user:permissions:{subject}"], env=env)
        if not result.isdecimal():
            raise RepairError("Targeted cache invalidation failed; rerun the operation")


def diagnose(ops):
    matches = ops.keycloak(["get", "users", "-r", REALM, "-q", "username=admin", "-q", "exact=true",
                            "--fields", "id,username,enabled,email,emailVerified"])
    if not isinstance(matches, list) or len(matches) != 1 or matches[0].get("username") != USERNAME:
        raise RepairError("Expected exactly one account named admin in the PMS realm")
    user = matches[0]
    subject = str(uuid.UUID(user["id"]))
    email = (user.get("email") or "").strip().lower()
    email_hash = hashlib.sha256(email.encode()).hexdigest() if email else ""
    data = ops.profile(subject, email_hash)
    if len(data["users"]) > 1:
        raise RepairError("Multiple PMS profiles refer to this Keycloak identity")
    profile = data["users"][0] if data["users"] else None
    roles = ops.keycloak(["get", f"users/{subject}/role-mappings/realm/composite", "-r", REALM])
    names = {role["name"] for role in roles}
    report = {
        "instance": DOMAIN, "realm": REALM, "username": USERNAME,
        "keycloakId": subject, "enabled": user.get("enabled") is True,
        "emailPresent": bool(email), "emailVerified": user.get("emailVerified") is True,
        "keycloakBusinessRoles": sorted(names & BUSINESS_ROLES),
        "keycloakSuperAdmin": ROLE in names,
        "pmsUserId": profile["id"] if profile else None,
        "pmsRole": profile["role"] if profile else "ABSENT",
        "pmsStatus": profile["status"] if profile else None,
        "identityConflict": bool(data["emailConflicts"]) or bool(
            profile and profile.get("emailHash") and profile["emailHash"] != email_hash),
    }
    return report, profile


def repair(ops, apply=False, expected_subject="", expected_role=""):
    if os.environ.get("APP_DOMAIN") != DOMAIN:
        raise RepairError("Refusing to run: APP_DOMAIN must be exactly app.baitly.fr")
    report, profile = diagnose(ops)
    print(json.dumps(report, indent=2))
    if not apply:
        return report
    if not expected_subject or str(uuid.UUID(expected_subject)) != report["keycloakId"]:
        raise RepairError("Apply requires the exact Keycloak ID returned by the diagnosis")
    if not expected_role or report["pmsRole"] not in {expected_role, ROLE}:
        raise RepairError("PMS role differs from the diagnosis; no change applied")
    if not report["enabled"] or report["identityConflict"]:
        raise RepairError("Disabled account or conflicting identity; no change applied")
    if profile and profile["status"] != "ACTIVE":
        raise RepairError("PMS profile is not active; no change applied")
    if not profile and (not report["emailPresent"] or not report["emailVerified"]):
        raise RepairError("Profile absent: a verified Keycloak email is required for the first PMS login")
    if not profile and set(report["keycloakBusinessRoles"]) - {ROLE}:
        raise RepairError("Profile absent with competing business roles; reconcile before promotion")

    subject = report["keycloakId"]
    if not report["keycloakSuperAdmin"]:
        # The deployment's Keycloak rejects role lookup by name; resolve the list instead.
        roles = ops.keycloak(["get", "roles", "-r", REALM])
        targets = [r for r in roles if r.get("name") == ROLE and not r.get("clientRole")]
        if not targets:
            # Fresh instances still import the legacy ADMIN role. The PMS expects
            # this explicit realm role; creating it grants nobody any rights.
            ops.keycloak(["create", "roles", "-r", REALM],
                         {"name": ROLE, "description": "Baitly platform administrator"})
            roles = ops.keycloak(["get", "roles", "-r", REALM])
            targets = [r for r in roles if r.get("name") == ROLE and not r.get("clientRole")]
        if len(targets) != 1:
            raise RepairError("SUPER_ADMIN realm role is missing or ambiguous; account role not changed")
        ops.keycloak(["create", f"users/{subject}/role-mappings/realm", "-r", REALM],
                     [{"id": targets[0]["id"], "name": ROLE}])
    if profile and profile["role"] != ROLE:
        ops.promote_profile(subject, profile)
    ops.clear_user_cache(subject)
    after, _ = diagnose(ops)
    if not after["keycloakSuperAdmin"] or (profile and after["pmsRole"] != ROLE):
        raise RepairError("Role verification failed; rerun diagnosis before proceeding")
    print(json.dumps({"verified": after, "reloginRequired": True}, indent=2))
    return after


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--expected-keycloak-id", default="")
    parser.add_argument("--expected-pms-role", default="")
    args = parser.parse_args()
    try:
        repair(Production(), args.apply, args.expected_keycloak_id, args.expected_pms_role)
    except (RepairError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"Baitly admin role: {error}") from None
