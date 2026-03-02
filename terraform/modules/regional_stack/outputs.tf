output "dynamodb_table_name" {
  value = aws_dynamodb_table.greeting_logs.name
}
