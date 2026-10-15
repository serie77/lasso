// Tiny JSON-RPC proxy so the browser never sees the Alchemy key.
// env: UPSTREAM (Alchemy URL), ALLOWED_ORIGIN (e.g. https://lasso.chud.tech), PORT
import { createServer } from 'node:http';

const UPSTREAM = process.env.UPSTREAM;
const ORIGIN = process.env.ALLOWED_ORIGIN ?? '*';
if (!UPSTREAM) throw new Error('missing env UPSTREAM');

createServer(async (req, res) => {
  const cors = { 'Access-Control-Allow-Origin': ORIGIN, 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'content-type', Vary: 'Origin' };
  if (req.method === 'OPTIONS') return res.writeHead(204, cors).end();
  if (req.method !== 'POST' || (ORIGIN !== '*' && req.headers.origin !== ORIGIN)) return res.writeHead(403, cors).end();
  const chunks = [];
  for await (const c of req) chunks.push(c);
  try {
    const r = await fetch(UPSTREAM, { method: 'POST', headers: { 'content-type': 'application/json' }, body: Buffer.concat(chunks), signal: AbortSignal.timeout(20000) });
    res.writeHead(r.status, { ...cors, 'content-type': 'application/json' }).end(Buffer.from(await r.arrayBuffer()));
  } catch {
    res.writeHead(502, cors).end();
  }
}).listen(Number(process.env.PORT ?? 8787));
