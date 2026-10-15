// Local preview of web/ that behaves like Cloudflare Pages: clean URLs (/docs -> docs.html) and _redirects.
// usage: node serve-web.mjs [port]
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(fileURLToPath(new URL('.', import.meta.url)), 'web');
const port = Number(process.argv[2] ?? 5177);
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.svg': 'image/svg+xml', '.png': 'image/png', '.css': 'text/css', '.json': 'application/json' };
const rules = (await readFile(join(root, '_redirects'), 'utf8')).split('\n').map(l => l.trim().split(/\s+/)).filter(r => r.length === 3);
const isFile = p => stat(p).then(s => s.isFile(), () => false);

createServer(async (req, res) => {
  let path = decodeURIComponent(new URL(req.url, 'http://x').pathname).replace(/\/+$/, '') || '/';
  const rule = rules.find(([from]) => from === path);
  if (rule && rule[2] !== '200') return res.writeHead(Number(rule[2]), { location: rule[1] }).end();
  if (rule) path = rule[1];
  if (path.endsWith('.html')) return res.writeHead(308, { location: path.slice(0, -5) || '/' }).end();
  const base = join(root, normalize(path === '/' ? '/index' : path));
  if (!base.startsWith(root) || base.includes('functions')) return res.writeHead(404).end();
  for (const file of [base, base + '.html']) {
    if (await isFile(file)) return res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream' }).end(await readFile(file));
  }
  res.writeHead(404).end('not found');
}).listen(port, () => console.log(`web on http://127.0.0.1:${port}`));
