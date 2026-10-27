#!/usr/bin/env bash
# Keep cluster DNS off the Raspberry Pis.
#
# k3s runs a single CoreDNS replica wherever it lands. If that is the Pi the
# instructor pulls, every http://word-service:8080 lookup fails until CoreDNS
# is rescheduled, and the whole app looks dead. The master is never pulled,
# so pin CoreDNS there and run two copies.
#
# k3s re-applies its CoreDNS manifest when the k3s server restarts, so
# deploy.sh runs this every time. Safe to run repeatedly.
set -euo pipefail

kubectl -n kube-system patch deployment coredns --type merge -p '{
  "spec": {
    "replicas": 2,
    "template": {
      "spec": {
        "nodeSelector": { "node-role.kubernetes.io/control-plane": "true" }
      }
    }
  }
}' >/dev/null
kubectl -n kube-system rollout status deployment/coredns --timeout=120s
