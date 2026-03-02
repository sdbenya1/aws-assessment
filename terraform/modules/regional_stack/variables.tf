variable "project_name" { type = string }
variable "region" { type = string }


variable "repo_url" {
  type        = string
  description = "Repo URL included in SNS verification payload."
}

variable "email" {
  type        = string
  description = "Your email included in SNS verification payload."
}

variable "verification_sns_arn" {
  type        = string
  description = "Unleash SNS topic ARN for verification."
}

variable "cognito_user_pool_id" {
  type        = string
  description = "Cognito User Pool ID (centralized in us-east-1)."
}

variable "cognito_user_pool_client_id" {
  type        = string
  description = "Cognito User Pool Client ID (audience for JWT authorizer)."
}

variable "cognito_region" {
  type        = string
  description = "Region where Cognito User Pool lives."
  default     = "us-east-1"
}