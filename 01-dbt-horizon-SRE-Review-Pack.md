# dbt-horizon SRE Review Pack

Oct 27, 2026 · @Anavsan

Please verify the ECS Fargate deployment of dbt-horizon in the test AWS account. It runs our Snowflake dbt project on DuckDB and rebuilds marts when source Iceberg tables get new data. All code is at tag v0.9.0 of github.com/harikrishna1822/dbt-horizon.

## Scope and status

The Terraform has passed `terraform validate` and `fmt` in CI, but has **never been applied to an AWS account**. The application and container are tested end to end against our Snowflake account. What needs SRE review is the AWS layer.

| Layer | Status | Evidence |
| --- | --- | --- |
| Application (`dbt-horizon` v0.9.0) | Tested | 162 offline tests and 7 online tests against Snowflake; CI green on Ubuntu and Windows |
| Data trigger (`watch`) | Tested live | 27 Oct: 3 rows inserted into a source at 09:31 UTC → 3 affected tables rebuilt by 09:35, untouched tables left alone |
| Container image | Built and smoke-tested in CI | `ghcr.io/harikrishna1822/dbt-horizon:v0.9.0`, run against Snowflake from a laptop with Docker |
| ECS Terraform (`deploy/aws`) | **Validated only** | `terraform fmt -check` and `validate` in CI; no `plan` or `apply` yet |

**What we're asking you to verify:**

1. The Terraform is safe and fits our AWS standards: IAM, network, secrets, logging, tagging.
2. It applies cleanly in the test account and the flow works end to end, following the verification plan below.
3. The known limitations are acceptable for a test environment, or tell us what must change first.

The account and region are never written in any file: Terraform and the AWS CLI take them from `AWS_PROFILE` / `AWS_REGION` at run time, so you choose the test account.

## The flow

Every 15 minutes, EventBridge Scheduler starts one Fargate task. The task checks whether any source Iceberg table has new data and rebuilds only the affected dbt models, then exits. Diagrams: [dbt-horizon Architecture](https://claude.ai/artifact/3h9cPr7X71XRBB3KfyYUtq), section 3.

One run, in order:

1. **Start:** EventBridge Scheduler calls `ecs:RunTask` on the task definition (`rate(15 minutes)` by default).
2. **Secrets:** ECS injects the two Snowflake PATs from Secrets Manager as environment variables. The config (no secrets) arrives as the `DBT_HORIZON_CONFIG` variable.
3. **Image:** pulled from ECR. Runs as a non-root user under `tini`, so SIGTERM is forwarded.
4. **Repo:** the task clones the dbt repo from GitHub over HTTPS, through the NAT gateway.
5. **Freshness check:** it asks Snowflake's Horizon catalog (Iceberg REST, HTTPS via the NAT Elastic IP) for the latest snapshot time of every source and target table. Metadata only.
6. **Build, only if something is stale:** DuckDB reads source data files from S3 with credentials Snowflake vends per table (through the S3 gateway endpoint). It then writes new Iceberg files and commits them through Horizon with the writer PAT.
7. **Exit:** code 0 (fresh, or built OK) or 1 (failed). Logs go to CloudWatch. A non-zero exit triggers an EventBridge rule → SNS → email.

**Network:** the task has no inbound traffic and only HTTPS egress. Everything except S3 leaves through one NAT gateway with an Elastic IP, and that IP is the one Snowflake's network policy allows.

## Code to review

All links are pinned to tag `v0.9.0` (commit `313f09c`). The repository is public. To work from a local copy: `git clone --branch v0.9.0 https://github.com/harikrishna1822/dbt-horizon.git`.

**Terraform** (`deploy/aws`, \~620 lines, the main review)

| File | What it defines | Look at |
| --- | --- | --- |
| [versions.tf](https://github.com/harikrishna1822/dbt-horizon/blob/v0.9.0/deploy/aws/versions.tf) | Terraform ≥ 1.5, AWS provider 6.x, default tags | No backend block: state is local, see limitations |
| [variables.tf](https://github.com/harikrishna1822/dbt-horizon/blob/v0.9.0/deploy/aws/variables.tf) | Inputs and their defaults | Sizes (1 vCPU / 4 GB / 30 GB), schedule, `run_mode`, `create_network` |
| [main.tf](https://github.com/harikrishna1822/dbt-horizon/blob/v0.9.0/deploy/aws/main.tf) | ECR, Secrets Manager, IAM (execution, task and scheduler roles), ECS cluster and task, Scheduler or service, failure alerts | IAM scope, task definition, the alert event pattern |
| [network.tf](https://github.com/harikrishna1822/dbt-horizon/blob/v0.9.0/deploy/aws/network.tf) | Optional VPC: one public and one private subnet, NAT with Elastic IP, S3 gateway endpoint, security group | Single AZ; egress-only security group (443) |
| [outputs.tf](https://github.com/harikrishna1822/dbt-horizon/blob/v0.9.0/deploy/aws/outputs.tf) | Egress IP, ECR URL, secret ARNs, run-once command | — |
| [terraform.tfvars.example](https://github.com/harikrishna1822/dbt-horizon/blob/v0.9.0/deploy/aws/terraform.tfvars.example) | Example inputs | — |

**Container**

| File | What it defines | Look at |
| --- | --- | --- |
| [Dockerfile](https://github.com/harikrishna1822/dbt-horizon/blob/v0.9.0/Dockerfile) | Two-stage build on `python:3.12-slim`; git, tini; user `dbthorizon` (uid 10001); DuckDB extensions baked in | Base image not pinned by digest |
| [docker/entrypoint.sh](https://github.com/harikrishna1822/dbt-horizon/blob/v0.9.0/docker/entrypoint.sh) | Where the config is read from; runs `dbt-horizon <command>` | Writes the config to `/tmp` when given as an env var |
| [.github/workflows/image.yml](https://github.com/harikrishna1822/dbt-horizon/blob/v0.9.0/.github/workflows/image.yml) | Build and smoke-test on PRs; push to GHCR on `v*` tags | No push to ECR: copied by hand (doc step 4) |
| [.github/workflows/ci.yml](https://github.com/harikrishna1822/dbt-horizon/blob/v0.9.0/.github/workflows/ci.yml) | Tests, package, Terraform validate, systemd deploy test | — |

**Docs**

- [docs/ecs.md](https://github.com/harikrishna1822/dbt-horizon/blob/v0.9.0/docs/ecs.md): the deployment runbook this plan follows.
- [docs/watch.md](https://github.com/harikrishna1822/dbt-horizon/blob/v0.9.0/docs/watch.md): how the data trigger decides what to rebuild.
- [docs/docker.md](https://github.com/harikrishna1822/dbt-horizon/blob/v0.9.0/docs/docker.md): image contents, configuration and environment variables.
- [docs/deploy.md](https://github.com/harikrishna1822/dbt-horizon/blob/v0.9.0/docs/deploy.md): the non-AWS option (systemd / Task Scheduler on a VM).

**Application code, for context only:** [src/dbt\_horizon/watch.py](https://github.com/harikrishna1822/dbt-horizon/blob/v0.9.0/src/dbt_horizon/watch.py) (freshness logic) and [catalog.py](https://github.com/harikrishna1822/dbt-horizon/blob/v0.9.0/src/dbt_horizon/catalog.py) (Horizon connection).

## Verification plan

Run these in the test account, in order. Each step says what you should see; stop at the first one that differs. Steps 5 and 8 need someone with Snowflake admin access (the data team).

**Prerequisites:** AWS CLI v2, Terraform ≥ 1.5, Docker, and an IAM principal that can create VPC, ECS, ECR, IAM, Secrets Manager, Scheduler, EventBridge, SNS and CloudWatch resources.

1. **Pick the account and region (environment only).**

   ```bash
   export AWS_PROFILE=<test-profile> AWS_REGION=<region of the Iceberg S3 bucket>
   aws sts get-caller-identity
   git clone --branch v0.9.0 https://github.com/harikrishna1822/dbt-horizon.git && cd dbt-horizon/deploy/aws
   cp terraform.tfvars.example terraform.tfvars   # deployment = "retail-test"; set alert_email
   ```

   Expect: the test account ID.
2. **Plan, then apply with the schedule off.**

   ```bash
   terraform init && terraform plan -var enabled=false -out tfplan
   terraform apply tfplan
   ```

   Expect: 31 resources to add (26 without alert\_email), 0 to change or destroy. The schedule is created in state `DISABLED`. Outputs: `egress_ip`, `ecr_repository_url`, `secrets`, `log_group`, `run_once_command`.
3. **Copy the image into ECR.**

   ```bash
   REPO=$(terraform output -raw ecr_repository_url)
   aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO%%/*}"
   docker pull ghcr.io/harikrishna1822/dbt-horizon:v0.9.0
   docker tag ghcr.io/harikrishna1822/dbt-horizon:v0.9.0 "$REPO:v0.9.0" && docker push "$REPO:v0.9.0"
   terraform apply -var enabled=false -var image_tag=v0.9.0
   ```

   Expect: the ECR scan on push finishes; the task definition gets a new revision pointing at `:v0.9.0`.
4. **Set the two secrets.** The values come from the data team; never put them in files or Terraform.

   ```bash
   aws secretsmanager put-secret-value --secret-id "$(terraform output -json secrets | jq -r .SNOWFLAKE_PAT)" --secret-string "$(read -rs v; echo $v)"
   aws secretsmanager put-secret-value --secret-id "$(terraform output -json secrets | jq -r .SNOWFLAKE_WRITE_PAT)" --secret-string "$(read -rs v; echo $v)"
   ```
5. **Snowflake network policy (data team).** Add `terraform output -raw egress_ip` to the network policy of both PAT users.
6. **Dry run: metadata only, nothing written.**

   ```bash
   eval "$(terraform output -raw run_once_command) --overrides '{\"containerOverrides\":[{\"name\":\"dbt-horizon\",\"command\":[\"watch\",\"--once\",\"--dry-run\"]}]}'"
   aws logs tail "$(terraform output -raw log_group)" --follow
   ```

   Expect: `Horizon 7 Iceberg table(s) in RETAIL_ANALYTICS`, then `Fresh 5 table(s) up to date with their sources` (or a list of stale tables). Task exit code 0. If you see `public IP is not allowed`, step 5 isn't done yet.
7. **Enable the schedule.** `terraform apply -var enabled=true -var image_tag=v0.9.0`. Expect: a task about every 15 minutes, each stopping with exit code 0 within about 2 minutes when nothing changed.
8. **Trigger test (data team).** Insert 3 marked test rows into `RETAIL_ANALYTICS.CORE_ICEBERG_S3.FACT_SALES`, copied from existing rows, with SALE\_SK 900000001–3 and TRANSACTION\_ID 'DBTH-TEST-…', so cleanup is one DELETE on that prefix. Expect, at the next scheduled task:
   - `Stale 3 of 5 table(s)`;
   - only `FCT_SALES`, `AGG_SALES_DAILY_STORE` and `AGG_PRODUCT_PERFORMANCE` rebuilt;
   - then `Fresh`, and `FCT_SALES` at 10,001 rows.

   Then delete the test rows; the following task rebuilds the same three back to 9,998 rows.
9. **Failure path.** Temporarily set the reader secret to an invalid value, then run step 6 without the dry-run override. Expect:
   - the log line `PAT rejected`;
   - task exit code 1;
   - an email from the SNS topic (confirm the subscription email first).

   Restore the secret afterwards.
10. **Overlap check (optional).** Start a run with `run_once_command` while a scheduled one is still running. Note what happens: in schedule mode nothing prevents two runs at once, see limitations.

## Security review points

| Area | How it is set up | Please confirm |
| --- | --- | --- |
| Execution role | `AmazonECSTaskExecutionRolePolicy` (ECR pull, logs) plus `secretsmanager:GetSecretValue` on this deployment's 2 secrets only | The AWS-managed policy is acceptable, or swap in a scoped one |
| Task role | No policies. The container calls no AWS API: Snowflake vends short-lived S3 credentials per table | — |
| Scheduler role | `ecs:RunTask` on this task family, limited to this cluster; `iam:PassRole` on the two task roles only. The trust policy requires `aws:SourceAccount` | — |
| Secrets | Created **empty** by Terraform; values set with the CLI, so they never enter Terraform state. 7-day recovery window | Rotation process: replace the value, and the next task uses it |
| Config | Plain YAML (no secrets) in the task definition env `DBT_HORIZON_CONFIG`, readable with `ecs:DescribeTaskDefinition` | Acceptable: it holds the account name, roles, schema names and the repo URL |
| Network | Private subnet, no public IP, no inbound rules; security group allows only TCP 443 out to 0.0.0.0/0. Egress via the NAT Elastic IP; S3 via the gateway endpoint | 443 to anywhere is acceptable, or restrict through an egress proxy |
| Snowflake access | Two roles: the reader only reads `CORE_ICEBERG_S3`; the writer only writes `DBT_RETAIL_ICEBERG` and can't see the sources. Both PAT users are locked to the Elastic IP by network policy | — |
| Image | Non-root (uid 10001), `tini` as PID 1, ECR scan on push. Built from public `python:3.12-slim`; dependencies pinned in the package | Base image pinned by tag, not digest; ECR tags are mutable |
| Logs | CloudWatch, 30 days. PATs are never printed; git token values are masked as `***` in errors | Retention and log destination meet policy |
| Code | Public GitHub repo; image public on GHCR | Is a public repo acceptable for this code? |

## Known limitations and open questions

These are known gaps in v0.9.0, most serious first. None blocks a test environment; items 1–4 should be resolved before production.

| # | Limitation | Impact | Proposed fix |
| --- | --- | --- | --- |
| 1 | **Never applied.** Only `validate` has run. The failure-alert event pattern (`exitCode` with `anything-but`) has not been seen to fire | First apply or first alert may need fixes | Steps 2 and 9 of the verification plan |
| 2 | **Runs can overlap in schedule mode.** EventBridge starts a task even if the previous one still runs. Two runs rebuilding the same table can collide (tables are rebuilt with drop + create) | A failed run, or a table missing until the next run | Keep the interval longer than a full build (\~2 min today), or use `run_mode = "service"` (always-on, never overlaps) |
| 3 | **Some failures don't alert.** The rule fires on a non-zero *container* exit. A task that never starts (image pull, missing secret, no capacity) has no exit code, and the schedule has no dead-letter queue | Silent missed runs | Add a rule on `stoppedReason` / `stopCode`, and a DLQ on the schedule target |
| 4 | **Local Terraform state**, no backend block | Not shareable between engineers, no locking | Add an S3 backend with locking, configured at `terraform init` |
| 5 | **Single AZ:** one private subnet, one NAT gateway | AZ outage = no runs. Acceptable for test | Two AZs for production, or `create_network = false` with your VPC |
| 6 | **Manual image promotion** from GHCR to ECR; mutable tags; base image not pinned by digest | Drift between what was tested and what runs | Push to ECR from CI on tag; immutable tags; deploy by digest |
| 7 | **Snowflake side is not in Terraform:** network policy, roles, PATs, target schema | Manual steps for the data team | `dbt-horizon setup-sql` prints the Snowflake script; could move to a Snowflake Terraform provider later |
| 8 | Container Insights enabled | Extra CloudWatch cost | Disable for test if not needed |
| 9 | S3 gateway endpoint only covers buckets **in the same region** | A bucket elsewhere routes through the NAT (data processing charge) | Deploy in the bucket's region |
| 10 | Code changes don't trigger a run; only new data does | A merged model change waits for the next data change | A second schedule running `watch --once --full` nightly, or the CI template on merge |

**Questions for SRE:**

- Is a public GitHub repo and public GHCR image acceptable, or should both move to a private org and registry?
- Should this use an existing VPC and NAT (`create_network = false`)? If so, which subnets, and what is their egress IP?
- Which alerting channel should replace the email: PagerDuty, Slack, or an existing SNS topic?
- Any mandatory tags, KMS keys (Secrets Manager, logs, ECR) or permission boundaries we need to add?

## Rollback and teardown

Nothing here affects Snowflake's own dbt run or the source tables. The deployment only reads `CORE_ICEBERG_S3` and writes `DBT_RETAIL_ICEBERG`.

| Situation | Action | Effect |
| --- | --- | --- |
| Pause | `terraform apply -var enabled=false` | Schedule disabled; no new tasks. A running task finishes |
| Stop a running task | `aws ecs stop-task --cluster <cluster> --task <arn>` | SIGTERM, then the current check finishes within the 120 s stop timeout. A table mid-rebuild may be missing until the next run |
| Bad image | Set `image_tag` to the previous tag, apply | The next task uses it |
| Remove everything | Delete the images from the ECR repository, then `terraform destroy` | All AWS resources removed. Secrets stay recoverable for 7 days |
| Remove the written tables | Data team: `DROP` the tables in `RETAIL_ANALYTICS.DBT_RETAIL_ICEBERG` | Snowflake's own `DBT_RETAIL` marts are untouched |

After `destroy`, the data team also removes the Elastic IP from the Snowflake network policy.

## Review checklist

Tick as you go, and comment on any line that needs a change.

- [ ] Terraform code reviewed: IAM, network, secrets, logging
- [ ] `terraform plan` clean in the test account (31 to add)
- [ ] Applied with the schedule disabled
- [ ] Image in ECR, scan results reviewed
- [ ] Secrets set (by the data team) and the Elastic IP in the Snowflake network policy
- [ ] Dry run: `Fresh` or a stale list, exit code 0
- [ ] Schedule enabled; tasks every 15 minutes, exit code 0
- [ ] Trigger test: 3 tables rebuilt, dimensions untouched
- [ ] Failure test: exit code 1 and an alert received
- [ ] Limitations 1–4 accepted for test, with an owner for each fix before production
- [ ] Questions for SRE answered
