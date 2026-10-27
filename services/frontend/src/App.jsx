import { useCallback, useEffect, useMemo, useState } from 'react';
import { api } from './api.js';
import { Board } from './components/Board.jsx';
import { Keyboard } from './components/Keyboard.jsx';
import { HintPanel } from './components/HintPanel.jsx';
import { TracePanel } from './components/TracePanel.jsx';

const WORD_LENGTH = 5;
const storageKey = (puzzleId) => `kube-guess:${puzzleId}`;

// Game progress lives only in the browser. Every request carries what the
// server needs, so any replica on any node can answer it.
function loadGame(puzzleId) {
  try {
    const saved = JSON.parse(localStorage.getItem(storageKey(puzzleId)));
    if (saved && Array.isArray(saved.rows)) return saved;
  } catch {
    // private mode or corrupt entry: start fresh
  }
  return { rows: [], status: 'playing', hardMode: false, answer: null };
}

function saveGame(puzzleId, game) {
  try {
    localStorage.setItem(storageKey(puzzleId), JSON.stringify(game));
  } catch {
    // storage unavailable; the game still works for this session
  }
}

export default function App() {
  const [puzzle, setPuzzle] = useState(null);
  const [loadError, setLoadError] = useState(null);
  const [game, setGame] = useState(null);
  const [input, setInput] = useState('');
  const [busy, setBusy] = useState(false);
  const [toast, setToast] = useState(null);
  const [shake, setShake] = useState(false);
  const [hint, setHint] = useState(null);
  const [requests, setRequests] = useState([]);

  const record = useCallback((label, res) => {
    setRequests((prev) => [{ label, ok: res.ok, status: res.status, trace: res.trace, at: Date.now() }, ...prev].slice(0, 8));
  }, []);

  const flash = useCallback((message) => {
    setToast(message);
    setTimeout(() => setToast((t) => (t === message ? null : t)), 2200);
  }, []);

  const loadPuzzle = useCallback(async () => {
    setLoadError(null);
    const res = await api.today();
    record('GET /api/today', res);
    if (!res.ok) return setLoadError(res.error);
    setPuzzle(res.data);
    setGame(loadGame(res.data.puzzle_id));
  }, [record]);

  useEffect(() => {
    loadPuzzle();
  }, [loadPuzzle]);

  const update = useCallback((next) => {
    setGame(next);
    saveGame(puzzle.puzzle_id, next);
  }, [puzzle]);

  const submit = useCallback(async () => {
    if (busy || !game || game.status !== 'playing') return;
    if (input.length !== WORD_LENGTH) {
      setShake(true);
      return flash('Not enough letters');
    }
    setBusy(true);
    const res = await api.guess({
      puzzle_id: puzzle.puzzle_id,
      guess: input,
      history: game.rows.map((r) => r.guess),
      hard_mode: game.hardMode,
    });
    setBusy(false);
    record(`POST /api/guess "${input}"`, res);
    if (!res.ok) {
      setShake(true);
      return flash(res.error);
    }
    const evaluator = res.trace.find((t) => t.service === 'evaluator');
    const rows = [...game.rows, { guess: res.data.guess, pattern: res.data.pattern, node: evaluator?.node }];
    update({ ...game, rows, status: res.data.status, answer: res.data.answer || null });
    setInput('');
    setHint(null);
    if (res.data.status === 'won') flash(['Genius', 'Magnificent', 'Impressive', 'Splendid', 'Great', 'Phew'][rows.length - 1]);
    if (res.data.status === 'lost') flash(`The word was ${res.data.answer.toUpperCase()}`);
  }, [busy, game, input, puzzle, record, update, flash]);

  const onKey = useCallback((key) => {
    if (!game || game.status !== 'playing' || busy) return;
    if (key === 'Enter') return submit();
    if (key === 'Backspace') return setInput((s) => s.slice(0, -1));
    if (/^[a-z]$/i.test(key)) setInput((s) => (s.length < WORD_LENGTH ? s + key.toLowerCase() : s));
  }, [game, busy, submit]);

  useEffect(() => {
    const handler = (e) => {
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      if (e.target instanceof HTMLInputElement) return;
      onKey(e.key);
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [onKey]);

  const askHint = useCallback(async () => {
    setBusy(true);
    const res = await api.hint({
      history: game.rows.map(({ guess, pattern }) => ({ guess, pattern })),
      hard_mode: game.hardMode,
    });
    setBusy(false);
    record('POST /api/hint', res);
    if (!res.ok) return flash(res.error);
    setHint(res.data);
  }, [game, record, flash]);

  const letterStates = useMemo(() => {
    const rank = { G: 3, Y: 2, B: 1 };
    const states = {};
    for (const { guess, pattern } of game?.rows || []) {
      [...guess].forEach((ch, i) => {
        if (!states[ch] || rank[pattern[i]] > rank[states[ch]]) states[ch] = pattern[i];
      });
    }
    return states;
  }, [game]);

  return (
    <div className="app">
      <header className="header">
        <div className="brand">
          <span className="logo" aria-hidden="true" />
          <div>
            <h1>Kube Guess</h1>
            <p className="tagline">Five letters. Six tries. Served by a Raspberry Pi cluster.</p>
          </div>
        </div>
        {puzzle && <span className="puzzle-id">Puzzle {puzzle.puzzle_id}</span>}
      </header>

      {loadError && (
        <div className="load-error">
          <p>Could not load today's puzzle: {loadError}</p>
          <button onClick={loadPuzzle}>Retry</button>
        </div>
      )}

      {puzzle && game && (
        <main className="layout">
          <section className="play">
            <div className="controls">
              <label className={`toggle ${game.rows.length ? 'locked' : ''}`} title={game.rows.length ? 'Can only change before your first guess' : ''}>
                <input
                  type="checkbox"
                  checked={game.hardMode}
                  disabled={game.rows.length > 0}
                  onChange={(e) => update({ ...game, hardMode: e.target.checked })}
                />
                Hard mode
              </label>
              <button className="hint-btn" onClick={askHint} disabled={busy || game.status !== 'playing'}>
                Hint
              </button>
            </div>

            <Board
              rows={game.rows}
              input={input}
              maxGuesses={puzzle.max_guesses}
              playing={game.status === 'playing'}
              shake={shake}
              onShakeEnd={() => setShake(false)}
            />

            {game.status !== 'playing' && (
              <div className={`result ${game.status}`}>
                {game.status === 'won'
                  ? `Solved in ${game.rows.length}/${puzzle.max_guesses}`
                  : `Out of guesses. The word was ${game.answer?.toUpperCase()}.`}
                <span className="muted"> New puzzle tomorrow.</span>
              </div>
            )}

            <Keyboard states={letterStates} onKey={onKey} disabled={busy || game.status !== 'playing'} />
          </section>

          <aside className="side">
            <HintPanel hint={hint} onPick={(w) => setInput(w)} />
            <TracePanel requests={requests} />
          </aside>
        </main>
      )}

      {toast && <div className="toast" role="status">{toast}</div>}
    </div>
  );
}
