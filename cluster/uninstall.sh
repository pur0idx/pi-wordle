#!/usr/bin/env bash
# Remove k3s from this machine (before returning the Pis, or to start over).
set -euo pipefail
if [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then sudo /usr/local/bin/k3s-agent-uninstall.sh; fi
if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then sudo /usr/local/bin/k3s-uninstall.sh; fi
echo "k3s removed"
