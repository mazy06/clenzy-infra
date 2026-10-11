#!/usr/bin/env bash
# Mesures Baitly staging uniquement ; aucune action sur le cycle de vie Docker.
set -euo pipefail
set +x
umask 077

case "${BAITLY_BENCHMARK_MODE:-}" in schema|baseline|cards|small|disable|diagnostic|purge-plan|purge) ;; *) exit 2 ;; esac
case "${BAITLY_BENCHMARK_MAX_RATE:-1}" in 1|5|10) ;; *) exit 2 ;; esac
[[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ ]] || exit 2
[[ "${VPS_HOST:-}" =~ ^[a-zA-Z0-9.-]+$ ]] || exit 2
[[ "${VPS_USER:-}" =~ ^[a-z_][a-z0-9_-]*$ ]] || exit 2
[[ "${VPS_PORT:-22}" =~ ^[0-9]{1,5}$ ]] || exit 2
[[ -n "${VPS_SSH_KEY:-}" ]] || exit 2

key=$(mktemp)
actors="${RUNNER_TEMP}/baitly-planning-actors-${GITHUB_RUN_ID}.json"
remote_dir="/tmp/baitly-planning-benchmark-${GITHUB_RUN_ID}"
printf '%s\n' "$VPS_SSH_KEY" > "$key"
chmod 600 "$key"
unset VPS_SSH_KEY
ssh_cmd=(ssh -i "$key" -p "${VPS_PORT:-22}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "${VPS_USER}@${VPS_HOST}")
scp_cmd=(scp -i "$key" -P "${VPS_PORT:-22}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
prepared=false
monitor_pid=''

remote() {
  {
    printf 'export BAITLY_OPERATION=%q BAITLY_REMOTE_DIR=%q BAITLY_INFRA_DIR=%q\n' "$1" "$remote_dir" "${VPS_INFRA_DIR:-}"
    cat <<'REMOTE_SCRIPT'
set -euo pipefail
set +x
umask 077
cd "${BAITLY_INFRA_DIR:-$HOME/clenzy-infra}"
set -a
. ./.env
set +a
# Garde exécutée AVANT les appels Keycloak, SQL ou API.
if [ "${APP_DOMAIN:-}" != app.clenzy.fr ]; then
  echo 'Refus : cette opération est réservée à app.clenzy.fr.' >&2
  exit 2
fi
script="$BAITLY_REMOTE_DIR/baitly-staging-fixtures.py"
case "$BAITLY_OPERATION" in
  diagnostic) python3 "$BAITLY_REMOTE_DIR/baitly_staging_error_classes.py" ;;
  identity-audit) python3 "$BAITLY_REMOTE_DIR/baitly_fixture_identity_audit.py" ;;
  schema) python3 "$script" schema --report "$BAITLY_REMOTE_DIR/schema.json" ;;
  provision)
    python3 "$script" provision --actors "$BAITLY_REMOTE_DIR/actors.json"
    python3 "$script" explain --actors "$BAITLY_REMOTE_DIR/actors.json" --report "$BAITLY_REMOTE_DIR/plans.json"
    ;;
  stats) python3 "$script" stats ;;
  disable) python3 "$script" disable ;;
  purge-plan) python3 "$script" purge-plan ;;
  purge) python3 "$script" purge ;;
  *) exit 2 ;;
esac
REMOTE_SCRIPT
  } | "${ssh_cmd[@]}" bash -s
}

cleanup() {
  original_status=$?
  trap - EXIT
  if [[ -n "$monitor_pid" ]]; then kill "$monitor_pid" 2>/dev/null || true; wait "$monitor_pid" 2>/dev/null || true; fi
  if [[ "$prepared" == true && "$BAITLY_BENCHMARK_MODE" != schema && "$BAITLY_BENCHMARK_MODE" != diagnostic \
      && "$BAITLY_BENCHMARK_MODE" != purge-plan && "$BAITLY_BENCHMARK_MODE" != purge ]]; then
    if ! remote disable; then
      echo '::error::La désactivation des clients de fixture a échoué ; relancer le mode disable.'
      original_status=1
    fi
  fi
  "${ssh_cmd[@]}" "rm -rf -- '$remote_dir'" || original_status=1
  rm -f -- "$key" "$actors"
  exit "$original_status"
}
trap cleanup EXIT

mkdir -p baitly-benchmark-results
git -C baitly-app rev-parse HEAD > baitly-benchmark-results/app-sha.txt
printf '%s\n' app.clenzy.fr > baitly-benchmark-results/domain.txt
"${ssh_cmd[@]}" "mkdir -m 700 -- '$remote_dir'"
"${scp_cmd[@]}" baitly-app/tests/performance/baitly-staging-fixtures.py "${VPS_USER}@${VPS_HOST}:$remote_dir/"
"${scp_cmd[@]}" .github/maintenance/baitly_staging_error_classes.py "${VPS_USER}@${VPS_HOST}:$remote_dir/"
"${scp_cmd[@]}" .github/maintenance/baitly_fixture_identity_audit.py "${VPS_USER}@${VPS_HOST}:$remote_dir/"
prepared=true
if [[ "$BAITLY_BENCHMARK_MODE" == diagnostic ]]; then
  remote diagnostic > baitly-benchmark-results/error-classes.json
  remote identity-audit > baitly-benchmark-results/fixture-identity-counts.json
  exit 0
fi
# Purge du jeu de benchmark : rapport JSON (tables et nombres de lignes) seulement.
# purge-plan joue la même transaction puis l'annule ; purge la valide et retire les clients.
if [[ "$BAITLY_BENCHMARK_MODE" == purge-plan || "$BAITLY_BENCHMARK_MODE" == purge ]]; then
  remote "$BAITLY_BENCHMARK_MODE" > "baitly-benchmark-results/${BAITLY_BENCHMARK_MODE}.json"
  cat "baitly-benchmark-results/${BAITLY_BENCHMARK_MODE}.json"
  exit 0
fi
remote schema
"${scp_cmd[@]}" "${VPS_USER}@${VPS_HOST}:$remote_dir/schema.json" baitly-benchmark-results/schema.json
if [[ "$BAITLY_BENCHMARK_MODE" == schema ]]; then exit 0; fi
if [[ "$BAITLY_BENCHMARK_MODE" == disable ]]; then remote disable; exit 0; fi

remote provision
"${scp_cmd[@]}" "${VPS_USER}@${VPS_HOST}:$remote_dir/actors.json" "$actors"
chmod 600 "$actors"
"${scp_cmd[@]}" "${VPS_USER}@${VPS_HOST}:$remote_dir/plans.json" baitly-benchmark-results/plans.json
k6 version > baitly-benchmark-results/k6-version.txt

# Échantillons CPU/RSS Docker et connexions/buffers PostgreSQL ; aucune donnée personnelle.
(trap - EXIT; while true; do remote stats >> baitly-benchmark-results/server-stats.jsonl || break; sleep 10; done) &
monitor_pid=$!

export BASE_URL=https://app.clenzy.fr
export PERF_ACTORS_FILE="$actors"
export PLANNING_VUS=30
export PLANNING_PLATEAU=2m
export PLANNING_DETAILS_MODE=cards
[[ "$BAITLY_BENCHMARK_MODE" != baseline ]] || export PLANNING_DETAILS_MODE=full
verdict=0

run_measurement() {
  local label=$1
  local status=0
  k6 run --summary-export "baitly-benchmark-results/${label}-summary.json" \
    baitly-app/tests/performance/baitly-planning-load.js || status=$?
  if [[ "$status" != 0 && "$status" != 99 ]]; then return "$status"; fi
  if [[ "$status" == 99 ]]; then verdict=99; fi
  return "$status"
}

# Petits portefeuilles : chauffe séparée puis trois répétitions à débit constant.
# Le mode small ignore max_rate et ne dépasse jamais une fenêtre par seconde.
if [[ "$BAITLY_BENCHMARK_MODE" == small ]]; then
  export PLANNING_WINDOWS_PER_SECOND=1 PLANNING_INCLUDE_CATALOG=true PLANNING_PLATEAU=30s
  for cohort in 10 100; do
    export PLANNING_PROPERTY_COUNT="$cohort"
    status=0
    run_measurement "warmup-${cohort}" || status=$?
    [[ "$status" == 0 || "$status" == 99 ]] || exit "$status"
  done
  # La chauffe peut dépasser les objectifs de latence, mais jamais masquer une erreur.
  python3 - <<'PYTHON'
import json
from pathlib import Path
for cohort in (10, 100):
    metrics = json.loads(Path(f"baitly-benchmark-results/warmup-{cohort}-summary.json").read_text())["metrics"]
    for name, value in (("planning_errors", "value"), ("planning_throttled", "value"), ("dropped_iterations", "count")):
        metric = metrics[name]
        values = metric.get("values", metric)
        if values[value] != 0:
            raise SystemExit("Chauffe invalide : erreurs, limitation ou fenêtres perdues.")
PYTHON
  verdict=0
  export PLANNING_PLATEAU=2m
  for round in 1 2 3; do
    cohorts=(10 100)
    [[ "$round" != 2 ]] || cohorts=(100 10)
    for cohort in "${cohorts[@]}"; do
      export PLANNING_PROPERTY_COUNT="$cohort"
      status=0
      run_measurement "small-${cohort}-round-${round}" || status=$?
      [[ "$status" == 0 || "$status" == 99 ]] || exit "$status"
    done
  done
  exit "$verdict"
fi

# Comparaison des trois tailles au même faible débit, avec toutes les pages du catalogue.
export PLANNING_WINDOWS_PER_SECOND=1 PLANNING_INCLUDE_CATALOG=true
for cohort in 10 100 1000; do
  export PLANNING_PROPERTY_COUNT="$cohort"
  status=0
  run_measurement "portfolio-${cohort}" || status=$?
  [[ "$status" == 0 || "$status" == 99 ]] || exit "$status"
done

# Douze comptes indépendants : montée conditionnée au succès du palier précédent.
unset PLANNING_PROPERTY_COUNT
export PLANNING_INCLUDE_CATALOG=false
for rate in 1 5 10; do
  [[ "$rate" -le "${BAITLY_BENCHMARK_MAX_RATE:-1}" ]] || break
  export PLANNING_WINDOWS_PER_SECOND="$rate"
  status=0
  run_measurement "multi-account-${rate}" || status=$?
  if [[ "$status" != 0 ]]; then
    echo 'Palier non validé : aucune augmentation supplémentaire du débit.'
    [[ "$status" == 99 ]] || exit "$status"
    break
  fi
done
exit "$verdict"
