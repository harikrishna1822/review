# dbt-horizon v0.9.0: SRE review package

Everything needed to review and test the ECS Fargate deployment of dbt-horizon. The code is
an exact export of tag `v0.9.0` (commit `313f09c`) of
https://github.com/harikrishna1822/dbt-horizon. No secrets are included: the `.env` files are
placeholders only.

## Start here

1. **`01-dbt-horizon-SRE-Review-Pack.md`**: what to verify, the 10-step test plan, security
   points, known limitations, and the sign-off checklist.
2. **`02-dbt-horizon-architecture.html`**: open it in a browser. It shows the diagrams: the
   system, the data trigger, the AWS deployment and the ingestion options.
3. **`code/`**: the files under review.

## What is in `code/`

| Path | What it is |
|---|---|
| `deploy/aws/` | **Terraform for ECS Fargate (the main review).** `versions.tf`, `variables.tf`, `main.tf`, `network.tf`, `outputs.tf`, `terraform.tfvars.example` |
| `Dockerfile`, `.dockerignore`, `docker/entrypoint.sh` | The container image |
| `docker/compose.yml`, `docker/example.env` | Running the container on a single VM or laptop |
| `deploy/run.sh`, `deploy/install.sh`, `deploy/cleanup.sh`, `deploy/settings.sh`, `deploy/systemd/` | The non-AWS option: a Linux VM with systemd timers |
| `deploy/windows/` | The same for Windows with Task Scheduler |
| `deploy/examples/` | Example config, settings and secrets template (placeholders) |
| `.github/workflows/` | CI: tests, image build and publish, Terraform fmt and validate, systemd deploy test |
| `docs/ecs.md` | Deployment runbook (the test plan follows it) |
| `docs/watch.md` | How the data trigger decides what to rebuild |
| `docs/docker.md`, `docs/deploy.md`, `docs/ci.md` | Image, VM deployment, CI |
| `docs/design.md` | Overall application design |
| `README.md`, `pyproject.toml` | Application overview and Python dependencies |

The container image itself is published as `ghcr.io/harikrishna1822/dbt-horizon:v0.9.0`.

## Status in one line

The application and container are tested end to end against Snowflake. The Terraform has passed
`terraform validate` but has **not been applied** to any AWS account yet. That is what this review
is for.
