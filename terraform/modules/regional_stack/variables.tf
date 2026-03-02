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
