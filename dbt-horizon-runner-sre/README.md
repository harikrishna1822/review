# dbt-horizon runner: hand-off for the SRE team (test environment)

This container runs our dbt project on **DuckDB** instead of a Snowflake warehouse. It reads
and writes Snowflake-managed Iceberg tables through Snowflake's Iceberg REST catalog (Horizon),
so the build uses no Snowflake warehouse compute.

On each run it does three things:
1. Clones a git branch that holds the DuckDB-compatible dbt models.
2. Runs `dbt build`.
3. Exits with dbt's exit code.

It has no web UI, opens no ports and keeps no state between runs.

| | |
|---|---|
| Image | `dbt-horizon-runner:2026-10-29`, linux/amd64, Python 3.12 slim; 228 MB tarball, about 950 MB on disk |
| Contents | git, tini, dbt-core 1.12.6, dbt-duckdb 1.11.0, DuckDB 1.5.6 with the iceberg, avro and httpfs extensions |
| Runs as | uid 10001 (`dbt`), working directory `/work` (scratch, rebuilt every run) |
| Inbound | none |
| Outbound | HTTPS 443 only: github.com, `fblpisn-umc02429.snowflakecomputing.com`, the S3 bucket of the Snowflake external volume |
| Secrets | 3, passed as environment variables, never baked into the image |

## Folder

```
image/SHA256SUMS                                          checksum of the image tarball
  (the tarball itself, dbt-horizon-runner_2026-10-29_linux-amd64.tar.gz, 217 MB, is attached to
   the GitHub Release runner-2026-10-29 of this repo: too large for git. Download it into image/)
build/Dockerfile, build/run.sh                            to rebuild the image instead of loading it
config/runner.env.example                                 every setting, for a local docker run
config/ecs-task-definition.json                           Fargate task definition template
```

## 1. Load (or build) the image and push it to ECR

Download `dbt-horizon-runner_2026-10-29_linux-amd64.tar.gz` from this repo's Releases page
(release `runner-2026-10-29`) into `image/`, then:

```bash
cd image && sha256sum -c SHA256SUMS && cd ..        # must print: OK
docker load -i image/dbt-horizon-runner_2026-10-29_linux-amd64.tar.gz      # -> dbt-horizon-runner:2026-10-29
#   or build it: docker build --platform linux/amd64 -t dbt-horizon-runner:2026-10-29 build/

aws ecr create-repository --repository-name dbt-horizon-runner              # once
aws ecr get-login-password --region <REGION> | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com
docker tag  dbt-horizon-runner:2026-10-29 <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/dbt-horizon-runner:2026-10-29
docker push <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/dbt-horizon-runner:2026-10-29
```

## 2. Secrets (Secrets Manager)

Create one secret, `dbt-horizon-runner/test`, with three JSON keys. The values are provided
separately by the data team, never through this folder.

| key | what |
|---|---|
| `GIT_TOKEN` | GitHub fine-grained token, Contents: **read-only**, on `harikrishna1822/dbt-demo` |
| `DBT_HORIZON_READER_PAT` | Snowflake programmatic access token of the reader user (role `DUCKDB_READER`: SELECT on the source tables) |
| `DBT_HORIZON_WRITER_PAT` | Snowflake programmatic access token of the writer user (role `DBT_DUCKDB_WRITER`: owns the output tables) |

The task **execution role** needs two permissions:
- `secretsmanager:GetSecretValue` on that secret, plus `kms:Decrypt` if it uses a customer-managed key
- `logs:CreateLogGroup`, or create the log group `/ecs/dbt-horizon-runner-test` in advance

The task role needs no AWS permissions. S3 access comes from short-lived credentials that
Snowflake vends to the container.

## 3. Task definition

Fill in the `<...>` placeholders in `config/ecs-task-definition.json` and register it:

```bash
aws ecs register-task-definition --cli-input-json file://config/ecs-task-definition.json
```

- **Size:** 2 vCPU and 8 GB is enough for this project. DuckDB uses up to 80% of the task memory, and if a model outgrows it, the task fails with an out-of-memory error. Ephemeral storage is the default 20 GB.
- **Plain settings** go in `environment` (the full list is in `config/runner.env.example`). The main ones:

| variable | value for this test |
|---|---|
| `RUNNER_REPO_URL` | `https://github.com/harikrishna1822/dbt-demo.git` |
| `RUNNER_REPO_REF` | `dbt-horizon/duckdb-test` |
| `RUNNER_PROJECT_DIR` | `retail_analytics_dbt` |
| `RUNNER_INTERVAL` | `0`: run once and exit (scheduled task). `900`: run every 15 minutes (ECS service) |
| `RUNNER_ARGS` | optional extra dbt arguments, e.g. `--threads 8` |

## 4. Network

The task makes outbound HTTPS (443) calls only:

| to | why |
|---|---|
| `github.com` | clone the branch |
| `fblpisn-umc02429.snowflakecomputing.com` | Iceberg REST catalog and token exchange (Horizon) |
| S3, the bucket(s) of the Snowflake external volume (us-west-2) | read and write Iceberg data files |

On a private subnet this needs a NAT gateway; an S3 gateway endpoint is optional. If the
Snowflake account has a network policy on the two users, it must allow the NAT gateway's
public IP. Tell the data team which IP it is.

## 5. Run and verify

```bash
aws ecs run-task --cluster <CLUSTER> --launch-type FARGATE --task-definition dbt-horizon-runner-test \
  --network-configuration "awsvpcConfiguration={subnets=[<SUBNET>],securityGroups=[<SG>],assignPublicIp=DISABLED}"
```

A successful run logs the branch, the dbt build, then the result. Expected for this project:
about 3 minutes, `PASS=35 ERROR=0`, and the runner's own last line:

```
hh:mm:ss runner: dbt-horizon/duckdb-test @ <commit>
hh:mm:ss runner: dbt build --target horizon_write --selector dbt_horizon
...
Done. PASS=35 WARN=0 ERROR=0 SKIP=0 NO-OP=0 REUSED=0 TOTAL=35
hh:mm:ss runner: finished in 186s, exit 0
```

| exit code | meaning | first check |
|---|---|---|
| 0 | success | |
| 1 | a dbt model or test failed | the log: which model or test (data issue, send it to the data team) |
| 2 | configuration or dbt error | a missing variable or PAT, an expired PAT, or Snowflake network policy (`403`/`401` in the log) |
| 3 | git clone or pull failed | URL, branch name, `GIT_TOKEN` expired or without access, github.com reachable? |

**Scheduling:** use an EventBridge Scheduler rule with target ECS `RunTask` and `RUNNER_INTERVAL=0`.
Alarm on the task's stopped event with a non-zero exit code. On stop (SIGTERM), the container
finishes its current step within `stopTimeout` (120 s).

**Local smoke test** on a machine with Docker:

```bash
cp config/runner.env.example runner.env      # fill in, keep private
docker run --rm --env-file runner.env dbt-horizon-runner:2026-10-29
docker run --rm -it --entrypoint sh dbt-horizon-runner:2026-10-29    # a shell for debugging
```

## Security notes

- **No secrets in the image or the git branch.** Tokens arrive only as environment variables.
- **The git token never reaches the URL, `.git/config` or the logs.** It is passed to git as an HTTP header through git's environment config.
- **The Snowflake PATs are used only by DuckDB.** They are exchanged for short-lived OAuth tokens at the Iceberg REST catalog. Each PAT belongs to a dedicated service user with one role.
- **Narrow access.** The reader role only reads the source Iceberg tables. The writer role owns the output Iceberg tables in `RETAIL_ANALYTICS.DBT_RETAIL_ICEBERG`. The data team holds the exact grants.
- **No inbound ports and nothing persisted.** `/work` is scratch space and is rebuilt every run.
- **Non-root:** the container runs as a non-root user. It writes to `/work` (clone, dbt `target/` and `logs/`) and `/tmp`. `readonlyRootFilesystem` has not been tested.

## Contact

Questions about the dbt models, the Snowflake roles or the PATs go to the data team.
