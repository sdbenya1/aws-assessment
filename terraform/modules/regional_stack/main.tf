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

# -------- API Gateway HTTP API  --------
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

# -------- Networking --------

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc-${var.region}"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-igw-${var.region}"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 0)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-${var.region}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.project_name}-rt-public-${var.region}"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}


# -------- ECS prerequisites --------
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project_name}-ecs-tasks-${var.region}"
  description = "ECS tasks egress-only"
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-ecs-tasks-${var.region}"
  }
}

resource "aws_ecs_cluster" "this" {
  name = "${var.project_name}-cluster-${var.region}"
}


resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project_name}-publisher-${var.region}"
  retention_in_days = 7
}

data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution_role" {
  name               = "${var.project_name}-ecs-exec-${var.region}"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_exec_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task role (what the container can do)
resource "aws_iam_role" "ecs_task_role" {
  name               = "${var.project_name}-ecs-task-${var.region}"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

data "aws_iam_policy_document" "ecs_task_publish" {
  statement {
    actions   = ["sns:Publish"]
    resources = [var.verification_sns_arn]
  }
}

resource "aws_iam_role_policy" "ecs_task_publish" {
  name   = "${var.project_name}-ecs-publish-${var.region}"
  role   = aws_iam_role.ecs_task_role.id
  policy = data.aws_iam_policy_document.ecs_task_publish.json
}


resource "aws_ecs_task_definition" "publisher" {
  family                   = "${var.project_name}-publisher-${var.region}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512

  execution_role_arn = aws_iam_role.ecs_execution_role.arn
  task_role_arn      = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "publisher"
      image     = "amazon/aws-cli:2.15.0"
      essential = true

      environment = [
        { name = "SNS_ARN", value = var.verification_sns_arn },
        { name = "EMAIL", value = var.email },
        { name = "REPO_URL", value = var.repo_url },
        { name = "REGION", value = var.region }
      ]

      entryPoint = ["sh", "-lc"]
      command = [
        "PAYLOAD=$(printf '{\"email\":\"%s\",\"source\":\"ECS\",\"region\":\"%s\",\"repo\":\"%s\"}' \"$EMAIL\" \"$REGION\" \"$REPO_URL\"); echo $PAYLOAD; aws sns publish --region us-east-1 --topic-arn \"$SNS_ARN\" --message \"$PAYLOAD\"; echo done"
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}

# -------- Dispatcher Lambda (runs ECS task) --------
data "aws_iam_policy_document" "dispatcher_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dispatcher_role" {
  name               = "${var.project_name}-dispatcher-${var.region}"
  assume_role_policy = data.aws_iam_policy_document.dispatcher_assume.json
}

resource "aws_iam_role_policy_attachment" "dispatcher_basic" {
  role       = aws_iam_role.dispatcher_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "dispatcher_policy" {
  statement {
    actions = [
      "ecs:RunTask",
      "ecs:DescribeTasks"
    ]
    resources = [
      aws_ecs_task_definition.publisher.arn
    ]
  }

  statement {
    actions = ["ecs:RunTask"]
    resources = [
      aws_ecs_cluster.this.arn
    ]
  }

  # Lambda must be allowed to pass the ECS roles to the task
  statement {
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.ecs_execution_role.arn,
      aws_iam_role.ecs_task_role.arn
    ]
  }
}

resource "aws_iam_role_policy" "dispatcher_inline" {
  name   = "${var.project_name}-dispatcher-inline-${var.region}"
  role   = aws_iam_role.dispatcher_role.id
  policy = data.aws_iam_policy_document.dispatcher_policy.json
}

data "archive_file" "dispatcher_zip" {
  type        = "zip"
  output_path = "${path.module}/dispatcher.zip"

  source {
    filename = "lambda_function.py"
    content  = <<-PY
import json, os
import boto3

ecs = boto3.client("ecs")

CLUSTER_ARN = os.environ["CLUSTER_ARN"]
TASK_DEF_ARN = os.environ["TASK_DEF_ARN"]
SUBNET_ID = os.environ["SUBNET_ID"]
SG_ID = os.environ["SG_ID"]

def handler(event, context):
    resp = ecs.run_task(
        cluster=CLUSTER_ARN,
        launchType="FARGATE",
        taskDefinition=TASK_DEF_ARN,
        networkConfiguration={
            "awsvpcConfiguration": {
                "subnets": [SUBNET_ID],
                "securityGroups": [SG_ID],
                "assignPublicIp": "ENABLED"
            }
        }
    )

    failures = resp.get("failures", [])
    if failures:
        return {
            "statusCode": 500,
            "headers": {"content-type": "application/json"},
            "body": json.dumps({"ok": False, "failures": failures})
        }

    task_arns = [t["taskArn"] for t in resp.get("tasks", [])]
    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json"},
        "body": json.dumps({"ok": True, "tasks": task_arns})
    }
PY
  }
}

resource "aws_lambda_function" "dispatcher" {
  function_name = "${var.project_name}-dispatcher-${var.region}"
  role          = aws_iam_role.dispatcher_role.arn
  handler       = "lambda_function.handler"
  runtime       = "python3.12"
  timeout       = 20
  memory_size   = 128

  filename         = data.archive_file.dispatcher_zip.output_path
  source_code_hash = data.archive_file.dispatcher_zip.output_base64sha256

  environment {
    variables = {
      CLUSTER_ARN  = aws_ecs_cluster.this.arn
      TASK_DEF_ARN = aws_ecs_task_definition.publisher.arn
      SUBNET_ID    = aws_subnet.public.id
      SG_ID        = aws_security_group.ecs_tasks.id
    }
  }
}

# Integration for /dispatch -> dispatcher lambda
resource "aws_apigatewayv2_integration" "dispatch_lambda" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.dispatcher.arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "dispatch" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "POST /dispatch"
  target    = "integrations/${aws_apigatewayv2_integration.dispatch_lambda.id}"

  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_jwt.id
}

resource "aws_lambda_permission" "allow_apigw_dispatch" {
  statement_id  = "AllowExecutionFromAPIGatewayDispatch-${var.region}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dispatcher.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}