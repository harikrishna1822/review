variable "deployment" {
  description = "Deployment name, e.g. retail-test: names every resource (dbt-horizon-<deployment>)."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,30}$", var.deployment))
    error_message = "Lower-case letters, digits and -, at most 31 characters."
  }
}

variable "config_file" {
  description = "Path to the dbt-horizon config (YAML, no secrets). Passed to the container as DBT_HORIZON_CONFIG."
  type        = string
}

variable "secret_env" {
  description = "Env vars the config names (pat_env, token_env). One Secrets Manager secret is created per name, empty: set the values with the AWS CLI."
  type        = list(string)
  default     = ["SNOWFLAKE_PAT", "SNOWFLAKE_WRITE_PAT"]
}

# --- image ---------------------------------------------------------------------------------

variable "image" {
  description = "Container image. Empty: the ECR repository this module creates, at image_tag."
  type        = string
  default     = ""
}

variable "image_tag" {
  description = "Tag of the ECR image (when image is empty)."
  type        = string
  default     = "latest"
}

# --- when it runs ----------------------------------------------------------------------------

variable "run_mode" {
  description = "schedule: EventBridge Scheduler starts `watch --once` on schedule (pay per run). service: one always-on task running the watch loop (never two runs at once)."
  type        = string
  default     = "schedule"
  validation {
    condition     = contains(["schedule", "service"], var.run_mode)
    error_message = "schedule or service."
  }
}

variable "schedule_expression" {
  description = "run_mode schedule: how often to check for new data, e.g. rate(15 minutes) or cron(0/15 * * * ? *). Keep it longer than a full build."
  type        = string
  default     = "rate(15 minutes)"
}

variable "schedule_timezone" {
  description = "Time zone of cron() schedules."
  type        = string
  default     = "UTC"
}

variable "watch_interval" {
  description = "run_mode service: seconds between checks."
  type        = number
  default     = 900
}

variable "watch_args" {
  description = "Extra watch options, e.g. [\"--max-passes\", \"2\"]."
  type        = list(string)
  default     = []
}

variable "enabled" {
  description = "false: the schedule is disabled / the service runs 0 tasks (pause without destroying)."
  type        = bool
  default     = true
}

# --- task size -------------------------------------------------------------------------------

variable "cpu" {
  description = "Fargate CPU units (1024 = 1 vCPU)."
  type        = number
  default     = 1024
}

variable "memory" {
  description = "Fargate memory (MiB). DuckDB works in memory: size for the largest model."
  type        = number
  default     = 4096
}

variable "ephemeral_storage_gib" {
  description = "Task disk (GiB, 21-200): repo clone, workspace, DuckDB spill."
  type        = number
  default     = 30
}

# --- network ---------------------------------------------------------------------------------

variable "create_network" {
  description = "true: a small VPC (one private subnet behind a NAT gateway with an Elastic IP). false: use subnet_ids."
  type        = bool
  default     = true
}

variable "vpc_cidr" {
  description = "create_network: VPC range."
  type        = string
  default     = "10.42.0.0/16"
}

variable "subnet_ids" {
  description = "create_network false: private subnets whose default route is a NAT gateway with a static (Elastic) IP."
  type        = list(string)
  default     = []
}

variable "vpc_id" {
  description = "create_network false: the VPC of subnet_ids."
  type        = string
  default     = ""
}

# --- operations ------------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch Logs retention."
  type        = number
  default     = 30
}

variable "alert_email" {
  description = "Email notified when a run ends with a non-zero exit code (confirm the SNS subscription mail). Empty: no alerts."
  type        = string
  default     = ""
}

variable "create_ecr" {
  description = "Create an ECR repository for the image."
  type        = bool
  default     = true
}
