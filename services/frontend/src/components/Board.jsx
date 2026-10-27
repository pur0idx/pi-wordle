import { shortNode } from '../nodeName.js';

const STATE_CLASS = { G: 'correct', Y: 'present', B: 'absent' };
const STATE_LABEL = { G: 'correct', Y: 'in word', B: 'not in word' };

function Row({ letters, pattern, node }) {
  return (
    <div className="row-wrap">
      <div className="row" role="row">
        {Array.from({ length: 5 }, (_, i) => {
          const ch = letters[i] || '';
          const state = pattern?.[i];
          const cls = state ? `tile revealed ${STATE_CLASS[state]}` : `tile ${ch ? 'filled' : ''}`;
          return (
            <div
              key={i}
              className={cls}
              style={state ? { animationDelay: `${i * 90}ms` } : undefined}
              aria-label={ch ? `${ch} ${state ? STATE_LABEL[state] : ''}` : 'empty'}
            >
              {ch}
            </div>
          );
        })}
      </div>
      <span className={`row-node ${node ? '' : 'hidden'}`} title="Node whose evaluator scored this guess">
        {shortNode(node)}
      </span>
    </div>
  );
}

export function Board({ rows, input, maxGuesses, playing, shake, onShakeEnd }) {
  const lines = [];
  for (let i = 0; i < maxGuesses; i++) {
    if (i < rows.length) {
      lines.push(<Row key={i} letters={rows[i].guess} pattern={rows[i].pattern} node={rows[i].node} />);
    } else if (i === rows.length && playing) {
      lines.push(
        <div key={i} className={shake ? 'shake' : ''} onAnimationEnd={onShakeEnd}>
          <Row letters={input} />
        </div>,
      );
    } else {
      lines.push(<Row key={i} letters="" />);
    }
  }
  return <div className="board" role="grid" aria-label="Guesses">{lines}</div>;
}
