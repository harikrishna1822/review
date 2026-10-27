# dbt-horizon on ECS Fargate: data-triggered dbt builds (dbt-horizon watch). See docs/ecs.md.
locals {
  name       = "dbt-horizon-${var.deployment}"
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  vpc_id     = var.create_network ? aws_vpc.this[0].id : var.vpc_id
  subnet_ids = var.create_network ? [aws_subnet.private[0].id] : var.subnet_ids
  image      = var.image != "" ? var.image : "${aws_ecr_repository.this[0].repository_url}:${var.image_tag}"
  command = (var.run_mode == "schedule"
    ? concat(["watch", "--once"], var.watch_args)
  : concat(["watch", "--interval", tostring(var.watch_interval)], var.watch_args))
}

check "inputs" {
  assert {
    condition     = var.create_network || (length(var.subnet_ids) > 0 && var.vpc_id != "")
    error_message = "create_network = false needs subnet_ids and vpc_id."
  }
  assert {
    condition     = var.image != "" || var.create_ecr
    error_message = "Set image, or create_ecr = true."
  }
}

# --- image repository ------------------------------------------------------------------------

resource "aws_ecr_repository" "this" {
  count                = var.create_ecr ? 1 : 0
  name                 = local.name
  image_tag_mutability = "MUTABLE"
  force_delete         = false
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  count      = var.create_ecr ? 1 : 0
  repository = aws_ecr_repository.this[0].name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep the last 20 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

# --- secrets: created empty; values are set outside Terraform (never in its state) -----------

resource "aws_secretsmanager_secret" "env" {
  for_each                = toset(var.secret_env)
  name                    = "${local.name}/${each.value}"
  description             = "dbt-horizon ${var.deployment}: ${each.value} (set the value with aws secretsmanager put-secret-value)"
  recovery_window_in_days = 7
}

# --- logs --------------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${local.name}"
  retention_in_days = var.log_retention_days
}

# --- IAM ---------------------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: pull the image, write logs, read this deployment's secrets. Nothing else.
resource "aws_iam_role" "execution" {
  name               = "${local.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [for s in aws_secretsmanager_secret.env : s.arn]
  }
}

resource "aws_iam_role_policy" "secrets" {
  count  = length(var.secret_env) > 0 ? 1 : 0
  name   = "read-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.secrets.json
}

# Task role: the container itself needs no AWS API (Snowflake vends the S3 credentials).
resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# --- cluster and task --------------------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  ephemeral_storage {
    size_in_gib = var.ephemeral_storage_gib
  }
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name        = "dbt-horizon"
    image       = local.image
    essential   = true
    command     = local.command
    stopTimeout = 120 # a build in progress finishes its cycle on SIGTERM
    environment = [
      { name = "DBT_HORIZON_CONFIG", value = file(var.config_file) },
      { name = "DBT_HORIZON_WORKSPACE_ROOT", value = "/data" },
    ]
    secrets = [for name, s in aws_secretsmanager_secret.env : { name = name, valueFrom = s.arn }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.this.name
        awslogs-region        = local.region
        awslogs-stream-prefix = "watch"
      }
    }
  }])
}

# --- run_mode schedule: EventBridge Scheduler starts `watch --once` -----------------------------

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count              = var.run_mode == "schedule" ? 1 : 0
  name               = "${local.name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["ecs:RunTask"]
    resources = ["${aws_ecs_task_definition.this.arn_without_revision}:*"]
    condition {
      test     = "ArnLike"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.this.arn]
    }
  }
  statement {
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.execution.arn, aws_iam_role.task.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  count  = var.run_mode == "schedule" ? 1 : 0
  name   = "run-task"
  role   = aws_iam_role.scheduler[0].id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "watch" {
  count                        = var.run_mode == "schedule" ? 1 : 0
  name                         = local.name
  description                  = "dbt-horizon ${var.deployment}: rebuild models whose source Iceberg tables have new data"
  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.schedule_timezone
  state                        = var.enabled ? "ENABLED" : "DISABLED"
  flexible_time_window {
    mode = "OFF"
  }
  target {
    arn      = aws_ecs_cluster.this.arn
    role_arn = aws_iam_role.scheduler[0].arn
    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.this.arn
      launch_type         = "FARGATE"
      task_count          = 1
      network_configuration {
        subnets          = local.subnet_ids
        security_groups  = [aws_security_group.task.id]
        assign_public_ip = false
      }
    }
    retry_policy {
      maximum_retry_attempts = 0 # the next scheduled check is the retry
    }
  }
}

# --- run_mode service: one always-on task running the watch loop ------------------------------

resource "aws_ecs_service" "watch" {
  count           = var.run_mode == "service" ? 1 : 0
  name            = local.name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.enabled ? 1 : 0
  launch_type     = "FARGATE"
  # never two tasks at once, also during a deployment: the old one stops before the new starts
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }
}

# --- alerts: a run that ends with a non-zero exit code -----------------------------------------

resource "aws_sns_topic" "alerts" {
  count = var.alert_email != "" ? 1 : 0
  name  = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_event_rule" "failed" {
  count       = var.alert_email != "" ? 1 : 0
  name        = "${local.name}-failed"
  description = "dbt-horizon ${var.deployment}: task stopped with a non-zero exit code"
  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      clusterArn = [aws_ecs_cluster.this.arn]
      lastStatus = ["STOPPED"]
      containers = { name = ["dbt-horizon"], exitCode = [{ "anything-but" = [0] }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "failed" {
  count     = var.alert_email != "" ? 1 : 0
  rule      = aws_cloudwatch_event_rule.failed[0].name
  target_id = "sns"
  arn       = aws_sns_topic.alerts[0].arn
  input_transformer {
    input_paths    = { task = "$.detail.taskArn", reason = "$.detail.stoppedReason" }
    input_template = "\"dbt-horizon ${var.deployment}: a run failed (task <task>, <reason>). Logs: CloudWatch ${aws_cloudwatch_log_group.this.name}\""
  }
}

data "aws_iam_policy_document" "alerts" {
  count = var.alert_email != "" ? 1 : 0
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts[0].arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.failed[0].arn]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  count  = var.alert_email != "" ? 1 : 0
  arn    = aws_sns_topic.alerts[0].arn
  policy = data.aws_iam_policy_document.alerts[0].json
}
