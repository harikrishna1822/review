terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}

# No account or region here: both come from the environment at run time
# (AWS_REGION / AWS_DEFAULT_REGION, and AWS_PROFILE or AWS_ACCESS_KEY_ID/...), see docs/ecs.md.
provider "aws" {
  default_tags {
    tags = {
      "app"        = "dbt-horizon"
      "deployment" = var.deployment
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
