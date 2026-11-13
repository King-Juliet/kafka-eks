# Gateway API object types (the "standard" channel, v1.5.0): GatewayClass, Gateway, HTTPRoute, GRPCRoute,
# ReferenceGrant, ListenerSet, TLSRoute, BackendTLSPolicy.
#
# These are only the TYPES. On their own they do nothing; a controller has to act on them. Here that is the
# AWS Load Balancer Controller, which turns a Gateway into an ALB and an HTTPRoute into its listener rules.
# The controller switches its Gateway support on when it finds these types at start-up, so this module is
# installed BEFORE the controller (see aws-load-balancer-controller.tf in the region folder).
#
# The files in ./chart/crds are copied unchanged from github.com/kubernetes-sigs/gateway-api, tag v1.5.0,
# folder config/crd/standard. The one file in that folder that is NOT a CRD (the ValidatingAdmissionPolicy
# gateway.networking.k8s.io_vap_safeupgrades.yaml) is left out.
#
# Helm installs files in a chart's crds/ folder once and never touches them again, and it never deletes
# them on uninstall. To upgrade the CRDs later, apply the new files by hand:
#   kubectl apply --server-side -f <new crd files>
# (they are too big for a normal client-side apply), then bump `version` in ./chart/Chart.yaml.

resource "helm_release" "crds" {
  name      = "gateway-api-crds"
  namespace = var.namespace
  chart     = "${path.module}/chart"
}