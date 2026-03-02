output "dynamodb_table_name" {
  value = aws_dynamodb_table.greeting_logs.name
}

output "greet_api_url" {
  value = aws_apigatewayv2_api.http.api_endpoint
}