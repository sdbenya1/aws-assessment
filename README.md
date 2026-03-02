# Unleash live AWS DevOps Engineer Assessment (Multi-Region)

This repo provisions a multi-region backend stack in **us-east-1** and **eu-west-1**, secured by a centralized **Cognito User Pool** in **us-east-1**. It includes an automated test runner and a CI workflow definition.

---

## Deliverables Included

- **Terraform IaC:** Modular, multi-region deployment (provider aliases) with identical regional stacks.
- **Automated Test Script:** Cognito auth → JWT → concurrent `/greet` + `/dispatch` calls in both regions + latency + assertions.
- **CI/CD Workflow:** fmt/validate + security scan + plan + test placeholder.
- **README:** This file.

---

## Architecture Overview

### Authentication (us-east-1)

- Cognito User Pool + User Pool Client
- Test user created (email)

### Regional Stack (deployed in BOTH us-east-1 and eu-west-1)

- API Gateway **HTTP API**
  - `POST /greet` (JWT protected)
  - `POST /dispatch` (JWT protected)
- Lambda **Greeter** (`/greet`)
  - Writes to regional DynamoDB table
  - Publishes verification payload to Unleash SNS (source = `Lambda`)
  - Returns executing region
- DynamoDB (regional table)
- Lambda **Dispatcher** (`/dispatch`)
  - Calls ECS `RunTask` to run a one-off Fargate task
- ECS Fargate publisher task
  - Uses AWS CLI container
  - Publishes verification payload to Unleash SNS (source = `ECS`)
  - Exits successfully
- Networking (per region, cost-optimized)
  - VPC + public subnet + IGW + route table
  - **No NAT gateway** (tasks use public IP)

---

## Verification SNS Topic + Payloads

Unleash verification topic (us-east-1):

- `arn:aws:sns:us-east-1:637226132752:Candidate-Verification-Topic`

Both regions publish to this same topic.

### Lambda `/greet` payload

```json
{"email":"<your_email>","source":"Lambda","region":"<executing_region>","repo":"https://github.com/sdbenya1/aws-assessment"}
```

### ECS `/dispatch` payload

```json
{"email":"<your_email>","source":"ECS","region":"<executing_region>","repo":"https://github.com/sdbenya1/aws-assessment"}
```

---

## Repository Layout

- `terraform/` Terraform root
  - `modules/regional_stack/` reusable regional module (deployed twice)
- `test/run_test.py` automated test runner
- `.github/workflows/deploy.yml` CI pipeline

---

## Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.5
- Python 3.9+ (tested with 3.9; boto3 may show a future deprecation warning)
- Permissions to create IAM, Lambda, API Gateway, Cognito, DynamoDB, ECS, VPC, CloudWatch

---

## Deploy (manual)

From repo root:

1) Create `terraform/terraform.tfvars` (do **NOT** commit):

```hcl
email        = "sdbenya@gmail.com"
project_name = "unleash-assessment"
repo_url     = "https://github.com/sdbenya1/aws-assessment"
```

2) Deploy:

```bash
cd terraform
terraform init
terraform apply
```

3) Capture outputs:

```bash
terraform output
```

You should see base API endpoints:

- `us_greet_api` (base URL) → use `POST <base>/greet` and `POST <base>/dispatch`
- `eu_greet_api` (base URL) → use `POST <base>/greet` and `POST <base>/dispatch`

---

## Cognito: Set Test User Password (one-time)

Terraform creates the user, but password is set via CLI:

```bash
aws cognito-idp admin-set-user-password \
  --user-pool-id us-east-1_surMKB1xy \
  --username "sdbenya@gmail.com" \
  --password "TempPassword1234" \
  --permanent \
  --region us-east-1
```

---

## Manual Endpoint Test (PowerShell)

1) Get a JWT:

```powershell
$auth = aws cognito-idp initiate-auth `
  --auth-flow USER_PASSWORD_AUTH `
  --client-id 1qacn7ia83vcr2mauea6kqbj5s `
  --auth-parameters USERNAME="sdbenya@gmail.com",PASSWORD="TempPassword1234" `
  --region us-east-1 | ConvertFrom-Json

$jwt = $auth.AuthenticationResult.IdToken
```

2) Call endpoints:

```powershell
$us_base = "https://<US_API_ID>.execute-api.us-east-1.amazonaws.com"
$eu_base = "https://<EU_API_ID>.execute-api.eu-west-1.amazonaws.com"

Invoke-RestMethod -Method Post -Uri "$us_base/greet"    -Headers @{ Authorization = "Bearer $jwt" } -ContentType "application/json"
Invoke-RestMethod -Method Post -Uri "$eu_base/greet"    -Headers @{ Authorization = "Bearer $jwt" } -ContentType "application/json"

Invoke-RestMethod -Method Post -Uri "$us_base/dispatch" -Headers @{ Authorization = "Bearer $jwt" } -ContentType "application/json"
Invoke-RestMethod -Method Post -Uri "$eu_base/dispatch" -Headers @{ Authorization = "Bearer $jwt" } -ContentType "application/json"
```

---

## Automated Test Runner

The test runner:

1) Authenticates to Cognito to retrieve a JWT
2) Concurrently calls `/greet` in both regions and asserts returned region matches
3) Concurrently calls `/dispatch` in both regions
4) Prints latency measurements for geographic comparison

Setup:

```bash
python -m venv .venv
# Windows:
.\.venv\Scripts\activate
pip install boto3 requests
```

Run:

```bash
python .\test\run_test.py \
  --client-id 1qacn7ia83vcr2mauea6kqbj5s \
  --username sdbenya@gmail.com \
  --password TempPassword1234 \
  --us-base https://rlxtci08rg.execute-api.us-east-1.amazonaws.com \
  --eu-base https://9em1bxcrm7.execute-api.eu-west-1.amazonaws.com
```

---

## CI/CD

See `.github/workflows/deploy.yml`:

- `terraform fmt -check`
- `terraform validate`
- `tfsec` security scan
- `terraform plan`
- Placeholder step showing where automated tests would run post-deploy

---

## Tear Down (IMPORTANT)

Destroy infrastructure to avoid charges:

```bash
cd terraform
terraform destroy
```

