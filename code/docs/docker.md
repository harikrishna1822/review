# dbt-horizon in Docker

One image runs every dbt-horizon command; by default `watch` (data-triggered builds, see
[watch.md](watch.md)). DuckDB runs inside the container: nothing else is needed.

| | |
|---|---|
| Image | `ghcr.io/harikrishna1822/dbt-horizon:<version>` (published for every `v*` tag), or build it: `docker build -t dbt-horizon .` |
| Base | `python:3.12-slim`, git, tini; runs as user `dbthorizon` (uid 10001) |
| DuckDB | pinned 1.5.6, extensions `httpfs`, `avro`, `iceberg` baked in (no download at start-up) |
| Config | `/config/dbt-horizon.yml` (mounted), or env `DBT_HORIZON_CONFIG` (the YAML) / `DBT_HORIZON_CONFIG_B64` / `DBT_HORIZON_CONFIG_FILE` |
| Secrets | env vars only: the names the config gives (`SNOWFLAKE_PAT`, `SNOWFLAKE_WRITE_PAT`, a git token) |
| State | `/data` (repo clone, workspaces): a volume keeps the clone between runs; without one, each run clones again |
| Entrypoint | `dbt-horizon <command> -c <config> <options>`: `docker run IMAGE run --mode read` = `dbt-horizon run -c <config> --mode read` |

## Run it

```bash
docker build -t dbt-horizon .                      # or docker pull ghcr.io/harikrishna1822/dbt-horizon:v0.9.0

# one check, nothing built
docker run --rm -e SNOWFLAKE_PAT -e SNOWFLAKE_WRITE_PAT \
  -v "$PWD/dbt-horizon.yml:/config/dbt-horizon.yml:ro" -v dbt-horizon-data:/data \
  dbt-horizon watch --once --dry-run

# other commands work the same way
docker run --rm -e SNOWFLAKE_PAT -v "$PWD/dbt-horizon.yml:/config/dbt-horizon.yml:ro" dbt-horizon connect --probe
docker run --rm -e SNOWFLAKE_PAT -e SNOWFLAKE_WRITE_PAT -v "$PWD/dbt-horizon.yml:/config/dbt-horizon.yml:ro" \
  dbt-horizon run --mode write
```

`-e SNOWFLAKE_PAT` passes the variable from your shell without writing its value on the command
line. The config's `workspace_root` is ignored in the container: `DBT_HORIZON_WORKSPACE_ROOT=/data`.

## Long-running watcher with Compose (a test VM)

```bash
cp docker/example.env docker/.env                  # fill in the PATs; git-ignored
cp deploy/examples/config.yml docker/dbt-horizon.yml   # your config; git-ignored
docker compose -f docker/compose.yml up --build -d
docker compose -f docker/compose.yml logs -f
```

It checks every 15 minutes (`DBT_HORIZON_INTERVAL` to change), restarts with the machine, and
finishes the current check before `docker compose down` stops it (`stop_grace_period: 2m`).

## Network

The container calls `github.com` (or your git server), `<account>.snowflakecomputing.com` and the
S3 bucket of the Iceberg tables, all HTTPS. Snowflake's network policy must allow the host's
**public egress IP**; on AWS use [ECS behind a NAT gateway](ecs.md).

## Debugging

```bash
docker run --rm -it --entrypoint sh dbt-horizon     # a shell in the image
docker run --rm -v dbt-horizon-data:/data --entrypoint sh dbt-horizon -c 'ls /data/workspaces/*/*/.dbt_horizon'
```
