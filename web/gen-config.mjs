// Cloudflare Pages build command: writes config.js from config.example.js, with rpc taken from the RPC_URL env var.
import { readFileSync, writeFileSync } from 'node:fs';

const rpc = process.env.RPC_URL;
let s = readFileSync(new URL('config.example.js', import.meta.url), 'utf8');
if (rpc) s = s.replace(/rpc: '[^']*'/, `rpc: '${rpc}'`);
writeFileSync(new URL('config.js', import.meta.url), s);
