# Gateway API object types (GatewayClass, Gateway, HTTPRoute, ...). The load balancer controller turns
# them into ALBs, but it only switches that on if the types already exist when it starts, so this
# is installed before it (see aws-load-balancer-controller.tf).
module "gateway_api" {
  source = "../gateway-api"
}