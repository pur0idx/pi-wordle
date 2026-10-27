# Building the Raspberry Pi cluster

Following these steps, anyone with the course kit can build the cluster from
scratch and deploy Kube Guess on it.

## Hardware (per group)

- 1 × TP-Link TL-WR841N router
- 5 × Raspberry Pi 3 B+ with power adapter, microSD card and Ethernet cable
- 1 notebook (or more) running the master as an Ubuntu VM
- Ethernet adapters for the notebook if needed (wired is strongly preferred for the demo)

## Overview

```
                    TP-Link router (192.168.0.1, DHCP)
     ┌───────────┬───────────┼───────────┬───────────┬──────────────┐
   pi-1        pi-2        pi-3        pi-4        pi-5     notebook ── Ubuntu VM (bridged)
 k3s agent   k3s agent   k3s agent   k3s agent   k3s agent        k3s server + chrony
```

The addresses below assume the router's default `192.168.0.0/24`. Adjust if yours differs.

## Step 1. Router

1. Factory-reset the router (hold reset ~10s) and connect a notebook to a LAN port.
2. Open http://192.168.0.1 (default login is on the label).
3. **DHCP → Address Reservation**: once each device has connected once, reserve a
   fixed IP for each Pi and the master VM, so the IPs survive reboots during the demo.

   | Host | IP (example) |
   |---|---|
   | master VM | 192.168.0.100 |
   | pi-1 … pi-5 | 192.168.0.101 … 105 |

4. Optional: plug the WAN port into a network with internet. It's needed during
   setup (installing packages and k3s, pulling images) but **not** during the demo.

## Step 2. Master VM (on a notebook)

1. Create an **Ubuntu Server 24.04** VM with **≥ 2 vCPU, ≥ 2 GB RAM, 20 GB disk**.
   - Apple Silicon Mac: UTM with the ARM64 ISO. Intel / Windows: VirtualBox or VMware with the amd64 ISO.
   - **Network: bridged** to the interface plugged into the router. With NAT, the
     Pis can't reach the VM.
2. In the VM, check that you have a `192.168.0.x` address: `hostname -I`.
3. Clone this repo into the VM and install the master:

   ```bash
   git clone <this repo> kube-guess && cd kube-guess
   MASTER_IP=192.168.0.100 cluster/master-install.sh
   ```

   This installs chrony (an NTP server for the Pis) and the k3s server with:

   | Flag | Why |
   |---|---|
   | `--disable traefik` | The app is exposed with a NodePort; no ingress controller needed |
   | `--node-taint node-role.kubernetes.io/control-plane=true:NoSchedule` | App pods run only on the Pis |
   | `--kube-controller-manager-arg node-monitor-grace-period=20s` | A pulled Pi is declared dead after 20s |
   | `--node-ip / --advertise-address / --tls-san` | Pin the API server to the LAN address |

   At the end it prints the `join-worker.sh` command, including the join token. Copy it.

4. `kubectl get nodes` should show the master as `Ready`.

## Step 3. Each Raspberry Pi

1. Flash **Raspberry Pi OS Lite (64-bit)** with Raspberry Pi Imager. In the
   Imager's settings, enable SSH and set a username and password. Set the hostname
   to `pi-1` … `pi-5`. The node names in Kubernetes and in the UI's trace come
   from these hostnames.
2. Boot it on the router's LAN and SSH in: `ssh <user>@pi-1.local`, or use the IP from the router's DHCP list.
3. Copy the repo's `cluster/` folder over (`scp -r cluster <user>@pi-1.local:`) and run:

   ```bash
   sudo MASTER_IP=192.168.0.100 ./cluster/pi-prep.sh pi-1
   sudo reboot
   ```

   `pi-prep.sh` sets the hostname, enables the memory cgroup (k3s won't start
   without it), disables swap, and syncs the clock from the master.

4. After the reboot, join the cluster with the command printed in step 2:

   ```bash
   MASTER_IP=192.168.0.100 K3S_TOKEN=K10…::server:… ./cluster/join-worker.sh
   ```

Repeat for all five Pis. On the master:

```bash
kubectl get nodes -o wide
```

```
NAME     STATUS   ROLES                  VERSION        INTERNAL-IP
master   Ready    control-plane,master   v1.35.5+k3s1   192.168.0.100
pi-1     Ready    <none>                 v1.35.5+k3s1   192.168.0.101
...
pi-5     Ready    <none>                 v1.35.5+k3s1   192.168.0.105
```

## Step 4. Container images

The Pis are `arm64` and the master may be `amd64`. GitHub Actions
(`.github/workflows/build.yml`) builds every image for both on each push to
`main`, and pushes them to GHCR as `ghcr.io/<owner>/kube-guess-<service>:latest`
and `:<git-sha>`.

1. Push the repo to GitHub and wait for the **build** workflow to go green.
2. Make the images pullable, choosing one option:
   - **Public packages** (simplest): GitHub → your profile → Packages → each
     `kube-guess-*` package → Package settings → Change visibility → Public.
     The repository itself stays private.
   - **Pull secret**: create a classic personal access token with `read:packages`, then
     `export GHCR_USER=<github-user> GHCR_TOKEN=<token>` before running `deploy.sh`.
3. Point the Pi overlay at your registry (once, then commit):

   ```bash
   scripts/set-registry.sh <github-owner>            # or: <owner> <git-sha> to pin a build
   ```

Without GitHub Actions, you can build and push from any machine with Docker buildx:

```bash
docker buildx create --use
for s in frontend gateway word-service evaluator hint-engine; do
  t=""; [[ $s == gateway || $s == hint-engine ]] && t="--target runtime"
  docker buildx build $t --platform linux/arm64,linux/amd64 \
    -f services/$s/Dockerfile -t ghcr.io/<owner>/kube-guess-$s:latest --push .
done
```

## Step 5. Deploy

On the master:

```bash
scripts/deploy.sh pi
```

This one command:

1. creates namespace `kube-guess` and Secret `kube-guess-secret` with a random
   `DAILY_SECRET` (set `DAILY_SECRET=...` first to choose it),
2. creates the GHCR pull secret if `GHCR_TOKEN` is set,
3. pins CoreDNS to the master (`scripts/harden-system.sh`),
4. runs `kubectl apply -k k8s/overlays/pi`: 5 Deployments × 2 replicas, 5 Services,
   and the image pre-pull DaemonSet,
5. waits for every rollout and prints `scripts/where.sh`.

Open **http://192.168.0.100:30080** (the master's IP) from any device on the
router's network.

## Step 6. Get ready for an offline demo

The demo room may have no internet. Before you go:

- [ ] `kubectl -n kube-guess get ds image-prepull` shows `5/5` ready, so every Pi has every image.
- [ ] `chronyc sources` on a Pi shows the master as the time source.
- [ ] Unplug the router's WAN cable, reboot everything, and confirm the app still
      comes up and survives `scripts/demo.sh` + pulling a Pi.
- [ ] Re-run `scripts/harden-system.sh` after any master reboot (k3s restores its
      default CoreDNS manifest on restart). `deploy.sh` does this too.

## Updating the app

```bash
git push                                   # CI builds new images
scripts/set-registry.sh <owner> <git-sha>  # pin the new build
scripts/deploy.sh pi                       # rolling update, zero downtime (maxUnavailable: 0)
```

## Troubleshooting

| Symptom | Check |
|---|---|
| Pi never joins | `sudo journalctl -u k3s-agent -f` on the Pi. Common causes: memory cgroup off (`grep cgroup_memory /proc/cmdline`), wrong token, VM not bridged (`ping 192.168.0.100` from the Pi), clock far off (`timedatectl`). |
| `x509: certificate has expired or is not yet valid` | The Pi clock is wrong. `sudo systemctl restart chrony; chronyc makestep` |
| Pods `ImagePullBackOff` | Images private (step 4.2) or the overlay still says `CHANGE_ME` (step 4.3) |
| Pods `Pending` | `kubectl describe pod`. Fewer than 2 Ready Pis can't satisfy the spread constraint, and a Pi out of memory shows `Insufficient memory`. |
| App unreachable but pods Running | Use the master's IP and port 30080; `kubectl -n kube-guess get svc frontend` |
| Everything breaks after pulling one specific Pi | CoreDNS was on it: `kubectl -n kube-system get pods -o wide -l k8s-app=kube-dns`, then re-run `scripts/harden-system.sh` |

## Tearing down (after the demo)

```bash
cluster/uninstall.sh      # on every machine
```

Then reflash every Pi with stock Raspberry Pi OS and factory-reset the router
before returning the kit (both are on the rubric).
