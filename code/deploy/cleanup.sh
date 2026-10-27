#!/usr/bin/env bash
# Remove old dbt-horizon workspaces and run logs (deploy layout, see docs/deploy.md).
#
#   cleanup.sh            uses $DBT_HORIZON_HOME (default: $HOME) and deploy.env
#
# Settings (environment, else deploy.env KEY=VALUE lines):
#   KEEP_WORKSPACE_DAYS   workspaces (one per repo commit) untouched this long are removed (default 14)
#   KEEP_LOG_DAYS         logs/<name>/<run> folders older than this are removed (default 30)
#   WORKSPACE_ROOT        where the configs' workspace_root folders live (default: $DBT_HORIZON_HOME/.dbt_horizon)
#
# The repo cache (repos/) and read-mode outputs (outputs/) are kept: they are reused.
set -euo pipefail

home_dir=${DBT_HORIZON_HOME:-$HOME}
# shellcheck source=settings.sh
. "$(dirname "$0")/settings.sh"
load_settings "$home_dir/deploy.env"
keep_ws=${KEEP_WORKSPACE_DAYS:-14}
keep_logs=${KEEP_LOG_DAYS:-30}
root=${WORKSPACE_ROOT:-$home_dir/.dbt_horizon}

removed=0
remove_old() {      # <parent> <depth> <days>: folders at that depth, not modified for <days>
  [ -d "$1" ] || return 0
  while IFS= read -r -d '' dir; do
    rm -rf -- "$dir"
    echo "removed $dir"
    removed=$((removed + 1))
  done < <(find "$1" -mindepth "$2" -maxdepth "$2" -type d -mtime "+$3" -print0)
}

# every workspaces/ folder under the root (one per config when workspace_root is per config)
if [ -d "$root" ]; then
  while IFS= read -r -d '' ws; do
    remove_old "$ws" 2 "$keep_ws"
  done < <(find "$root" -maxdepth 3 -type d -name workspaces -print0)
fi
remove_old "$home_dir/logs" 2 "$keep_logs"
echo "cleanup done: $removed folder(s) removed"
