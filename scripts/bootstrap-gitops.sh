#!/usr/bin/env bash
# Installs Argo CD, registers the repo, starts the "app of apps" and waits for every sync wave to finish.
# Runs from inside the VPC (the Kubernetes API is private) with the deploy role's AWS credentials.
# Idempotent: running it again on a healthy cluster changes nothing.
#
# Env (all optional):
#   CLUSTER_NAME          default kafka-test
#   AWS_REGION            default us-east-1
#   ARGOCD_VERSION        default v3.6.1
#   ARGOCD_INSTALL_SHA256 if set, the downloaded install.yaml must match it (otherwise the hash is only printed)
#   REPO_URL              default https://github.com/King-Juliet/kafka-eks.git
#   WAIT_REQUIRED_SECONDS per required app, default 3600
#   WAIT_OPTIONAL_SECONDS per optional (ARC) app, default 900
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kafka-test}"
REGION="${AWS_REGION:-us-east-1}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.6.1}"
REPO_URL="${REPO_URL:-https://github.com/King-Juliet/kafka-eks.git}"
WAIT_REQUIRED_SECONDS="${WAIT_REQUIRED_SECONDS:-3600}"
WAIT_OPTIONAL_SECONDS="${WAIT_OPTIONAL_SECONDS:-900}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRED_APPS=(kafka-prereqs strimzi-operator kafka-cluster kafka-secrets gateway)
OPTIONAL_APPS=(arc-config arc-controller arc-runner-set)

log() { printf '\n== %s\n' "$*"; }

aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" >/dev/null

# ---------------------------------------------------------------- Git credentials for Argo CD (private repo)
# If the repo credential secret is still an empty shell, fill it from the runner token (the same GitHub token).
# External Secrets copies it into the argocd namespace. Skipped when a value is already there.
ensure_repo_credentials() {
  if aws secretsmanager get-secret-value --region "$REGION" --secret-id /argocd/gitops-repo >/dev/null 2>&1; then
    echo "repo credential already set"
    return 0
  fi
  local token
  token="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id /github/runner-auth \
    --query SecretString --output text | jq -r '.github_token // empty')"
  if [ -z "$token" ]; then
    echo "WARNING: /github/runner-auth has no token yet; Argo CD cannot read a private repo" >&2
    return 0
  fi
  jq -n --arg url "$REPO_URL" --arg pw "$token" '{type: "git", url: $url, username: "git", password: $pw}' |
    aws secretsmanager put-secret-value --region "$REGION" --secret-id /argocd/gitops-repo --secret-string file:///dev/stdin >/dev/null
  echo "repo credential written from the runner token"
}

log "Git credentials"
ensure_repo_credentials

# ---------------------------------------------------------------- Argo CD
log "Argo CD $ARGOCD_VERSION"
kubectl get namespace argocd >/dev/null 2>&1 || kubectl create namespace argocd
manifest="$(mktemp)"
curl -fsSL "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" -o "$manifest"
actual="$(sha256sum "$manifest" | cut -d' ' -f1)"
echo "install.yaml sha256: $actual"
if [ -n "${ARGOCD_INSTALL_SHA256:-}" ] && [ "$actual" != "$ARGOCD_INSTALL_SHA256" ]; then
  echo "install.yaml does not match ARGOCD_INSTALL_SHA256" >&2
  exit 1
fi
# Server-side apply: the CRDs are too large for client-side apply.
kubectl apply --server-side --force-conflicts -n argocd -f "$manifest"
rm -f "$manifest"

kubectl -n argocd wait --for=condition=Available deployment --all --timeout=900s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=900s

# ---------------------------------------------------------------- health checks, repo registrations, root app
log "Health checks (what makes sync waves wait)"
before="$(kubectl -n argocd get configmap argocd-cm -o json | jq -S '.data // {}' | sha256sum)"
kubectl apply --server-side --force-conflicts --field-manager=gitops-bootstrap -f "$ROOT/gitops/bootstrap/argocd-cm-health.yaml"
after="$(kubectl -n argocd get configmap argocd-cm -o json | jq -S '.data // {}' | sha256sum)"
if [ "$before" != "$after" ]; then
  echo "argocd-cm changed: restarting the application controller so it reloads the checks"
  kubectl -n argocd rollout restart statefulset/argocd-application-controller
  kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s
fi

log "Registering OCI Helm registries and the root application"
kubectl apply -f "$ROOT/gitops/bootstrap/repo-strimzi-oci.yaml"
kubectl apply -f "$ROOT/gitops/bootstrap/repo-arc-oci.yaml"
kubectl apply -f "$ROOT/gitops/bootstrap/root-app.yaml"

# ---------------------------------------------------------------- wait for the waves
app_state() { # prints "<health>/<sync>" or "missing"
  kubectl -n argocd get application "$1" -o jsonpath='{.status.health.status}/{.status.sync.status}' 2>/dev/null || echo "missing"
}

wait_for_app() { # name, timeout seconds; returns 0 when Healthy/Synced
  local app="$1" limit="$2" waited=0 state last=""
  while [ "$waited" -lt "$limit" ]; do
    state="$(app_state "$app")"
    if [ "$state" = "Healthy/Synced" ]; then
      echo "  $app: Healthy/Synced"
      return 0
    fi
    if [ "$state" != "$last" ]; then
      echo "  $app: $state (waited ${waited}s)"
      last="$state"
    fi
    sleep 20
    waited=$((waited + 20))
  done
  echo "  $app: still $(app_state "$app") after ${limit}s" >&2
  return 1
}

explain_failure() {
  echo "---- application summary" >&2
  kubectl -n argocd get applications.argoproj.io >&2 || true
  echo "---- $1 conditions and last operation" >&2
  kubectl -n argocd get application "$1" -o json 2>/dev/null |
    jq '{conditions: .status.conditions, operation: .status.operationState.message, resources: [.status.resources[]? | select(.health.status != "Healthy" and .health.status != null) | {kind, name, health: .health.status, message: .health.message}]}' >&2 || true
}

log "Waiting for sync waves (kafka stack is required)"
for app in "${REQUIRED_APPS[@]}"; do
  wait_for_app "$app" "$WAIT_REQUIRED_SECONDS" || {
    explain_failure "$app"
    exit 1
  }
done

# ---------------------------------------------------------------- publish what other jobs and the ASGs need
log "Publishing the Kafka bootstrap address"
bootstrap="$(kubectl -n kafka get kafka kafka-test -o jsonpath='{.status.listeners[?(@.name=="external")].bootstrapServers}')"
if [ -z "$bootstrap" ]; then
  echo "Kafka is Ready but reports no external bootstrap address" >&2
  exit 1
fi
echo "bootstrap: $bootstrap"
aws ssm put-parameter --region "$REGION" --name /kafka-eks/kafka/bootstrap --type String --value "$bootstrap" --overwrite >/dev/null

log "Actions Runner Controller (optional: it is the fallback-to-nothing, not a blocker)"
arc_ready=false
arc_all_ok=true
for app in "${OPTIONAL_APPS[@]}"; do
  wait_for_app "$app" "$WAIT_OPTIONAL_SECONDS" || arc_all_ok=false
done
if [ "$arc_all_ok" = true ]; then
  # ASSUMPTION: the scale-set listener pod has "listener" in its name (ARC's naming). Unverified from here.
  listener_running="$(kubectl -n arc-systems get pods -o json | jq '[.items[] | select(.metadata.name | test("listener")) | select(.status.phase == "Running")] | length')"
  if [ "${listener_running:-0}" -ge 1 ]; then
    arc_ready=true
  else
    echo "ARC apps are Healthy but no listener pod is Running yet" >&2
  fi
fi
echo "arc-ready=$arc_ready"
aws ssm put-parameter --region "$REGION" --name /kafka-eks/ci/arc-ready --type String --value "$arc_ready" --overwrite >/dev/null
echo
echo "bootstrap-gitops: done"