// Live smoke test on mainnet with tiny size: opens and closes a long and a short on hXMAX, tries an XMAX long
// (refunded while the stock market is closed), then withdraws the LP seed. Needs the keeper running.
// env: RPC, KEEPER_KEY (same funded wallet), LASSO, COLLATERAL_USDG (6 dec), SIZE_USD (whole dollars)
import { createPublicClient, createWalletClient, http, parseAbi, formatUnits } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const RPC = process.env.RPC || 'https://rpc.mainnet.chain.robinhood.com';
const LASSO = process.env.LASSO;
const USDG = '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168';
const COLLATERAL = BigInt(process.env.COLLATERAL_USDG ?? '6500000');
const SIZE = BigInt(process.env.SIZE_USD ?? '10') * 10n ** 18n;

const abi = parseAbi([
  'function createOrder(uint16,bool,bool,address,uint256,uint256,uint256) payable returns (uint256)',
  'function orderCount() view returns (uint256)',
  'function getOrder(uint256) view returns ((address trader,uint16 market,bool isLong,bool isIncrease,address token,uint256 collateralDelta,uint256 sizeDelta,uint256 acceptablePrice,uint64 createdAt,uint8 status))',
  'function positionKey(address,uint16,bool) view returns (bytes32)',
  'function getPosition(bytes32) view returns ((uint256 size,uint256 collateral,uint256 entryPrice,uint256 entryBorrowIndex,address token))',
  'function markPrice(uint16) view returns (uint256,bool)',
  'function withdraw(uint256,address) returns (uint256)',
  'function lp() view returns (address)',
  'function totalOi() view returns (uint256)',
  'function poolAmount(address) view returns (uint256)',
  'function collateralHeld(address) view returns (uint256)',
  'function escrowed(address) view returns (uint256)',
  'function protocolFees(address) view returns (uint256)',
  'event OrderCancelled(uint256 indexed id, string reason)',
]);
const erc20 = parseAbi(['function balanceOf(address) view returns (uint256)']);
const farmAbi = parseAbi(['function earned(address) view returns (uint256,uint256)', 'function traderFees(address) view returns (uint256)']);

const account = privateKeyToAccount(process.env.KEEPER_KEY);
const chain = { id: 4663, name: 'Robinhood Chain', nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [RPC] } } };
const pub = createPublicClient({ chain, transport: http(RPC) });
const wallet = createWalletClient({ chain, transport: http(RPC), account });
const L = { address: LASSO, abi };
const r = (functionName, args = []) => pub.readContract({ ...L, functionName, args });
const usdg = () => pub.readContract({ address: USDG, abi: erc20, functionName: 'balanceOf', args: [account.address] });
const $ = (v, d = 6) => Number(formatUnits(v, d)).toFixed(4);
const sleep = ms => new Promise(res => setTimeout(res, ms));
let failures = 0;
const ok = (c, msg, extra = '') => { console.log(`${c ? '  PASS' : '  FAIL'} ${msg}${extra ? ' — ' + extra : ''}`); if (!c) failures++; };

async function send(fn, args) {
  const { request } = await pub.simulateContract({ ...L, functionName: fn, args, account });
  const hash = await wallet.writeContract(request);
  const rc = await pub.waitForTransactionReceipt({ hash });
  if (rc.status !== 'success') throw new Error(`${fn} reverted ${hash}`);
  return { hash, rc };
}
async function order(market, isLong, isIncrease, collateral, size, acceptable) {
  const id = await r('orderCount');
  const { hash } = await send('createOrder', [market, isLong, isIncrease, USDG, collateral, size, acceptable]);
  console.log(`  order #${id} ${isIncrease ? 'open' : 'close'} ${isLong ? 'long' : 'short'} market ${market} · ${hash}`);
  const t0 = Date.now();
  for (;;) {
    const o = await r('getOrder', [id]);
    if (o.status !== 1) return { id, status: o.status };
    if (Date.now() - t0 > 7 * 60_000) throw new Error(`order ${id} not processed`);
    await sleep(1500);
  }
}
async function solvent() {
  const owed = (await r('poolAmount', [USDG])) + (await r('collateralHeld', [USDG])) + (await r('escrowed', [USDG])) + (await r('protocolFees', [USDG]));
  const bal = await pub.readContract({ address: USDG, abi: erc20, functionName: 'balanceOf', args: [LASSO] });
  ok(bal >= owed, 'contract holds everything it owes', `${$(bal)} >= ${$(owed)} USDG`);
}

const MAX = 2n ** 255n;
const start = await usdg();
console.log(`wallet ${account.address} · USDG ${$(start)}`);

for (const isLong of [true, false]) {
  const side = isLong ? 'long' : 'short';
  console.log(`\n[hXMAX ${side}]`);
  const before = await usdg();
  const open = await order(1, isLong, true, COLLATERAL, SIZE, isLong ? MAX : 1n);
  ok(open.status === 2, `${side} opened by keeper`);
  const key = await r('positionKey', [account.address, 1, isLong]);
  const p = await r('getPosition', [key]);
  ok(p.size === SIZE, `position size $${formatUnits(SIZE, 18)}`, `collateral ${$(p.collateral)} USDG, entry $${$(p.entryPrice, 18)}`);
  const close = await order(1, isLong, false, 0n, SIZE, isLong ? 1n : MAX);
  ok(close.status === 2, `${side} closed by keeper`);
  ok((await r('getPosition', [key])).size === 0n, 'position gone');
  const back = await usdg();
  ok(back > before - COLLATERAL / 10n, `${side} round trip returned collateral minus fees and spread`, `paid ${$(before - back)} USDG`);
  await solvent();
}

console.log('\n[XMAX long]');
const [, open] = await r('markPrice', [0]);
const before = await usdg();
const x = await order(0, true, true, COLLATERAL, SIZE, MAX);
if (open) {
  ok(x.status === 2, 'XMAX long opened (market open)');
  const c = await order(0, true, false, 0n, SIZE, 1n);
  ok(c.status === 2, 'XMAX long closed');
} else {
  ok(x.status === 3, 'XMAX long cancelled while the stock market is closed');
  ok((await usdg()) === before, 'collateral refunded in full', `${$(await usdg())} USDG`);
}
await solvent();

console.log('\n[farm]');
const farm = '0xC97493E716190bFC2cc7479ed28041EA295B1695';
const [claimable, today] = await pub.readContract({ address: farm, abi: farmAbi, functionName: 'earned', args: [account.address] });
const fees = await pub.readContract({ address: farm, abi: farmAbi, functionName: 'traderFees', args: [account.address] });
ok(claimable > 0n, 'LP $LASSO accruing', $(claimable, 18));
ok(fees > 0n && today > 0n, "trading fees counted toward today's $LASSO", `fees $${$(fees, 18)}, today ${$(today, 18)} LASSO`);

console.log('\n[LP withdraw]');
ok((await r('totalOi')) === 0n, 'no open interest left');
const lpToken = await r('lp');
const shares = await pub.readContract({ address: lpToken, abi: erc20, functionName: 'balanceOf', args: [account.address] });
const pre = await usdg();
await send('withdraw', [shares, USDG]);
const got = (await usdg()) - pre;
ok(got > 0n, 'withdrew all LLP', `${$(got)} USDG`);
await solvent();

const end = await usdg();
console.log(`\nUSDG start ${$(start)} → end ${$(end)} (spent ${$(start - end)})`);
console.log(failures ? `${failures} CHECK(S) FAILED` : 'ALL LIVE CHECKS PASSED');
process.exit(failures ? 1 : 0);
