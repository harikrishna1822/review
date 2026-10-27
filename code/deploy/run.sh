#!/usr/bin/env bash
# dbt-horizon scheduled run: one deployment (config) per call, never two at once.
#
#   run.sh <name> [dbt-horizon options...]       e.g. run.sh retail.prod --mode write
#
# Uses the deploy layout under $DBT_HORIZON_HOME (default: $HOME), see docs/deploy.md:
#   configs/<name>.yml    the dbt-horizon config
#   secrets/<name>.env    its PATs / git token (optional: else the environment is used)
#   deploy.env            settings below (optional)
#   logs/<name>/<UTC time>/run.log, status.json, artifacts/
#
# Settings (environment, else deploy.env KEY=VALUE lines):
#   DBT_HORIZON_BIN       dbt-horizon executable (default: $DBT_HORIZON_HOME/venv/bin/dbt-horizon)
#   DBT_HORIZON_COMMAND   run | analyze | export | connect ... (default: run)
#   LOCK_NAME             lock shared by deployments that must not overlap (default: <name>)
#   NOTIFY_WEBHOOK        Slack-compatible webhook, posted {"text": ...}
#   NOTIFY_ON             failure | always (default: failure)
#
# Exit code: dbt-horizon's (0 ok, 1 failed, 2 config error), 75 = skipped, the previous run
# of the same lock is still going.
set -uo pipefail

if [ $# -lt 1 ] || [ "${1#-}" != "$1" ]; then
  echo "usage: $0 <name> [dbt-horizon options...]" >&2
  exit 2
fi
name=$1
shift
case $name in
  *[!A-Za-z0-9._-]*) echo "invalid deployment name: $name (letters, digits, . _ -)" >&2; exit 2 ;;
esac

home_dir=${DBT_HORIZON_HOME:-$HOME}
# shellcheck source=settings.sh
. "$(dirname "$0")/settings.sh"
load_settings "$home_dir/deploy.env"
bin=${DBT_HORIZON_BIN:-$home_dir/venv/bin/dbt-horizon}
command=${DBT_HORIZON_COMMAND:-run}
lock_name=${LOCK_NAME:-$name}
notify_on=${NOTIFY_ON:-failure}

config=$home_dir/configs/$name.yml
env_file=$home_dir/secrets/$name.env
if [ ! -f "$config" ]; then
  echo "config not found: $config" >&2
  exit 2
fi

# --- lock: one run per lock name ------------------------------------------------------
mkdir -p "$home_dir/locks"
lock=$home_dir/locks/$lock_name.lock
if command -v flock >/dev/null 2>&1; then
  exec 9>"$lock"
  if ! flock -n 9; then
    echo "skipped: a run holding lock '$lock_name' is still going ($lock)" >&2
    exit 75
  fi
else
  # No flock (e.g. Git Bash): a lock directory holding the owner's pid; stale ones are taken over.
  if ! mkdir "$lock.d" 2>/dev/null; then
    owner=$(cat "$lock.d/pid" 2>/dev/null || true)
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      echo "skipped: a run holding lock '$lock_name' is still going (pid $owner)" >&2
      exit 75
    fi
    rm -rf "$lock.d" && mkdir "$lock.d" || { echo "can't take lock $lock.d" >&2; exit 75; }
  fi
  echo $$ > "$lock.d/pid"
  trap 'rm -rf "$lock.d"' EXIT
fi

# --- run --------------------------------------------------------------------------------
started=$(date -u +%Y%m%dT%H%M%SZ)
run_dir=$home_dir/logs/$name/$started
[ -e "$run_dir" ] && run_dir=$run_dir-$$          # two runs in one second (e.g. a different command)
mkdir -p "$run_dir"

args=("$command" -c "$config")
[ -f "$env_file" ] && args+=(--env-file "$env_file")
case $command in
  run|analyze|export) args+=(--artifacts "$run_dir/artifacts") ;;
esac
args+=("$@")

{
  echo "dbt-horizon deploy: $name, $command, started $started on $(hostname)"
  echo "command: $bin ${args[*]}"
} | tee "$run_dir/run.log"
"$bin" "${args[@]}" 2>&1 | tee -a "$run_dir/run.log"
code=${PIPESTATUS[0]}
finished=$(date -u +%Y%m%dT%H%M%SZ)
echo "finished $finished, exit code $code" | tee -a "$run_dir/run.log"

cat > "$run_dir/status.json" <<EOF
{"name": "$name", "command": "$command", "started": "$started", "finished": "$finished", "exit_code": $code, "log": "$run_dir/run.log"}
EOF
cp "$run_dir/status.json" "$home_dir/logs/$name/last_status.json"

# --- notify -----------------------------------------------------------------------------
if [ -n "${NOTIFY_WEBHOOK:-}" ] && { [ "$code" -ne 0 ] || [ "$notify_on" = always ]; }; then
  result=$([ "$code" -eq 0 ] && echo "OK" || echo "FAILED (exit $code)")
  text="dbt-horizon $name ($command) on $(hostname): $result. Log: $run_dir/run.log"
  text=${text//\\/\/}
  text=${text//\"/\'}
  curl -fsS -m 15 -H 'Content-Type: application/json' -d "{\"text\": \"$text\"}" "$NOTIFY_WEBHOOK" >/dev/null \
    || echo "warning: notification to NOTIFY_WEBHOOK failed" >&2
fi
exit "$code"
