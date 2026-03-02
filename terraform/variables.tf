variable "email" {
  description = "Email for the test user (must be the one used to contact recruiting)."
  type        = string
}

variable "project_name" {
  description = "Prefix for resource names."
  type        = string
  default     = "unleash-assessment"
}
