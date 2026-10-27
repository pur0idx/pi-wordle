# Local testing on a Mac (or any Docker machine)

Before touching the Pis, run the full system on a laptop. **k3d** runs k3s (the
same Kubernetes distribution used on the Pis) with each node as a Docker
container, so you get a real multi-node cluster:

| k3d node | Stands in for |
|---|---|
| `k3d-kube-guess-server-0` | the notebook master (tainted, no app pods) |
| `k3d-kube-guess-agent-0` … `agent-4` | the five Raspberry Pis |

Stopping an agent container behaves like pulling a Pi's power cable: the
kubelet goes silent, and Kubernetes has to notice and reschedule.

## 1. Prerequisites

```bash
brew install k3d kubectl          # kubectl may already be installed
open -a Docker                    # Docker Desktop must be running
```

Give Docker Desktop at least 4 CPUs and 6 GB of memory (Settings → Resources).
Tested with Docker 29, k3d 5.9 (k3s v1.35), kubectl 1.36 on an Apple Silicon Mac.

## 2. Bring it up

```bash
scripts/local-up.sh
```

This script:

1. creates the cluster (1 server + 5 agents) with the same k3s flags as the real
   master: Traefik disabled, master tainted, node grace period 20s,
2. builds the five images (`scripts/build.sh`),
3. imports them into every node (`k3d image import`), so no registry is needed,
4. deploys with `scripts/deploy.sh local`: creates the Secret, pins CoreDNS,
   runs `kubectl apply -k k8s/overlays/local`, and waits for rollouts.

The first run takes about 3–4 minutes (it pulls the k3s image). After that it
finishes in under a minute. Re-run it after code changes: it rebuilds,
re-imports and restarts the Deployments.

Open **http://localhost:8080** (set `HOST_PORT=9090` to use another port).

```bash
kubectl config current-context   # k3d-kube-guess
scripts/where.sh                 # pods per node
```

Expected: every service has 2 pods, on 2 different `agent-*` nodes, and nothing on `server-0`.

## 3. Play and inspect

- Make a guess. The **Request path** panel shows frontend → gateway →
  word-service (×2) → evaluator, each with its node and pod suffix.
- Press **Hint** to see the remaining answer count and suggestions.
- Reload the page: your game is restored from `localStorage`.
- Press Enter on a word that isn't real: you get "not in word list" (422).

From the terminal:

```bash
curl -s localhost:8080/api/today | python3 -m json.tool
kubectl -n kube-guess logs -l app.kubernetes.io/name=gateway --tail=20 --prefix
```

## 4. Simulate pulling a Pi

Use two terminals.

**Terminal 1**, continuous client traffic:

```bash
scripts/demo.sh
```

Each line is one request: status, result and the path it took, for example

```
22:21:02 OK  200 guess house    BBBBB   gateway@agent-4 -> word-service@agent-3 -> word-service@agent-2 -> evaluator@agent-2
```

**Terminal 2**, kill a node and watch:

```bash
scripts/node.sh kill random     # or: scripts/node.sh kill agent-3
watch -n1 scripts/where.sh      # brew install watch, or just re-run it
```

What you should see:

| Time | `where.sh` | `demo.sh` |
|---|---|---|
| 0–20s | node still `Ready`, then `NotReady`; its pods show `LOST(node-down)` | a few `ERR` lines (timeouts on the dead pods) mixed with OKs |
| ~35s | new pods for the lost services appear on other agents, `Starting` → `Running` | all OK |
| after | lost pods stay listed until the node returns, as Kubernetes can't confirm they stopped | all OK, traces never mention the dead node |

Bring the node back and the old pods are cleaned up:

```bash
scripts/node.sh restore all
```

Pulling two nodes at once also works as long as no service loses both
replicas, but the assignment only requires one at a time.

## 5. Run without Kubernetes

For quick UI or API work:

```bash
docker compose up --build        # http://localhost:8080, gateway also on :8000
```

Hot-reload the UI against the compose backend:

```bash
cd services/frontend && npm install && npm run dev   # http://localhost:5173
```

## 6. Unit tests

```bash
scripts/test.sh
```

| Service | Tests |
|---|---|
| word-service | deterministic answers across replicas, secret dependence, validation, future-id rejection |
| evaluator | shared scoring vectors, win/loss, history re-scoring, game-over, hard mode, input validation |
| hint-engine | shared scoring vectors, filtering, non-answer guesses, entropy ordering, hard mode, endgame, precomputed matrix = live scoring |
| gateway | 2+ containers per request, word rejection, input validation, retry on a dead replica, 503 when a backend stays down |

## 7. Clean up

```bash
scripts/local-down.sh
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Docker is not running` | `open -a Docker`, wait for the whale icon to settle |
| `localhost:8080` hangs | Is something else on 8080? `lsof -iTCP:8080 -sTCP:LISTEN`. Use `HOST_PORT=9090 scripts/local-up.sh` after `scripts/local-down.sh`. (k3d's `:direct` port mode hangs on Docker Desktop, so the script routes through k3d's load balancer.) |
| Pods `ErrImageNeverPull` / `ImagePullBackOff` | Images weren't imported: re-run `scripts/local-up.sh` |
| Pods `Pending` with `didn't match pod topology spread constraints` | Fewer than 2 healthy agents. `scripts/node.sh restore all` |
| A code change doesn't show up | `scripts/local-up.sh` (rebuild + import + restart); hard-refresh the browser |
| `where.sh`: `column: command not found` (Linux) | `sudo apt install bsdextrautils` |
