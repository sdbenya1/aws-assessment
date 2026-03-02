resource "aws_cognito_user_pool" "this" {
  name = "${var.project_name}-pool"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }
}

resource "aws_cognito_user_pool_client" "this" {
  name         = "${var.project_name}-client"
  user_pool_id = aws_cognito_user_pool.this.id

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH"
  ]

  generate_secret = false
}

# Create a test user with your email.
resource "aws_cognito_user" "test" {
  user_pool_id = aws_cognito_user_pool.this.id
  username     = var.email

  attributes = {
    email          = var.email
    email_verified = "true"
  }

  # Don't send the default invite email (smoother for take-home).
  message_action = "SUPPRESS"
}
