# Argo CD itself is installed by scripts/bootstrap-gitops.sh (CD), but two things need its namespace first:
# the ExternalSecret that feeds Argo CD its Git credentials, and the install. Creating the namespace here means
# neither has to guess the order. Argo CD / the bootstrap script may add labels and annotations later; those are ignored.
resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }

  lifecycle {
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
  }
}