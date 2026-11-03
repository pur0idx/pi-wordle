#!/usr/bin/env bash
# Turn SSH key login back on in the master VM and install this Mac's public
# key there, so scripts/cluster-up.sh can log in without a password.
#
#   scripts/enable-vm-key.sh                      # MASTER_USER@MASTER_IP from cluster/hosts.env
#   scripts/enable-vm-key.sh kube@192.168.0.143   # or name the machine
#
# Asks for the VM user's password (to log in), then its sudo password.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ge 1 ]]; then
  TARGET=$1
else
  # shellcheck disable=SC1091
  source cluster/hosts.env
  TARGET="$MASTER_USER@$MASTER_IP"
fi

PUB=""
for k in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
  [[ -f $k ]] && { PUB=$(cat "$k"); break; }
done
[[ -n $PUB ]] || { echo "no SSH key on this Mac; create one with: ssh-keygen -t ed25519"; exit 1; }

OPTS=(-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

echo "==> $TARGET: installing your key and enabling key login"
echo "    (enter the VM password, then the sudo password)"
# The drop-in is named 00-* so it is read before any other sshd_config.d file;
# for sshd the first value read wins.
ssh -t "${OPTS[@]}" -o PubkeyAuthentication=no "$TARGET" "
  set -e
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
  grep -qxF '$PUB' ~/.ssh/authorized_keys || echo '$PUB' >> ~/.ssh/authorized_keys
  printf 'PubkeyAuthentication yes\nAuthenticationMethods any\n' \
    | sudo tee /etc/ssh/sshd_config.d/00-kube-guess.conf >/dev/null
  sudo sshd -t
  sudo systemctl restart ssh
"

echo "==> testing key login"
if ssh "${OPTS[@]}" -o BatchMode=yes "$TARGET" true; then
  echo "  ✓ $TARGET accepts your key. Next: scripts/cluster-up.sh"
else
  echo "  ✗ still refused. In the VM, look for a setting that overrides it:"
  echo "    sudo sshd -T | grep -Ei 'pubkey|authenticationmethods'"
  echo "    sudo grep -rniE 'pubkey|authenticationmethods|^match' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/"
  exit 1
fi
