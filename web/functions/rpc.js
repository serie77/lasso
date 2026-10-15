// Cloudflare Pages Function at /rpc: forwards read-only JSON-RPC to Alchemy so the key never reaches the browser.
// Set ALCHEMY_URL as an encrypted environment variable in the Pages project.
const ALLOWED = new Set([
  'eth_chainId', 'eth_blockNumber', 'eth_call', 'eth_getLogs', 'eth_getBlockByNumber', 'eth_getBalance', 'eth_getCode',
  'eth_getTransactionReceipt', 'eth_getTransactionByHash', 'eth_estimateGas', 'eth_gasPrice', 'eth_maxPriorityFeePerGas',
  'eth_feeHistory', 'eth_getTransactionCount', 'net_version',
]);

export async function onRequestPost({ request, env }) {
  let body;
  try {
    body = await request.json();
  } catch {
    return new Response('bad request', { status: 400 });
  }
  const calls = Array.isArray(body) ? body : [body];
  if (calls.length > 50 || calls.some(c => !ALLOWED.has(c?.method))) return new Response('method not allowed', { status: 403 });
  const r = await fetch(env.ALCHEMY_URL, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  return new Response(r.body, { status: r.status, headers: { 'content-type': 'application/json' } });
}
