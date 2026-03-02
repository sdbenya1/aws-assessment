output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "cognito_user_pool_client_id" {
  value = aws_cognito_user_pool_client.this.id
}
output "us_table" {
  value = module.regional_us.dynamodb_table_name
}
output "eu_table" {
  value = module.regional_eu.dynamodb_table_name
}

output "us_greet_api" {
  value = module.regional_us.greet_api_url
}

output "eu_greet_api" {
  value = module.regional_eu.greet_api_url
}