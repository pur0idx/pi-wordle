"""gateway: the single entry point for the API.

Owns no game logic. It validates input, fans out to the backend services over
Kubernetes Service DNS, and stitches their answers (and their `trace`
entries) into one response. Every /api call touches at least two containers.

    /api/today  -> word-service
    /api/guess  -> word-service (validate + answer, in parallel) -> evaluator
    /api/hint   -> hint-engine
"""

import asyncio
import logging
import os
import re
import socket
import time
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse
from pydantic import BaseModel, Field

log = logging.getLogger("gateway")
logging.basicConfig(level=logging.INFO, format="%(message)s")

WORD_SERVICE = os.environ.get("WORD_SERVICE_URL", "http://word-service:8080")
EVALUATOR = os.environ.get("EVALUATOR_URL", "http://evaluator:8080")
HINT_ENGINE = os.environ.get("HINT_ENGINE_URL", "http://hint-engine:8080")
MAX_GUESSES = 6
# Each attempt is a new connection, so kube-proxy picks a replica at random.
# With one of two replicas on a dead node, 3 attempts all failing is 1 in 8.
ATTEMPTS = int(os.environ.get("UPSTREAM_ATTEMPTS", "3"))

SELF = {
    "service": "gateway",
    "pod": os.environ.get("POD_NAME", socket.gethostname()),
    "node": os.environ.get("NODE_NAME", "local"),
}
WORD_RE = re.compile(r"^[a-z]{5}$")

http: httpx.AsyncClient


@asynccontextmanager
async def lifespan(app: FastAPI):
    global http
    # No keep-alive: each call opens a fresh connection, so kube-proxy picks a
    # replica per request. That spreads load, shows different pods in the
    # trace, and means we never stay pinned to a pod on a node that just died.
    # Short connect timeout + retries let a request hop to the surviving
    # replica while Kubernetes is still noticing the node is gone.
    http = httpx.AsyncClient(
        timeout=httpx.Timeout(float(os.environ.get("UPSTREAM_TIMEOUT", "4")),
                              connect=float(os.environ.get("UPSTREAM_CONNECT_TIMEOUT", "1"))),
        limits=httpx.Limits(max_keepalive_connections=0),
    )
    log.info("gateway ready pod=%s node=%s", SELF["pod"], SELF["node"])
    yield
    await http.aclose()


app = FastAPI(title="gateway", lifespan=lifespan)


class UpstreamError(Exception):
    def __init__(self, status: int, message: str, trace: list):
        self.status, self.message, self.trace = status, message, trace


async def call(service: str, method: str, url: str, trace: list, **kwargs) -> dict:
    """Call a backend, retrying on connection failure or 5xx.

    Appends the backend's own trace entries (with measured latency) to
    `trace`. Raises UpstreamError for anything that is not a 2xx.
    """
    last_error = "no attempt"
    for attempt in range(1, ATTEMPTS + 1):
        start = time.perf_counter()
        try:
            resp = await http.request(method, url, **kwargs)
        except httpx.TransportError as e:
            last_error = f"{type(e).__name__}"
            log.warning("%s attempt %d failed: %s", service, attempt, last_error)
            continue
        if resp.status_code >= 500:
            last_error = f"HTTP {resp.status_code}"
            log.warning("%s attempt %d failed: %s", service, attempt, last_error)
            continue

        ms = round((time.perf_counter() - start) * 1000, 1)
        body = resp.json()
        for entry in body.pop("trace", [{"service": service}]):
            trace.append({**entry, "ms": ms})
        if resp.status_code >= 400:
            raise UpstreamError(resp.status_code, body.get("error", "request rejected"), trace)
        return body

    raise UpstreamError(503, f"{service} unavailable ({last_error})", trace)


def respond(body: dict, trace: list, started: float, status: int = 200) -> JSONResponse:
    me = {**SELF, "ms": round((time.perf_counter() - started) * 1000, 1)}
    return JSONResponse({**body, "trace": [me, *trace]}, status_code=status)


@app.exception_handler(UpstreamError)
async def upstream_error(request: Request, exc: UpstreamError):
    return respond({"error": exc.message}, exc.trace, request.state.started, exc.status)


@app.middleware("http")
async def timing(request: Request, call_next):
    request.state.started = time.perf_counter()
    response = await call_next(request)
    if request.url.path.startswith("/api/"):
        log.info("%s %s %d %.1fms", request.method, request.url.path, response.status_code,
                 (time.perf_counter() - request.state.started) * 1000)
    return response


@app.get("/api/today")
async def today(request: Request):
    trace: list = []
    body = await call("word-service", "GET", f"{WORD_SERVICE}/today", trace)
    return respond(body, trace, request.state.started)


class GuessRequest(BaseModel):
    puzzle_id: str
    guess: str
    history: list[str] = Field(default_factory=list, max_length=MAX_GUESSES)
    hard_mode: bool = False


@app.post("/api/guess")
async def guess(req: GuessRequest, request: Request):
    started = request.state.started
    trace: list = []
    word = req.guess.strip().lower()
    history = [h.strip().lower() for h in req.history]
    if not WORD_RE.match(word):
        return respond({"error": "guess must be 5 letters"}, trace, started, 400)

    # Independent lookups on the same service: run them concurrently.
    validated, answer = await asyncio.gather(
        call("word-service", "GET", f"{WORD_SERVICE}/validate", trace, params={"word": word}),
        call("word-service", "GET", f"{WORD_SERVICE}/answer", trace,
             params={"puzzle_id": req.puzzle_id}),
    )
    if not validated["valid"]:
        return respond({"error": "not in word list"}, trace, started, 422)

    result = await call("evaluator", "POST", f"{EVALUATOR}/evaluate", trace, json={
        "guess": word,
        "answer": answer["answer"],
        "history": history,
        "max_guesses": MAX_GUESSES,
        "hard_mode": req.hard_mode,
    })

    status = "won" if result["solved"] else "lost" if result["game_over"] else "playing"
    body = {
        "guess": word,
        "pattern": result["pattern"],
        "attempt": result["attempt"],
        "status": status,
        "history": result["history"] + [{"guess": word, "pattern": result["pattern"]}],
    }
    if status == "lost":
        body["answer"] = answer["answer"]
    return respond(body, trace, started)


class HintRow(BaseModel):
    guess: str
    pattern: str


class HintRequest(BaseModel):
    history: list[HintRow] = Field(default_factory=list, max_length=MAX_GUESSES)
    hard_mode: bool = False


@app.post("/api/hint")
async def hint(req: HintRequest, request: Request):
    trace: list = []
    body = await call("hint-engine", "POST", f"{HINT_ENGINE}/hint", trace, json=req.model_dump())
    return respond(body, trace, request.state.started)


@app.get("/healthz", response_class=PlainTextResponse)
def healthz():
    return "ok"


@app.get("/readyz", response_class=PlainTextResponse)
def readyz():
    return "ok"
