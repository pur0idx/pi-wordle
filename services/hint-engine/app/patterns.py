"""Vectorised Wordle-style scoring.

Must match services/evaluator/src/rules.js exactly; both are tested against
data/test-vectors.json.

A pattern is stored as one base-3 integer (0..242): B=0, Y=1, G=2, first
letter most significant. That lets a whole guess-vs-every-answer row fit in a
uint8 array, and lets us bincount patterns to get entropy.
"""

from pathlib import Path

import numpy as np

N_PATTERNS = 3**5
WEIGHTS = np.array([81, 27, 9, 3, 1], dtype=np.int64)
_SYMBOL = {"B": 0, "Y": 1, "G": 2}


def encode_words(words: list[str]) -> np.ndarray:
    """(n, 5) uint8 array of letter indices 0..25."""
    raw = np.frombuffer("".join(words).encode("ascii"), dtype=np.uint8)
    return (raw.reshape(len(words), 5) - ord("a")).astype(np.uint8)


def pattern_to_code(pattern: str) -> int:
    return int(sum(_SYMBOL[c] * w for c, w in zip(pattern, WEIGHTS)))


def code_to_pattern(code: int) -> str:
    out = []
    for w in WEIGHTS:
        digit, code = divmod(code, int(w))
        out.append("BYG"[digit])
    return "".join(out)


def score_against_all(guess: np.ndarray, answers: np.ndarray) -> np.ndarray:
    """Pattern codes for one encoded guess (5,) against every answer (n, 5)."""
    n = answers.shape[0]
    green = answers == guess  # (n, 5)
    result = np.where(green, 2, 0).astype(np.int64)

    # Letters of each answer not used by a green, counted per letter.
    remaining = np.zeros((n, 26), dtype=np.int64)
    rows = np.repeat(np.arange(n), 5)
    np.add.at(remaining, (rows, answers.reshape(-1)), (~green).reshape(-1).astype(np.int64))

    # Hand out yellows left to right, like the two-pass scalar algorithm.
    for i in range(5):
        letter = int(guess[i])
        give = (~green[:, i]) & (remaining[:, letter] > 0)
        result[give, i] = 1
        remaining[give, letter] -= 1

    return (result @ WEIGHTS).astype(np.uint8)


def build_matrix(guesses: np.ndarray, answers: np.ndarray) -> np.ndarray:
    """(len(guesses), len(answers)) uint8 matrix of pattern codes."""
    return np.stack([score_against_all(g, answers) for g in guesses])


def load_words(path: Path) -> list[str]:
    words = []
    for line in path.read_text().splitlines():
        w = line.strip().lower()
        if len(w) == 5 and w.isascii() and w.isalpha():
            words.append(w)
    return words
