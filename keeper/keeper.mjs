// Lasso keeper: executes orders once a fresh Hooke price exists, liquidates, and posts the ETH price if ETH
// collateral is enabled. Standalone: no build artifacts needed.
// env: RPC, KEEPER_KEY, LASSO, [ETH_PRICE_SOURCE] [ETH_PRICE_URL] [POLL_MS] [ETH_POST_MS]
import { createPublicClient, createWalletClient, http, parseAbi, formatUnits } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const env = (k, d) => process.env[k] || d || (() => { throw new Error(`missing env ${k}`); })();

const RPC = env('RPC', 'https://rpc.mainnet.chain.robinhood.com');
const LASSO = env('LASSO');
const ETH_SOURCE = process.env.ETH_PRICE_SOURCE || null;
const POLL_MS = Number(env('POLL_MS', '3000'));
const ETH_POST_MS = Number(env('ETH_POST_MS', '300000'));
const ETH_PRICE_URL = env('ETH_PRICE_URL', 'https://api.coinbase.com/v2/prices/ETH-USD/spot');

const lassoAbi = parseAbi([
  'function adapter() view returns (address)',
  'function params() view returns (uint32 minExecDelay,uint32 orderTtl,uint16 protocolShareBps,uint16 lpFeeBps,uint128 liquidationFeeUsd,uint128 minCollateralUsd)',
  'function orderCount() view returns (uint256)',
  'function getOrder(uint256) view returns ((address trader,uint16 market,bool isLong,bool isIncrease,address token,uint256 collateralDelta,uint256 sizeDelta,uint256 acceptablePrice,uint64 createdAt,uint8 status))',
  'function getMarketConfig(uint16) view returns ((string name,(uint8 source,bytes32 feedId,address feeHook,uint32 twapWindow,uint8 tokenDecimals,uint8 quoteDecimals) price,bool active,bool allowIncreaseWhenClosed,uint16 closedSpreadBps,uint16 maxLeverageX,uint16 maintenanceBps,uint16 openFeeBps,uint16 closeFeeBps,uint16 tensionFeeMaxBps,uint128 maxOiUsd,uint128 borrowRatePerSec))',
  'function positionCount() view returns (uint256)',
  'function positionKeys(uint256) view returns (bytes32)',
  'function positionHealth(bytes32) view returns (int256,int256,uint256,uint256,bool)',
  'function positionMeta(bytes32) view returns (address trader,uint16 market,bool isLong)',
  'function executeOrder(uint256)',
  'function cancelOrder(uint256)',
  'function liquidate(address,uint16,bool)',
]);
const adapterAbi = parseAbi(['function registry() view returns (address)']);
const feeHookAbi = parseAbi(['function currentState() view returns (uint256,uint256,int256,uint24,uint24,bool,bool)']);
// Hooke's own verdict on its oracle. While it says unhealthy, share-market orders wait (and expire to a refund)
// and share-market liquidations pause, so nobody is filled or liquidated on a price Hooke itself distrusts.
const oracleHealthy = feeHook => pub.readContract({ address: feeHook, abi: feeHookAbi, functionName: 'currentState' }).then(s => s[6]).catch(() => false);
const postedAbi = parseAbi([
  'function post(uint256 priceUsd)',
  'function lastPrice() view returns (uint256)',
  'function lastUpdate() view returns (uint256)',
  'function poolSpotPrice() view returns (uint256)',
  'function bandBps() view returns (uint256)',
]);
const registryAbi = parseAbi([
  'function latestPrice(bytes32) view returns (uint256 price,uint64 sourceTime,uint64 publishTime,bool marketOpen,uint64 validUntil,address publisher)',
]);

const account = privateKeyToAccount(env('KEEPER_KEY'));
const chain = { id: 4663, name: 'Robinhood Chain', nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [RPC] } } };
const pub = createPublicClient({ chain, transport: http(RPC), batch: { multicall: true } });
const wallet = createWalletClient({ chain, transport: http(RPC), account });

const log = (...a) => console.log(new Date().toISOString(), ...a);
const lasso = { address: LASSO, abi: lassoAbi };

async function send(fn, args, label) {
  try {
    const { request } = await pub.simulateContract({ ...lasso, functionName: fn, args, account });
    const hash = await wallet.writeContract(request);
    const r = await pub.waitForTransactionReceipt({ hash });
    log(label, fn, args.map(String).join(','), r.status, hash);
    return r.status === 'success';
  } catch (e) {
    log(label, fn, 'skip:', (e.shortMessage ?? e.message).split('\n')[0]);
    return false;
  }
}

// ---- ETH price ----
let lastEthPost = 0;
async function fetchEthPrice() {
  try {
    const r = await fetch(ETH_PRICE_URL, { signal: AbortSignal.timeout(5000) });
    const j = await r.json();
    const v = Number(j?.data?.amount ?? j?.price ?? j?.ethereum?.usd);
    if (v > 0) return v;
  } catch {}
  return null;
}
async function postEthPrice(force = false) {
  if (!ETH_SOURCE) return;
  if (!force && Date.now() - lastEthPost < ETH_POST_MS) return;
  const src = { address: ETH_SOURCE, abi: postedAbi };
  const [pool, band, last] = await Promise.all([
    pub.readContract({ ...src, functionName: 'poolSpotPrice' }),
    pub.readContract({ ...src, functionName: 'bandBps' }),
    pub.readContract({ ...src, functionName: 'lastPrice' }),
  ]);
  let price = await fetchEthPrice();
  let wad = price ? BigInt(Math.round(price * 1e6)) * 10n ** 12n : pool;
  // keep inside the contract's band around the onchain pool, otherwise the post reverts
  if (band > 0n) {
    const lo = pool * (10000n - band) / 10000n, hi = pool * (10000n + band) / 10000n;
    if (wad < lo || wad > hi) { log('eth price', price, 'outside pool band, clamping to pool', formatUnits(pool, 18)); wad = wad < lo ? lo : hi; }
  }
  if (last > 0n && (wad > last ? wad - last : last - wad) * 1000n < last && !force) { lastEthPost = Date.now(); return; }
  try {
    const { request } = await pub.simulateContract({ ...src, functionName: 'post', args: [wad], account });
    const hash = await wallet.writeContract(request);
    await pub.waitForTransactionReceipt({ hash });
    log('posted ETH', formatUnits(wad, 18), hash);
    lastEthPost = Date.now();
  } catch (e) { log('post ETH failed', (e.shortMessage ?? e.message).split('\n')[0]); }
}

// ---- orders ----
const marketCache = new Map();
async function market(id) {
  if (!marketCache.has(id)) marketCache.set(id, await pub.readContract({ ...lasso, functionName: 'getMarketConfig', args: [id] }));
  return marketCache.get(id);
}
let registry, params, nextOrder = 0n;
async function init() {
  const adapter = await pub.readContract({ ...lasso, functionName: 'adapter' });
  registry = await pub.readContract({ address: adapter, abi: adapterAbi, functionName: 'registry' });
  const p = await pub.readContract({ ...lasso, functionName: 'params' });
  params = { minExecDelay: Number(p[0]), orderTtl: Number(p[1]) };
  const n = await pub.readContract({ ...lasso, functionName: 'orderCount' });
  // resume from the first still-pending order
  for (let i = 0n; i < n; i++) {
    const o = await pub.readContract({ ...lasso, functionName: 'getOrder', args: [i] });
    if (o.status === 1) { nextOrder = i; break; }
    nextOrder = i + 1n;
  }
  log('keeper', account.address, 'lasso', LASSO, 'registry', registry, 'resume at order', nextOrder);
}

async function processOrders(now) {
  const n = await pub.readContract({ ...lasso, functionName: 'orderCount' });
  let firstPending = null;
  for (let i = nextOrder; i < n; i++) {
    const o = await pub.readContract({ ...lasso, functionName: 'getOrder', args: [i] });
    if (o.status !== 1) { if (firstPending === null) nextOrder = i + 1n; continue; }
    if (firstPending === null) firstPending = i;
    const created = Number(o.createdAt);
    if (now > created + params.orderTtl) { await send('cancelOrder', [i], 'expired'); continue; }
    const cfg = await market(o.market);
    if (cfg.price.source === 0) {
      if (!(await oracleHealthy(cfg.price.feeHook))) continue;
      const [, , publishTime] = await pub.readContract({ address: registry, abi: registryAbi, functionName: 'latestPrice', args: [cfg.price.feedId] });
      if (Number(publishTime) <= created) continue; // wait for Hooke's next publish
    } else if (now < created + params.minExecDelay) continue;
    await send('executeOrder', [i], 'execute');
  }
}

// ---- liquidations ----
async function processLiquidations() {
  const n = Number(await pub.readContract({ ...lasso, functionName: 'positionCount' }));
  const keys = await Promise.all([...Array(n).keys()].map(i => pub.readContract({ ...lasso, functionName: 'positionKeys', args: [BigInt(i)] })));
  const health = await Promise.all(keys.map(key => pub.readContract({ ...lasso, functionName: 'positionHealth', args: [key] }).catch(() => null)));
  for (const [i, key] of keys.entries()) {
    if (!health[i]?.[4]) continue;
    const meta = await pub.readContract({ ...lasso, functionName: 'positionMeta', args: [key] });
    const cfg = await market(meta[1]);
    if (cfg.price.source === 0 && !(await oracleHealthy(cfg.price.feeHook))) continue;
    await send('liquidate', [meta[0], meta[1], meta[2]], 'liquidate');
  }
}

await init();
await postEthPrice(true);
for (;;) {
  try {
    const block = await pub.getBlock();
    // the next block's timestamp will be at least the wall clock; the chain's last block may be older
    const now = Math.max(Number(block.timestamp), Math.floor(Date.now() / 1000));
    await postEthPrice();
    await processOrders(now);
    await processLiquidations();
  } catch (e) { log('loop error', (e.shortMessage ?? e.message).split('\n')[0]); }
  await new Promise(r => setTimeout(r, POLL_MS));
}
