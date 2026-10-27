"""Build the answers x answers pattern matrix ahead of time.

Run during `docker build` so pods start in about a second instead of
spending CPU time on a Raspberry Pi every time Kubernetes reschedules them.

    python -m app.precompute <words_dir> <out.npz>
"""

import sys
import time
from pathlib import Path

import numpy as np

from . import patterns


def main(words_dir: str, out: str) -> None:
    start = time.perf_counter()
    answers = patterns.load_words(Path(words_dir) / "answers.txt")
    enc = patterns.encode_words(answers)
    matrix = patterns.build_matrix(enc, enc)
    np.savez_compressed(out, matrix=matrix, words=np.array(answers))
    print(f"wrote {out}: {matrix.shape} in {time.perf_counter() - start:.2f}s")


if __name__ == "__main__":
    main(*sys.argv[1:3])
