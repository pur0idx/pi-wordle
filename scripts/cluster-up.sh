#!/usr/bin/env bash
# Build the whole Raspberry Pi cluster and deploy Kube Guess, from your Mac,
# in one command:
#
#   scripts/cluster-up.sh [--no-runner] [--no-deploy]
#
# Before running it (the parts no script can do):
#   - router on, master VM running (bridged), 5 Pis flashed and powered
#   - cluster/hosts.env filled in (cp cluster/hosts.example.env cluster/hosts.env)
#
# What it does, over SSH, and safe to re-run (finished steps are skipped):
#   1. checks it can reach every machine; installs your SSH key if needed
#   2. master: k3s server + chrony (cluster/master-install.sh)
#   3. Pis, all in parallel: prep, reboot if needed, join the cluster
#   4. waits until all nodes are Ready; writes ~/.kube/pi-cluster
#   5. installs a GitHub Actions runner on the master, so every push to main
#      redeploys automatically (skip with --no-runner)
#   6. deploys the app (scripts/deploy.sh pi; skip with --no-deploy)
set -euo pipefail
cd "$(dirname "$0")/.."

WITH_RUNNER=1
WITH_DEPLOY=1
for arg in "$@"; do
  case "$arg" in
    --no-runner) WITH_RUNNER=0 ;;
    --no-deploy) WITH_DEPLOY=0 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg"; exit 1 ;;
  esac
done

INVENTORY="${INVENTORY:-cluster/hosts.env}"
[[ -f "$INVENTORY" ]] || {
  echo "missing $INVENTORY. Create it with:"
  echo "  cp cluster/hosts.example.env cluster/hosts.env   # then edit the addresses"
  exit 1
}
# shellcheck disable=SC1090
source "$INVENTORY"
: "${MASTER_IP:?set MASTER_IP in $INVENTORY}" "${MASTER_USER:?}" "${PIS:?}" "${PI_USER:?}"

KUBECONFIG_OUT="${KUBECONFIG_OUT:-$HOME/.kube/pi-cluster}"
LOG_DIR=.deploy/logs
mkdir -p "$LOG_DIR" "$(dirname "$KUBECONFIG_OUT")"

# Lab LAN: reflashed Pis come back with new host keys, so do not pin them.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
MASTER="$MASTER_USER@$MASTER_IP"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
good() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }

# "pi-1" -> pi-1 / pi-1.local ; "pi-1=192.168.0.101" -> pi-1 / 192.168.0.101
NAMES=(); ADDRS=()
for entry in $PIS; do
  name="${entry%%=*}"
  addr="${entry#*=}"
  [[ "$addr" == "$entry" ]] && addr="$name.local"
  NAMES+=("$name"); ADDRS+=("$addr")
done

can_ssh() { ssh "${SSH_OPTS[@]}" "$1" true 2>/dev/null; }

wait_for_ssh() {  # target timeout-seconds
  local end=$((SECONDS + $2))
  while (( SECONDS < end )); do can_ssh "$1" && return 0; sleep 5; done
  return 1
}

ensure_key_access() {  # target
  can_ssh "$1" && return 0
  echo "  $1 does not accept your SSH key yet; installing it (enter that machine's password)"
  ssh-copy-id -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$1" >/dev/null
  can_ssh "$1" && return 0
  # Reachable, but the server never offers "publickey" (disabled in sshd_config).
  if ssh "${SSH_OPTS[@]}" -v "$1" true 2>&1 | grep 'Authentications that can continue' | grep -qv publickey; then
    echo "  $1 has SSH key login disabled. On that machine run:"
    echo "    printf 'PubkeyAuthentication yes\\nAuthenticationMethods any\\n' | sudo tee /etc/ssh/sshd_config.d/00-kube-guess.conf"
    echo "    sudo systemctl restart ssh"
  fi
  return 1
}

# ---------------------------------------------------------------- 1. preflight
say "1/6 checking tools and machines"
for tool in ssh scp kubectl openssl; do
  command -v "$tool" >/dev/null || { bad "missing $tool"; exit 1; }
done
if (( WITH_RUNNER )) && ! gh auth status >/dev/null 2>&1; then
  bad "GitHub CLI not logged in (gh auth login), or rerun with --no-runner"; exit 1
fi
if [[ ! -f ~/.ssh/id_ed25519.pub && ! -f ~/.ssh/id_rsa.pub ]]; then
  echo "  no SSH key on this Mac; creating ~/.ssh/id_ed25519"
  ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519
fi

failed=0
for target in "$MASTER" $(for i in "${!NAMES[@]}"; do echo "$PI_USER@${ADDRS[$i]}"; done); do
  if ensure_key_access "$target"; then good "$target"; else bad "$target unreachable"; failed=1; fi
done
(( failed )) && { echo "Fix the unreachable machines (powered on? on the router? right address in $INVENTORY?) and rerun."; exit 1; }

# ------------------------------------------------------------------- 2. master
say "2/6 master $MASTER_IP"
scp -q "${SSH_OPTS[@]}" cluster/master-install.sh cluster/install-runner.sh "$MASTER:"
if ssh "${SSH_OPTS[@]}" "$MASTER" 'systemctl is-active --quiet k3s && test -f ~/.kube/node-token'; then
  good "k3s server already running"
else
  # -t: the first run may ask for the VM user's sudo password (once).
  ssh -t "${SSH_OPTS[@]}" "$MASTER" "MASTER_IP=$MASTER_IP ./master-install.sh" | tee "$LOG_DIR/master.log"
fi
K3S_TOKEN=$(ssh "${SSH_OPTS[@]}" "$MASTER" 'cat ~/.kube/node-token')
scp -q "${SSH_OPTS[@]}" "$MASTER:.kube/config" "$KUBECONFIG_OUT"
chmod 600 "$KUBECONFIG_OUT"
export KUBECONFIG="$KUBECONFIG_OUT"
good "kubeconfig written to $KUBECONFIG_OUT"

# --------------------------------------------------------------------- 3. Pis
say "3/6 preparing and joining ${#NAMES[@]} Pis in parallel (logs: $LOG_DIR/<pi>.log)"

setup_pi() {  # name address
  local name=$1 target="$PI_USER@$2"
  local rsh=(ssh "${SSH_OPTS[@]}" "$target")
  scp -q "${SSH_OPTS[@]}" cluster/pi-prep.sh cluster/join-worker.sh "$target:"
  if "${rsh[@]}" 'systemctl is-active --quiet k3s-agent'; then
    echo "already joined"; return 0
  fi
  "${rsh[@]}" 'sudo -n true' || { echo "sudo needs a password for $PI_USER on $name"; return 1; }
  "${rsh[@]}" "sudo -n env MASTER_IP=$MASTER_IP ./pi-prep.sh $name"
  if ! "${rsh[@]}" 'grep -q cgroup_memory=1 /proc/cmdline'; then
    echo "rebooting to enable the memory cgroup"
    "${rsh[@]}" 'sudo -n systemctl reboot' || true
    sleep 20
    wait_for_ssh "$target" 300 || { echo "did not come back after reboot"; return 1; }
    "${rsh[@]}" 'grep -q cgroup_memory=1 /proc/cmdline' || { echo "memory cgroup still off"; return 1; }
  fi
  "${rsh[@]}" "MASTER_IP=$MASTER_IP K3S_TOKEN='$K3S_TOKEN' ./join-worker.sh"
}

for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"
  rm -f "$LOG_DIR/$name.status"
  (
    # bash ignores `set -e` inside anything run from an `if`/`&&`, so run the
    # steps in their own subshell where it applies, then record the result.
    set +e
    ( set -e; setup_pi "$name" "${ADDRS[$i]}" )
    if [[ $? -eq 0 ]]; then echo ok; else echo fail; fi > "$LOG_DIR/$name.status"
  ) > "$LOG_DIR/$name.log" 2>&1 &
done
wait

failed=0
for name in "${NAMES[@]}"; do
  if [[ "$(cat "$LOG_DIR/$name.status" 2>/dev/null)" == ok ]]; then
    good "$name"
  else
    bad "$name, last lines of $LOG_DIR/$name.log:"; tail -5 "$LOG_DIR/$name.log" | sed 's/^/      /'
    failed=1
  fi
done
(( failed )) && { echo "Fix the failed Pis and rerun: finished ones are skipped."; exit 1; }

# ------------------------------------------------------------------- 4. nodes
say "4/6 waiting for all nodes to be Ready"
expected=$(( ${#NAMES[@]} + 1 ))
end=$((SECONDS + 300))
until [[ "$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ')" -ge "$expected" ]]; do
  (( SECONDS < end )) || { kubectl get nodes; bad "not all $expected nodes Ready after 5 min"; exit 1; }
  sleep 5
done
kubectl get nodes -o wide

# ------------------------------------------------------------------ 5. runner
say "5/6 GitHub continuous deployment"
if (( ! WITH_RUNNER )); then
  echo "  skipped (--no-runner)"
else
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  if [[ "$(gh repo view --json visibility -q .visibility)" == PUBLIC ]]; then
    # On a public repo, anyone's pull request could try to run code on a
    # self-hosted runner, which here sits inside your cluster's network.
    bad "$REPO is public: not installing a self-hosted runner. Make it private (the course requires it) and rerun."
  else
    REG_TOKEN=$(gh api -X POST "repos/$REPO/actions/runners/registration-token" -q .token)
    ssh -t "${SSH_OPTS[@]}" "$MASTER" "./install-runner.sh https://github.com/$REPO $REG_TOKEN" \
      | tee "$LOG_DIR/runner.log"
    gh variable set DEPLOY_TO_PI --body true --repo "$REPO"
    good "runner online; pushes to main now redeploy the Pis"
  fi
fi

# ------------------------------------------------------------------ 6. deploy
say "6/6 deploying Kube Guess"
if (( WITH_DEPLOY )); then
  scripts/deploy.sh pi
else
  echo "  skipped (--no-deploy)"
fi

say "done"
echo "  App:      http://$MASTER_IP:30080"
echo "  kubectl:  export KUBECONFIG=$KUBECONFIG_OUT"
