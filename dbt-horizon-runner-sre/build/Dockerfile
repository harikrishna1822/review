# dbt-horizon runner: a branch exported by `dbt-horizon export`, run with plain dbt on DuckDB.
# No dbt-horizon, no dashboard: git + dbt-core + dbt-duckdb + DuckDB with its extensions baked in.
#
#   docker build -t dbt-horizon-runner docker/runner
#   docker run --rm --env-file docker/runner/runner.env dbt-horizon-runner
#
# Configured by environment variables only (docker/runner/runner.env.example); see docs/runner.md.

FROM python:3.12-slim
LABEL org.opencontainers.image.source="https://github.com/harikrishna1822/dbt-horizon" \
      org.opencontainers.image.description="Run a dbt-horizon export branch on DuckDB over Snowflake Horizon Iceberg tables" \
      org.opencontainers.image.licenses="Proprietary"

# the versions `dbt-horizon export` generates for (its README)
ARG DBT_CORE=1.12.6
ARG DBT_DUCKDB=1.11.0
ARG DUCKDB=1.5.6

# git: the branch is pulled at run time; tini: PID 1 that forwards docker stop / ECS SIGTERM
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates tini \
 && rm -rf /var/lib/apt/lists/*

RUN PIP_DEFAULT_TIMEOUT=60 PIP_RETRIES=10 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    pip install --no-cache-dir "dbt-core==${DBT_CORE}" "dbt-duckdb==${DBT_DUCKDB}" "duckdb==${DUCKDB}"

RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin dbt \
 && mkdir -p /work && chown dbt:dbt /work
USER dbt
WORKDIR /home/dbt

# DuckDB extensions baked in: no download at start-up (iceberg reads avro manifests)
RUN python -c "import duckdb; c = duckdb.connect(); [c.execute(f'INSTALL {e}; LOAD {e}') for e in ('httpfs', 'avro', 'iceberg')]"

ENV DBT_SEND_ANONYMOUS_USAGE_STATS=false \
    DBT_USE_COLORS=false \
    RUNNER_WORK_DIR=/work \
    PYTHONUNBUFFERED=1
COPY --chmod=755 run.sh /usr/local/bin/dbt-horizon-runner

ENTRYPOINT ["tini", "--", "dbt-horizon-runner"]
CMD ["run"]
