#!/usr/bin/env python3
"""Baitly trusted-backup rehearsal. The only destination is a new temporary cluster."""
import argparse
import contextlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import time

from baitly_archive import extract_verified


class Sandbox:
    def __init__(self, directory, max_seconds=14400):
        self.root = pathlib.Path(directory)
        self.root.chmod(0o700)
        self.socket = self.root / "socket"
        self.socket.mkdir(mode=0o700)
        self.data = self.root / "data"
        self.started = time.monotonic()
        self.limit = max_seconds
        bindir = os.environ.get("BAITLY_PG_BINDIR") or str(pathlib.Path(shutil.which("initdb") or "").parent)
        self.bindir = pathlib.Path(bindir).absolute()
        # Never inherit a service, connection string, password file or PGOPTIONS.
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("PG")}
        self.env.update(PGHOST=str(self.socket), PGPORT="5432", PGUSER="baitly_restore_admin", PGPASSFILE=os.devnull)

    def run(self, program, *args, input=None, cleanup=False):
        timeout = 30 if cleanup else max(1, self.limit - (time.monotonic() - self.started))
        result = subprocess.run([str(self.bindir / program), *args], env=self.env, input=input,
                                capture_output=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError("Isolated database operation failed (details withheld)")
        return result.stdout

    def start(self):
        self.run("initdb", "-D", str(self.data), "-U", "baitly_restore_admin", "--auth=trust", "--no-locale", "--encoding=UTF8")
        with (self.data / "postgresql.auto.conf").open("a") as config:
            socket = str(self.socket).replace("'", "''")
            config.write(f"\nlisten_addresses = ''\nunix_socket_directories = '{socket}'\nport = 5432\n")
        self.run("pg_ctl", "-D", str(self.data), "-l", str(self.root / "postgres.log"),
                 "-w", "start")

    def stop(self):
        if (self.data / "postmaster.pid").exists():
            self.run("pg_ctl", "-D", str(self.data), "-m", "immediate", "-w", "stop", cleanup=True)

    def sql(self, database, statement):
        if database not in ("postgres", "baitly_application", "baitly_authentication"):
            raise ValueError("Only owned sandbox database names are accepted")
        return self.run("psql", "--no-psqlrc", "--no-password", "-v", "ON_ERROR_STOP=1", "-At", "-d", database,
                        input=statement.encode()).decode().strip()

    def restore(self, database, dump):
        if database not in ("baitly_application", "baitly_authentication"):
            raise ValueError("Only fixed sandbox destinations are accepted")
        self.run("createdb", "--no-password", "--template=template0", database)
        self.run("pg_restore", "--no-password", "--exit-on-error", "--single-transaction", "--no-owner", "--no-privileges",
                 "-d", database, str(dump))
        return int(self.sql(database, "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
                            "WHERE c.relkind IN ('r','p') AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'"))


@contextlib.contextmanager
def sandbox(max_seconds=14400):
    # Short private socket path also works on macOS. No Docker stop/restart.
    directory = tempfile.mkdtemp(prefix="baitly-dr-", dir=tempfile.gettempdir())
    cluster = Sandbox(directory, max_seconds)
    try:
        cluster.start()
        yield cluster
    finally:
        # On stop failure, leave the owned private directory rather than deleting
        # data underneath a running process. The caller receives a controlled failure.
        cluster.stop()
        shutil.rmtree(directory)


def rehearse(archive, max_seconds=14400):
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="baitly-dumps-") as directory:
        manifest = extract_verified(archive, directory)
        with sandbox(max_seconds) as cluster:
            counts = {}
            for role, database in (("application", "baitly_application"), ("authentication", "baitly_authentication")):
                entry = next(f for f in manifest["files"] if f["role"] == role)
                counts[role] = cluster.restore(database, pathlib.Path(directory) / entry["path"])
                if counts[role] < 1:
                    raise ValueError("Empty restored database")
            realms = cluster.sql("baitly_authentication", "SELECT count(*) FROM realm WHERE name IN ('clenzy','clenzy-guests')")
            if realms != "2":
                raise ValueError("Both authentication realms are required")
    return dict(database_restore_verified=True, restored_tables=counts, authentication_realms=2,
                elapsed_seconds=round(time.monotonic() - started, 3), live_target_used=False,
                full_rto_proven=False, documents_proven=False, offsite_proven=False)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Restore trusted Baitly DB backups only into an owned temporary cluster")
    parser.add_argument("--archive", required=True)
    parser.add_argument("--max-seconds", type=int, default=14400)
    args = parser.parse_args()
    try:
        if args.max_seconds < 1 or args.max_seconds > 14400:
            raise ValueError("Invalid rehearsal duration")
        print(json.dumps(rehearse(args.archive, args.max_seconds)))
    except Exception:
        raise SystemExit("Baitly isolated database rehearsal failed; private details withheld")
