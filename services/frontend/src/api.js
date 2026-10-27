// All calls go to /api on the same origin; nginx proxies them to the gateway.
// nginx stamps every response with the frontend pod and node, which we put
// at the front of the trace so the UI shows the full request path.

function frontendHop(res) {
  const pod = res.headers.get('X-Served-By-Pod');
  if (!pod) return [];
  return [{ service: 'frontend', pod, node: res.headers.get('X-Served-By-Node') || '?' }];
}

const TIMEOUT_MS = 4000;
const RETRYABLE = new Set([0, 502, 503, 504]);

async function send(method, path, body) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    return await fetch(path, {
      method,
      headers: body ? { 'Content-Type': 'application/json' } : undefined,
      body: body ? JSON.stringify(body) : undefined,
      signal: ctrl.signal,
    });
  } catch {
    return null; // network error or timeout
  } finally {
    clearTimeout(timer);
  }
}

// When a node dies, the NodePort can still route a new connection to a
// frontend pod on that node until Kubernetes notices. Retrying once opens a
// new connection that will usually reach a live pod. Retrying a POST is safe
// here because the backend is stateless: the same guess with the same
// history always produces the same answer.
async function request(method, path, body) {
  let res = await send(method, path, body);
  if (!res || RETRYABLE.has(res.status)) {
    res = (await send(method, path, body)) || res;
  }
  if (!res) {
    return { ok: false, status: 0, error: 'cannot reach the cluster', trace: [] };
  }
  let data = {};
  try {
    data = await res.json();
  } catch {
    // nginx 502/504 pages are HTML; keep going with an empty body
  }
  const trace = [...frontendHop(res), ...(data.trace || [])];
  if (!res.ok) {
    const error = data.error || (res.status >= 502 ? 'cluster is recovering, try again' : `error ${res.status}`);
    return { ok: false, status: res.status, error, trace };
  }
  return { ok: true, status: res.status, data, trace };
}

export const api = {
  today: () => request('GET', '/api/today'),
  guess: (body) => request('POST', '/api/guess', body),
  hint: (body) => request('POST', '/api/hint', body),
};
