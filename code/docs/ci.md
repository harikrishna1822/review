# Running dbt-horizon in CI

Templates: [`templates/ci/github-actions.yml`](../templates/ci/github-actions.yml) and
[`templates/ci/gitlab-ci.yml`](../templates/ci/gitlab-ci.yml). Both live in the **dbt repo**
next to its `dbt-horizon.yml`, and run:

| Trigger | Job | What it does |
|---|---|---|
| pull / merge request | `analyze` | compatibility report for the change (write-mode plan), uploaded as an artifact |
| schedule / manual | `run` | `dbt build` on DuckDB in `read` or `write` mode, reports uploaded as an artifact |

## Set up for a repo + account

1. Create the config in the dbt repo and commit it:

   ```bash
   pip install "dbt-horizon @ git+https://github.com/harikrishna1822/dbt-horizon@main"
   dbt-horizon init --repo-url <the repo's https URL> --account <org>-<account> \
     --database <SOURCE_DB> --project-dir <folder of dbt_project.yml>
   ```

   Add `source_mapping` rules if the Iceberg copies of the sources live in other schemas, then
   check locally: `dbt-horizon connect -c dbt-horizon.yml --probe` and `dbt-horizon analyze -c dbt-horizon.yml`.

2. Write mode only: `dbt-horizon setup-sql -c dbt-horizon.yml --external-volume <VOLUME>
   --network-policy <POLICY>` and run the script in Snowflake once.

3. Store the PATs as CI secrets: `SNOWFLAKE_PAT` (reader) and `SNOWFLAKE_WRITE_PAT` (writer).
   GitHub: Settings > Secrets and variables > Actions. GitLab: Settings > CI/CD > Variables (masked).

4. Allow the CI runners in the network policy of both PAT users. GitHub- and GitLab-hosted
   runners have changing IPs: use self-hosted runners with a fixed egress IP, or a policy that
   covers the runners' published ranges.

5. Copy the template into the repo (`.github/workflows/dbt-horizon.yml`, or the GitLab jobs into
   `.gitlab-ci.yml`) and pin `DBT_HORIZON` to a released tag.

## How the CI jobs find the code

`--repo-url .` (GitHub) / `--repo-url "$CI_PROJECT_DIR"` (GitLab) with `--ref <commit SHA>` makes
dbt-horizon use the commit the pipeline already checked out: no second clone and no repo token.
The templates check out the full history (`fetch-depth: 0` / `GIT_DEPTH: "0"`); GitLab also marks
the checkout as a `safe.directory`, because the container user doesn't own it.

To run against a different repo than the pipeline's (e.g. a central ops repo running many dbt
repos), leave `--repo-url` out and set `repo.token_env` in the config (`GITHUB_TOKEN`, or a GitLab
token; with GitLab's `CI_JOB_TOKEN` also set `repo.token_user: gitlab-ci-token`).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | analysis not runnable (policy `fail`), preflight failed, dbt build failed, Horizon/repo error |
| 2 | config error (invalid config, missing PAT env var, bad option) |

`--artifacts <folder>` copies the reports even when the build fails: `workspace.json` (repo, commit),
`compat_report_<mode>.md/.json`, `overlay.json`, `run_<mode>.json` (per-node dbt results).
