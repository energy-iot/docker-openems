# ---------------------------------------------------------------------------
# Lambda VPC proxy — forwards MBE requests to OpenEMS B2B on private IP
# ---------------------------------------------------------------------------

# Package the function code into a zip
data "archive_file" "lambda_proxy" {
  type        = "zip"
  source_file = "${path.module}/lambda/index.mjs"
  output_path = "${path.module}/lambda/proxy.zip"
}

# ---------------------------------------------------------------------------
# IAM execution role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "lambda_proxy" {
  name = "${var.project_name}-${var.environment}-lambda-proxy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-lambda-proxy-role"
  }
}

# AWSLambdaVPCAccessExecutionRole covers: VPC ENI management + CloudWatch Logs
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda_proxy.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# ---------------------------------------------------------------------------
# Security group for Lambda
# ---------------------------------------------------------------------------

resource "aws_security_group" "lambda_proxy" {
  name        = "${var.project_name}-${var.environment}-lambda-proxy-sg"
  description = "Lambda proxy: egress to OpenEMS B2B port only"
  vpc_id      = aws_vpc.main.id

  egress {
    description     = "OpenEMS B2B REST"
    from_port       = 8075
    to_port         = 8075
    protocol        = "tcp"
    security_groups = [aws_security_group.openems.id]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-lambda-proxy-sg"
  }
}

# ---------------------------------------------------------------------------
# Lambda function
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "proxy" {
  function_name    = "${var.project_name}-${var.environment}-b2b-proxy"
  role             = aws_iam_role.lambda_proxy.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.lambda_proxy.output_path
  source_code_hash = data.archive_file.lambda_proxy.output_base64sha256

  memory_size = 128
  timeout     = 30

  vpc_config {
    subnet_ids         = [aws_subnet.public.id]
    security_group_ids = [aws_security_group.lambda_proxy.id]
  }

  environment {
    variables = {
      OPENEMS_HOST      = aws_instance.openems.private_ip
      OPENEMS_B2B_CREDS = var.openems_b2b_creds
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_vpc_access,
    aws_cloudwatch_log_group.lambda_proxy,
  ]

  tags = {
    Name = "${var.project_name}-${var.environment}-b2b-proxy"
  }
}

# ---------------------------------------------------------------------------
# Function URL (HTTPS + IAM SigV4 auth)
# ---------------------------------------------------------------------------

resource "aws_lambda_function_url" "proxy" {
  function_name      = aws_lambda_function.proxy.function_name
  authorization_type = "AWS_IAM"
  invoke_mode        = "BUFFERED"
}

# ---------------------------------------------------------------------------
# CloudWatch log group
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "lambda_proxy" {
  name              = "/aws/lambda/${var.project_name}-${var.environment}-b2b-proxy"
  retention_in_days = 14

  tags = {
    Name = "${var.project_name}-${var.environment}-b2b-proxy-logs"
  }
}

# ---------------------------------------------------------------------------
# IAM user for Vercel (MBE invoker)
# ---------------------------------------------------------------------------

resource "aws_iam_user" "mbe_invoker" {
  name = "${var.project_name}-${var.environment}-mbe-invoker"

  tags = {
    Name = "${var.project_name}-${var.environment}-mbe-invoker"
  }
}

resource "aws_iam_access_key" "mbe_invoker" {
  user = aws_iam_user.mbe_invoker.name
}

resource "aws_iam_user_policy" "mbe_invoker_invoke" {
  name = "${var.project_name}-${var.environment}-mbe-invoker-policy"
  user = aws_iam_user.mbe_invoker.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "lambda:InvokeFunctionUrl",
        "lambda:InvokeFunction",
      ]
      Resource = aws_lambda_function.proxy.arn
      Condition = {
        StringEquals = {
          "lambda:FunctionUrlAuthType" = "AWS_IAM"
        }
        Bool = {
          "lambda:InvokedViaFunctionUrl" = "true"
        }
      }
    }]
  })
}
