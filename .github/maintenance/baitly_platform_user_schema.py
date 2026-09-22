"""Apply the reviewed Baitly platform-user Liquibase repair, without a deployment."""

import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile


APP_COMMIT = "a1453b31fc62a7ce4d38f9f96c88db356cee26f7"
CHANGELOG = "db/changelog/0479-platform-users-organization.yaml"
SQL_FILE = "db/changelog/changes/0479__platform_users_organization.sql"
FILE_HASHES = {
    CHANGELOG: "6468c435e27a1c57e356b796fdd4526751789e5f7c95aa55ba2bcf419af659ba",
    SQL_FILE: "1fc0e04f16983f29e4059266a5b55d4f91685cbd7be4658abcd772762d0c30b8",
}
CHANGESET = "0479-platform-users-organization"
LIQUIBASE_IMAGE = "liquibase/liquibase:4.29.2"


def run(*args, env=None):
    result = subprocess.run(args, capture_output=True, text=True, env=env, check=False)
    if result.returncode:
        # Subprocess output may contain connection details: fail without printing it.
        raise RuntimeError(f"Command failed: {args[0]} (exit {result.returncode})")
    return result.stdout


def validate_environment(env):
    if env.get("APP_DOMAIN") != "app.baitly.fr":
        raise ValueError("This repair is restricted to app.baitly.fr")
    for key in ("POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"):
        if not env.get(key):
            raise ValueError(f"Required database setting missing: {key}")
    # Database name is used in a JDBC path. Reject URL parameters and shell syntax.
    import re
    if not re.fullmatch(r"[A-Za-z0-9_]+", env["POSTGRES_DB"]):
        raise ValueError("Unexpected database name")


def export_migration(app_repo, destination):
    run("git", "-C", str(app_repo), "fetch", "origin", "main")
    run("git", "-C", str(app_repo), "merge-base", "--is-ancestor", APP_COMMIT, "origin/main")
    for name, expected in FILE_HASHES.items():
        content = run("git", "-C", str(app_repo), "show", f"{APP_COMMIT}:server/src/main/resources/{name}")
        if hashlib.sha256(content.encode()).hexdigest() != expected:
            raise ValueError(f"Reviewed migration digest mismatch: {name}")
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        path.chmod(0o644)
    # The Liquibase image runs as a non-root user.
    destination.chmod(0o755)
    for path in destination.rglob("*"):
        if path.is_dir():
            path.chmod(0o755)


def command_env(env):
    return {
        **env,
        "LIQUIBASE_COMMAND_URL": f"jdbc:postgresql://postgres:5432/{env['POSTGRES_DB']}?sslmode=prefer",
        "LIQUIBASE_COMMAND_USERNAME": env["POSTGRES_USER"],
        "LIQUIBASE_COMMAND_PASSWORD": env["POSTGRES_PASSWORD"],
    }


def liquibase(resources, env, command):
    if command not in ("validate", "status", "update"):
        raise ValueError("Unsupported Liquibase command")
    # Pass credentials through the container environment, never command arguments.
    return run(
        "docker", "run", "--rm", "--network", "clenzy-network",
        "-v", f"{resources}:/liquibase/resources:ro", "-w", "/liquibase/resources",
        "-e", "LIQUIBASE_COMMAND_URL", "-e", "LIQUIBASE_COMMAND_USERNAME",
        "-e", "LIQUIBASE_COMMAND_PASSWORD", LIQUIBASE_IMAGE,
        f"--changelog-file={CHANGELOG}", "--log-level=WARNING", command,
        env=command_env(env),
    )


def verify_applied(infra_dir, env):
    query = (
        "SELECT (SELECT is_nullable FROM information_schema.columns "
        "WHERE table_schema='public' AND table_name='users' AND column_name='organization_id'),"
        "(SELECT count(*) FROM databasechangelog WHERE id='" + CHANGESET + "' "
        "AND author='clenzy-team' AND filename='" + CHANGELOG + "' AND exectype='EXECUTED');"
    )
    output = run(
        "docker", "compose", "-f", str(infra_dir / "docker-compose.prod.yml"),
        "--env-file", str(infra_dir / ".env"), "exec", "-T", "postgres",
        "psql", "-X", "-v", "ON_ERROR_STOP=1", "-U", env["POSTGRES_USER"],
        "-d", env["POSTGRES_DB"], "-Atc", query,
    ).strip()
    if output != "YES|1":
        raise RuntimeError("Liquibase repair did not pass schema/history verification")
    print("Verified: users.organization_id is nullable; one canonical Liquibase execution recorded.")


def execute(infra_dir, env, apply=False):
    validate_environment(env)
    app_repo = infra_dir.parent / "clenzy"
    with tempfile.TemporaryDirectory(prefix="baitly-staff-schema-") as temporary:
        resources = Path(temporary)
        export_migration(app_repo, resources)
        liquibase(resources, env, "validate")
        liquibase(resources, env, "status")
        print(f"Validated reviewed migration {CHANGESET} at {APP_COMMIT} for app.baitly.fr.")
        if apply:
            liquibase(resources, env, "update")
            verify_applied(infra_dir, env)
        else:
            print("Diagnosis only: no migration applied.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    execute(Path.cwd(), dict(os.environ), args.apply)
