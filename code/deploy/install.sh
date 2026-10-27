#!/usr/bin/env bash
# Install or upgrade dbt-horizon on a Linux machine, in the deploy layout (docs/deploy.md).
#
#   install.sh --version v0.8.0 [--home DIR] [--python python3.12] [--repo URL]
#
# Run as the service user. Re-run with another --version to upgrade or roll back.
# Private repo: set DBT_HORIZON_GIT_TOKEN (read-only token), it is not stored.
set -euo pipefail

version="" home_dir=${DBT_HORIZON_HOME:-$HOME} python=python3 repo=https://github.com/harikrishna1822/dbt-horizon.git
while [ $# -gt 0 ]; do
  case $1 in
    --version) version=$2; shift 2 ;;
    --home) home_dir=$2; shift 2 ;;
    --python) python=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$version" ] || { echo "--version is required (a release tag, e.g. v0.8.0)" >&2; exit 2; }

command -v git >/dev/null || { echo "git is not installed" >&2; exit 1; }
"$python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null \
  || { echo "$python must be Python 3.11 or newer (use --python python3.12)" >&2; exit 1; }

git_auth=()
if [ -n "${DBT_HORIZON_GIT_TOKEN:-}" ]; then
  basic=$(printf 'x-access-token:%s' "$DBT_HORIZON_GIT_TOKEN" | base64 | tr -d '\n')
  git_auth=(-c "http.extraHeader=Authorization: Basic $basic")
fi

app=$home_dir/app
echo "==> dbt-horizon $version into $app"
if [ -d "$app/.git" ]; then
  git "${git_auth[@]}" -C "$app" fetch --quiet --tags --force origin
else
  git "${git_auth[@]}" clone --quiet "$repo" "$app"
fi
git -C "$app" -c advice.detachedHead=false checkout --quiet --force "refs/tags/$version"

echo "==> Python environment $home_dir/venv"
[ -x "$home_dir/venv/bin/python" ] || "$python" -m venv "$home_dir/venv"
"$home_dir/venv/bin/python" -m pip install --quiet --upgrade "$app[export]"
chmod +x "$app"/deploy/*.sh "$app"/deploy/systemd/*.sh

echo "==> Folders"
mkdir -p "$home_dir"/{configs,secrets,logs,locks,.dbt_horizon}
chmod 700 "$home_dir/secrets"
if [ ! -f "$home_dir/deploy.env" ]; then
  cp "$app/deploy/examples/deploy.env" "$home_dir/deploy.env"
  echo "    created $home_dir/deploy.env"
fi

installed=$("$home_dir/venv/bin/dbt-horizon" version)
echo "==> Installed dbt-horizon $installed"
cat <<EOF

Next (docs/deploy.md):
  1. $home_dir/venv/bin/dbt-horizon init ... -o $home_dir/configs/<name>.yml
     (or copy $app/deploy/examples/config.yml), with workspace_root: ../.dbt_horizon/<name>
  2. $home_dir/secrets/<name>.env from $app/deploy/examples/secrets.env, chmod 600
  3. $app/deploy/run.sh <name> --mode read
  4. sudo $app/deploy/systemd/install-units.sh $(id -un) $home_dir, then
     sudo systemctl enable --now dbt-horizon@<name>.timer
EOF
