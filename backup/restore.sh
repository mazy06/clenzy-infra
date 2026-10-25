#!/usr/bin/env bash
# Baitly recovery entry point: rehearsal only, never a live database destination.
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-$SCRIPT_DIR/data}"
ENV=dev
ARCHIVE=""
ISOLATED=false
LIST=false
LATEST=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --env) ENV="${2:?Missing environment}"; shift 2 ;;
        --archive) ARCHIVE="${2:?Missing archive}"; shift 2 ;;
        --isolated) ISOLATED=true; shift ;;
        --list) LIST=true; shift ;;
        --latest) LATEST=true; shift ;;
        --yes|-y) echo "Live restore is disabled; --yes cannot override isolation" >&2; exit 64 ;;
        --help) echo "Usage: restore.sh --archive <trusted-backup.tar.gz> --isolated | --list --env dev|staging|prod"; exit 0 ;;
        *) echo "Unknown recovery argument" >&2; exit 64 ;;
    esac
done
case "$ENV" in dev|staging|prod) ;; *) echo "Invalid environment" >&2; exit 64 ;; esac
if [ "$LIST" = true ]; then
    python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); print("local_archive_count="+str(sum(1 for f in p.glob("clenzy_backup_*.tar.gz") if f.is_file() and not f.is_symlink())))' "$BACKUP_ROOT/$ENV"
    exit 0
fi
if [ "$ISOLATED" != true ]; then
    echo "Live restore disabled: use --isolated for a trusted-backup rehearsal. Real recovery requires reviewed CI/CD." >&2
    exit 64
fi
if [ "$LATEST" = true ]; then
    ARCHIVE=$(python3 -c 'import pathlib,sys; files=[p for p in pathlib.Path(sys.argv[1]).glob("clenzy_backup_*.tar.gz") if p.is_file() and not p.is_symlink()]; print(max(files,key=lambda p:p.stat().st_mtime) if files else "")' "$BACKUP_ROOT/$ENV")
fi
if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then echo "Recovery archive missing" >&2; exit 64; fi
# No .env, Keycloak credential, Docker command or production connection is loaded.
exec python3 "$SCRIPT_DIR/baitly_restore_rehearsal.py" --archive "$ARCHIVE"
