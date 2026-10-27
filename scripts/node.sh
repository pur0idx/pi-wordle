#!/usr/bin/env bash
# Simulate pulling a Raspberry Pi on the local k3d cluster.
#
#   scripts/node.sh list                   nodes and their containers
#   scripts/node.sh kill [agent-N|random]  stop that node's container (pull the Pi)
#   scripts/node.sh restore [agent-N|all]  start it again (plug the Pi back in)
set -euo pipefail
CLUSTER="${CLUSTER:-kube-guess}"
PREFIX="k3d-$CLUSTER"

agents() { docker ps -a --filter "name=^${PREFIX}-agent-" --format '{{.Names}}' | sort; }

case "${1:-list}" in
  list)
    docker ps -a --filter "name=^${PREFIX}-(server|agent)-" --format 'table {{.Names}}\t{{.Status}}'
    ;;
  kill)
    target="${2:-random}"
    if [[ "$target" == random ]]; then
      target=$(docker ps --filter "name=^${PREFIX}-agent-" --format '{{.Names}}' | sort -R | head -1)
      [[ -n "$target" ]] || { echo "no running agents"; exit 1; }
    else
      target="${PREFIX}-${target#${PREFIX}-}"
    fi
    echo "Services on $target before pulling it:"
    kubectl -n kube-guess get pods --field-selector "spec.nodeName=$target" \
      -l app.kubernetes.io/name!=image-prepull -o custom-columns='SERVICE:.metadata.labels.app\.kubernetes\.io/name,POD:.metadata.name' || true
    docker stop "$target" >/dev/null
    echo
    echo "Pulled $target at $(date +%T). Watch replacements with:"
    echo "  watch -n1 scripts/where.sh"
    ;;
  restore)
    target="${2:-all}"
    if [[ "$target" == all ]]; then
      agents | xargs docker start >/dev/null
    else
      docker start "${PREFIX}-${target#${PREFIX}-}" >/dev/null
    fi
    echo "restored $target"
    ;;
  *)
    echo "usage: $0 list | kill [agent-N|random] | restore [agent-N|all]"; exit 1
    ;;
esac
