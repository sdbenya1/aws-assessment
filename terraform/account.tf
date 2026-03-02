data "aws_caller_identity" "me" {}

output "account_id" {
  value = data.aws_caller_identity.me.account_id
}

