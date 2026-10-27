output "egress_ip" {
  description = "Allow this IP in the network policy of the Snowflake reader and writer PAT users (create_network = true)."
  value       = var.create_network ? aws_eip.nat[0].public_ip : "the Elastic IP of your NAT gateway"
}

output "ecr_repository_url" {
  description = "Push the image here (docs/ecs.md)."
  value       = var.create_ecr ? aws_ecr_repository.this[0].repository_url : null
}

output "image" {
  value = local.image
}

output "secrets" {
  description = "Set each value: aws secretsmanager put-secret-value --secret-id <arn> --secret-string <value>"
  value       = { for name, s in aws_secretsmanager_secret.env : name => s.arn }
}

output "cluster" {
  value = aws_ecs_cluster.this.name
}

output "task_definition" {
  value = aws_ecs_task_definition.this.family
}

output "log_group" {
  value = aws_cloudwatch_log_group.this.name
}

output "run_once_command" {
  description = "Start one check now (dry run: add --overrides with command watch --once --dry-run, see docs/ecs.md)."
  value = join(" ", [
    "aws ecs run-task --cluster", aws_ecs_cluster.this.name,
    "--task-definition", aws_ecs_task_definition.this.family,
    "--launch-type FARGATE --network-configuration",
    "'awsvpcConfiguration={subnets=[${join(",", local.subnet_ids)}],securityGroups=[${aws_security_group.task.id}],assignPublicIp=DISABLED}'",
  ])
}
