// k3d names nodes "k3d-<cluster>-agent-3"; show just "agent-3". Real Pi node
// names ("pi-3") are already short and pass through unchanged.
export function shortNode(node = '') {
  const m = node.match(/^k3d-.+-((?:agent|server)-\d+)$/);
  return m ? m[1] : node;
}
