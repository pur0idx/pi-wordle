#!/usr/bin/env bash
# Run once on each Raspberry Pi (Raspberry Pi OS Lite 64-bit), then reboot.
#
#   sudo MASTER_IP=192.168.0.100 ./pi-prep.sh pi-1
#
# - sets the hostname (node names in kubectl / the UI trace come from this)
# - enables the memory cgroup, which k3s needs and Pi OS leaves off
# - disables swap (kubelet expects it off)
# - syncs the clock from the master with chrony
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
NAME="${1:?usage: sudo MASTER_IP=<ip> ./pi-prep.sh <hostname, e.g. pi-1>}"
MASTER_IP="${MASTER_IP:?set MASTER_IP to the IP of the master VM}"

echo "==> hostname $NAME"
hostnamectl set-hostname "$NAME"
sed -i "s/^127.0.1.1.*/127.0.1.1\t$NAME/" /etc/hosts

CMDLINE=/boot/firmware/cmdline.txt
[[ -f $CMDLINE ]] || CMDLINE=/boot/cmdline.txt
if ! grep -q cgroup_memory=1 "$CMDLINE"; then
  echo "==> enabling memory cgroup in $CMDLINE"
  sed -i '1 s/$/ cgroup_memory=1 cgroup_enable=memory/' "$CMDLINE"
fi

echo "==> disabling swap"
swapoff -a || true
systemctl disable --now dphys-swapfile 2>/dev/null || true
systemctl mask --now rpi-zram-writeback.timer 2>/dev/null || true

echo "==> chrony -> $MASTER_IP"
apt-get update -qq
apt-get install -y -qq chrony curl
echo "server $MASTER_IP iburst prefer" > /etc/chrony/conf.d/kube-guess.conf
systemctl restart chrony

echo
echo "Done. Reboot now:  sudo reboot"
