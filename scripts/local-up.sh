#!/usr/bin/env bash
# Local stand-in for the Pi cluster, using k3d (k3s in Docker):
#   1 server  = the notebook master (tainted: no app pods run on it)
#   5 agents  = the five Raspberry Pis
# Then builds the images, imports them into every node, and deploys.
#
#   scripts/local-up.sh            -> http://localhost:8080
#   HOST_PORT=9090 scripts/local-up.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER="${CLUSTER:-kube-guess}"
AGENTS="${AGENTS:-5}"
HOST_PORT="${HOST_PORT:-8080}"

command -v k3d >/dev/null || { echo "install k3d first: brew install k3d"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker is not running"; exit 1; }

if ! k3d cluster list "$CLUSTER" >/dev/null 2>&1; then
  echo "==> creating k3d cluster '$CLUSTER' (1 server + $AGENTS agents)"
  # Same k3s flags as cluster/master-install.sh on the real master:
  #  - no Traefik (we expose the app with a NodePort)
  #  - master tainted so app pods only land on "Pis"
  #  - node declared dead after 20s of silence instead of 40-50s
  # The NodePort is published from the server node, like using the
  # master's IP on the real cluster. It goes through k3d's load-balancer
  # container: a ":direct" mapping onto the node hangs on Docker Desktop.
  k3d cluster create "$CLUSTER" \
    --servers 1 --agents "$AGENTS" \
    --k3s-arg "--disable=traefik@server:0" \
    --k3s-arg "--node-taint=node-role.kubernetes.io/control-plane=true:NoSchedule@server:0" \
    --k3s-arg "--kube-controller-manager-arg=node-monitor-grace-period=20s@server:0" \
    --port "${HOST_PORT}:30080@server:0" \
    --wait
fi
kubectl config use-context "k3d-$CLUSTER" >/dev/null

echo "==> building images"
scripts/build.sh

echo "==> importing images into every node"
k3d image import -c "$CLUSTER" \
  kube-guess/frontend:dev kube-guess/gateway:dev kube-guess/word-service:dev \
  kube-guess/evaluator:dev kube-guess/hint-engine:dev

# Rebuilt images keep the :dev tag; restart so pods pick up the new image.
if kubectl get namespace kube-guess >/dev/null 2>&1; then
  kubectl -n kube-guess rollout restart deployment >/dev/null 2>&1 || true
fi

scripts/deploy.sh local
echo
echo "Kube Guess is up: http://localhost:${HOST_PORT}"
