# Deploying dbt-horizon on a machine

How to run dbt-horizon on your own server (a VM or an on-prem machine) on a schedule:
installed from a release tag, one **deployment** per dbt repo and environment, each run locked,
logged and cleaned up. Linux (systemd) first; [Windows](#windows) uses the same layout.

DuckDB is not a server: it is a library inside the dbt-horizon process (pinned `duckdb==1.5.6`,
installed with it). Nothing else needs to run on the machine.

```
  GitHub / GitLab              this machine                           Snowflake
 ┌───────────────┐      ┌──────────────────────────────────┐      ┌──────────────────┐
 │ dbt repo(s)   │─git─►│ systemd timer / Task Scheduler   │      │ Horizon catalog  │
 │ (read only)   │      │   └─ deploy/run.sh <deployment>  │─PAT─►│ Iceberg tables   │
 └───────────────┘      │        └─ dbt-horizon + DuckDB   │◄─S3─►│ (S3 / ext. vol.) │
                        └──────────────────────────────────┘      └──────────────────┘
```

## The deploy layout

Everything lives under one folder, the **home** (`$DBT_HORIZON_HOME`, default: the service user's
home on Linux, `C:\dbt-horizon` on Windows):

| Path | What | Who writes it |
|---|---|---|
| `app/` | this repo, checked out at a release tag (the scripts) | `install.sh` |
| `venv/` | Python environment with dbt-horizon from `app/` | `install.sh` |
| `configs/<name>.yml` | one deployment: repo + project + account + environment | you |
| `secrets/<name>.env` | its PATs and git token, `KEY=VALUE`, owner-only | you |
| `deploy.env` | machine settings (notifications, retention), no secrets | you (created from the example) |
| `.dbt_horizon/<name>/` | the deployment's repo clone, workspaces, read-mode outputs | dbt-horizon |
| `logs/<name>/<UTC time>/` | `run.log`, `status.json`, `artifacts/` (reports) per run | `run.sh` |
| `logs/<name>/last_status.json` | result of the latest run (for monitoring) | `run.sh` |
| `locks/` | one lock per deployment | `run.sh` |

**A deployment** is a name such as `retail.prod`: `configs/retail.prod.yml` +
`secrets/retail.prod.env`, run by `run.sh retail.prod` and the timer `dbt-horizon@retail.prod.timer`.
Make one per dbt repo *and* environment (`retail.prod`, `retail.test`, `finance.prod`).

Rules that keep deployments apart:

- **`workspace_root: ../.dbt_horizon/<name>` in every config.** Each deployment gets its own repo
  clone and workspaces, so two deployments can run at the same time without touching each other's
  files (two runs sharing one clone would fight over its checkout).
- **A different `target_naming.schema` per environment of the same repo** (`{schema}_ICEBERG` for
  prod, `{schema}_ICEBERG_TEST` for test), so a test run never writes production tables.
- **Never two runs of one deployment at once:** `run.sh` takes the deployment's lock; a run that
  finds it taken exits with code 75 and does nothing. Two deployments that write the *same*
  tables share a lock: set `LOCK_NAME` for both (see [Settings](#settings)).

## Linux, step by step

### 1. The machine (once)

| | Recommendation |
|---|---|
| OS | Ubuntu 22.04/24.04 or any systemd Linux; Python 3.11+ and git |
| Size | 4 vCPU, 16 GB RAM, 50 GB disk to start (DuckDB works in memory) |
| Location | the cloud region of the S3 bucket behind the Iceberg tables |
| Public IP | **static** (e.g. AWS Elastic IP): Snowflake's network policy allows exact IPs |
| Network | outbound HTTPS to `github.com`, `<account>.snowflakecomputing.com`, the S3 endpoint; no inbound ports |

```bash
sudo apt update && sudo apt install -y python3 python3-venv git curl
sudo useradd -m -s /bin/bash dbthorizon        # service user: owns everything, not root
```

### 2. Install dbt-horizon (once; again to upgrade)

```bash
sudo -iu dbthorizon
curl -fsSLO https://raw.githubusercontent.com/harikrishna1822/dbt-horizon/v0.8.0/deploy/install.sh
bash install.sh --version v0.8.0              # --python python3.12 if python3 is older than 3.11
```

`install.sh` clones this repo into `~/app` at the tag, creates `~/venv` and installs dbt-horizon
from it, and creates `configs/ secrets/ logs/ locks/ .dbt_horizon/` and `deploy.env`. Always install
a **tag**, never `main`: the machine runs a known version, and the scripts match the package.
Private copy of this repo: `DBT_HORIZON_GIT_TOKEN=<read-only token> bash install.sh ...`.

### 3. Snowflake (once per account)

1. Create the setup script and run it in Snowflake as an administrator: writer role, target
   schema(s) with the external volume, grants.

   ```bash
   ~/venv/bin/dbt-horizon setup-sql -c ~/configs/retail.prod.yml \
     --external-volume S3_LAKE_VOL --service-user DBT_HORIZON_SVC --network-policy DBT_HORIZON_NP -o setup.sql
   ```

2. Allow the machine's **static public IP** in the network policy of the reader and writer PAT
   users (`curl -s https://checkip.amazonaws.com` prints it).
3. Create the two PATs: reader (`DUCKDB_READER`, SELECT only) and writer (`DBT_DUCKDB_WRITER`).

### 4. Git access (once per dbt repo)

Public repos need nothing. For a private repo create a **read-only** token (GitHub fine-grained:
"Contents: read" on that repo only; GitLab: project access token, `read_repository`) and set
`repo.token_env` in the config. The machine never pushes, unless you run `export --push`.

### 5. A deployment: config + secrets

```bash
cp ~/app/deploy/examples/config.yml ~/configs/retail.prod.yml     # or: dbt-horizon init ... -o
cp ~/app/deploy/examples/secrets.env ~/secrets/retail.prod.env
chmod 600 ~/secrets/retail.prod.env
nano ~/configs/retail.prod.yml ~/secrets/retail.prod.env
```

In the config: `repo` (url, `ref: main`, `project_dir`), `snowflake` (account, databases, roles),
`source_mapping`, `target_naming`, `mode: write`, and `workspace_root: ../.dbt_horizon/retail.prod`.
In the secrets file: the values of the env vars the config names (`SNOWFLAKE_PAT`,
`SNOWFLAKE_WRITE_PAT`, and the git token if any). See [the example](../deploy/examples/config.yml).

### 6. First run by hand (once per deployment)

Each must pass before the next:

```bash
R=~/app/deploy/run.sh
DBT_HORIZON_COMMAND=connect $R retail.prod --probe      # Horizon login, IP allowed, S3 readable
DBT_HORIZON_COMMAND=analyze $R retail.prod --mode write # report: nothing needs_mapping
$R retail.prod --mode read                              # builds into a local file, Snowflake untouched
$R retail.prod --mode write                             # builds the Iceberg tables
```

Every call leaves `~/logs/retail.prod/<time>/run.log` and its reports in `artifacts/`.

### 7. Schedule it

```bash
sudo ~/app/deploy/systemd/install-units.sh dbthorizon            # once per machine
sudo systemctl enable --now dbt-horizon@retail.prod.timer         # once per deployment
systemctl list-timers 'dbt-horizon*'
```

`install-units.sh` installs:

| Unit | Does |
|---|---|
| `dbt-horizon@<name>.service` | one run: `run.sh <name>` as the service user (`mode` from the config) |
| `dbt-horizon@<name>.timer` | daily at 02:00; a run missed while the machine was off starts at boot |
| `dbt-horizon-cleanup.timer` | weekly (Sunday 04:00): `cleanup.sh` (enabled by `install-units.sh`) |

Another schedule for one deployment:

```bash
sudo systemctl edit dbt-horizon@retail.prod.timer
#   [Timer]
#   OnCalendar=
#   OnCalendar=*-*-* 06,18:00:00
```

Run now / follow it: `sudo systemctl start dbt-horizon@retail.prod.service` and
`journalctl -u dbt-horizon@retail.prod.service -f`. Extra options for scheduled runs (for example
`--select tag:daily`) go in an override: `sudo systemctl edit dbt-horizon@retail.prod.service` with
`ExecStart=` then `ExecStart=/home/dbthorizon/app/deploy/run.sh %i --select tag:daily`.

### 8. Operate

| Task | How |
|---|---|
| Is it healthy? | `cat ~/logs/<name>/last_status.json`: `exit_code` 0, `finished` recent |
| Alerts | `NOTIFY_WEBHOOK` in `deploy.env` (Slack-compatible): posted on every failed run |
| Why did it fail? | `~/logs/<name>/<time>/run.log`, then `artifacts/compat_report_*.md` and `run_*.json` |
| Disk | `cleanup.sh` (weekly timer) removes workspaces unused for `KEEP_WORKSPACE_DAYS` and logs older than `KEEP_LOG_DAYS` |
| PAT rotation | replace the value in `secrets/<name>.env`; the next run uses it, nothing to restart |
| Upgrade | `bash ~/app/deploy/install.sh --version v0.9.0`, then step 6's `analyze` once |
| Roll back | the same with the previous tag |
| New dbt repo / environment | steps 4–7 for a new deployment name only |
| Pause a deployment | `sudo systemctl disable --now dbt-horizon@<name>.timer` |

## Windows

Same layout under `C:\dbt-horizon`, PowerShell scripts in `deploy\windows\`, Task Scheduler instead
of systemd. Install [Python 3.11+](https://www.python.org/downloads/windows/) and
[Git for Windows](https://git-scm.com/download/win) first, then, as the service user:

```powershell
git clone https://github.com/harikrishna1822/dbt-horizon.git C:\dbt-horizon\app
powershell -ExecutionPolicy Bypass -File C:\dbt-horizon\app\deploy\windows\install.ps1 -Version v0.8.0
```

`install.ps1` checks out the tag, creates `venv\`, the folders and `deploy.env`, and limits
`secrets\` to this user, SYSTEM and Administrators. Then steps 3–6 as on Linux with
`C:\dbt-horizon\app\deploy\windows\run.ps1 retail.prod --mode read` and, as administrator:

```powershell
C:\dbt-horizon\app\deploy\windows\register-tasks.ps1 -Name retail.prod -At 02:00
C:\dbt-horizon\app\deploy\windows\register-tasks.ps1 -Cleanup
Start-ScheduledTask -TaskPath '\dbt-horizon\' -TaskName 'dbt-horizon retail.prod'
```

The tasks run as the given user whether it is logged on or not (no password stored), never start
twice (`MultipleInstances IgnoreNew`) and stop after 6 hours. `run.ps1` also takes a lock, so a
run started by hand during a scheduled one exits with 75.

## Run on every merge instead of a schedule

Make the machine a self-hosted CI runner for the dbt repo (GitHub: repo > Settings > Actions >
Runners; GitLab: Settings > CI/CD > Runners) and use the [CI templates](ci.md) with
`runs-on: self-hosted`. Merges then build on this machine, with its static IP. Keep one timer as
a nightly safety net, and give both the same deployment lock or the same CI concurrency group.

## Settings

`deploy.env` holds `KEY=VALUE` lines (no shell, no inline comments); a variable set in the
environment wins over the file.

| Setting | Default | Used by |
|---|---|---|
| `DBT_HORIZON_HOME` | `$HOME` / `C:\dbt-horizon` | all (environment only) |
| `DBT_HORIZON_BIN` | `<home>/venv/bin/dbt-horizon` | run |
| `DBT_HORIZON_COMMAND` | `run` | run: `run`, `analyze`, `connect`, `export`, `inspect` |
| `LOCK_NAME` | the deployment name | run: deployments writing the same tables share one |
| `NOTIFY_WEBHOOK` | none | run: Slack-compatible URL, posted `{"text": ...}` |
| `NOTIFY_ON` | `failure` | run: `failure` or `always` |
| `KEEP_WORKSPACE_DAYS` | 14 | cleanup |
| `KEEP_LOG_DAYS` | 30 | cleanup |
| `WORKSPACE_ROOT` | `<home>/.dbt_horizon` | cleanup |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | the run failed: dbt build failure, preflight, Horizon or repo error ([details](ci.md#exit-codes)) |
| 2 | config error, or unknown deployment |
| 75 | skipped: the previous run holding the same lock is still going (systemd counts it as success) |

## Troubleshooting

| Message in `run.log` | Fix |
|---|---|
| `This machine's public IP is not allowed by the network policy` | add the IP to the PAT users' network policy; give the machine a static IP |
| `PAT rejected` | PAT expired or wrong, or the role is not granted to the PAT's user: new PAT in `secrets/` |
| `Preflight ... not visible to role` | run `setup-sql` and execute the script (a new target schema) |
| `Several dbt projects in the repo` | set `repo.project_dir` |
| `config not found` | the deployment name must match `configs/<name>.yml` |
| `skipped: a run holding lock ... is still going` | normal when runs overlap; if it never clears, check for a hung run (`systemctl status`) |
| git authentication errors | `repo.token_env` names a variable in `secrets/<name>.env` with a valid read-only token |
