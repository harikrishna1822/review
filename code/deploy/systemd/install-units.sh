#!/usr/bin/env bash
# Install the dbt-horizon systemd units for the service user (run as root).
#
#   sudo install-units.sh <user> [home]      e.g. sudo install-units.sh dbthorizon /home/dbthorizon
#
# Then per deployment: sudo systemctl enable --now dbt-horizon@<name>.timer
set -euo pipefail

user=${1:?usage: install-units.sh <user> [home]}
home_dir=${2:-$(getent passwd "$user" | cut -d: -f6)}
group=$(id -gn "$user")
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
[ -x "$home_dir/app/deploy/run.sh" ] || { echo "$home_dir/app/deploy/run.sh not found: run install.sh first" >&2; exit 1; }

src=$(cd "$(dirname "$0")" && pwd)
for unit in dbt-horizon@.service dbt-horizon@.timer dbt-horizon-cleanup.service dbt-horizon-cleanup.timer; do
  sed -e "s|@USER@|$user|g" -e "s|@GROUP@|$group|g" -e "s|@HOME@|$home_dir|g" "$src/$unit" \
    > "/etc/systemd/system/$unit"
  echo "installed /etc/systemd/system/$unit"
done
systemctl daemon-reload
systemctl enable --now dbt-horizon-cleanup.timer
echo "Enable a deployment: systemctl enable --now dbt-horizon@<name>.timer"
