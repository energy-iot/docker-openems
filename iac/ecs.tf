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
  name = "/ecs/${var.project_name}-${var.environment}-new-td"

  lifecycle {
    create_before_destroy = true
  }
}

# create task definition
resource "aws_ecs_task_definition" "ecs_task_definition" {
  family                   = "${var.project_name}-${var.environment}-td"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 8192
  memory                   = 20480

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.architecture
  }

  # create container definition
  container_definitions = jsonencode([
    {
      name      = "${var.project_name}-${var.environment}-container-ui"
      image     = "${local.secrets.ecr_registry}/${var.image_name_openems_ui}:${var.image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = 8089
          hostPort      = 8089
        }
      ]

      logConfiguration = {
        logDriver = "awslogs",
        options = {
          "awslogs-group"         = "${aws_cloudwatch_log_group.log_group.name}",
          "awslogs-region"        = "${var.region}",
          "awslogs-stream-prefix" = "ecs"
        }
      }
    },
    {
      name      = "${var.project_name}-${var.environment}-container-backend"
      image     = "${local.secrets.ecr_registry}/${var.image_name_openems_backend}:${var.image_tag}"
      essential = false
      
      environment = [
        {
          name  = "DB_HOST",
          value = "applicationdb.clkigksc2ezs.us-east-1.rds.amazonaws.com"
        },
        {
          name  = "DB_PORT",
          value = "5432"
        },
        {
          name  = "DB_NAME",
          value = "openemsdb"
        },
        {
          name  = "DB_USER",
          value = "openems"
        },
        {
          name  = "DB_PASSWORD",
          value = "openempassword"
        }
      ]

      portMappings = [
        {
          containerPort = 8075
          hostPort      = 8075
        }
      ]

      logConfiguration = {
        logDriver = "awslogs",
        options = {
          "awslogs-group"         = "${aws_cloudwatch_log_group.log_group.name}",
          "awslogs-region"        = "${var.region}",
          "awslogs-stream-prefix" = "ecs"
        }
      }
    },
    # {
    #   name      = "${var.project_name}-${var.environment}-container-backend-db"
    #   image     = "${local.secrets.ecr_registry}/${var.image_name_openems_db}:${var.image_tag}"
    #   essential = false


    #   portMappings = [
    #     {
    #       containerPort = 5432
    #       hostPort      = 5432
    #     }
    #   ]

    #   logConfiguration = {
    #     logDriver = "awslogs",
    #     options = {
    #       "awslogs-group"         = "${aws_cloudwatch_log_group.log_group.name}",
    #       "awslogs-region"        = "${var.region}",
    #       "awslogs-stream-prefix" = "ecs"
    #     }
    #   }
    # },
    {
      name      = "${var.project_name}-${var.environment}-container-odoo"
      image     = "${local.secrets.ecr_registry}/${var.image_name_odoo}:${var.image_tag}"
      essential = false

      environment = [
        {
          name  = "DB_HOST",
          value = "applicationdb.clkigksc2ezs.us-east-1.rds.amazonaws.com"
        },
        {
          name  = "DB_PORT",
          value = "5432"
        },
        {
          name  = "DB_NAME",
          value = "openemsdb"
        },
        {
          name  = "DB_USER",
          value = "openems"
        },
        {
          name  = "DB_PASSWORD",
          value = "openempassword"
        }
      ]

      portMappings = [
        {
          containerPort = 8069
          hostPort      = 8069
        }
      ]

      logConfiguration = {
        logDriver = "awslogs",
        options = {
          "awslogs-group"         = "${aws_cloudwatch_log_group.log_group.name}",
          "awslogs-region"        = "${var.region}",
          "awslogs-stream-prefix" = "ecs"
        }
      }
    },
    {
      name      = "${var.project_name}-${var.environment}-container-edge"
      image     = "${local.secrets.ecr_registry}/${var.image_name_openems_edge}:${var.image_tag}"
      essential = false

      logConfiguration = {
        logDriver = "awslogs",
        options = {
          "awslogs-group"         = "${aws_cloudwatch_log_group.log_group.name}",
          "awslogs-region"        = "${var.region}",
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
    # {
    #   name      = "${var.project_name}-${var.environment}-container-odoo-db"
    #   image     = "${local.secrets.ecr_registry}/${var.image_name_odoo_db}:${var.image_tag}"
    #   essential = false
      
    #   portMappings = [
    #     {
    #       containerPort = 5433
    #       hostPort      = 5433
    #     }
    #   ]

    #  logConfiguration = {
    #     logDriver = "awslogs",
    #     options = {
    #       "awslogs-group"         = "${aws_cloudwatch_log_group.log_group.name}",
    #       "awslogs-region"        = "${var.region}",
    #       "awslogs-stream-prefix" = "ecs"
    #     }
    #   }
    # }
  ])
}


# create ecs service
resource "aws_ecs_service" "ecs_service" {
  name                               = "${var.project_name}-${var.environment}-service"
  launch_type                        = "FARGATE"
  cluster                            = aws_ecs_cluster.ecs_cluster.id
  task_definition                    = aws_ecs_task_definition.ecs_task_definition.arn
  platform_version                   = "LATEST"
  desired_count                      = 1
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # task tagging configuration
  enable_ecs_managed_tags = false
  propagate_tags          = "SERVICE"

  # vpc and security groups
  network_configuration {
    subnets          = [aws_subnet.public_subnet_az1.id, aws_subnet.public_subnet_az2.id]
    security_groups  = [aws_security_group.openems_security_group.id]
    assign_public_ip = true
  }
}
