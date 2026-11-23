#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-kafka-test}"

lb_services() {
  kubectl get svc -A -o json | jq -r '.items[] | select(.spec.type == "LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"'
}

wait_until_empty() {
  local what="$1" limit="$2" waited=0
  shift 2
  while [ -n "$("$@")" ]; do
    if [ "$waited" -ge "$limit" ]; then
      echo "$what still present after ${limit}s:" >&2
      "$@" >&2
      return 1
    fi
    sleep 15
    waited=$((waited + 15))
  done
  echo "$what: gone"
}

strip_finalizers() {
  local kind="$1"
  { kubectl get "$kind" -A -o json 2>/dev/null || echo '{"items":[]}'; } |
    jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' |
    while read -r ns name; do
      kubectl -n "$ns" patch "$kind" "$name" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null || true
    done
}

aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" >/dev/null

kubectl -n argocd scale statefulset argocd-application-controller --replicas=0 || true
kubectl -n argocd scale deployment argocd-applicationset-controller --replicas=0 || true

for kind in pushsecrets.external-secrets.io externalsecrets.external-secrets.io; do
  if kubectl get crd "$kind" >/dev/null 2>&1; then
    kubectl delete "$kind" --all -A --ignore-not-found --timeout=2m || strip_finalizers "$kind"
  fi
done

kubectl -n gateway delete gateway --all --ignore-not-found --timeout=10m
kubectl delete httproute --all -A --ignore-not-found --timeout=5m
kubectl -n kafka delete kafka --all --ignore-not-found --timeout=10m
kubectl -n kafka delete kafkanodepool --all --ignore-not-found --timeout=10m
wait_until_empty "Kafka pods" 900 kubectl -n kafka get pods -o name

lb_services | while read -r svc; do
  kubectl -n "${svc%/*}" delete svc "${svc#*/}" --ignore-not-found --timeout=10m
done
wait_until_empty "LoadBalancer services" 900 lb_services

kubectl -n kafka delete pvc --all --ignore-not-found --timeout=5m

kubectl delete nodepool --all --ignore-not-found --timeout=15m
wait_until_empty "Karpenter nodes" 900 kubectl get nodeclaims -o name