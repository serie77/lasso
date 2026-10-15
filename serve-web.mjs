// Local preview of web/ that behaves like Vercel with web/vercel.json: clean URLs, redirects and rewrites.
// /rpc is not proxied locally; web/config.js points straight at an RPC instead.
// usage: node serve-web.mjs [port]
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(fileURLToPath(new URL('.', import.meta.url)), 'web');
const port = Number(process.argv[2] ?? 5177);
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.svg': 'image/svg+xml', '.png': 'image/png', '.css': 'text/css', '.json': 'application/json' };
const cfg = JSON.parse(await readFile(join(root, 'vercel.json'), 'utf8'));
const isFile = p => stat(p).then(s => s.isFile(), () => false);

createServer(async (req, res) => {
  let path = decodeURIComponent(new URL(req.url, 'http://x').pathname).replace(/\/+$/, '') || '/';
  const redirect = cfg.redirects.find(r => r.source === path);
  if (redirect) return res.writeHead(redirect.permanent ? 308 : 307, { location: redirect.destination }).end();
  if (path.endsWith('.html')) return res.writeHead(308, { location: path.slice(0, -5) || '/' }).end();
  path = cfg.rewrites.find(r => r.source === path)?.destination ?? path;
  const base = join(root, normalize(path === '/' ? '/index' : path));
  if (!base.startsWith(root) || base.includes(join(root, 'api'))) return res.writeHead(404).end();
  for (const file of [base, base + '.html']) {
    if (await isFile(file)) return res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream' }).end(await readFile(file));
  }
  res.writeHead(404).end('not found');
}).listen(port, () => console.log(`web on http://127.0.0.1:${port}`));
