resource "aws_dynamodb_table" "greeting_logs" {
  name         = "${var.project_name}-GreetingLogs-${var.region}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }
}

data "aws_region" "current" {}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "greeter_role" {
  name               = "${var.project_name}-greeter-${var.region}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Basic logging
resource "aws_iam_role_policy_attachment" "greeter_basic" {
  role       = aws_iam_role.greeter_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# DynamoDB + SNS permissions (least-ish privilege)
data "aws_iam_policy_document" "greeter_policy" {
  statement {
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.greeting_logs.arn]
  }

  statement {
    actions   = ["sns:Publish"]
    resources = [var.verification_sns_arn]
  }
}

resource "aws_iam_role_policy" "greeter_inline" {
  name   = "${var.project_name}-greeter-inline-${var.region}"
  role   = aws_iam_role.greeter_role.id
  policy = data.aws_iam_policy_document.greeter_policy.json
}

# Lambda source generated inline for speed (we'll refactor later if you want)
data "archive_file" "greeter_zip" {
  type        = "zip"
  output_path = "${path.module}/greeter.zip"

  source {
    content  = <<-PY
import json, os, time
import boto3

ddb = boto3.client("dynamodb")
sns = boto3.client("sns", region_name=os.environ.get("SNS_REGION", "us-east-1"))

TABLE = os.environ["TABLE_NAME"]
SNS_ARN = os.environ["SNS_ARN"]
EMAIL = os.environ["EMAIL"]
REPO_URL = os.environ["REPO_URL"]
REGION = os.environ["AWS_REGION"]

def handler(event, context):
    # Write a simple record
    pk = str(int(time.time() * 1000))
    ddb.put_item(
        TableName=TABLE,
        Item={
            "pk": {"S": pk},
            "email": {"S": EMAIL},
            "region": {"S": REGION}
        }
    )

    # Publish verification payload
    payload = {
        "email": EMAIL,
        "source": "Lambda",
        "region": REGION,
        "repo": REPO_URL
    }
    sns.publish(TopicArn=SNS_ARN, Message=json.dumps(payload))

    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json"},
        "body": json.dumps({"region": REGION})
    }
PY
    filename = "lambda_function.py"
  }
}

resource "aws_lambda_function" "greeter" {
  function_name = "${var.project_name}-greeter-${var.region}"
  role          = aws_iam_role.greeter_role.arn
  handler       = "lambda_function.handler"
  runtime       = "python3.12"
  timeout       = 10
  memory_size   = 128

  filename         = data.archive_file.greeter_zip.output_path
  source_code_hash = data.archive_file.greeter_zip.output_base64sha256

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.greeting_logs.name
      SNS_REGION = "us-east-1"
      SNS_ARN    = var.verification_sns_arn
      EMAIL      = var.email
      REPO_URL   = var.repo_url
    }
  }
}

# -------- API Gateway HTTP API (v2) --------
resource "aws_apigatewayv2_api" "http" {
  name          = "${var.project_name}-http-${var.region}"
  protocol_type = "HTTP"
}

# JWT Authorizer (Cognito) - centralized in us-east-1
# issuer = https://cognito-idp.<region>.amazonaws.com/<user_pool_id>
resource "aws_apigatewayv2_authorizer" "cognito_jwt" {
  api_id          = aws_apigatewayv2_api.http.id
  authorizer_type = "JWT"
  name            = "${var.project_name}-jwt-${var.region}"

  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [var.cognito_user_pool_client_id]
    issuer   = "https://cognito-idp.${var.cognito_region}.amazonaws.com/${var.cognito_user_pool_id}"
  }
}

# Lambda integration
resource "aws_apigatewayv2_integration" "greet_lambda" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.greeter.arn
  payload_format_version = "2.0"
}

# Route: POST /greet
resource "aws_apigatewayv2_route" "greet" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "POST /greet"
  target    = "integrations/${aws_apigatewayv2_integration.greet_lambda.id}"

  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_jwt.id
}

# Stage (auto-deploy)
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
}

# Allow API Gateway to invoke Lambda
resource "aws_lambda_permission" "allow_apigw_greet" {
  statement_id  = "AllowExecutionFromAPIGatewayGreet-${var.region}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.greeter.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}