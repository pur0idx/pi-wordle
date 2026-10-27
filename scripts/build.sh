#!/usr/bin/env bash
# Build all five images for this machine's architecture as kube-guess/<svc>:dev.
# (Multi-arch images for the Pis are built by .github/workflows/build.yml.)
set -euo pipefail
cd "$(dirname "$0")/.."

SERVICES=(frontend gateway word-service evaluator hint-engine)
for svc in "${SERVICES[@]}"; do
  target=()
  # Python images have a `test` stage after `runtime`; build the runtime one.
  grep -q "AS runtime" "services/$svc/Dockerfile" && target=(--target runtime)
  echo "==> building kube-guess/$svc:dev"
  # ${arr[@]+...} form: macOS ships bash 3.2, which treats an empty array as unset.
  docker build -q ${target[@]+"${target[@]}"} -f "services/$svc/Dockerfile" -t "kube-guess/$svc:dev" . >/dev/null
done
docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep '^kube-guess/' | sort
