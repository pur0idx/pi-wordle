#!/usr/bin/env bash
# Run on the master VM: installs a GitHub Actions self-hosted runner as a
# service, labelled `kube-guess`. The `deploy` job in
# .github/workflows/build.yml runs on it, so a push to main redeploys the Pis.
#
#   ./install-runner.sh <repo-url> <registration-token>
#
# scripts/cluster-up.sh calls this for you (it gets the token with `gh`).
# GitHub's hosted runners cannot reach the Pi LAN; this runner sits inside it
# and only makes outbound connections to GitHub.
set -euo pipefail
REPO_URL="${1:?usage: install-runner.sh <repo-url> <registration-token>}"
TOKEN="${2:?missing registration token}"
DIR="$HOME/actions-runner"

if [[ -f "$DIR/.runner" ]]; then
  echo "runner already configured in $DIR"
  sudo "$DIR/svc.sh" start >/dev/null 2>&1 || true
  exit 0
fi

case "$(uname -m)" in
  aarch64|arm64) ARCH=arm64 ;;
  x86_64) ARCH=x64 ;;
  *) echo "unsupported architecture $(uname -m)"; exit 1 ;;
esac
VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
  | sed -nE 's/.*"tag_name": *"v([^"]+)".*/\1/p' | head -1)
[[ -n "$VERSION" ]] || { echo "could not look up the runner version"; exit 1; }

echo "==> GitHub Actions runner $VERSION ($ARCH)"
mkdir -p "$DIR" && cd "$DIR"
curl -fsSL -o runner.tgz \
  "https://github.com/actions/runner/releases/download/v$VERSION/actions-runner-linux-$ARCH-$VERSION.tar.gz"
tar xzf runner.tgz && rm runner.tgz
sudo ./bin/installdependencies.sh >/dev/null

./config.sh --unattended --replace \
  --url "$REPO_URL" --token "$TOKEN" \
  --name "$(hostname)" --labels kube-guess

sudo ./svc.sh install "$(id -un)"
sudo ./svc.sh start
echo "runner installed and running as a service"
