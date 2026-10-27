#!/bin/sh
# dbt-horizon container entrypoint: finds the config, then runs `dbt-horizon <command> -c <config> ...`.
#
# Config, first found:
#   DBT_HORIZON_CONFIG       the YAML itself (e.g. an ECS environment variable)
#   DBT_HORIZON_CONFIG_B64   the YAML, base64-encoded
#   DBT_HORIZON_CONFIG_FILE  a path (default /config/dbt-horizon.yml, e.g. a mounted file)
# Secrets: the env vars the config names (pat_env, token_env), e.g. SNOWFLAKE_PAT.
set -eu

command=${1:-watch}
[ $# -gt 0 ] && shift

case $command in
  version|--help|-h|help) exec dbt-horizon "$command" "$@" ;;
  sh|bash) exec "$command" "$@" ;;                  # debugging: docker run -it ... sh
esac

config=${DBT_HORIZON_CONFIG_FILE:-/config/dbt-horizon.yml}
if [ -n "${DBT_HORIZON_CONFIG:-}" ]; then
  config=/tmp/dbt-horizon.yml
  printf '%s\n' "$DBT_HORIZON_CONFIG" > "$config"
elif [ -n "${DBT_HORIZON_CONFIG_B64:-}" ]; then
  config=/tmp/dbt-horizon.yml
  printf '%s' "$DBT_HORIZON_CONFIG_B64" | base64 -d > "$config"
fi
if [ ! -f "$config" ]; then
  echo "dbt-horizon: no config. Mount it at /config/dbt-horizon.yml, or set DBT_HORIZON_CONFIG," >&2
  echo "DBT_HORIZON_CONFIG_B64 or DBT_HORIZON_CONFIG_FILE." >&2
  exit 2
fi

exec dbt-horizon "$command" -c "$config" "$@"
