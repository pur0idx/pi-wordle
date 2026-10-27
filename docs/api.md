# API reference

Patterns are 5-character strings: `G` = right letter, right spot; `Y` = in the
word, wrong spot; `B` = not in the word. Every response (including errors)
carries a `trace` list of `{service, pod, node, ms?}` entries.

## Public API (through the frontend at `/api`)

### `GET /api/today`

```json
{
  "puzzle_id": "2026-11-17",
  "length": 5,
  "max_guesses": 6,
  "trace": [
    {"service": "gateway", "pod": "gateway-8b6565b7-m6cv7", "node": "pi-2", "ms": 6.3},
    {"service": "word-service", "pod": "word-service-557d6f4786-l8s9v", "node": "pi-4", "ms": 5.9}
  ]
}
```

### `POST /api/guess`

Request:

```json
{"puzzle_id": "2026-11-17", "guess": "crane", "history": ["slate"], "hard_mode": false}
```

`history` is the list of earlier guesses, oldest first. The server re-scores it
from the real answer, so the client never needs to send patterns.

Response `200`:

```json
{
  "guess": "crane",
  "pattern": "BGGBG",
  "attempt": 2,
  "status": "playing",
  "history": [
    {"guess": "slate", "pattern": "BBGYB"},
    {"guess": "crane", "pattern": "BGGBG"}
  ],
  "trace": [ ... gateway, word-service, word-service, evaluator ... ]
}
```

`status` is `playing`, `won` or `lost`. `answer` is included only when `status` is `lost`.

Errors:

| Status | `error` | Cause |
|---|---|---|
| 400 | `guess must be 5 letters` | Malformed guess (checked by the gateway; no backend called) |
| 400 | `puzzle_id must be YYYY-MM-DD` | Malformed puzzle id |
| 403 | `puzzle_id is in the future` | More than `PUZZLE_MAX_FUTURE_DAYS` (default 1) ahead |
| 409 | `this game is already over` | History already contains the answer or has 6 guesses |
| 422 | `not in word list` | Word isn't in `allowed.txt` |
| 422 | `hard mode: letter 3 must be A` | Hard mode broken (green moved / yellow dropped) |
| 503 | `<service> unavailable (...)` | All gateway attempts to a backend failed |

### `POST /api/hint`

Request:

```json
{"history": [{"guess": "slate", "pattern": "BBGYB"}], "hard_mode": false}
```

Response `200`:

```json
{
  "remaining": 12,
  "suggestions": [
    {"word": "drift", "bits": 3.42, "possible": false},
    {"word": "craft", "bits": 3.25, "possible": true}
  ],
  "candidates": ["adapt", "apart", "chant", "chart", "craft", "..."],
  "trace": [ ... gateway, hint-engine ... ]
}
```

`bits` is the expected information from that guess. `possible` means the word
could itself be the answer. `candidates` is filled in only when 12 or fewer
answers remain.

## Internal APIs (cluster-only, via Service DNS)

The browser can't reach these. Only the gateway calls them.

### word-service — `http://word-service:8080`

| Method | Path | Response |
|---|---|---|
| GET | `/today` | `{puzzle_id, length, max_guesses}` (date in `PUZZLE_TZ`, default Asia/Bangkok) |
| GET | `/validate?word=crane` | `{word, valid}` |
| GET | `/answer?puzzle_id=2026-11-17` | `{puzzle_id, answer}`; 400/403 as above |

### evaluator — `http://evaluator:8080`

`POST /evaluate`

```json
{"guess": "crane", "answer": "track", "history": ["slate"], "max_guesses": 6, "hard_mode": false}
```

returns `{pattern, attempt, solved, game_over, history: [{guess, pattern}]}`,
or `{error}` with 400 / 409 / 422.

### hint-engine — `http://hint-engine:8080`

`POST /hint`: same body and response as the public `/api/hint` (without the gateway's trace entry).

### Health

Every service serves `GET /healthz` (liveness) and `GET /readyz` (readiness).
hint-engine's `/readyz` returns 503 until its pattern matrix is loaded.

## Configuration

| Service | Variable | Default | Purpose |
|---|---|---|---|
| all | `POD_NAME`, `NODE_NAME` | hostname / `local` | Set from the downward API; used in `trace` |
| frontend | `GATEWAY_HOST`, `GATEWAY_PORT` | `gateway`, `8000` | Upstream for `/api` |
| gateway | `WORD_SERVICE_URL` | `http://word-service:8080` | |
| gateway | `EVALUATOR_URL` | `http://evaluator:8080` | |
| gateway | `HINT_ENGINE_URL` | `http://hint-engine:8080` | |
| gateway | `UPSTREAM_ATTEMPTS` | `3` | Tries per backend call |
| gateway | `UPSTREAM_CONNECT_TIMEOUT`, `UPSTREAM_TIMEOUT` | `1`, `4` (seconds) | |
| word-service | `DAILY_SECRET` | none (required) | From Secret `kube-guess-secret` |
| word-service | `PUZZLE_TZ` | `Asia/Bangkok` | When "today" changes |
| word-service | `PUZZLE_MAX_FUTURE_DAYS` | `1` | Clock-skew slack |
| word-service, hint-engine | `WORDS_DIR` | `/app/words` | |
| hint-engine | `MATRIX_PATH` | `/app/patterns.npz` | Precomputed matrix; rebuilt at startup if missing or stale |
