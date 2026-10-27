# Demo runbook: November 17, 2026, 13:00–16:00

The rubric counts for 100% of the demo grade. This page walks through it in
order, with the exact command and what to say for each line.

## Before the time slot

- [ ] All five members present.
- [ ] Router, 5 Pis and the master notebook powered and wired. VM running.
- [ ] `kubectl get nodes`: 1 master + 5 Pis, all `Ready`.
- [ ] Namespace removed so the deployment can be shown from scratch:
      `kubectl delete namespace kube-guess --wait` (images stay cached on the Pis).
- [ ] Browser tab on `http://<master-ip>:30080` (it will error until deployed).
- [ ] Three terminals open on the master, font large enough to read:
  - **T1** for commands
  - **T2** `watch -n1 scripts/where.sh`
  - **T3** ready to run `scripts/demo.sh http://<master-ip>:30080`

## The rubric, step by step

| # | Rubric line | Do | Say / show |
|---|---|---|---|
| 1 | Group members all present | | |
| 2 | Master nodes on notebooks, kube cluster up | T1: `kubectl get nodes -o wide` | Master is the Ubuntu VM on this notebook; the 5 workers are the Pis. The master is tainted, so all app pods run on Pis. |
| 3 | Demo automated deployment | T1: `scripts/deploy.sh pi` | One command: Secret, CoreDNS pinning, kustomize apply, wait for rollouts. Every manifest and image is in the GitHub repo; CI builds the arm64 images. |
| 4 | Introduce application | Browser: play a word, press Hint | Daily 5-letter word game. Explain the colors, the hint engine (remaining answers, entropy), hard mode. |
| 5 | Application consists of 4-5 different containers | `kubectl -n kube-guess get deploy` | frontend (nginx/React), gateway (FastAPI), word-service (Go), evaluator (Node), hint-engine (NumPy): five images, four languages. |
| 6 | Logical design of services | Show `docs/architecture.svg` | Each split has a reason: the secret lives only in word-service; the rules engine is separate from the data and re-checks the client's history; the CPU-heavy hint engine is isolated and scales on its own; the gateway is the only one that knows the call graph. Stateless: answer = HMAC(secret, puzzle_id), progress in the browser. |
| 7 | Each client request touches at least 2 containers | Browser: **Request path** panel | A guess goes frontend → gateway → word-service ×2 → evaluator: 4 services, usually on 3–4 different Pis. |
| 8 | All 4-5 containers are used across all services | Same panel after a guess + a hint | today: word-service; guess: word-service + evaluator; hint: hint-engine; all go through frontend + gateway. |
| 9 | Show current deployment of containers on nodes | T2 (`where.sh`) | 2 replicas per service, never both on the same Pi, nothing on the master. |
| 10 | Demo all client requests successfully | T3: `scripts/demo.sh http://<master-ip>:30080` | Every line OK, with the path through the cluster. |
| 11 | Randomly pick a Pi and note its services | Instructor picks, e.g. `pi-3`. T1: `kubectl -n kube-guess get pods -o wide --field-selector spec.nodeName=pi-3` | Read out the services on it. |
| 12 | Take Pi offline | Pull its power or Ethernet | Keep T3 visible: a few ERR lines appear while Kubernetes notices, then OKs resume. |
| 13 | Check that replacements were created | T2, ~30–40s after the pull | The Pi goes `NotReady`, its pods show `LOST(node-down)`, and new pods for those services appear on the other Pis. Grace period 20s + toleration 15s. |
| 14 | Demo all client requests successfully again | T3 + browser: make a guess, press Hint | All OK. The traces no longer mention the pulled Pi. |
| 15+ | Reset router, reflash Pis, return kit | see below | |

If time allows, repeat steps 11–14 with a second Pi. Plug the first one back in
first. It rejoins on its own, and its old pods are cleaned up.

## If something goes wrong

| Problem | Fix |
|---|---|
| A Pi shows `NotReady` before the demo | Reseat its power/Ethernet; `ssh` in, `sudo systemctl restart k3s-agent` |
| `deploy.sh` waits forever on one deployment | `kubectl -n kube-guess describe pod <pending pod>`. Usually a NotReady Pi (spread constraint) or a missing image (check the pre-pull DaemonSet) |
| After the pull, every request fails, even after 60s | CoreDNS was on that Pi: `scripts/harden-system.sh` (it should already be pinned to the master) |
| Replacements stuck in `ContainerCreating` | `kubectl describe pod`. The image is missing on that Pi: confirm `kubectl -n kube-guess get ds image-prepull` is 5/5 before the demo |
| Browser shows an error page | Use the master IP (not a Pi IP) with port 30080 |
| Page loads but says the cluster is recovering | Expected during the ~20s detection window; press Retry |

## After the demo (rubric)

```bash
kubectl delete namespace kube-guess
cluster/uninstall.sh            # on the master and every Pi
```

1. Factory-reset the wireless router (hold reset ~10s).
2. Reflash every Pi's SD card with the default Raspberry Pi OS image.
3. Sign in and return: router, Pis, power adapters, Ethernet adapters.
