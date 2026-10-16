"""Dedicated staging PostgreSQL roles. Run only by the isolated-VM CI/CD installer."""
import json
from pathlib import Path
import secrets
import subprocess


def sql(database, statement):
    result = subprocess.run(["runuser", "-u", "postgres", "--", "psql", "-X", "-qAt",
                             "-v", "ON_ERROR_STOP=1", "-d", database], input=statement,
                            text=True, capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError("Dedicated IoT database operation failed; no SQL or credentials logged")
    return result.stdout.strip()


def provision(directory):
    path = Path(directory) / "database-secrets.json"
    if path.exists():
        credentials = json.loads(path.read_text())
    else:
        credentials = {name: secrets.token_hex(32) for name in ("runtime", "migration")}
        path.write_text(json.dumps(credentials))
        path.chmod(0o600)
    if set(credentials) != {"runtime", "migration"} or any(not isinstance(value, str) or len(value) != 64
            or any(c not in "0123456789abcdef" for c in value) for value in credentials.values()):
        raise ValueError("Invalid stored database credentials")
    for role, key in (("baitly_iot_runtime", "runtime"), ("baitly_iot_migration", "migration")):
        sql("postgres", f"""DO $$ BEGIN
          IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='{role}') THEN
            CREATE ROLE {role} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
          END IF;
        END $$;
        ALTER ROLE {role} PASSWORD '{credentials[key]}';""")
    if sql("postgres", "SELECT 1 FROM pg_database WHERE datname='baitly_iot_staging';") != "1":
        sql("postgres", "CREATE DATABASE baitly_iot_staging OWNER baitly_iot_migration;")
    sql("baitly_iot_staging", """
        REVOKE ALL ON DATABASE baitly_iot_staging FROM PUBLIC;
        REVOKE ALL ON SCHEMA public FROM PUBLIC;
        GRANT CONNECT ON DATABASE baitly_iot_staging TO baitly_iot_runtime;
        GRANT USAGE ON SCHEMA public TO baitly_iot_runtime;
    """)
    return credentials


def grant_runtime():
    sql("baitly_iot_staging", """
        GRANT SELECT, INSERT, UPDATE ON baitly_iot_devices TO baitly_iot_runtime;
        GRANT SELECT, INSERT ON baitly_iot_noise_measurements TO baitly_iot_runtime;
    """)
