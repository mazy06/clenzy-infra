#!/usr/bin/env python3
"""Baitly database archive integrity checks. Never print archive contents or errors."""
import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import tarfile

MAX_BYTES = 20 * 1024 ** 3


def digest(stream):
    value = hashlib.sha256()
    while chunk := stream.read(1024 * 1024):
        value.update(chunk)
    return value.hexdigest()


def create(directory, environment, snapshot_started_at):
    directory = pathlib.Path(directory)
    files = []
    for path in sorted(directory.iterdir()):
        if path.is_symlink() or not path.is_file():
            raise ValueError("Only regular backup files are supported")
        if path.name == "baitly-manifest.json":
            raise ValueError("Manifest already exists")
        role = ("application" if path.name.startswith("postgres_") and path.suffix == ".dump"
                else "authentication" if path.name.startswith("keycloak_db_") and path.suffix == ".dump"
                else "auxiliary")
        with path.open("rb") as stream:
            files.append(dict(path=path.name, role=role, size=path.stat().st_size, sha256=digest(stream)))
    for role in ("application", "authentication"):
        matches = [f for f in files if f["role"] == role]
        if len(matches) != 1 or matches[0]["size"] == 0:
            raise ValueError("Both complete database dumps are required")
    snapshot = dt.datetime.fromisoformat(snapshot_started_at.replace("Z", "+00:00"))
    if snapshot.tzinfo is None:
        raise ValueError("Snapshot timestamp must include timezone")
    data = dict(version=1, environment=environment, snapshot_started_at=snapshot.isoformat(), files=files,
                coverage=dict(application_database=True, authentication_database=True,
                              documents=False, deployment_secrets=False, encryption=False, offsite=False))
    manifest = directory / "baitly-manifest.json"
    with manifest.open("x", encoding="utf-8") as out:
        manifest.chmod(0o600)
        json.dump(data, out)
    return data


def verify(archive_path, max_bytes=MAX_BYTES):
    """Hash the bounded archive before extracting anything. Hashes are not signatures."""
    with tarfile.open(archive_path, "r:gz") as archive:
        files, total, root = {}, 0, None
        for index, member in enumerate(archive):
            if index > 1000:
                raise ValueError("Too many archive members")
            path = pathlib.PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or not path.parts:
                raise ValueError("Unsafe archive path")
            if len(path.parts) > 2:
                raise ValueError("Unexpected archive depth")
            if member.isdir():
                if len(path.parts) != 1:
                    raise ValueError("Unexpected archive directory")
                continue
            if not member.isfile() or len(path.parts) != 2:
                raise ValueError("Only regular files within one archive root are accepted")
            if root is None:
                root = path.parts[0]
            if root != path.parts[0] or path.name in files:
                raise ValueError("Ambiguous archive members")
            total += member.size
            if total > max_bytes:
                raise ValueError("Archive size limit exceeded")
            files[path.name] = member
        item = files.get("baitly-manifest.json")
        if item is None or item.size > 65536:
            raise ValueError("A bounded manifest is required")
        manifest = json.loads(archive.extractfile(item).read())
        if manifest.get("version") != 1 or manifest.get("environment") not in ("dev", "staging", "prod"):
            raise ValueError("Unsupported manifest")
        started = dt.datetime.fromisoformat(manifest["snapshot_started_at"].replace("Z", "+00:00"))
        if started.tzinfo is None or started > dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=5):
            raise ValueError("Invalid snapshot timestamp")
        declared = manifest["files"]
        if not isinstance(declared, list) or len(declared) != len(files) - 1:
            raise ValueError("Manifest membership mismatch")
        seen = set()
        for entry in declared:
            name = entry["path"]
            if name in seen or name == "baitly-manifest.json" or name not in files:
                raise ValueError("Invalid manifest member")
            seen.add(name)
            if entry["size"] != files[name].size or digest(archive.extractfile(files[name])) != entry["sha256"]:
                raise ValueError("Archive integrity check failed")
        for role in ("application", "authentication"):
            entries = [f for f in declared if f["role"] == role]
            if len(entries) != 1 or entries[0]["size"] <= 0:
                raise ValueError("Incomplete database coverage")
        return manifest


def extract_verified(archive_path, destination):
    manifest = verify(archive_path)
    destination = pathlib.Path(destination)
    # No tar.extract/all: links, permissions and absolute paths are never applied.
    with tarfile.open(archive_path, "r:gz") as archive:
        by_name = {pathlib.PurePosixPath(m.name).name: m for m in archive if m.isfile()}
        for entry in manifest["files"]:
            name = entry["path"]
            if by_name[name].size != entry["size"]:
                raise ValueError("Archive changed during verification")
            with archive.extractfile(by_name[name]) as source, (destination / name).open("xb") as target:
                os.fchmod(target.fileno(), 0o600)
                remaining = entry["size"]
                while remaining:
                    chunk = source.read(min(remaining, 1024 * 1024))
                    if not chunk:
                        raise ValueError("Truncated archive member")
                    target.write(chunk)
                    remaining -= len(chunk)
            # Recheck copied bytes too, so a file changed between passes is refused.
            with (destination / name).open("rb") as source:
                if digest(source) != entry["sha256"]:
                    raise ValueError("Archive changed during verification")
    return manifest


def retention(directory, environment, today=None, apply=False):
    today = today or dt.datetime.now(dt.timezone.utc).date()
    candidates = []
    pattern = re.compile(r"clenzy_backup_" + re.escape(environment) + r"_(\d{8})_\d{6}\.tar\.gz")
    for path in pathlib.Path(directory).iterdir():
        match = pattern.fullmatch(path.name)
        if path.is_symlink() or not path.is_file() or not match:
            continue
        try:
            snapshot = dt.datetime.strptime(match[1], "%Y%m%d").date()
        except ValueError:
            continue
        days = 180 if snapshot.day == 1 else 28 if snapshot.weekday() == 6 else 7
        if (today - snapshot).days > days:
            candidates.append(path)
    if apply:
        for path in candidates:
            path.unlink()
    return len(candidates)


def main():
    parser = argparse.ArgumentParser(description="Baitly database archive verification; no live restore")
    sub = parser.add_subparsers(dest="command", required=True)
    make = sub.add_parser("create")
    make.add_argument("directory")
    make.add_argument("--environment", choices=("dev", "staging", "prod"), required=True)
    make.add_argument("--snapshot-started-at", required=True)
    check = sub.add_parser("verify")
    check.add_argument("archive")
    prune = sub.add_parser("retention")
    prune.add_argument("directory")
    prune.add_argument("--environment", choices=("dev", "staging", "prod"), required=True)
    prune.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if args.command == "create":
        create(args.directory, args.environment, args.snapshot_started_at)
        print("Database manifest created; no offsite/encryption/document coverage claimed")
    elif args.command == "verify":
        verify(args.archive)
        print("Database archive integrity verified; authenticity and full recovery not established")
    else:
        print("retention_candidates=" + str(retention(args.directory, args.environment, apply=args.apply)))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        raise SystemExit("Baitly archive verification failed; private details withheld")
