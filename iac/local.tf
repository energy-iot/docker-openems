locals {
  # ECR registry lives in this account/region — no secret indirection needed.
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"

  # Edge/Pi-facing hostname for the Edge.Websocket, host-routed on 443.
  # (The UI + its websocket stay on the apex openems.eiot.energy:8082 because
  # the UI bundle hard-wires ${location.hostname}:8082. Odoo is NOT public —
  # SSM/ECS-Exec tunnel only.)
  backend_host = var.domain_name != "" ? "backend.${var.domain_name}" : ""

  # Backend2Backend REST/JSON-RPC (:8075), host-routed on 443. This is what the
  # Metering & Billing Engine (MBE, on Vercel) hits to pull meter data. It POSTs
  # JSON-RPC to https://<b2b_host>/jsonrpc with HTTP Basic auth (validated
  # against an OpenEMS/Odoo user).
  b2b_host = var.domain_name != "" ? "b2b.${var.domain_name}" : ""
}
