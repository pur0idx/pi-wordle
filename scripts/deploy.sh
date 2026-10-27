#!/usr/bin/env bash
# One-command deployment:  scripts/deploy.sh [local|pi]
#
#   1. creates the namespace and the daily-answer Secret (random, if missing)
#   2. pins CoreDNS to the control plane (scripts/harden-system.sh)
#   3. applies k8s/overlays/<overlay> with kustomize
#   4. waits until every deployment has all replicas ready
set -euo pipefail
cd "$(dirname "$0")/.."

OVERLAY="${1:-local}"
NS=kube-guess
[[ -d "k8s/overlays/$OVERLAY" ]] || { echo "unknown overlay: $OVERLAY (use local or pi)"; exit 1; }
if [[ "$OVERLAY" == pi ]] && grep -q CHANGE_ME k8s/overlays/pi/kustomization.yaml; then
  echo "Set your registry first: scripts/set-registry.sh <github-owner>"; exit 1
fi

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"

# The secret never lives in git. Every word-service replica reads the same
# value, which is what makes their daily answers agree.
if ! kubectl -n "$NS" get secret kube-guess-secret >/dev/null 2>&1; then
  SECRET="${DAILY_SECRET:-$(openssl rand -hex 32)}"
  kubectl -n "$NS" create secret generic kube-guess-secret --from-literal=DAILY_SECRET="$SECRET"
  echo "created secret kube-guess-secret"
fi

# Images from a private GitHub repo are private on GHCR too. Either make the
# packages public, or export GHCR_USER and GHCR_TOKEN (a PAT with
# read:packages) and every pod in the namespace gets a pull secret.
if [[ -n "${GHCR_TOKEN:-}" ]]; then
  kubectl -n "$NS" create secret docker-registry ghcr-pull \
    --docker-server=ghcr.io --docker-username="${GHCR_USER:?set GHCR_USER}" --docker-password="$GHCR_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$NS" patch serviceaccount default -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}'
fi

echo "==> pinning CoreDNS to the control plane"
scripts/harden-system.sh

echo "==> applying k8s/overlays/$OVERLAY"
kubectl apply -k "k8s/overlays/$OVERLAY"

echo "==> waiting for rollouts"
for d in word-service evaluator hint-engine gateway frontend; do
  kubectl -n "$NS" rollout status "deployment/$d" --timeout=300s
done
kubectl -n "$NS" rollout status daemonset/image-prepull --timeout=300s

echo
scripts/where.sh
