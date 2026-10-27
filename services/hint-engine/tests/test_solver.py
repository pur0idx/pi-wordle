import json
from pathlib import Path

import numpy as np
import pytest

from app import patterns
from app.solver import Solver

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent.parent  # services/hint-engine/tests -> repo root (when run from the repo)
VECTORS = next(p for p in (HERE / "test-vectors.json", REPO / "data/test-vectors.json") if p.exists())
WORDS = next(p for p in (Path("/app/words"), REPO / "data/words") if p.exists())


def score(guess: str, answer: str) -> str:
    enc = patterns.encode_words([guess, answer])
    return patterns.code_to_pattern(int(patterns.score_against_all(enc[0], enc[1:])[0]))


@pytest.mark.parametrize("v", json.loads(VECTORS.read_text())["vectors"])
def test_matches_shared_vectors(v):
    assert score(v["guess"], v["answer"]) == v["pattern"]


def test_code_round_trip():
    for code in range(patterns.N_PATTERNS):
        assert patterns.pattern_to_code(patterns.code_to_pattern(code)) == code


@pytest.fixture(scope="module")
def solver():
    return Solver.load(WORDS, Path("/nonexistent.npz"))


def test_filters_to_the_answer(solver):
    answer = "crane"
    history = [(g, score(g, answer)) for g in ("slate", "brick")]
    remaining = [solver.answers[i] for i in solver.remaining(history)]
    assert answer in remaining
    assert len(remaining) < 20
    # Every remaining word must be consistent with every clue.
    for word in remaining:
        for g, p in history:
            assert score(g, word) == p


def test_accepts_guesses_outside_the_answer_list(solver):
    history = [("zebus", score("zebus", "crane"))]
    assert "crane" in [solver.answers[i] for i in solver.remaining(history)]


def test_opening_hint_is_informative(solver):
    h = solver.hint([])
    assert h.remaining == len(solver.answers)
    assert len(h.suggestions) == 5
    assert h.suggestions[0]["bits"] > 4
    assert h.suggestions == sorted(h.suggestions, key=lambda s: -s["bits"])


def test_hard_mode_only_suggests_possible_words(solver):
    history = [("slate", score("slate", "crane"))]
    h = solver.hint(history, hard_mode=True)
    assert h.suggestions and all(s["possible"] for s in h.suggestions)


def test_endgame_lists_candidates(solver):
    history = [(g, score(g, "crane")) for g in ("slate", "brick", "grand")]
    h = solver.hint(history)
    assert 1 <= h.remaining <= 12
    assert "crane" in h.candidates


def test_inconsistent_history_leaves_nothing(solver):
    h = solver.hint([("crane", "GGGGB"), ("crane", "BBBBB")])
    assert h.remaining == 0 and h.suggestions == []


def test_precomputed_matrix_matches_live_scoring(solver, tmp_path):
    from app import precompute
    out = tmp_path / "m.npz"
    precompute.main(str(WORDS), str(out))
    loaded = Solver.load(WORDS, out)
    assert np.array_equal(loaded.matrix, solver.matrix)
