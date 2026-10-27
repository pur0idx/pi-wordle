# Architecture

This document explains what each service does, why the system is split the way
it is, how it stays stateless, and how it survives losing a Raspberry Pi.

![architecture](architecture.svg)

## 1. Services

| Service | Language | Port | Responsibility | Talks to |
|---|---|---|---|---|
| **frontend** | React (Vite) on nginx | 8080 (NodePort 30080) | Serves the UI. Proxies `/api/*` to the gateway. Stamps responses with its pod and node. | gateway |
| **gateway** | Python, FastAPI + httpx | 8000 | Single API entry point. Validates input, calls backends (in parallel where possible), retries on failure, assembles the trace. Holds no game logic. | word-service, evaluator, hint-engine |
| **word-service** | Go (standard library only) | 8080 | Owns the word lists. Checks whether a word is allowed. Computes the daily answer. **The only service with `DAILY_SECRET`.** | none |
| **evaluator** | Node.js, Express | 8080 | The rules engine: scoring (including duplicate letters), win/loss, max guesses, hard mode, re-scoring the history against the real answer. | none |
| **hint-engine** | Python, NumPy | 8080 | Filters the answers still consistent with the clues so far and ranks the next guess by expected information (entropy). | none |

### Why split it this way

The slides warn against splitting services "just for the sake of this project".
Each boundary has a reason:

- **frontend / gateway.** Static file serving and API logic scale and fail
  differently. The gateway is also the only place that knows the call graph,
  so the backends stay independent of each other.
- **word-service.** It owns the secret. The answer is produced, and the
  secret is held, by one small service. Nothing else can compute tomorrow's
  answer, and rotating the secret touches one Deployment.
- **evaluator.** The game's rules live in one place, separate from the data
  (word-service) and from the client. It recomputes every history row from the
  real answer instead of trusting the browser, so a tampered history can't fake
  a win, skip the six-guess limit, or get around hard mode.
- **hint-engine.** It is CPU-heavy. One hint is a NumPy reduction over an
  873 × 873 pattern matrix, roughly 100× the work of scoring a guess. Running it
  separately means a burst of hints can't slow down `/guess`, and it can be
  scaled on its own (for example with a HorizontalPodAutoscaler on CPU). It
  deliberately never receives the answer. Like a human solver, it works only
  from the guesses and colors, which also means it can't leak the answer.

### Request flows

```
GET /api/today
  browser → frontend(nginx) → gateway → word-service /today

POST /api/guess {puzzle_id, guess, history[], hard_mode}
  browser → frontend → gateway ─┬─ word-service /validate?word=     (in parallel)
                                └─ word-service /answer?puzzle_id=
                                → evaluator /evaluate {guess, answer, history, hard_mode}

POST /api/hint {history[{guess, pattern}], hard_mode}
  browser → frontend → gateway → hint-engine /hint
```

Each service returns a `trace` entry `{service, pod, node}`. The gateway adds
the latency it measured for each call and puts itself first, and the browser
adds the frontend hop from nginx's `X-Served-By-*` headers. The UI's
**Request path** panel and `scripts/demo.sh` display this, which demonstrates
that every request is served by multiple containers on different nodes.

## 2. Statelessness

No service keeps state between requests, and there is no database.

| State | Where it lives |
|---|---|
| Today's answer | Computed on demand: `answers[HMAC-SHA256(DAILY_SECRET, puzzle_id) mod N]` |
| The secret | Kubernetes Secret `kube-guess-secret`, injected only into word-service |
| Word lists, pattern matrix | Baked into the images at build time |
| A player's guesses | The browser's `localStorage`, sent with every request |

Any replica of any service can handle any request, and killing a pod loses
nothing. This is what makes the fault-tolerance demo work.

### Why `puzzle_id` is sent by the client

The obvious approach, where each word-service computes "today" from its own clock,
breaks on Raspberry Pis. They have no real-time clock, and at the demo there may
be no internet for NTP. Two replicas with different clocks would disagree on
the answer partway through a game.

Instead, `/api/today` hands out a `puzzle_id` (for example `2026-11-17`) once.
The browser sends it back with every guess, and word-service derives the answer
from it. Clocks only matter at the start of a game, and every replica agrees on
the answer for a given id. To stop players asking for tomorrow's answer early,
word-service rejects ids more than one day in the future
(`PUZZLE_MAX_FUTURE_DAYS`). The setup scripts also run chrony on the Pis, synced
to the master, because k3s TLS needs sane clocks anyway.

## 3. Fault tolerance

The requirement: pull any single Pi, and the app must work again once Kubernetes
has replaced what was running there. Each layer contributes:

| Layer | Mechanism | Where |
|---|---|---|
| Placement | 2 replicas per Deployment, `topologySpreadConstraints` on `kubernetes.io/hostname` with `DoNotSchedule`. No Pi ever holds both replicas of a service, so one always survives. `nodeTaintsPolicy: Honor` leaves the master and dead nodes out of the spreading calculation. | `k8s/base/*.yaml` |
| Detection | `node-monitor-grace-period=20s` on the controller manager. A silent node is marked NotReady after 20s (default 40–50s). | `cluster/master-install.sh`, `scripts/local-up.sh` |
| Replacement | Pods tolerate `unreachable` / `not-ready` for 15s instead of the default 300s, then get evicted and recreated on healthy Pis. | `k8s/base/*.yaml` |
| Routing | Readiness probes every 3s. When a node goes NotReady its pods are marked not-ready and leave the Service endpoints. | `k8s/base/*.yaml` |
| Retries | Browser: 4s timeout, 1 retry. nginx: 1s connect timeout, retries once on a new connection. Gateway: 1s connect timeout, 3 attempts, no keep-alive, so each attempt is load-balanced again. Retrying is safe because every endpoint is a pure function of its input. | `api.js`, `default.conf.template`, `gateway/app/main.py` |
| DNS | CoreDNS runs 2 replicas pinned to the master, which is never pulled. Otherwise pulling the Pi running k3s's single CoreDNS would break every service name lookup. | `scripts/harden-system.sh` |
| Images | A DaemonSet pre-pulls all five images onto every Pi, so a replacement pod never waits on, or fails at, a download. | `k8s/base/prepull.yaml` |
| Startup | hint-engine's pattern matrix is computed at image build time, so replacements are ready in about a second. | `services/hint-engine/Dockerfile` |

### Timeline when a Pi is pulled (measured locally)

```
t=0s     Pi pulled. Requests routed to its pods time out after 1s; retries go to the other replica.
t≈20s    Node marked NotReady (taint: unreachable). Its pods leave the Service endpoints.
t≈35s    15s toleration expires. Pods evicted; replacements scheduled on other Pis.
t≈40s    Replacements Ready (images already present).
```

In a local test that pulled the node holding frontend, evaluator and
hint-engine replicas while requests were running, 161 of 165 requests
succeeded. The 4 failures were all in the first ~12 seconds, on new connections
from outside the cluster that the NodePort routed to the dead frontend pod.
The browser's retry covers this case for real users.

### Why the master holds no app pods

The master is tainted `NoSchedule`, so all app pods run on the Pis, which is
the point of the project. It still runs the control plane and CoreDNS, and its
NodePort forwards to pods on the Pis, so **clients should use the master's IP**.
Using a Pi's IP would fail whenever that Pi is the one being pulled.

## 4. Algorithms

### Scoring (evaluator, and hint-engine in vectorized form)

Two passes, which is what makes duplicate letters correct:

1. Mark exact matches green, and count the answer's remaining (non-green) letters.
2. Left to right, mark each non-green guess letter yellow if any copies of that
   letter remain, using one up. Otherwise mark it gray.

So `speed` against `abide` scores `BBYBY`: only one `E` is yellow, because the
answer has only one. Both implementations are tested against the same cases in
`data/test-vectors.json`.

### Hints (hint-engine)

- At build time, compute `M[g][a]`: the pattern code (0–242, base 3) of guess
  `g` against answer `a`, for all 873 × 873 pairs (0.76 MB).
- **Filter:** an answer stays possible if, for every past guess,
  `M[guess][answer]` equals the observed pattern. Guesses outside the answer list
  are scored live against all answers.
- **Rank:** for each candidate guess, count how the remaining answers spread
  across the 243 patterns (one `bincount` for all guesses at once), and compute
  the entropy `−Σ p·log₂p`. The highest-entropy guess splits the remaining
  answers most evenly. Ties go to a word that could itself be the answer.
- In hard mode, only words that are still possible answers are suggested.
- With 12 or fewer answers left, they are listed. With 2 or fewer, it suggests
  guessing them directly.

## 5. Known limitations

- The browser is trusted with `history` for the guess limit. A player who
  edits localStorage can start over, and the answer is revealed on the 6th miss.
  This is acceptable for a casual daily game and is the price of having no
  server-side state.
- The pattern matrix covers answer-list guesses only. Hint suggestions come
  from the 873 answers, not all 12,602 allowed words, to keep memory and CPU
  reasonable on a Pi 3B+ with 1 GB RAM.
- One master means the control plane isn't highly available. The assignment
  only pulls workers. Adding two more k3s servers with embedded etcd would fix
  this.
