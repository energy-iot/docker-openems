# Postgres 15 — matches the existing local data directory AND the RDS
# engine version in iac/terraform.tfvars. Keep the three in lockstep;
# a major-version bump is its own change with a pg_upgrade plan.
FROM postgres:15

# Expose the default port for PostgreSQL
EXPOSE 5432
