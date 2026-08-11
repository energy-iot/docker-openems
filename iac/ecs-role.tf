# create iam policy document. this policy allows the ecs service to assume a role
data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# permissions the execution role needs to START a task: pull images from ECR
# and write container logs.
data "aws_iam_policy_document" "ecs_task_execution_policy_document" {
  statement {
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = ["*"]
  }
}

# create the ECS task execution role
resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "${var.project_name}-${var.environment}-ecs-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
}

# Attach the ECR/logs permissions as an INLINE policy (not a standalone managed
# aws_iam_policy). Inline policies are created with iam:PutRolePolicy, which the
# deploy role has; a managed policy would additionally require iam:TagPolicy
# (Terraform tags everything via default_tags), which the deploy role lacks.
resource "aws_iam_role_policy" "ecs_task_execution" {
  name   = "${var.project_name}-${var.environment}-ecs-task-execution"
  role   = aws_iam_role.ecs_task_execution_role.id
  policy = data.aws_iam_policy_document.ecs_task_execution_policy_document.json
}

# allow the execution role to resolve the app-credentials secret when
# injecting container secrets (scoped to that one secret ARN)
resource "aws_iam_role_policy" "ecs_secrets_access" {
  name = "${var.project_name}-${var.environment}-ecs-secrets-access"
  role = aws_iam_role.ecs_task_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.app_credentials.arn]
      }
    ]
  })
}
