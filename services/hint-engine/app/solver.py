"""Candidate filtering and entropy ranking.

The hint engine never sees the answer. Like a human solver, it only knows the
guesses and the colors they got, and works out which answers are still
possible and which next guess would split them most evenly.
"""

from dataclasses import dataclass
from pathlib import Path

import numpy as np

from . import patterns

MAX_LISTED_CANDIDATES = 12


@dataclass
class Hint:
    remaining: int
    suggestions: list
    candidates: list


class Solver:
    def __init__(self, answers: list[str], matrix: np.ndarray):
        if matrix.shape != (len(answers), len(answers)):
            raise ValueError(f"matrix {matrix.shape} does not match {len(answers)} answers")
        self.answers = answers
        self.encoded = patterns.encode_words(answers)
        self.index = {w: i for i, w in enumerate(answers)}
        self.matrix = matrix
        self._opening = {}

    @classmethod
    def load(cls, words_dir: Path, matrix_path: Path) -> "Solver":
        answers = patterns.load_words(words_dir / "answers.txt")
        if matrix_path.exists():
            data = np.load(matrix_path)
            if list(data["words"]) == answers:
                return cls(answers, data["matrix"])
            print(f"{matrix_path} was built from a different word list; recomputing", flush=True)
        enc = patterns.encode_words(answers)
        return cls(answers, patterns.build_matrix(enc, enc))

    def _row(self, guess: str) -> np.ndarray:
        """Pattern codes of `guess` against every answer."""
        i = self.index.get(guess)
        if i is not None:
            return self.matrix[i]
        encoded = patterns.encode_words([guess])[0]
        return patterns.score_against_all(encoded, self.encoded)

    def remaining(self, history: list[tuple[str, str]]) -> np.ndarray:
        mask = np.ones(len(self.answers), dtype=bool)
        for guess, pattern in history:
            mask &= self._row(guess) == patterns.pattern_to_code(pattern)
        return np.flatnonzero(mask)

    def entropy(self, pool: np.ndarray, remaining: np.ndarray) -> np.ndarray:
        """Expected information (bits) of each guess in `pool`."""
        sub = self.matrix[np.ix_(pool, remaining)].astype(np.int64)
        offsets = np.arange(len(pool))[:, None] * patterns.N_PATTERNS
        counts = np.bincount((sub + offsets).ravel(), minlength=len(pool) * patterns.N_PATTERNS)
        p = counts.reshape(len(pool), patterns.N_PATTERNS) / len(remaining)
        with np.errstate(divide="ignore", invalid="ignore"):
            return -np.nansum(np.where(p > 0, p * np.log2(p), 0.0), axis=1)

    def hint(self, history: list[tuple[str, str]], hard_mode: bool = False, top: int = 5) -> Hint:
        if not history and hard_mode in self._opening:
            return self._opening[hard_mode]

        remaining = self.remaining(history)
        n = len(remaining)
        candidates = [self.answers[i] for i in remaining] if n <= MAX_LISTED_CANDIDATES else []

        if n == 0:
            result = Hint(0, [], [])
        elif n <= 2:
            # Nothing left to learn: just guess one of them.
            result = Hint(n, [{"word": self.answers[i], "bits": round(np.log2(n), 2), "possible": True}
                              for i in remaining], candidates)
        else:
            # Hard mode only allows guesses consistent with what is known,
            # which is exactly the remaining set.
            pool = remaining if hard_mode else np.arange(len(self.answers))
            bits = self.entropy(pool, remaining)
            possible = np.isin(pool, remaining)
            # Best entropy first; on ties prefer a word that could still win.
            order = np.lexsort((~possible, -np.round(bits, 6)))[:top]
            result = Hint(n, [{"word": self.answers[pool[i]],
                               "bits": round(float(bits[i]), 2),
                               "possible": bool(possible[i])} for i in order], candidates)

        if not history:
            self._opening[hard_mode] = result
        return result
