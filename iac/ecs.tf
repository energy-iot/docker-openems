# create ecs cluster
resource "aws_ecs_cluster" "ecs_cluster" {
  name = "${var.project_name}-${var.environment}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

# create cloudwatch log group
resource "aws_cloudwatch_log_group" "log_group" {
  name = "/ecs/${var.project_name}-${var.environment}-tds"

  lifecycle {
    create_before_destroy = true
  }
}

# Task definition — the "monolith" task: ui + backend + odoo + influxdb.
#
# This is the source of truth for the task's structure; the deploy pipeline
# only stamps fresh image URIs onto .github/workflows/openems-deployment-td.json
# (kept in sync with this) when registering new revisions.
#
# Notes:
# - Containers in one awsvpc task share a network namespace, so they reach
#   each other on localhost (NOT compose service names like "db"/"odoo16").
# - Edges are NOT part of the AWS stack. They run in the field (or locally)
#   and connect in over the backend's Edge.Websocket (:8081).
# - InfluxDB storage is EPHEMERAL in this task (lost on task replacement).
#   Acceptable for the PR-A base; PR-B moves telemetry to a managed store.
resource "aws_ecs_task_definition" "ecs_task_definition" {
  family                   = "${var.project_name}-${var.environment}-td"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 2048
  memory                   = 6144

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.architecture
  }

  container_definitions = jsonencode([
    {
      name      = "${var.project_name}-${var.environment}-container-ui"
      image     = "${local.ecr_registry}/${var.image_name_openems_ui}:${var.image_tag}"
      essential = true

      portMappings = [
        { containerPort = 8089, hostPort = 8089 } # nginx serves the UI on 8089
      ]

      logConfiguration = {
        logDriver = "awslogs",
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.log_group.name,
          "awslogs-region"        = var.region,
          "awslogs-stream-prefix" = "ecs"
        }
      }
    },
    {
      name      = "${var.project_name}-${var.environment}-container-backend"
      image     = "${local.ecr_registry}/${var.image_name_openems_backend}:${var.image_tag}"
      essential = true

      # Rendered into the Felix configs by openems-backend.sh at startup.
      environment = [
        { name = "DB_HOST", value = aws_db_instance.database_instance.address },
        { name = "DB_NAME", value = "openems" },
        { name = "DB_USER", value = var.master_username },
        { name = "ODOO_HOST", value = "localhost" },
        { name = "ODOO_PORT", value = "8069" },
        { name = "INFLUX_URL", value = "http://localhost:8086" }
      ]

      secrets = [
        { name = "DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.app_credentials.arn}:db_password::" },
        { name = "ODOO_PASSWORD", valueFrom = "${aws_secretsmanager_secret.app_credentials.arn}:odoo_password::" }
      ]

      portMappings = [
        { containerPort = 8075, hostPort = 8075 }, # Backend2Backend REST (MBE)
        { containerPort = 8079, hostPort = 8079 }, # Backend2Backend Websocket
        { containerPort = 8081, hostPort = 8081 }, # Edge.Websocket (edges connect here)
        { containerPort = 8082, hostPort = 8082 }  # Ui.Websocket (browser connects here)
      ]

      dependsOn = [
        { containerName = "${var.project_name}-${var.environment}-container-influxdb", condition = "HEALTHY" }
      ]

      healthCheck = {
        # curl exits 0 on any HTTP response; non-zero when nothing listens.
        command     = ["CMD-SHELL", "curl -s -o /dev/null http://localhost:8075 || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 120
      }

      logConfiguration = {
        logDriver = "awslogs",
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.log_group.name,
          "awslogs-region"        = var.region,
          "awslogs-stream-prefix" = "ecs"
        }
      }
    },
    {
      name      = "${var.project_name}-${var.environment}-container-odoo"
      image     = "${local.ecr_registry}/${var.image_name_odoo}:${var.image_tag}"
      essential = true

      environment = [
        { name = "HOST", value = aws_db_instance.database_instance.address },
        { name = "PORT", value = "5432" },
        { name = "USER", value = var.master_username }
      ]

      secrets = [
        { name = "PASSWORD", valueFrom = "${aws_secretsmanager_secret.app_credentials.arn}:db_password::" }
      ]

      portMappings = [
        { containerPort = 8069, hostPort = 8069 }
      ]

      logConfiguration = {
        logDriver = "awslogs",
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.log_group.name,
          "awslogs-region"        = var.region,
          "awslogs-stream-prefix" = "ecs"
        }
      }
    },
    {
      name      = "${var.project_name}-${var.environment}-container-influxdb"
      image     = "influxdb:1.8" # public Docker Hub image, never pushed to ECR
      essential = true

      environment = [
        { name = "INFLUXDB_DB", value = "openemsdb" },
        { name = "INFLUXDB_HTTP_AUTH_ENABLED", value = "false" }
      ]

      portMappings = [
        { containerPort = 8086, hostPort = 8086 } # NOT exposed by the security group
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "influx -execute 'SHOW DATABASES' || exit 1"]
        interval    = 10
        timeout     = 5
        retries     = 5
        startPeriod = 30
      }

      logConfiguration = {
        logDriver = "awslogs",
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.log_group.name,
          "awslogs-region"        = var.region,
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}


# create ecs service
resource "aws_ecs_service" "ecs_service" {
  name                   = "${var.project_name}-${var.environment}-service"
  launch_type            = "FARGATE"
  cluster                = aws_ecs_cluster.ecs_cluster.id
  task_definition        = aws_ecs_task_definition.ecs_task_definition.arn
  platform_version       = "LATEST"
  desired_count          = 1
  enable_execute_command = true # allow `aws ecs execute-command` (SSM shell into a container)

  # The backend is a singleton: edges hold one persistent websocket each and
  # telemetry has a single writer. Deploys must stop the old task before
  # starting the new one — never run two backends side by side.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  # task tagging configuration
  enable_ecs_managed_tags = false
  propagate_tags          = "SERVICE"

  # Give the backend time to boot before the ALB starts failing health checks.
  health_check_grace_period_seconds = 300

  # vpc and security groups.
  # Still in the public subnets with a public IP (needed to pull ECR/Secrets
  # over the IGW — there is no NAT). Ingress is now closed to everything but
  # the ALB SG, so the public IP is not directly reachable on the app ports.
  network_configuration {
    subnets          = [aws_subnet.public_subnet_az1.id, aws_subnet.public_subnet_az2.id]
    security_groups  = [aws_security_group.openems_security_group.id]
    assign_public_ip = true
  }

  # Register the task's container ports with the ALB target groups.
  load_balancer {
    target_group_arn = aws_lb_target_group.ui.arn
    container_name   = "${var.project_name}-${var.environment}-container-ui"
    container_port   = 8089
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.uiws.arn
    container_name   = "${var.project_name}-${var.environment}-container-backend"
    container_port   = 8082
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.edgews.arn
    container_name   = "${var.project_name}-${var.environment}-container-backend"
    container_port   = 8081
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.b2b.arn
    container_name   = "${var.project_name}-${var.environment}-container-backend"
    container_port   = 8075
  }

  # Ensure a listener/rule attaches each target group to the ALB before ECS
  # tries to register targets into it.
  depends_on = [
    aws_lb_listener.http_ui,
    aws_lb_listener.http_uiws,
    aws_lb_listener.http_edgews,
    aws_lb_listener.https_ui,
    aws_lb_listener.https_uiws,
    aws_lb_listener_rule.edge_ws,
    aws_lb_listener_rule.b2b,
  ]
}
