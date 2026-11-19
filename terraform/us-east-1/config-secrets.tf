# Small settings that live outside Terraform: the ETL instances and the CD scripts read them. They are Secrets Manager
# secrets, created EMPTY here (same module as the Argo CD secrets). Whoever learns the value writes it:
#   db-endpoint       cd.yml, right after layer 1 is applied (the database has no address before that)
#   kafka-bootstrap   scripts/bootstrap-gitops.sh, once Kafka reports its address
#   clients-release   scripts/release_clients.sh, after every upload
#   arc-ready         scripts/bootstrap-gitops.sh ("true" once ARC can run jobs)
# None of them is a password, so there is no recovery window: after a destroy the names can be reused straight away.
locals {
  config_secret_names = {
    db_endpoint     = "/kafka-eks/config/db-endpoint"
    kafka_bootstrap = "/kafka-eks/config/kafka-bootstrap"
    clients_release = "/kafka-eks/config/clients-release"
    arc_ready       = "/kafka-eks/config/arc-ready"
  }
}

module "config_secrets" {
  source = "../secrets-shells"

  secret_names            = values(local.config_secret_names)
  recovery_window_in_days = 0
  tags                    = local.tags
}