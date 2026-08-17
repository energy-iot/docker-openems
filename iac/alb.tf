# PR-C ingress: an Application Load Balancer is the ONLY public entry point.
#
# It terminates TLS and fans out to the single ECS task's container ports.
#
# TLS routing (enable_tls=true):
#   openems.eiot.energy  :443  -> UI static (nginx)      -> container 8089
#   openems.eiot.energy  :8082 -> Ui.Websocket (browser) -> container 8082
#   backend.openems...   :443  -> Edge.Websocket (Pis)   -> container 8081
#                                 (host-routed off the 443 listener)
#   :80 -> 301 redirect to :443
#
# The UI page host and its websocket are welded to the same name on :8082 —
# the UI bundle hard-wires `${location.hostname}:8082`, so they can't be split
# or moved to 443. Only the edge websocket is free to get its own name/port.
#
# Pre-DNS testing (enable_tls=false): plain HTTP/ws listeners on 80/8082/8081
# over the ALB's default *.elb.amazonaws.com name (no host-routing — there are
# no subdomains yet), so edges test on ws://<alb>:8081 until TLS is switched on.

# ---------------------------------------------------------------------------
# ALB security group: the only thing open to the internet.
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${var.environment}-alb-sg"
  description = "Public ingress to the OpenEMS ALB"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description = "HTTP (redirects to HTTPS when TLS is on)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS / UI"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Edges and B2B ride the 443 listener (host-routed), so no dedicated ALB
  # ingress port for them under TLS. (The pre-TLS HTTP test path used :8081;
  # re-add a rule here if you ever run with enable_tls=false again.)

  ingress {
    description = "Ui.Websocket (browser connects here; hard-wired port)"
    from_port   = 8082
    to_port     = 8082
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-alb-sg"
  }
}

# ---------------------------------------------------------------------------
# The load balancer (public subnets, both AZs).
# ---------------------------------------------------------------------------
resource "aws_lb" "alb" {
  name               = "${var.project_name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_subnet_az1.id, aws_subnet.public_subnet_az2.id]

  # Edge and UI websockets are long-lived; bump the idle timeout so a quiet
  # connection isn't culled between OpenEMS heartbeats/telemetry frames.
  idle_timeout = 300

  tags = {
    Name = "${var.project_name}-${var.environment}-alb"
  }
}

# ---------------------------------------------------------------------------
# Target groups (IP targets — awsvpc/Fargate). One per backend port.
#
# Health checks all probe nginx on 8089 (which reliably answers HTTP 200),
# not the websocket ports (a raw ws server may not answer a plain HTTP GET).
# All four containers are essential and share one task ENI, so nginx being
# up is a valid liveness signal for the whole task.
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "ui" {
  name        = "${var.project_name}-${var.environment}-ui-tg"
  port        = 8089
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.vpc.id

  deregistration_delay = 30

  health_check {
    path                = "/"
    port                = "8089"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-ui-tg"
  }
}

resource "aws_lb_target_group" "uiws" {
  name        = "${var.project_name}-${var.environment}-uiws-tg"
  port        = 8082
  protocol    = "HTTP" # ws upgrades over HTTP; TLS terminates at the listener
  target_type = "ip"
  vpc_id      = aws_vpc.vpc.id

  deregistration_delay = 30

  health_check {
    path                = "/"
    port                = "8089" # probe nginx, not the ws port
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-uiws-tg"
  }
}

resource "aws_lb_target_group" "edgews" {
  name        = "${var.project_name}-${var.environment}-edgews-tg"
  port        = 8081
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.vpc.id

  deregistration_delay = 30

  health_check {
    path                = "/"
    port                = "8089" # probe nginx, not the ws port
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-edgews-tg"
  }
}

# Backend2Backend REST/JSON-RPC (:8075) — MBE pulls meter data here.
resource "aws_lb_target_group" "b2b" {
  name        = "${var.project_name}-${var.environment}-b2b-tg"
  port        = 8075
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.vpc.id

  deregistration_delay = 30

  health_check {
    path                = "/"
    port                = "8089" # 8075 requires auth (401); probe nginx instead
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-b2b-tg"
  }
}

# ---------------------------------------------------------------------------
# Listeners — HTTP variant (enable_tls = false)
# ---------------------------------------------------------------------------
resource "aws_lb_listener" "http_ui" {
  count             = var.enable_tls ? 0 : 1
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui.arn
  }
}

resource "aws_lb_listener" "http_uiws" {
  count             = var.enable_tls ? 0 : 1
  load_balancer_arn = aws_lb.alb.arn
  port              = 8082
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.uiws.arn
  }
}

resource "aws_lb_listener" "http_edgews" {
  count             = var.enable_tls ? 0 : 1
  load_balancer_arn = aws_lb.alb.arn
  port              = 8081
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.edgews.arn
  }
}

# ---------------------------------------------------------------------------
# Listeners — TLS variant (enable_tls = true)
# ---------------------------------------------------------------------------
resource "aws_lb_listener" "https_ui" {
  count             = var.enable_tls ? 1 : 0
  load_balancer_arn = aws_lb.alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.cert[0].certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui.arn
  }
}

resource "aws_lb_listener" "https_uiws" {
  count             = var.enable_tls ? 1 : 0
  load_balancer_arn = aws_lb.alb.arn
  port              = 8082
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.cert[0].certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.uiws.arn
  }
}

# Edge websocket rides on the 443 listener, separated by hostname:
# wss://backend.openems.eiot.energy -> Edge.Websocket target group.
# 443 is firewall-friendly for field Pis (8081 outbound is often blocked).
resource "aws_lb_listener_rule" "edge_ws" {
  count        = var.enable_tls ? 1 : 0
  listener_arn = aws_lb_listener.https_ui[0].arn
  priority     = 10

  condition {
    host_header {
      values = [local.backend_host]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.edgews.arn
  }
}

# Backend2Backend REST rides the 443 listener too, by hostname:
# https://b2b.openems.eiot.energy/jsonrpc -> B2B target group (backend :8075).
# MBE (Vercel) authenticates with HTTP Basic against an OpenEMS/Odoo user.
resource "aws_lb_listener_rule" "b2b" {
  count        = var.enable_tls ? 1 : 0
  listener_arn = aws_lb_listener.https_ui[0].arn
  priority     = 20

  condition {
    host_header {
      values = [local.b2b_host]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.b2b.arn
  }
}

# Port 80 -> 443 redirect once TLS is on.
resource "aws_lb_listener" "http_redirect" {
  count             = var.enable_tls ? 1 : 0
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
