const ROWS = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm'];
const STATE_CLASS = { G: 'correct', Y: 'present', B: 'absent' };

export function Keyboard({ states, onKey, disabled }) {
  return (
    <div className={`keyboard ${disabled ? 'disabled' : ''}`} aria-label="Keyboard">
      {ROWS.map((row, r) => (
        <div className="kb-row" key={row}>
          {r === 2 && <button className="key wide" onClick={() => onKey('Enter')}>Enter</button>}
          {[...row].map((ch) => (
            <button key={ch} className={`key ${STATE_CLASS[states[ch]] || ''}`} onClick={() => onKey(ch)}>
              {ch}
            </button>
          ))}
          {r === 2 && (
            <button className="key wide" onClick={() => onKey('Backspace')} aria-label="Backspace">
              ⌫
            </button>
          )}
        </div>
      ))}
    </div>
  );
}
