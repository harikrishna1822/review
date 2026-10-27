# dbt-horizon: run a Snowflake dbt project on DuckDB over Snowflake Horizon Iceberg tables.
#
#   docker build -t dbt-horizon .
#   docker run --rm -e SNOWFLAKE_PAT -e SNOWFLAKE_WRITE_PAT \
#     -v $PWD/dbt-horizon.yml:/config/dbt-horizon.yml:ro dbt-horizon watch --once
#
# Config: /config/dbt-horizon.yml, or DBT_HORIZON_CONFIG (YAML text) / DBT_HORIZON_CONFIG_B64.
# Secrets (PATs, git token): environment variables only. State: /data (repo clone, workspaces).
# See docs/docker.md.

FROM python:3.12-slim AS build
# a slow package index fails the build otherwise (pip gives up after 15 s per request)
ENV PIP_DEFAULT_TIMEOUT=60 PIP_RETRIES=10 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /src
COPY pyproject.toml README.md ./
COPY src ./src
RUN pip wheel --no-cache-dir --no-deps -w /dist .

FROM python:3.12-slim
LABEL org.opencontainers.image.source="https://github.com/harikrishna1822/dbt-horizon" \
      org.opencontainers.image.description="Run Snowflake dbt projects on DuckDB over Snowflake Horizon Iceberg tables" \
      org.opencontainers.image.licenses="Proprietary"

# git: the dbt repo is cloned at run time; tini: PID 1 that forwards docker stop / ECS SIGTERM
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates tini \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /dist/ /tmp/dist/
RUN PIP_DEFAULT_TIMEOUT=60 PIP_RETRIES=10 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    pip install --no-cache-dir /tmp/dist/*.whl && rm -rf /tmp/dist

RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin dbthorizon \
 && mkdir -p /config /data && chown dbthorizon:dbthorizon /data
USER dbthorizon
WORKDIR /home/dbthorizon

# DuckDB extensions baked in: no download at start-up (iceberg reads avro manifests)
RUN python -c "import duckdb; c = duckdb.connect(); [c.execute(f'INSTALL {e}; LOAD {e}') for e in ('httpfs', 'avro', 'iceberg')]"

ENV DBT_HORIZON_WORKSPACE_ROOT=/data \
    DBT_SEND_ANONYMOUS_USAGE_STATS=false \
    PYTHONUNBUFFERED=1
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/dbt-horizon-entrypoint

VOLUME ["/data"]
ENTRYPOINT ["tini", "--", "dbt-horizon-entrypoint"]
CMD ["watch"]
