"""hint-engine: the CPU-heavy service.

Filtering candidates and ranking guesses by entropy is NumPy work over a
(answers x answers) pattern matrix. It is split out so it can be scaled
independently and so a slow hint can never delay a plain /guess.
"""

import logging
import os
import re
import socket
import time
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse
from pydantic import BaseModel, Field, field_validator

from .solver import Solver

log = logging.getLogger("hint-engine")
logging.basicConfig(level=logging.INFO, format="%(message)s")

SELF = {
    "service": "hint-engine",
    "pod": os.environ.get("POD_NAME", socket.gethostname()),
    "node": os.environ.get("NODE_NAME", "local"),
}
WORD_RE = re.compile(r"^[a-z]{5}$")
PATTERN_RE = re.compile(r"^[GYB]{5}$")

state: dict = {}


@asynccontextmanager
async def lifespan(app: FastAPI):
    start = time.perf_counter()
    state["solver"] = Solver.load(
        Path(os.environ.get("WORDS_DIR", "/app/words")),
        Path(os.environ.get("MATRIX_PATH", "/app/patterns.npz")),
    )
    # Warm the opening-move cache so the first real request is fast.
    state["solver"].hint([])
    log.info("hint-engine ready in %.2fs (%d answers) pod=%s node=%s",
             time.perf_counter() - start, len(state["solver"].answers), SELF["pod"], SELF["node"])
    yield


app = FastAPI(title="hint-engine", lifespan=lifespan)


class Row(BaseModel):
    guess: str
    pattern: str

    @field_validator("guess")
    @classmethod
    def _guess(cls, v: str) -> str:
        if not WORD_RE.match(v):
            raise ValueError("guess must be 5 letters a-z")
        return v

    @field_validator("pattern")
    @classmethod
    def _pattern(cls, v: str) -> str:
        if not PATTERN_RE.match(v):
            raise ValueError("pattern must be 5 of G/Y/B")
        return v


class HintRequest(BaseModel):
    history: list[Row] = Field(default_factory=list, max_length=6)
    hard_mode: bool = False


@app.middleware("http")
async def log_requests(request: Request, call_next):
    if request.url.path in ("/healthz", "/readyz"):
        return await call_next(request)
    start = time.perf_counter()
    response = await call_next(request)
    log.info("%s %s %d %.2fms", request.method, request.url.path, response.status_code,
             (time.perf_counter() - start) * 1000)
    return response


@app.post("/hint")
def hint(req: HintRequest):
    # Plain `def` so FastAPI runs it in a worker thread and the NumPy work
    # does not block the event loop (health checks keep answering).
    h = state["solver"].hint([(r.guess, r.pattern) for r in req.history], req.hard_mode)
    return {
        "remaining": h.remaining,
        "suggestions": h.suggestions,
        "candidates": h.candidates,
        "trace": [SELF],
    }


@app.get("/healthz", response_class=PlainTextResponse)
def healthz():
    return "ok"


@app.get("/readyz")
def readyz():
    if "solver" not in state:
        return JSONResponse({"ready": False}, status_code=503)
    return PlainTextResponse("ok")
