"""Gateway tests with the backends replaced by an in-process fake."""

import json

import httpx
import pytest
from fastapi.testclient import TestClient

from app import main


class FakeBackends:
    def __init__(self):
        self.fail_next = 0  # number of upcoming calls that raise ConnectError
        self.calls: list[str] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.calls.append(f"{request.url.host}{request.url.path}")
        if self.fail_next:
            self.fail_next -= 1
            raise httpx.ConnectError("node is gone", request=request)
        me = lambda svc: [{"service": svc, "pod": f"{svc}-pod", "node": "pi-1"}]
        path = request.url.path
        if path == "/today":
            return httpx.Response(200, json={"puzzle_id": "2026-11-17", "length": 5,
                                             "max_guesses": 6, "trace": me("word-service")})
        if path == "/validate":
            word = request.url.params["word"]
            return httpx.Response(200, json={"word": word, "valid": word != "qqqqq",
                                             "trace": me("word-service")})
        if path == "/answer":
            return httpx.Response(200, json={"answer": "crane", "trace": me("word-service")})
        if path == "/evaluate":
            b = json.loads(request.content)
            solved = b["guess"] == b["answer"]
            return httpx.Response(200, json={
                "pattern": "GGGGG" if solved else "BBGBG", "attempt": len(b["history"]) + 1,
                "solved": solved, "game_over": solved or len(b["history"]) + 1 >= 6,
                "history": [{"guess": g, "pattern": "BBBBB"} for g in b["history"]],
                "trace": me("evaluator")})
        if path == "/hint":
            return httpx.Response(200, json={"remaining": 3, "suggestions": [], "candidates": [],
                                             "trace": me("hint-engine")})
        return httpx.Response(404, json={"error": "not found"})


@pytest.fixture
def client():
    fake = FakeBackends()
    with TestClient(main.app) as c:
        main.http = httpx.AsyncClient(transport=httpx.MockTransport(fake))
        c.fake = fake
        yield c


def services(resp) -> list[str]:
    return [t["service"] for t in resp.json()["trace"]]


def test_today_touches_two_containers(client):
    r = client.get("/api/today")
    assert r.status_code == 200
    assert r.json()["puzzle_id"] == "2026-11-17"
    assert services(r) == ["gateway", "word-service"]


def test_guess_touches_three_services(client):
    r = client.post("/api/guess", json={"puzzle_id": "2026-11-17", "guess": "Slate"})
    assert r.status_code == 200
    body = r.json()
    assert body["pattern"] == "BBGBG" and body["status"] == "playing"
    assert "answer" not in body
    assert set(services(r)) == {"gateway", "word-service", "evaluator"}


def test_win_and_loss(client):
    won = client.post("/api/guess", json={"puzzle_id": "2026-11-17", "guess": "crane"})
    assert won.json()["status"] == "won"
    lost = client.post("/api/guess", json={"puzzle_id": "2026-11-17", "guess": "slate",
                                           "history": ["pilot"] * 5})
    assert lost.json()["status"] == "lost" and lost.json()["answer"] == "crane"


def test_rejects_unknown_word(client):
    r = client.post("/api/guess", json={"puzzle_id": "2026-11-17", "guess": "qqqqq"})
    assert r.status_code == 422 and r.json()["error"] == "not in word list"
    assert "evaluator" not in services(r)


def test_rejects_bad_shape_without_calling_backends(client):
    r = client.post("/api/guess", json={"puzzle_id": "2026-11-17", "guess": "abc"})
    assert r.status_code == 400 and client.fake.calls == []


def test_retries_when_a_replica_is_down(client):
    client.fake.fail_next = 2
    r = client.post("/api/hint", json={"history": []})
    assert r.status_code == 200
    assert client.fake.calls == ["hint-engine/hint"] * 3


def test_reports_503_when_backend_stays_down(client):
    client.fake.fail_next = main.ATTEMPTS
    r = client.post("/api/hint", json={"history": []})
    assert r.status_code == 503 and "hint-engine unavailable" in r.json()["error"]
