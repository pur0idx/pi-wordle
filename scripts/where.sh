#!/usr/bin/env bash
# Which kube-guess pods run on which node: "show current deployment of
# containers on nodes" and "note the services on the Pi we are about to pull".
#
# A pod on a dead node still says Running (its kubelet can no longer report),
# so pods on NotReady nodes are shown as LOST and pods being deleted as
# Terminating.
set -euo pipefail
NS=kube-guess

NODES=$(kubectl get nodes --no-headers -o custom-columns='N:.metadata.name,R:.status.conditions[?(@.type=="Ready")].status,CP:.metadata.labels.node-role\.kubernetes\.io/control-plane')
{
  echo "NODE STATUS ROLE"
  echo "$NODES" | awk '{ print $1, ($2 == "True" ? "Ready" : "NotReady"), ($3 == "true" ? "control-plane" : "worker") }'
} | column -t
echo
# BSD awk (macOS) rejects newlines in -v values, so pass a flat list.
DOWN=$(echo "$NODES" | awk '$2 != "True" { printf "%s ", $1 }')

kubectl -n "$NS" get pods --no-headers -l 'app.kubernetes.io/part-of=kube-guess,app.kubernetes.io/name!=image-prepull' \
  -o custom-columns='NODE:.spec.nodeName,SERVICE:.metadata.labels.app\.kubernetes\.io/name,POD:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[0].ready,DEL:.metadata.deletionTimestamp' \
| awk -v down="$DOWN" '
  BEGIN { n = split(down, d, " "); for (i = 1; i <= n; i++) dead[d[i]] = 1 }
  {
    state = $4
    if ($6 != "<none>") state = "Terminating"
    if ($1 in dead) state = "LOST(node-down)"
    if (state == "Running" && $5 != "true") state = "Starting"
    print $1, $2, $3, state
  }' \
| sort | { echo "NODE SERVICE POD STATE"; cat; } | column -t
