# dbt-horizon on AWS ECS Fargate

Data-triggered dbt builds ([watch.md](watch.md)) on Fargate, from the [Docker image](docker.md).
Terraform in [`deploy/aws/`](../deploy/aws). **No AWS account or region is written anywhere:**
Terraform and the AWS CLI take them from the environment at run time.

```
 EventBridge Scheduler ── every 15 min ──► ECS Fargate task: dbt-horizon watch --once
                                             │  private subnet, no inbound
                                             ▼
                                   NAT gateway + Elastic IP  ──►  Snowflake Horizon (network policy: this IP)
                                             │                    github.com (repo)
                         S3 gateway endpoint ┴──────────────────►  S3 (Iceberg data files)
 Secrets Manager ─ PATs as env vars ─► task          CloudWatch Logs ◄─ task output
 failed run (exit ≠ 0) ─► EventBridge rule ─► SNS ─► email (optional)
```

| Created | |
|---|---|
| ECR repository | the image, scan on push, last 20 images kept |
| ECS cluster + task definition | 1 vCPU / 4 GB / 30 GB disk by default (`cpu`, `memory`, `ephemeral_storage_gib`) |
| EventBridge Scheduler (`run_mode = "schedule"`) | starts `watch --once` on `schedule_expression` (default `rate(15 minutes)`) |
| ECS service (`run_mode = "service"`) | instead: one always-on task running the watch loop; never two runs at once |
| Secrets Manager | one **empty** secret per env var in `secret_env`; you set the values (never in Terraform state) |
| IAM | execution role (pull image, logs, read these secrets), task role (no permissions), scheduler role (run this task only) |
| CloudWatch Logs | `/ecs/dbt-horizon-<deployment>`, 30 days |
| Network (`create_network = true`) | VPC, one private subnet, NAT gateway with an Elastic IP, S3 gateway endpoint, security group with HTTPS egress only |
| Alerts (`alert_email` set) | email when a task stops with a non-zero exit code |

## 1. Tools and AWS credentials (your shell)

AWS CLI v2, Terraform ≥ 1.5, Docker. Pick the account and region **in the environment**:

```bash
export AWS_PROFILE=<profile>          # or AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
export AWS_REGION=<region>            # same region as the S3 bucket of the Iceberg tables
aws sts get-caller-identity           # check: the account you meant
```

Changing these two variables deploys the same code to another account or region.

## 2. Config

The dbt-horizon config, as for any run ([example](../deploy/examples/config.yml)): repo,
Snowflake account, roles and the env-var names of the PATs, `source_mapping`, `target_naming`.
No secrets in it: it is passed to the container as `DBT_HORIZON_CONFIG`.

```bash
cd deploy/aws
cp terraform.tfvars.example terraform.tfvars      # deployment name, config_file; git-ignored
```

## 3. Create the infrastructure (paused)

```bash
terraform init
terraform apply -var enabled=false                # schedule created disabled
```

`enabled=false` keeps the schedule off until the image and secrets exist. Outputs: `egress_ip`,
`ecr_repository_url`, `secrets`, `run_once_command`.

For a shared team state, add an S3 backend at init: `terraform init -backend-config=...` with a
`backend "s3" {}` block; the region of the state bucket can also come from the environment.

## 4. Push the image

```bash
REPO=$(terraform output -raw ecr_repository_url)
aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO%%/*}"
docker pull ghcr.io/harikrishna1822/dbt-horizon:v0.9.0       # or: docker build -t dbt-horizon ../..
docker tag ghcr.io/harikrishna1822/dbt-horizon:v0.9.0 "$REPO:v0.9.0"
docker push "$REPO:v0.9.0"
```

Use the version tag in Terraform: `image_tag = "v0.9.0"` in `terraform.tfvars` (not `latest`, so
every run uses a known image).

## 5. Secrets

```bash
for name in SNOWFLAKE_PAT SNOWFLAKE_WRITE_PAT; do
  arn=$(terraform output -json secrets | python3 -c "import sys, json; print(json.load(sys.stdin)['$name'])")
  read -rsp "$name: " value; echo
  aws secretsmanager put-secret-value --secret-id "$arn" --secret-string "$value"
done
```

The values never touch a file or Terraform. Rotating a PAT = the same command; the next run uses it.

## 6. Snowflake network policy

Allow `terraform output -raw egress_ip` in the network policy of the reader and writer PAT users.
With your own network (`create_network = false`), allow the Elastic IP of the NAT gateway your
subnets route through.

## 7. Test one run

```bash
eval "$(terraform output -raw run_once_command) --overrides \
  '{\"containerOverrides\":[{\"name\":\"dbt-horizon\",\"command\":[\"watch\",\"--once\",\"--dry-run\"]}]}'"
aws logs tail "$(terraform output -raw log_group)" --follow
```

Expected: `Fresh 5 table(s) up to date with their sources`, or the list of stale tables. Then the
same without `--overrides` builds them.

## 8. Turn it on

```bash
terraform apply -var enabled=true       # or set enabled = true in terraform.tfvars
```

From now on every 15 minutes: a task starts, checks the snapshot times, builds what is stale, stops.

## Operate

| Task | How |
|---|---|
| Follow the runs | `aws logs tail /ecs/dbt-horizon-<deployment> --follow --since 1h` |
| Change the interval | `schedule_expression = "rate(30 minutes)"` or `cron(0/10 6-22 * * ? *)` with `schedule_timezone`, then apply |
| Long builds | keep the interval longer than a full build, or `run_mode = "service"` (loop, never overlaps) |
| Nightly full rebuild | a second deployment of the same config with `watch_args = ["--full"]` and a cron schedule |
| Upgrade | push the new image tag, set `image_tag`, apply: the next run uses it |
| Pause | `enabled = false`, apply |
| Bigger models | raise `memory` (Fargate: up to 30 GB at 4 vCPU) |
| Remove | `terraform destroy` (the ECR repository must be empty first; secrets are kept 7 days) |

Costs: Fargate is billed per second while a task runs (a check with nothing stale takes about a
minute). The NAT gateway is billed per hour plus data and is usually the largest fixed cost; with
`create_network = false` you reuse an existing one. S3 traffic goes through the free gateway
endpoint.
