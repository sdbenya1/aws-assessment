terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Default provider = us-east-1 (N. Virginia)
provider "aws" {
  region = "us-east-1"
}

# Aliased provider = eu-west-1 (Ireland)
provider "aws" {
  alias  = "eu"
  region = "eu-west-1"
}

module "regional_us" {
  source    = "./modules/regional_stack"
  providers = { aws = aws }

  project_name                = var.project_name
  region                      = "us-east-1"
  email                       = var.email
  repo_url                    = var.repo_url
  verification_sns_arn        = "arn:aws:sns:us-east-1:637226132752:Candidate-Verification-Topic"
  cognito_user_pool_id        = aws_cognito_user_pool.this.id
  cognito_user_pool_client_id = aws_cognito_user_pool_client.this.id
  cognito_region              = "us-east-1"
}

module "regional_eu" {
  source    = "./modules/regional_stack"
  providers = { aws = aws.eu }

  project_name                = var.project_name
  region                      = "eu-west-1"
  email                       = var.email
  repo_url                    = var.repo_url
  verification_sns_arn        = "arn:aws:sns:us-east-1:637226132752:Candidate-Verification-Topic"
  cognito_user_pool_id        = aws_cognito_user_pool.this.id
  cognito_user_pool_client_id = aws_cognito_user_pool_client.this.id
  cognito_region              = "us-east-1"
}
