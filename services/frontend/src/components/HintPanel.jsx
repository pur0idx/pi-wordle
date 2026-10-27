export function HintPanel({ hint, onPick }) {
  return (
    <div className="panel">
      <h2>Hint engine</h2>
      {!hint && <p className="muted">Press Hint to see how many answers are still possible and which guess narrows them down the most.</p>}
      {hint && (
        <>
          <p className="remaining">
            <strong>{hint.remaining}</strong> possible answer{hint.remaining === 1 ? '' : 's'} left
          </p>
          {hint.suggestions.length > 0 && (
            <ol className="suggestions">
              {hint.suggestions.map((s) => (
                <li key={s.word}>
                  <button className="link" onClick={() => onPick(s.word)} title="Type this word">
                    {s.word}
                  </button>
                  <span className="bits">{s.bits.toFixed(2)} bits</span>
                  {s.possible && <span className="badge">could win</span>}
                </li>
              ))}
            </ol>
          )}
          {hint.candidates.length > 0 && (
            <p className="candidates muted">Still possible: {hint.candidates.join(', ')}</p>
          )}
        </>
      )}
    </div>
  );
}
