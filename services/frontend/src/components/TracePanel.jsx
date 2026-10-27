import { shortNode } from '../nodeName.js';

// Shows which pod on which node handled each hop of a request. This is the
// live proof that every client request is served by 2+ containers, and it
// makes node failures and rescheduling visible during the demo.
export function TracePanel({ requests }) {
  return (
    <div className="panel">
      <h2>Request path</h2>
      {requests.length === 0 && <p className="muted">Requests will appear here.</p>}
      <ul className="requests">
        {requests.map((r) => (
          <li key={r.at} className={r.ok ? '' : 'failed'}>
            <div className="req-label">
              <span>{r.label}</span>
              <span className={`status ${r.ok ? 'ok' : 'err'}`}>{r.status || 'net'}</span>
            </div>
            <ol className="hops">
              {r.trace.map((h, i) => (
                <li key={i} className={`hop svc-${h.service}`}>
                  <span className="svc">{h.service}</span>
                  <span className="node" title={h.node}>{shortNode(h.node)}</span>
                  <span className="pod" title={h.pod}>{shortPod(h.pod)}</span>
                  {h.ms !== undefined && <span className="ms">{h.ms}ms</span>}
                </li>
              ))}
            </ol>
          </li>
        ))}
      </ul>
    </div>
  );
}

// "evaluator-7c9f8d6b5-x2k4p" -> "…x2k4p": the suffix is what tells replicas apart.
function shortPod(pod = '') {
  const parts = pod.split('-');
  return parts.length > 2 ? `…${parts[parts.length - 1]}` : pod;
}
