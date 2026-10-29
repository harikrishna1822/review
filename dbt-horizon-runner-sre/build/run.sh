#!/bin/sh
# dbt-horizon runner: pull a branch exported by `dbt-horizon export` and run it with plain dbt on
# DuckDB (no dbt-horizon, no dashboard). The branch holds the DuckDB-compatible models, macros,
# sources and the profile (<project>/dbt_horizon/profiles.yml). See docs/runner.md.
#
# Required
#   RUNNER_REPO_URL             https URL of the dbt repo
#   RUNNER_REPO_REF             the exported branch, e.g. dbt-horizon/duckdb-test
#   DBT_HORIZON_READER_PAT   Snowflake PAT of the reader role  (or SNOWFLAKE_PAT)
#   DBT_HORIZON_WRITER_PAT   Snowflake PAT of the writer role  (or SNOWFLAKE_WRITE_PAT; write mode)
# Optional
#   GIT_TOKEN                private repo: read-only token (or GITHUB_TOKEN); GIT_TOKEN_USER (x-access-token)
#   RUNNER_PROJECT_DIR          the dbt project inside the repo (default: repo root)
#   RUNNER_COMMAND              build | run | test | seed | ... (default build)
#   RUNNER_TARGET               horizon_write | horizon_read (default horizon_write)
#   RUNNER_SELECTOR             default dbt_horizon (what runs on DuckDB); RUNNER_SELECT: --select instead
#   RUNNER_ARGS                 extra dbt arguments, e.g. "--full-refresh" or "--threads 4"
#   RUNNER_INTERVAL             0: run once and exit with dbt's code (ECS scheduled task, default);
#                            N: pull + run every N seconds (long-running ECS service)
set -eu

case ${1:-run} in
  sh|bash) exec "$@" ;;                             # debugging: docker run -it ... sh
  version) exec dbt --version ;;
esac

: "${RUNNER_REPO_URL:?set RUNNER_REPO_URL}"
: "${RUNNER_REPO_REF:?set RUNNER_REPO_REF (the exported branch)}"
DBT_HORIZON_READER_PAT=${DBT_HORIZON_READER_PAT:-${SNOWFLAKE_PAT:-}}
DBT_HORIZON_WRITER_PAT=${DBT_HORIZON_WRITER_PAT:-${SNOWFLAKE_WRITE_PAT:-}}
export DBT_HORIZON_READER_PAT DBT_HORIZON_WRITER_PAT
unset SNOWFLAKE_PAT SNOWFLAKE_WRITE_PAT
[ -n "$DBT_HORIZON_READER_PAT" ] || { echo "runner: set DBT_HORIZON_READER_PAT (or SNOWFLAKE_PAT)" >&2; exit 2; }

target=${RUNNER_TARGET:-horizon_write}
[ "$target" = horizon_read ] || [ -n "$DBT_HORIZON_WRITER_PAT" ] || {
  echo "runner: target $target writes Iceberg tables: set DBT_HORIZON_WRITER_PAT (or SNOWFLAKE_WRITE_PAT)" >&2; exit 2; }

# git auth through an http header in git's environment config: the token is never in the URL,
# the clone's .git/config or the logs
token=${GIT_TOKEN:-${GITHUB_TOKEN:-}}
unset GIT_TOKEN GITHUB_TOKEN
if [ -n "$token" ]; then
  basic=$(printf '%s:%s' "${GIT_TOKEN_USER:-x-access-token}" "$token" | base64 | tr -d '\n')
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="Authorization: Basic $basic"
  unset basic token
fi
export GIT_TERMINAL_PROMPT=0

repo=${RUNNER_WORK_DIR:-/work}/repo
project=$repo/${RUNNER_PROJECT_DIR:-.}
interval=${RUNNER_INTERVAL:-0}
stopping=0
trap 'stopping=1; echo "runner: stop requested; exiting after the current step"' TERM INT

log() { echo "$(date -u +%H:%M:%S) runner: $*"; }

# (called as `pull || ...`, where set -e doesn't apply: every step checks its own result)
pull() {
  if [ -d "$repo/.git" ]; then
    git -C "$repo" fetch --quiet --depth 1 origin "$RUNNER_REPO_REF" \
      && git -C "$repo" reset --quiet --hard FETCH_HEAD \
      && git -C "$repo" clean --quiet -ffdx -e target -e logs -e dbt_packages \
      || { log "git pull of $RUNNER_REPO_REF failed"; return 3; }
  else
    rm -rf "$repo"
    git clone --quiet --depth 1 --branch "$RUNNER_REPO_REF" "$RUNNER_REPO_URL" "$repo" \
      || { log "git clone of $RUNNER_REPO_REF failed (URL, branch, GIT_TOKEN?)"; return 3; }
  fi
  log "$RUNNER_REPO_REF @ $(git -C "$repo" rev-parse --short=12 HEAD)"
  [ -f "$project/dbt_project.yml" ] || { log "no dbt_project.yml in ${RUNNER_PROJECT_DIR:-.}: set RUNNER_PROJECT_DIR"; return 2; }
  [ -f "$project/dbt_horizon/profiles.yml" ] || { log "no dbt_horizon/profiles.yml: is $RUNNER_REPO_REF a dbt-horizon export branch?"; return 2; }
}

run_dbt() {
  cd "$project" || return 2
  common="--profiles-dir dbt_horizon --target $target"
  if [ -f packages.yml ] || [ -f dependencies.yml ]; then
    # shellcheck disable=SC2086
    dbt deps $common --quiet || { log "dbt deps failed"; return 2; }
  fi
  if [ -n "${RUNNER_SELECT:-}" ]; then select="--select $RUNNER_SELECT"; else select="--selector ${RUNNER_SELECTOR:-dbt_horizon}"; fi
  log "dbt ${RUNNER_COMMAND:-build} --target $target $select ${RUNNER_ARGS:-}"
  # word splitting of $select / $RUNNER_ARGS is intended
  # shellcheck disable=SC2086
  dbt "${RUNNER_COMMAND:-build}" $common $select ${RUNNER_ARGS:-}
}

cycle() {
  started=$(date +%s)
  code=0
  pull || code=$?
  [ "$code" -ne 0 ] || run_dbt || code=$?
  log "finished in $(( $(date +%s) - started ))s, exit $code"
  return "$code"
}

if [ "$interval" -eq 0 ]; then
  cycle
  exit $?
fi

while [ "$stopping" -eq 0 ]; do
  cycle || true
  [ "$stopping" -eq 0 ] || break
  log "next run in ${interval}s"
  sleep "$interval" &
  wait $! || true
done
log "stopped"
