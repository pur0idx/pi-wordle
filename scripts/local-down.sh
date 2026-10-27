#!/usr/bin/env bash
# Delete the local k3d cluster.
set -euo pipefail
k3d cluster delete "${CLUSTER:-kube-guess}"
