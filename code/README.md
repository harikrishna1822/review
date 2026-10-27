# dbt-horizon

Run a Snowflake dbt project on DuckDB against the account's Snowflake-managed Iceberg tables,
through the Snowflake Horizon Iceberg REST Catalog. Works for any dbt repo (GitHub, GitLab,
self-hosted) and any Snowflake account; the customer repo is never modified.

Design: [docs/design.md](docs/design.md). Status:
- **Phase 1 (foundation)**: config, repo sync, workspace, Horizon connection, `connect`.
- **Phase 2 (inspect + analyze)**: dbt-parsed inventory, rule engine, compatibility report.
- **Phase 3 (read mode)**: overlay in the workspace, `dbt build` on DuckDB into a local file.
- **Phase 4 (write mode)**: models written back as Snowflake-managed Iceberg tables, preflight, `setup-sql`.
- **Phase 5 (SQL layer)**: Snowflake SQL checked with DuckDB's parser and rewritten with sqlglot.
- **Phase 6 (packaging)**: pip-installable wheel, `init`, CI options and templates ([docs/ci.md](docs/ci.md)).
- **Phase 7 (export)**: the overlay committed into the dbt repo as a branch for a PR, Snowflake target unchanged.
- **Phase 8 (deploy)**: install on your own machine, scheduled and locked runs with systemd or
  Task Scheduler, logs, alerts and cleanup ([docs/deploy.md](docs/deploy.md)).
- **Phase 9 (data-triggered, containers)**: `watch` rebuilds only the models whose source
  Iceberg tables have new data ([docs/watch.md](docs/watch.md)); Docker image
  ([docs/docker.md](docs/docker.md)); ECS Fargate with Terraform ([docs/ecs.md](docs/ecs.md)).

## Install

```bash
pip install "dbt-horizon @ git+https://github.com/harikrishna1822/dbt-horizon@main"   # pin a tag
```

Python 3.11+ and git on the PATH. For development:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -e ".[dev]"
```

## Configure

One YAML file per repo + account; secrets are referenced by env var name only.

```bash
dbt-horizon init --repo-url https://github.com/org/dbt-repo.git --account myorg-myaccount \
  --database RAW --project-dir analytics -o dbt-horizon.yml
```

See also [examples/snowflake-dbt.yml](examples/snowflake-dbt.yml). To run in GitHub Actions or
GitLab CI, see [docs/ci.md](docs/ci.md).

```powershell
Copy-Item examples\snowflake-dbt.env.example examples\snowflake-dbt.env   # fill in the PATs (git-ignored)
```

| Setting | Meaning |
|---|---|
| `repo.url`, `repo.ref` | git URL and branch/tag/commit to run |
| `repo.project_dir` | folder of `dbt_project.yml` (auto-detected if the repo has one) |
| `repo.token_env` | env var with an HTTPS token, for private repos |
| `repo.token_user` | user name sent with the token (`gitlab-ci-token` for GitLab's CI_JOB_TOKEN) |
| `snowflake.account` | `<org>-<account>` |
| `snowflake.databases` | databases to attach |
| `snowflake.reader` / `writer` | role + env var of its PAT (writer: write mode only) |
| `source_mapping` | where the Iceberg copy of a source schema lives (e.g. `CORE` -> `CORE_ICEBERG_S3`) |
| `snowflake.target` | database/schema of the Snowflake dbt target (default: the repo's `profiles.yml`) |
| `target_naming.schema` | write-mode target schema, e.g. `{schema}_ICEBERG` |
| `unsupported_policy` | `exclude` (skip blocked models and everything downstream) or `fail` |

## Commands

| Command | |
|---|---|
| `connect` | check Horizon access, list the Iceberg tables |
| `inspect` / `analyze` | inventory / compatibility report |
| `run` | `dbt build` on DuckDB, read or write mode |
| `watch` | write mode, data-triggered: rebuild models whose sources have new data ([docs/watch.md](docs/watch.md)) |
| `setup-sql` | Snowflake setup script for write mode |
| `export` | the overlay as a branch of the dbt repo |

```powershell
dbt-horizon connect -c examples\snowflake-dbt.yml --env-file examples\snowflake-dbt.env --probe
```

`connect` fetches the repo at the pinned ref into `.dbt_horizon/repos/`, builds a workspace copy
under `.dbt_horizon/workspaces/<repo>/<commit>/`, attaches each database through Horizon with
the reader PAT (read-only), lists the Iceberg tables (`--probe` reads one row of each), and, if a
writer is configured, lists the schemas the writer role can see.

```powershell
dbt-horizon inspect -c examples\snowflake-dbt.yml
dbt-horizon analyze -c examples\snowflake-dbt.yml --env-file examples\snowflake-dbt.env --mode write
```

`inspect` runs `dbt parse` in the workspace against a throwaway DuckDB profile that resolves
names like the Snowflake target (no Snowflake credentials), and prints the inventory: models by
materialization, tests, sources (and which take their location from `var()`), hooks, packages.

`analyze` applies the rules and writes `compat_report_<mode>.md` / `.json` in the workspace's
`.dbt_horizon/` folder. Every finding has one outcome:

| Outcome | Meaning |
|---|---|
| `auto_fixed` | the overlay changes it deterministically (e.g. view -> ephemeral, `--vars` remap) |
| `review` | runs, but a person should check it (e.g. FLATTEN until the transpile layer) |
| `needs_mapping` | config input required (e.g. source has no Iceberg copy in Horizon) |
| `unsupported` | can't run on DuckDB (e.g. Python/Snowpark models, CONNECT BY) |

Blocking outcomes (`needs_mapping`, `unsupported`) exclude the node and everything downstream
(policy `exclude`), or stop the run (policy `fail`, exit code 1). `--offline` skips the Horizon
check (sources become `review`).

```powershell
dbt-horizon run -c examples\snowflake-dbt.yml --env-file examples\snowflake-dbt.env --mode read
```

`run` analyzes, applies the overlay to the workspace copy and runs `dbt build` (in a subprocess,
the reader PAT passed only to it). Models build into
`.dbt_horizon/outputs/<repo>/<project>_local.duckdb`, schemas named as in Snowflake.

Read-mode overlay (all in the workspace, listed in `.dbt_horizon/overlay.json`):

| Change | Why |
|---|---|
| generated `profiles.yml` (target `horizon_read`) | local output file + every source database attached read-only through Horizon under its own name; PAT via `env_var('DBT_HORIZON_READER_PAT')` |
| `--vars` / sources yml rewrite | sources read their Iceberg copy (`source_mapping`) |
| `--exclude <node>+` | blocked nodes and everything downstream |
| `macros/dbt_horizon/compat.sql` + `on-run-start` hook | DuckDB macros for IFF, NVL, NVL2, DIV0, ZEROIFNULL, NULLIFZERO, TO_VARCHAR, ARRAY_SIZE |
| `macros/dbt_horizon/run_hooks.sql` | model hooks that are Snowflake admin statements (GRANT, ...) are skipped |
| `macros/dbt_horizon/naming.sql` | every model builds into the local database (`generate_database_name`) |
| `macros/dbt_horizon/materialization_<name>.sql` | `dynamic_table` / `materialized_view` build as tables |
| `dbt_project.yml` hooks | Snowflake admin statements removed from on-run-start/end |

Staging views keep their Snowflake materialization; they read the Horizon attach, so they work
during dbt runs (and in any session that attaches the same databases), tables work anywhere.

### SQL layer (both modes)

Every SQL model, snapshot and singular test is checked during `analyze` / `run`:

1. Jinja is masked: `{{ ... }}` inside the SQL becomes a placeholder; leading Jinja (`config()`,
   `set`) and trailing statement/comment tags are kept aside verbatim.
2. DuckDB's own parser (pinned DuckDB, `json_serialize_sql`, no tables needed) must accept it, and
   every function and type it names must exist in DuckDB or in the compat macros.
3. If not, or if Snowflake syntax DuckDB would read differently is detected (e.g. `col:field`,
   `FLATTEN`, which DuckDB has with another meaning), sqlglot (pinned) rewrites it Snowflake ->
   DuckDB, plus two transforms of ours:
   - `LATERAL FLATTEN(input => x) f` with `f.value` -> `UNNEST(x) AS f(value)`;
   - `v:path::string` -> `v ->> '$.path'` (plain text, as in Snowflake, not a quoted JSON string).
4. The rewrite is used only if it passes step 2; it replaces the model file in the workspace copy,
   with a `-- rewritten ... (sqlglot <version>)` header.

| Result | Outcome |
|---|---|
| unchanged, only compat functions (IFF, NVL, DIV0, TO_TIMESTAMP_NTZ, ...) | `auto_fixed` |
| rewritten (DATEADD, TRY_TO_*, TIMESTAMP_NTZ, IDENTIFIER, WITHIN GROUP, ...) | `auto_fixed` |
| rewritten semi-structured access (FLATTEN, `col:field`, PARSE_JSON, OBJECT_CONSTRUCT) | `review`: the result depends on whether the Iceberg column is a STRUCT or JSON text |
| not rewritable (FLATTEN with INDEX/PATH/OUTER, unknown function, parse error) | `review`, expected to fail at run time |
| Jinja `{% if %}` blocks inside the SQL | not checked or rewritten |
| CONNECT BY, MATCH_RECOGNIZE, stages | `unsupported` (excluded) |

### Export: the overlay as a pull request (optional)

```bash
pip install "dbt-horizon[export] @ git+https://github.com/harikrishna1822/dbt-horizon@v0.6.0"
dbt-horizon export -c dbt-horizon.yml --mode write            # local branch only
dbt-horizon export -c dbt-horizon.yml --mode write --push     # push it, print the PR / MR link
```

Instead of applying the overlay per run, `export` commits it into the dbt repo on a branch
(`dbt-horizon/<mode>-<commit>`), so the team can review it and run it with plain dbt:
`dbt build --profiles-dir dbt_horizon --target horizon_<mode> --selector dbt_horizon`.

Everything exported is conditional on `target.type == 'duckdb'`, so the repo's Snowflake run is
unchanged:

| Overlay piece | Exported as |
|---|---|
| shim macros (`run_hooks`, `generate_*_name`) | `dbt_horizon__<name>` + a dispatcher: DuckDB -> shim, other adapters -> the project's macro (renamed `project_<name>`) or dbt's own dispatch |
| materializations | unchanged (declared for `adapter="duckdb"` only) |
| source remap | the sources yml value: `"{{ 'CORE_ICEBERG_S3' if target.type == 'duckdb' else (var('source_schema')) }}"` (not in `vars:`: dbt doesn't render Jinja in var values) |
| rewritten SQL | `{% if target.type == 'duckdb' %}rewritten{% else %}original{% endif %}` |
| Snowflake admin project hooks | wrapped in `{% if target.type != 'duckdb' %}` |
| excludes | selector `dbt_horizon` in `selectors.yml` |
| profile | `dbt_horizon/profiles.yml` (+ `README.md`); the repo's `profiles.yml` is not touched |

Before committing, `export` compiles the original and the exported project against a Snowflake
target (offline, dummy credentials, needs the `export` extra) and requires the same SQL for every
node; otherwise nothing is committed. Files keep their committed newline style, so the PR diff
shows only real changes. Branches under `dbt-horizon/` are the app's: re-exporting replaces them.

### Write mode

```powershell
dbt-horizon setup-sql -c examples\snowflake-dbt.yml --external-volume S3_LAKE_VOL --network-policy DUCKDB_NP
#   -> run the generated script in Snowflake once, put the writer PAT in the env file
dbt-horizon run -c examples\snowflake-dbt.yml --env-file examples\snowflake-dbt.env --mode write
```

Models land in Snowflake as Iceberg tables: `<DB>.<target_naming.schema>.<NAME>`, e.g.
`RETAIL_ANALYTICS.DBT_RETAIL_ICEBERG.FCT_SALES`, owned by the writer role and queryable from Snowflake.

- **Preflight**: the writer PAT works and every target schema exists and is visible to the
  writer role; otherwise nothing runs and `setup-sql` is suggested.
- **`setup-sql`**: renders the Snowflake script for the config (writer role, target schemas with
  `EXTERNAL_VOLUME` + `CATALOG = 'SNOWFLAKE'`, grants, service user, PAT); unknown values are
  `<PLACEHOLDERS>`.
- **Profile** (target `horizon_write`): each source database attached read-only with the reader
  PAT (`<DB>`), each target database with the writer PAT and Horizon's write options (`<DB>__OUT`).
- **Shim** (no model config is changed; the root project's materializations win):
  - `table`, `dynamic_table`, `materialized_view`: DROP + CTAS (Iceberg REST has no rename);
  - `incremental`: append, or delete+insert / merge on `unique_key`;
  - column types Iceberg can't store are cast from a `DESCRIBE` of the query
    (`HUGEINT` from `SUM(int)` -> `DECIMAL(38,0)`, unsigned / small ints, `ENUM`, ...);
  - naming: the project's (or dbt's default) names, then `target_naming` (schema template,
    upper-case identifiers);
  - views and seeds go to DuckDB's in-memory database for the run (Iceberg holds neither);
  - every statement and hook commits on its own (Horizon commits one table per transaction).
- A table is missing between its DROP and CTAS, and stays missing if the CTAS fails: re-run it.
- Not supported in write mode: snapshots (excluded with everything downstream).

## Tests

```powershell
.\.venv\Scripts\python.exe -m pytest                      # unit + offline, no network
$env:DBT_HORIZON_ONLINE = "1"; $env:DBT_HORIZON_ENV_FILE = "examples\snowflake-dbt.env"
.\.venv\Scripts\python.exe -m pytest tests/online         # against the real account
```

Offline tests use local git repos and a local DuckDB file attached under the Snowflake
database name, so they exercise the same code paths without Snowflake.
