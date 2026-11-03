# Automated cluster build and deployment

Two levels of automation:

1. **`scripts/cluster-up.sh`**: one command on your Mac turns a powered-on
   master VM and five freshly flashed Pis into a running cluster with the app
   deployed.
2. **Push to deploy**: after that, every push to `main` is tested, built for
   arm64 + amd64, and rolled out to the Pis by GitHub Actions, with no command
   on your side.

```
 git push ──► GitHub Actions: test ──► build images (ghcr.io/<owner>/kube-guess-*:<sha>)
                                                   │
                                                   ▼
                           deploy job on the self-hosted runner (master VM, inside the Pi LAN)
                                                   │  scripts/deploy.sh pi  (IMAGE_TAG=<sha>)
                                                   ▼
                                    k3s cluster: rolling update, zero downtime
```

## What still needs hands (about 1 hour, once)

Scripts can't press buttons or move SD cards. Do these, then run one command.

| # | Task | Details |
|---|---|---|
| 1 | **Router** | Factory reset. WAN port to internet. Set your Wi-Fi name and password at http://192.168.0.1. |
| 2 | **Master VM** | UTM → Ubuntu Server 24.04 ARM64, 2 CPU, 2 GB RAM, 20 GB, **network Bridged** to the interface on the router. Install with **OpenSSH server** enabled. See [cluster-setup.md, step 2](cluster-setup.md#step-2-master-vm-on-a-notebook). |
| 3 | **Flash 5 SD cards** | Raspberry Pi Imager → Raspberry Pi OS Lite (64-bit). Settings: hostname `pi-1`…`pi-5`, user `pi`, **Services → Enable SSH → Allow public-key authentication only**, pasting `~/.ssh/id_ed25519.pub` from your Mac. Wi-Fi only on the Pis without a cable. |
| 4 | **Power on and plug in** | The router has 4 LAN ports: 4 Pis by cable, the 5th Pi and the Mac on Wi-Fi (or the Mac by USB-Ethernet adapter and 2 Pis on Wi-Fi). |
| 5 | **Fix the IPs** | Router → DHCP → Address Reservation: the master VM and each Pi. **The master IP must never change.** |
| 6 | **GitHub** | Repo **private** (required by the course, and required here before a self-hosted runner is installed). `gh auth login` on the Mac. |

If you don't have an SSH key yet, run `ssh-keygen -t ed25519` before flashing.
If a machine doesn't accept the key, `cluster-up.sh` asks for its password once
and installs the key itself.

## The one command

```bash
cp cluster/hosts.example.env cluster/hosts.env   # once: edit MASTER_IP etc.
scripts/cluster-up.sh
```

`cluster/hosts.env`:

```bash
MASTER_IP=192.168.0.100
MASTER_USER=kube                 # the user you created in the Ubuntu installer
PIS="pi-1 pi-2 pi-3 pi-4 pi-5"   # or "pi-1=192.168.0.101 ..." if .local names don't resolve
PI_USER=pi
```

What it does:

| Step | Action | Notes |
|---|---|---|
| 1 | Checks tools, SSH to every machine, `gh` login | Stops before changing anything if a machine is unreachable |
| 2 | Master: `cluster/master-install.sh` | k3s server, chrony, passwordless sudo for that user (asks for the sudo password once, the first time) |
| 3 | All Pis **in parallel**: `pi-prep.sh`, reboot if the memory cgroup was off, `join-worker.sh` | Per-Pi logs in `.deploy/logs/pi-N.log` |
| 4 | Waits for all 6 nodes to be `Ready` | Copies the kubeconfig to `~/.kube/pi-cluster` |
| 5 | Installs the GitHub Actions runner on the master and sets repo variable `DEPLOY_TO_PI=true` | Skipped with `--no-runner`, or if the repo is public |
| 6 | `scripts/deploy.sh pi` | Same as the manual deploy |

Expect about 15–25 minutes on a first run, most of it Pis installing packages
and k3s. **It is safe to re-run.** Joined Pis and an installed master are
skipped, so after fixing a failed Pi, just run it again.

Afterwards, from any Mac terminal:

```bash
export KUBECONFIG=~/.kube/pi-cluster
kubectl get nodes
scripts/where.sh
open http://192.168.0.100:30080
```

## Push to deploy

Once step 5 has run:

```bash
git commit -am "change something" && git push
```

GitHub → **Actions** shows `test` → `images` (×5) → `deploy`. The deploy job
runs on the master VM (`runs-on: [self-hosted, kube-guess]`) and calls
`scripts/deploy.sh pi` with `IMAGE_TAG=<that commit>`. Kubernetes then does a
rolling update with `maxUnavailable: 0`, so the game stays up during the
update. The pre-pull DaemonSet updates too, so every Pi caches the new images.

- **Turn it off:** `gh variable set DEPLOY_TO_PI --body false` (builds still run, deploys are skipped).
- **Turn it on:** `gh variable set DEPLOY_TO_PI --body true`.
- **Runner status:** GitHub → Settings → Actions → Runners (it should say *Idle*).

The runner only makes outbound connections to GitHub. Nothing on your LAN is
exposed to the internet.

## How `deploy.sh pi` picks images

Pods use `imagePullPolicy: IfNotPresent`, so they can start offline from
cached images. The flip side is that a moving tag like `latest` would never be
re-pulled. So every deploy pins an exact commit:

| Source, in order | When |
|---|---|
| `IMAGE_TAG` | Set by the GitHub deploy job (the commit just built) |
| Newest successful `build` run on `main` (via `gh`) | Running from your Mac with internet |
| `.deploy/last-tag` | No internet (demo room): reuses what the Pis already have |
| `latest` | Nothing else available (prints a warning) |

The image owner comes from `IMAGE_OWNER`, or from `git remote origin`, so
`scripts/set-registry.sh` is no longer needed. It still works if you want to
pin a tag in git by hand.

The first lines of every deploy show which cluster and which images it's using:

```
==> cluster: default  (KUBECONFIG=/Users/you/.kube/pi-cluster)
==> images: ghcr.io/<owner>/kube-guess-*:25d74477b90f9bfe1233cfca76a065aa7f9e1f54
```

`deploy.sh local` refuses to run against anything that isn't a k3d cluster, so a
wrong current context can't receive the local overlay.

## Demo day

Nothing new to learn: the rubric's "automated deployment" is still

```bash
export KUBECONFIG=~/.kube/pi-cluster
kubectl delete namespace kube-guess --wait   # before the slot
scripts/deploy.sh pi                          # during the demo
```

If the room has internet, you can also show push-to-deploy: make a visible
one-line change, `git push`, and watch Actions plus `scripts/where.sh` roll the
pods. Without internet the runner can't reach GitHub, but the command above
still works because it uses the last deployed tag and the images cached on
every Pi.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Step 1: `unreachable` | Machine off, not on the router, or wrong address. Try `ping pi-1.local`, or put `pi-1=<ip>` in `hosts.env` |
| Step 3: `sudo needs a password` | That Pi's user isn't the one created by Raspberry Pi Imager (which has passwordless sudo). Reflash with Imager settings |
| Step 3: one Pi `✗` | Read `.deploy/logs/pi-N.log`, fix it, and rerun `scripts/cluster-up.sh` |
| Step 4 times out | `kubectl get nodes`. On the stuck Pi: `sudo journalctl -u k3s-agent -n 50` |
| Step 5: "repo is public" | Make it private, rerun (the rest is skipped quickly) |
| Deploy job stays *Queued* | Runner offline: VM off, or `sudo ~/actions-runner/svc.sh status` on the VM |
| Deploy job: `cannot reach cluster` | The runner user's `~/.kube/config` is missing: rerun `scripts/cluster-up.sh` |
