# Data-triggered runs: `dbt-horizon watch`

`watch` rebuilds a model when the Iceberg tables it reads get new data, the way a Snowflake
dynamic table refreshes within its `TARGET_LAG`. Write mode only.

## How it decides

Every Iceberg commit creates a **snapshot** with a timestamp (UTC). The source tables are Iceberg
tables, and so are the tables dbt-horizon writes. So the decision needs no stored state:

> A model is **stale** if its table doesn't exist yet, or if any source it reads (directly or
> through other models) has a snapshot **newer** than the model's own table.

Each check:

1. Reads the latest snapshot time of every source (reader role) and every model table (writer
   role, read-only) from Horizon's table metadata: **no warehouse, no data scanned**.
2. Builds the stale models, everything downstream of them, and the session views and seeds they
   read (those exist only during a run): `dbt build --select <those nodes>`.
3. Checks again: data committed **while** the build ran (newer than the build's start) triggers
   another pass, up to `--max-passes` (default 3). Anything left is picked up by the next check.

Fresh models are not touched, so a check where nothing changed costs a few seconds of metadata
reads plus `dbt parse` (about a minute end to end on snowflake-dbt).

Example, snowflake-dbt: new rows land in `CORE_ICEBERG_S3.FACT_SALES`:

```text
Stale      3 of 5 table(s):
  agg_product_performance        source core.fact_sales has data from 2026-10-27 08:00:00 UTC, table built 2026-10-26 10:12:00 UTC
  agg_sales_daily_store          source core.fact_sales has data from 2026-10-27 08:00:00 UTC, table built 2026-10-26 10:12:00 UTC
  fct_sales                      source core.fact_sales has data from 2026-10-27 08:00:00 UTC, table built 2026-10-26 10:12:00 UTC
Building   agg_product_performance agg_sales_daily_store fct_sales stg_product stg_sales stg_store
```

`DIM_PRODUCT` and `DIM_STORE` read only the product and store sources, so they are not rebuilt.
`stg_product` and `stg_store` are built anyway: they are session views `fct_sales` reads.

## Running it

```bash
dbt-horizon watch -c dbt-horizon.yml --once --dry-run     # what is stale, build nothing
dbt-horizon watch -c dbt-horizon.yml --once               # one check (+ build): for a scheduler
dbt-horizon watch -c dbt-horizon.yml --interval 900       # loop: check every 15 minutes
dbt-horizon watch -c dbt-horizon.yml --once --full        # rebuild everything (e.g. nightly)
```

| Option | |
|---|---|
| `--once` | one check, then exit with 0 (fresh or built) or 1 (failed). For cron, a systemd timer, EventBridge |
| `--interval N` | loop mode: seconds between checks (default 900). Each check fetches the repo again, so merged code is used from the next check on. `docker stop` / SIGTERM ends the loop after the current check |
| `--dry-run` | report what is stale and what would be built |
| `--full` | build everything once, stale or not |
| `--max-passes N` | re-checks after a build for data that landed during it (default 3) |
| `--artifacts DIR` | copy the reports, including `watch.json` (snapshot times, stale models, results per pass) |

Where to run it: [Docker](docker.md), [ECS Fargate](ecs.md), or a machine with the deploy scripts
([docs/deploy.md](deploy.md): `DBT_HORIZON_COMMAND=watch` with `--once` on a timer).

## Things to know

- **Code changes** are not data changes: a changed model whose sources didn't change is not
  rebuilt by `watch`. Build after merges with the [CI template](ci.md), or schedule a nightly
  `watch --once --full`.
- **One watcher per target.** Two runs writing the same tables at once can collide (tables are
  rebuilt with drop + create). Keep the check interval longer than a full build, or use loop
  mode / the ECS `service` mode, which never overlaps.
- **Clocks:** source snapshot times are set by Snowflake, model snapshot times by the machine
  running DuckDB. Keep its clock in sync (NTP; containers and Fargate are).
- A source whose snapshots can't be read is reported (`Snapshot ...` on stderr) and does not
  trigger a build; a model table that can't be read is rebuilt.
