#!/usr/bin/env bash
# Run on the master: an Ubuntu VM (>= 2 vCPU, 2 GB RAM) on a notebook, with a
# BRIDGED network adapter so it gets an IP on the Pi router's LAN.
#
#   MASTER_IP=192.168.0.100 ./master-install.sh
#
# Installs:
#   - chrony as an NTP server for the Pis (they have no real-time clock, and
#     the demo network may have no internet; k3s TLS breaks with wrong clocks)
#   - k3s server, tainted so app pods only run on the Pis
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.35.5+k3s1}"   # same version the local k3d test uses
MASTER_IP="${MASTER_IP:-$(hostname -I | awk '{print $1}')}"
LAN_CIDR="${LAN_CIDR:-$(echo "$MASTER_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')}"

echo "==> master IP $MASTER_IP, LAN $LAN_CIDR, k3s $K3S_VERSION"

echo "==> chrony (NTP server for the Pis)"
sudo apt-get update -qq
sudo apt-get install -y -qq chrony curl
sudo tee /etc/chrony/conf.d/kube-guess.conf >/dev/null <<CONF
allow $LAN_CIDR
# keep serving time even when this VM has no upstream NTP (offline demo)
local stratum 8
CONF
sudo systemctl restart chrony

echo "==> k3s server"
# --disable traefik      we expose the app with a NodePort instead
# --node-taint           no app pods on the master; the Pis do the work
# node-monitor-grace-period=20s
#                        declare a pulled Pi dead after 20s instead of 40-50s
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server \
  --node-ip "$MASTER_IP" \
  --advertise-address "$MASTER_IP" \
  --tls-san "$MASTER_IP" \
  --disable traefik \
  --node-taint node-role.kubernetes.io/control-plane=true:NoSchedule \
  --kube-controller-manager-arg node-monitor-grace-period=20s \
  --write-kubeconfig-mode 644

mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
sed -i "s#https://127.0.0.1:6443#https://$MASTER_IP:6443#" ~/.kube/config

echo
echo "k3s server is up. Join each Pi with:"
echo
echo "  MASTER_IP=$MASTER_IP K3S_TOKEN=$(sudo cat /var/lib/rancher/k3s/server/node-token) ./join-worker.sh"
echo
