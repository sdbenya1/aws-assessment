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
