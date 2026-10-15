// End-to-end on an anvil fork of Robinhood Chain: deploys with the real script, runs the real keeper as a child
// process, trades through the contracts, simulates Hooke oracle publishes by writing the registry's storage, and
// checks every outcome. Usage: anvil --fork-url <RPC> --port 8545  (then)  node e2e.mjs
import { createPublicClient, createWalletClient, http, parseAbi, formatUnits, parseUnits, keccak256, encodeAbiParameters, toHex, pad, concat } from 'viem';
import { privateKeyToAccount, generatePrivateKey } from 'viem/accounts';
import { spawn, execSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const RPC = process.env.RPC ?? 'http://127.0.0.1:8545';
const A = {
  USDG: '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168',
  POOL_MANAGER: '0x8366a39CC670B4001A1121B8F6A443A643e40951',
  REGISTRY: '0x33c5341DC45E389B2A993F4599649D121646240C',
  FEE_HOOK: '0xb51d89BBc50B5AE469be8CFbF305CAb6ff3A50Cc',
  FEED: '0xd87eb24cefadd05cc0a3e9ae61754d652fc1444f24d4ccffca82357bec14943b',
};
// anvil default keys for deployer + keeper; fresh random keys for traders (anvil's well-known addresses can carry
// code on a mainnet fork — account #4 does on Robinhood Chain and forwards any ETH it receives)
const KEYS = [
  '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80',
  '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d',
  generatePrivateKey(),
  generatePrivateKey(),
  generatePrivateKey(),
];
const [deployer, keeper, lp, alice, bob] = KEYS.map(k => privateKeyToAccount(k));
const chain = { id: 4663, name: 'anvil-robinhood', nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [RPC] } } };
const pub = createPublicClient({ chain, transport: http(RPC) });
const wallets = Object.fromEntries([deployer, keeper, lp, alice, bob].map(a => [a.address, createWalletClient({ chain, transport: http(RPC), account: a })]));

const erc20 = parseAbi(['function transfer(address,uint256) returns (bool)', 'function approve(address,uint256) returns (bool)', 'function balanceOf(address) view returns (uint256)']);
const registryAbi = parseAbi(['function latestPrice(bytes32) view returns (uint256,uint64,uint64,bool,uint64,address)']);
const hookAbi = parseAbi(['function currentState() view returns (uint256,uint256,int256,uint256,uint256,bool,bool)']);

let failures = 0;
const ok = (cond, msg, extra = '') => { console.log(`${cond ? '  PASS' : '  FAIL'} ${msg}${extra ? ' — ' + extra : ''}`); if (!cond) failures++; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const fmt = (v, d = 6) => Number(formatUnits(v, d)).toFixed(d === 6 ? 2 : 5);

// ---------- 1. deploy with the real script ----------
console.log('\n[1] deploy');
execSync(`forge script script/Deploy.s.sol --rpc-url ${RPC} --broadcast --private-key ${KEYS[0]} -q`, {
  cwd: root, stdio: 'inherit', env: { ...process.env, PRIVATE_KEY: KEYS[0], KEEPER: keeper.address, TREASURY: deployer.address },
});
const dep = JSON.parse(readFileSync(join(root, 'deployments', '4663.json')));
const lassoAbi = JSON.parse(readFileSync(join(root, 'out', 'Lasso.sol', 'Lasso.json'))).abi;
const farmAbi = JSON.parse(readFileSync(join(root, 'out', 'LassoFarm.sol', 'LassoFarm.json'))).abi;
const T = { address: dep.lasso, abi: lassoAbi };
const F = { address: dep.farm, abi: farmAbi };
console.log('  Lasso', dep.lasso, 'farm', dep.farm);

// ---------- 2. fund actors ----------
console.log('\n[2] fund');
for (const a of [lp, alice, bob, keeper]) await pub.request({ method: 'anvil_setBalance', params: [a.address, toHex(100n * 10n ** 18n)] });
await pub.request({ method: 'anvil_impersonateAccount', params: [A.POOL_MANAGER] });
await pub.request({ method: 'anvil_setBalance', params: [A.POOL_MANAGER, toHex(10n ** 18n)] });
for (const [to, amt] of [[lp.address, 300_000n * 10n ** 6n], [alice.address, 50_000n * 10n ** 6n], [bob.address, 50_000n * 10n ** 6n]]) {
  const data = `0xa9059cbb${pad(to).slice(2)}${pad(toHex(amt)).slice(2)}`;
  const h = await pub.request({ method: 'eth_sendTransaction', params: [{ from: A.POOL_MANAGER, to: A.USDG, data }] });
  await pub.waitForTransactionReceipt({ hash: h });
}
ok((await pub.readContract({ address: A.USDG, abi: erc20, functionName: 'balanceOf', args: [lp.address] })) >= 300_000n * 10n ** 6n, 'USDG funded');

const w = async (acct, fn, args, value = 0n, c = T) => {
  const { request } = await pub.simulateContract({ ...c, functionName: fn, args, account: acct, value });
  const hash = await wallets[acct.address].writeContract(request);
  return pub.waitForTransactionReceipt({ hash });
};
const r = (fn, args = []) => pub.readContract({ ...T, functionName: fn, args });

// ---------- 3. start the real keeper ----------
console.log('\n[3] keeper');
const kp = spawn(process.execPath, [join(here, 'keeper.mjs')], {
  env: { ...process.env, RPC, KEEPER_KEY: KEYS[1], LASSO: dep.lasso, POLL_MS: '1000' },
  stdio: ['ignore', 'pipe', 'pipe'],
});
kp.stdout.on('data', d => process.stdout.write('  [keeper] ' + d));
kp.stderr.on('data', d => process.stdout.write('  [keeper!] ' + d));
await sleep(4000);

// ---------- oracle simulation: write Hooke's registry slot the way its publisher would ----------
const base = BigInt(keccak256(encodeAbiParameters([{ type: 'bytes32' }, { type: 'uint256' }], [A.FEED, 3n])));
async function publish(priceWad, open = true) {
  const now = BigInt((await pub.getBlock()).timestamp) + 1n;
  const packed = (now - 1n) | (now << 64n) | ((open ? 1n : 0n) << 128n) | ((now + 15n) << 136n);
  await pub.request({ method: 'anvil_setStorageAt', params: [A.REGISTRY, toHex(base, { size: 32 }), toHex(priceWad, { size: 32 })] });
  await pub.request({ method: 'anvil_setStorageAt', params: [A.REGISTRY, toHex(base + 1n, { size: 32 }), toHex(packed, { size: 32 })] });
  await pub.request({ method: 'evm_mine', params: [] });
  const [p, , pub2, o] = await pub.readContract({ address: A.REGISTRY, abi: registryAbi, functionName: 'latestPrice', args: [A.FEED] });
  if (p !== priceWad || pub2 !== now || o !== open) throw new Error('registry storage write did not take');
}
const waitOrder = async (id, timeoutMs = 30000) => {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    const o = await r('getOrder', [id]);
    if (o.status !== 1) return o;
    await sleep(500);
  }
  throw new Error(`order ${id} not processed`);
};
const solvent = async () => {
  const usdgOwed = (await r('poolAmount', [A.USDG])) + (await r('collateralHeld', [A.USDG])) + (await r('escrowed', [A.USDG])) + (await r('protocolFees', [A.USDG]));
  const usdgBal = await pub.readContract({ address: A.USDG, abi: erc20, functionName: 'balanceOf', args: [dep.lasso] });
  ok(usdgBal >= usdgOwed, 'solvency: contract holds everything it owes', `USDG ${fmt(usdgBal)} >= ${fmt(usdgOwed)}`);
};

try {
  // ---------- 4. liquidity ----------
  console.log('\n[4] liquidity');
  await w(lp, 'approve', [dep.lasso, 2n ** 256n - 1n], 0n, { address: A.USDG, abi: erc20 });
  await w(lp, 'deposit', [A.USDG, 200_000n * 10n ** 6n]);
  const lpShares = await pub.readContract({ address: await r('lp'), abi: erc20, functionName: 'balanceOf', args: [lp.address] });
  const poolValue = await r('poolValueUsd');
  ok(lpShares > 0n, 'LP shares minted', formatUnits(lpShares, 18));
  ok(poolValue === 200_000n * 10n ** 18n, 'pool value = full deposit (the 0.1% fee stays in the pool)', '$' + fmt(poolValue, 18));
  ok(lpShares === 199_800n * 10n ** 18n, 'first LP gets 1 LLP per $1 net of fee', formatUnits(lpShares, 18));
  const ethEnabled = (await r('tokens', ['0x0000000000000000000000000000000000000000']))[0];
  ok(!ethEnabled, 'USDG-only: ETH collateral disabled');

  // ---------- 5. long XMAX with USDG, executed by the keeper after a fresh oracle publish ----------
  console.log('\n[5] long XMAX (oracle market)');
  await w(alice, 'approve', [dep.lasso, 2n ** 256n - 1n], 0n, { address: A.USDG, abi: erc20 });
  // Hooke's publisher refreshes every ~9s on mainnet; on the fork we do it ourselves with the current stored price
  const storedPrice = BigInt(await pub.getStorageAt({ address: A.REGISTRY, slot: toHex(base, { size: 32 }) }));
  await publish(storedPrice);
  const [[mark]] = [await r('markPrice', [0])];
  await w(alice, 'createOrder', [0, true, true, A.USDG, 1_000n * 10n ** 6n, 5_000n * 10n ** 18n, 2n ** 255n]);
  await sleep(2500);
  let o = await r('getOrder', [0n]);
  ok(o.status === 1, 'order waits for the next Hooke publish (keeper did not execute on the stale price)');
  await publish(mark);
  o = await waitOrder(0n);
  ok(o.status === 2, 'keeper executed after the publish');
  const keyA = await r('positionKey', [alice.address, 0, true]);
  let pos = await r('getPosition', [keyA]);
  ok(pos.size === 5_000n * 10n ** 18n && pos.collateral === 970n * 10n ** 6n, 'position opened: $5000 long, 970 USDG collateral after $30 fees', `entry $${fmt(pos.entryPrice, 18)}`);

  // ---------- 6. short hXMAX (pool market, no oracle needed) ----------
  console.log('\n[6] short hXMAX (pool market)');
  await w(bob, 'approve', [dep.lasso, 2n ** 256n - 1n], 0n, { address: A.USDG, abi: erc20 });
  await w(bob, 'createOrder', [1, false, true, A.USDG, 1_000n * 10n ** 6n, 4_000n * 10n ** 18n, 1n]);
  o = await waitOrder(1n);
  ok(o.status === 2, 'executed after minExecDelay');
  const keyB = await r('positionKey', [bob.address, 1, false]);
  pos = await r('getPosition', [keyB]);
  const [spot] = await pub.readContract({ address: A.FEE_HOOK, abi: hookAbi, functionName: 'currentState' });
  ok(pos.size === 4_000n * 10n ** 18n, 'hXMAX short open', `entry $${fmt(pos.entryPrice, 18)} vs Hooke spot $${fmt(spot, 18)}`);

  // ---------- 7. stock +10%, alice closes in profit ----------
  console.log('\n[7] XMAX +10%, close long');
  await publish(mark * 110n / 100n);
  const [equity, pnl, , , liq] = await r('positionHealth', [keyA]);
  ok(pnl > 499n * 10n ** 18n && pnl < 501n * 10n ** 18n && !liq, 'unrealized pnl ≈ +$500', `pnl $${fmt(pnl, 18)} equity $${fmt(equity, 18)}`);
  const aBefore = await pub.readContract({ address: A.USDG, abi: erc20, functionName: 'balanceOf', args: [alice.address] });
  await w(alice, 'createOrder', [0, true, false, A.USDG, 0n, 5_000n * 10n ** 18n, 1n]);
  await sleep(1500);
  await publish(mark * 110n / 100n); // next publish, same price
  o = await waitOrder(2n);
  const aGot = (await pub.readContract({ address: A.USDG, abi: erc20, functionName: 'balanceOf', args: [alice.address] })) - aBefore;
  ok(o.status === 2 && aGot > 1_463n * 10n ** 6n && aGot < 1_466n * 10n ** 6n, 'alice received collateral + profit - fees ≈ 1465 USDG', fmt(aGot) + ' USDG');
  ok((await r('getPosition', [keyA])).size === 0n, 'position closed');

  // ---------- 8. bob closes the ETH short ----------
  console.log('\n[8] close hXMAX short');
  const bBefore = await pub.readContract({ address: A.USDG, abi: erc20, functionName: 'balanceOf', args: [bob.address] });
  await w(bob, 'createOrder', [1, false, false, A.USDG, 0n, 4_000n * 10n ** 18n, 2n ** 255n]);
  o = await waitOrder(3n);
  const bGot = (await pub.readContract({ address: A.USDG, abi: erc20, functionName: 'balanceOf', args: [bob.address] })) - bBefore;
  ok(o.status === 2 && bGot > 900n * 10n ** 6n && bGot < 1_000n * 10n ** 6n, 'bob got his USDG back minus fees (flat price)', fmt(bGot) + ' USDG');
  ok((await r('getPosition', [keyB])).size === 0n && (await r('totalOi')) === 0n, 'no open interest left');

  // ---------- 9. liquidation ----------
  console.log('\n[9] liquidation');
  await w(bob, 'createOrder', [0, true, true, A.USDG, 1_000n * 10n ** 6n, 9_000n * 10n ** 18n, 2n ** 255n]);
  await sleep(1500);
  await publish(mark);
  o = await waitOrder(4n);
  ok(o.status === 2, '9x long opened');
  const keyC = await r('positionKey', [bob.address, 0, true]);
  const kBefore = await pub.readContract({ address: A.USDG, abi: erc20, functionName: 'balanceOf', args: [keeper.address] });
  await publish(mark * 90n / 100n);
  const t0 = Date.now();
  while ((await r('getPosition', [keyC])).size !== 0n && Date.now() - t0 < 30000) await sleep(500);
  const kGot = (await pub.readContract({ address: A.USDG, abi: erc20, functionName: 'balanceOf', args: [keeper.address] })) - kBefore;
  ok((await r('getPosition', [keyC])).size === 0n, 'keeper liquidated the underwater long after -10%');
  ok(kGot === 1n * 10n ** 6n, 'liquidator reward $1 paid', fmt(kGot) + ' USDG');

  // ---------- 10. closed market ----------
  console.log('\n[10] closed market');
  await publish(mark, false);
  await w(alice, 'createOrder', [0, true, true, A.USDG, 1_000n * 10n ** 6n, 5_000n * 10n ** 18n, 2n ** 255n]);
  await sleep(1500);
  await publish(mark, false);
  o = await waitOrder(5n);
  ok(o.status === 3, 'new risk while the stock market is closed is cancelled and refunded');
  await publish(mark, true);

  // ---------- 11. $LASSO farm ----------
  console.log('\n[11] farm');
  const [lpEarned] = await pub.readContract({ ...F, functionName: 'earned', args: [lp.address] });
  ok(lpEarned > 0n, 'LP accrues $LASSO by holding LLP', fmt(lpEarned, 18));
  const [aNow, aToday] = await pub.readContract({ ...F, functionName: 'earned', args: [alice.address] });
  const [, bToday] = await pub.readContract({ ...F, functionName: 'earned', args: [bob.address] });
  ok(aToday + aNow > 0n && bToday > 0n, "traders hold a share of the day's trading emission", `alice ${fmt(aToday + aNow, 18)}, bob ${fmt(bToday, 18)}`);
  await pub.request({ method: 'evm_increaseTime', params: [toHex(86400)] });
  await pub.request({ method: 'evm_mine', params: [] });
  const [aClaimable] = await pub.readContract({ ...F, functionName: 'earned', args: [alice.address] });
  ok(aClaimable >= aToday + aNow, 'trading share becomes claimable after the UTC day ends', fmt(aClaimable, 18));
  const emitted = await pub.readContract({ ...F, functionName: 'totalEmitted' });
  ok(emitted >= lpEarned + aClaimable, 'farm owes no more than it emitted', fmt(emitted, 18));
  await publish(mark); // keep the oracle fresh after the time jump

  // ---------- 12. LP exits fully ----------
  console.log('\n[12] LP withdraw everything');
  const lpUsdgBefore = await pub.readContract({ address: A.USDG, abi: erc20, functionName: 'balanceOf', args: [lp.address] });
  const expected = (await r('poolValueUsd')) / 10n ** 12n * 999n / 1000n;
  await w(lp, 'withdraw', [lpShares, A.USDG]);
  const lpGot = (await pub.readContract({ address: A.USDG, abi: erc20, functionName: 'balanceOf', args: [lp.address] })) - lpUsdgBefore;
  ok(lpGot + 1n >= expected && lpGot > 200_000n * 10n ** 6n, 'LP withdrew all shares, with trader losses + fees on top', fmt(lpGot) + ' USDG');
  const llpLeft = await pub.readContract({ address: await r('lp'), abi: erc20, functionName: 'balanceOf', args: [lp.address] });
  ok(llpLeft === 0n, 'LP holds no LLP after full exit');
  const fees = await r('protocolFees', [A.USDG]);
  ok(fees > 0n, 'protocol fees accrued', fmt(fees) + ' USDG');
  await solvent();
} catch (e) {
  failures++;
  console.log('  ERROR', e.shortMessage ?? e.message);
} finally {
  kp.kill();
}
console.log(`\n${failures === 0 ? 'ALL CHECKS PASSED' : failures + ' CHECK(S) FAILED'}`);
process.exit(failures === 0 ? 0 : 1);
