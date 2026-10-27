#!/usr/bin/env bash
# Point the Pi overlay at your GHCR images:  scripts/set-registry.sh <github-owner> [tag]
set -euo pipefail
cd "$(dirname "$0")/.."
OWNER="$(echo "${1:?usage: set-registry.sh <github-owner> [tag]}" | tr '[:upper:]' '[:lower:]')"
TAG="${2:-latest}"
F=k8s/overlays/pi/kustomization.yaml
sed -i.bak -E "s#ghcr.io/[^/]+/#ghcr.io/$OWNER/#; s#newTag: [^ }]+#newTag: $TAG#" "$F" && rm "$F.bak"
grep newName "$F"
