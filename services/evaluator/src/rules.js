// Game rules. Pure functions, no I/O, so they are easy to test against
// data/test-vectors.json (hint-engine tests against the same file).

const WORD_RE = /^[a-z]{5}$/;

// G = right letter, right spot. Y = in the word, wrong spot. B = not in the
// word, or every copy of that letter is already accounted for.
//
// Two passes are what makes duplicate letters correct: greens consume their
// letters first, then yellows are handed out left to right from what is left.
function score(guess, answer) {
  const result = Array(guess.length).fill('B');
  const remaining = {};
  for (let i = 0; i < guess.length; i++) {
    if (guess[i] === answer[i]) {
      result[i] = 'G';
    } else {
      remaining[answer[i]] = (remaining[answer[i]] || 0) + 1;
    }
  }
  for (let i = 0; i < guess.length; i++) {
    if (result[i] === 'G') continue;
    if (remaining[guess[i]] > 0) {
      result[i] = 'Y';
      remaining[guess[i]] -= 1;
    }
  }
  return result.join('');
}

// Hard mode: every revealed hint must be used in later guesses.
// Greens must stay in place; yellow/green letters must appear at least as
// many times as they were revealed in any single earlier row.
function hardModeViolation(guess, scoredHistory) {
  for (const { guess: prev, pattern } of scoredHistory) {
    for (let i = 0; i < pattern.length; i++) {
      if (pattern[i] === 'G' && guess[i] !== prev[i]) {
        return `letter ${i + 1} must be ${prev[i].toUpperCase()}`;
      }
    }
    const needed = {};
    for (let i = 0; i < pattern.length; i++) {
      if (pattern[i] !== 'B') needed[prev[i]] = (needed[prev[i]] || 0) + 1;
    }
    for (const [letter, count] of Object.entries(needed)) {
      const have = [...guess].filter((c) => c === letter).length;
      if (have < count) return `guess must contain ${letter.toUpperCase()}`;
    }
  }
  return null;
}

class RuleError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

// Scores one guess in the context of the whole game. History patterns are
// recomputed here from the real answer instead of being trusted from the
// client, so a tampered history cannot unlock hints or a fake game over.
function evaluate({ guess, answer, history = [], maxGuesses = 6, hardMode = false }) {
  if (!WORD_RE.test(guess || '')) throw new RuleError(400, 'guess must be 5 letters a-z');
  if (!WORD_RE.test(answer || '')) throw new RuleError(400, 'answer must be 5 letters a-z');
  if (!Array.isArray(history) || !history.every((g) => WORD_RE.test(g))) {
    throw new RuleError(400, 'history must be a list of 5-letter words');
  }

  const scoredHistory = history.map((g) => ({ guess: g, pattern: score(g, answer) }));
  if (history.includes(answer) || history.length >= maxGuesses) {
    throw new RuleError(409, 'this game is already over');
  }
  if (hardMode) {
    const violation = hardModeViolation(guess, scoredHistory);
    if (violation) throw new RuleError(422, `hard mode: ${violation}`);
  }

  const pattern = score(guess, answer);
  const attempt = history.length + 1;
  const solved = pattern === 'GGGGG';
  return {
    pattern,
    attempt,
    solved,
    game_over: solved || attempt >= maxGuesses,
    history: scoredHistory,
  };
}

module.exports = { score, hardModeViolation, evaluate, RuleError };
