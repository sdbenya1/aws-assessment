variable "email" {
  description = "Email for the test user (must be the one used to contact recruiting)."
  type        = string
}

variable "project_name" {
  description = "Prefix for resource names."
  type        = string
  default     = "unleash-assessment"
}

variable "repo_url" {
  description = "GitHub repo URL used in SNS verification payloads."
  type        = string
}

variable "regions" {
  description = "Regions to deploy the regional stack into."
  type        = list(string)
  default     = ["us-east-1", "eu-west-1"]
}
