#!/usr/bin/env bash
# Run on each Pi after pi-prep.sh + reboot. Joins it to the k3s cluster.
#
#   MASTER_IP=192.168.0.100 K3S_TOKEN=K10...::server:... ./join-worker.sh
#
# The exact command (with the token filled in) is printed by master-install.sh.
set -euo pipefail
K3S_VERSION="${K3S_VERSION:-v1.35.5+k3s1}"
MASTER_IP="${MASTER_IP:?set MASTER_IP}"
K3S_TOKEN="${K3S_TOKEN:?set K3S_TOKEN (sudo cat /var/lib/rancher/k3s/server/node-token on the master)}"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"

grep -q cgroup_memory=1 /proc/cmdline || { echo "memory cgroup is off: run pi-prep.sh and reboot first"; exit 1; }

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" \
  K3S_URL="https://$MASTER_IP:6443" K3S_TOKEN="$K3S_TOKEN" sh -s - agent --node-ip "$NODE_IP"

echo "Joined. On the master, check: kubectl get nodes -o wide"
