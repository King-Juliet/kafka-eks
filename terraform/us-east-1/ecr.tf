# Your own copy of the public charts and images the cluster pulls (README "Images and charts come from your ECR").
# Nothing in the cluster pulls from quay.io, ghcr.io or public.ecr.aws directly: it asks this registry, and the
# registry fetches from upstream the first time and keeps the copy.
#
#   ecr-public  <- public.ecr.aws   Karpenter, the AWS Load Balancer Controller image, Argo CD's Redis
#   quay        <- quay.io          Strimzi (chart and images), Argo CD
#   ghcr        <- ghcr.io          Actions Runner Controller (charts, images, runner), External Secrets, Argo CD's Dex
#
# ghcr.io is the only one that needs a login: ECR reads it from the secret you create once by hand
# (var.ghcr_pull_secret_name, README step 3). If that secret is missing, the plan stops with "secret not found".
data "aws_secretsmanager_secret" "ghcr_pull" {
  name = var.ghcr_pull_secret_name
}

module "ecr_cache" {
  source = "../ecr-cache"

  region      = var.region
  policy_name = "${var.cluster_name}-ecr-cache-pull"

  upstreams = {
    "ecr-public" = { registry_url = "public.ecr.aws" }
    quay         = { registry_url = "quay.io" }
    ghcr = {
      registry_url          = "ghcr.io"
      credential_secret_arn = data.aws_secretsmanager_secret.ghcr_pull.arn
    }
  }

  tags = local.tags
}

# The system node group runs Argo CD and the Strimzi operator. (Karpenter's nodes and the External Secrets role get
# the same policy in layer 2, where those roles are created.)
resource "aws_iam_role_policy_attachment" "system_nodes_ecr_cache" {
  role       = module.eks.node_role_name
  policy_arn = module.ecr_cache.puller_policy_arn
}