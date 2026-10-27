const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const { score, evaluate, RuleError } = require('../src/rules');

// In the Docker build the vectors are copied next to the tests; in the repo
// they live at data/test-vectors.json.
const vectorsPath = [
  path.join(__dirname, 'test-vectors.json'),
  path.join(__dirname, '../../../data/test-vectors.json'),
].find((p) => fs.existsSync(p));
const { vectors } = JSON.parse(fs.readFileSync(vectorsPath, 'utf8'));

test('scores every shared vector', () => {
  for (const v of vectors) {
    assert.strictEqual(score(v.guess, v.answer), v.pattern, `${v.guess} vs ${v.answer}`);
  }
});

test('reports win and game over', () => {
  const won = evaluate({ guess: 'crane', answer: 'crane' });
  assert.deepStrictEqual([won.solved, won.game_over, won.attempt], [true, true, 1]);

  const lost = evaluate({
    guess: 'pilot',
    answer: 'crane',
    history: ['slate', 'block', 'dummy', 'fight', 'quick'],
  });
  assert.deepStrictEqual([lost.solved, lost.game_over, lost.attempt], [false, true, 6]);
});

test('recomputes history patterns from the real answer', () => {
  const r = evaluate({ guess: 'crane', answer: 'crane', history: ['slate'] });
  assert.deepStrictEqual(r.history, [{ guess: 'slate', pattern: 'BBGBG' }]);
});

test('refuses to continue a finished game', () => {
  assert.throws(
    () => evaluate({ guess: 'slate', answer: 'crane', history: ['crane'] }),
    (e) => e instanceof RuleError && e.status === 409,
  );
});

test('hard mode keeps greens in place and reuses yellows', () => {
  // slate vs crane = BBGBG: A stays in slot 3, E stays in slot 5
  assert.throws(
    () => evaluate({ guess: 'pilot', answer: 'crane', history: ['slate'], hardMode: true }),
    (e) => e.status === 422 && /letter 3 must be A/.test(e.message),
  );
  // speed vs abide = BBYBY: must contain E and D somewhere
  assert.throws(
    () => evaluate({ guess: 'plane', answer: 'abide', history: ['speed'], hardMode: true }),
    (e) => e.status === 422 && /contain D/.test(e.message),
  );
  const ok = evaluate({ guess: 'grape', answer: 'crane', history: ['slate'], hardMode: true });
  assert.strictEqual(ok.pattern, 'BGGBG');
});

test('rejects malformed input', () => {
  for (const bad of ['', 'four', 'toolong', 'CRANE', 'cr4ne']) {
    assert.throws(() => evaluate({ guess: bad, answer: 'crane' }), (e) => e.status === 400);
  }
});
