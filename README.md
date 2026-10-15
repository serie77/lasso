# Lasso — perps on Hooke

Long or short Hooke's tokenized stocks with leverage on Robinhood Chain, and farm `$LASSO` while you do it.

## Mainnet (Robinhood Chain, 4663)

| Contract | Address |
|---|---|
| Lasso (core: pool, orders, positions) | `0xcBBe708dce939f2772B70967c1D0EB8e11b5DC27` |
| LassoFarm (`$LASSO` emissions) | `0xC97493E716190bFC2cc7479ed28041EA295B1695` |
| LLP (LP share token) | `0xBD380F2C9829816EDAc44335a7a081f3cd557FDb` |
| HookePriceAdapter | `0xfF915229f38f74fe57410deB901Efb2ADe684c56` |

Owner, keeper and treasury: `0xb180955C5d1997f570bb085fa9f3c385AC765e92`. Collateral: USDG only.

## Markets

| Market | Priced off | Trades | Max lev |
|---|---|---|---|
| `XMAX` | Hooke oracle (the real share) | while the stock market is open; closes always fill (0.5% spread when closed) | 10x |
| `hXMAX` | Hooke pool spot vs 30-min TWAP (worse one for you) | 24/7 | 5x |

OI caps per side: XMAX $1M, hXMAX $100k (`script/SetOiCap.s.sol` changes them). Both markets on one stock is the
point: short hXMAX + long XMAX = short the token premium, the trade Hooke's dynamic tax is designed around.

**Other Hooke tokens.** Hooke memes (35 launched, 1 graduated: WOLFPACK) trade only in their own hXMAX pool, with no
TWAP in the meme hook and ~$75k of depth against a $2M market cap. A perp on that is manipulable at any fee or cap,
so Lasso does not list memes until a pool is deep enough. Meme holders are implicitly long XMAX; shorting hXMAX
hedges that today.

## How it works

- **Pool vs trader.** LPs deposit USDG and get LLP. The pool takes the other side of every position. It earns 80% of
  fees (open, close, tension, borrow) plus traders' losses, and it pays their profits. Treasury takes 20% of fees.
- **Two-step orders.** You place an order. A keeper fills it at the first Hooke price *published after* your order.
  Slippage, a closed market or limits cancel the order and refund you instead of reverting.
- **Tension fee.** 0.10% when your trade pulls open interest toward balance, up to +0.50% at 100% skew.
- **Liquidation.** Below 1% (XMAX) / 2% (hXMAX) equity. Anyone can liquidate, for a $1 reward.

## Farming $LASSO (Season 1)

10,000,000 `$LASSO` over 30 days, accrued onchain as 1:1 claims on the token, which launches later on Hooke.

- **Liquidity: 6,000,000** (`lpRate` ≈ 2.3148 / s). Pro-rata to LLP balance every second. Holding is enough:
  LLP reports every mint, burn and transfer to the farm, so there's no staking step and transfers carry only future
  rewards.
- **Trading: 4,000,000** (`tradeRate` ≈ 1.5432 / s). Grouped into UTC days. Each day's emission is
  `tradeRate × seconds of that day inside the season`, split by fees each trader paid that day. Claimable at
  00:00 UTC. Points are bought with fees that go to LPs, so wash trading costs real money.

Guarantees, all tested (27 forge tests, including a fuzz test with 10,000 runs over random mints, burns, transfers,
fees and time jumps):
- Every share rounds down: `Σ claimable ≤ totalEmitted()` always.
- No emission while nobody holds LLP. No backfill if the season is extended after it ended.
- `totalEmitted()` never exceeds the season budget.

**At token launch:** `farm.setLasso(token)` (one time, can't be changed), transfer `farm.totalEmitted()` (after the
season, ≤ 10M) to the farm, and users hit Claim.

## Run it

```sh
# tests (fork of live Robinhood Chain + farm unit/fuzz)
forge test

# end to end on an anvil fork with the real deploy script + keeper
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port 8545 --block-time 1
cd keeper && npm i && node e2e.mjs
```

Secrets live in `.env` (copy `.env.example`); it is gitignored, as is `web/config.js`.

**Keeper (must run 24/7 or orders never fill).** Self-contained, no build needed. On Railway: root `keeper/`, start
`npm start`, env `KEEPER_KEY`, `LASSO=0xcBBe708dce939f2772B70967c1D0EB8e11b5DC27`. Each fill costs ~$0.03 in gas.

**Site (Cloudflare Pages, lassodex.fun).** `web/` is static with clean URLs: `/` (landing), `/trade`, `/earn`,
`/farm` (one page, `trade.html`, routed by path via `_redirects`), `/docs`. `web/functions/rpc.js` serves `/rpc`, a read-only proxy to Alchemy, so the key stays server-side.
Pages settings: root directory `web`, build command `node gen-config.mjs`, output directory `.`, env vars
`RPC_URL=https://lassodex.fun/rpc` and `ALCHEMY_URL` (encrypted, the full Alchemy URL). Locally: copy
`web/config.example.js` to `web/config.js`, then `node serve-web.mjs` (behaves like Pages).

**Brand.** `brand/lasso-avatar.png` (1000×1000), `brand/lasso-banner.png` (3000×1000), `brand/mark.svg`.

## Layout

```
src/Lasso.sol              core: pool, orders, positions, liquidation
src/LassoFarm.sol          $LASSO emissions for LPs and traders
src/LassoLP.sol            LLP share token, reports balance changes to the farm
src/HookePriceAdapter.sol  prices from Hooke's oracle registry + fee hook (spot/TWAP)
src/price/*                collateral prices (USDG fixed $1; posted ETH price, unused on mainnet)
script/Deploy.s.sol        deploys + configures everything
script/SetOiCap.s.sol      change a market's OI cap (LASSO, MARKET, MAX_OI_USD env)
keeper/keeper.mjs          fills orders, liquidates
web/                       landing, app, docs (static)
```

## Known limits

- One oracle publisher (Hooke's). If it stops, XMAX prices go stale and trading halts until it resumes.
- Admin is a single EOA (can change markets, params, price sources). Move to a multisig before the pool grows.
- Leveraged equity exposure is regulated; geofence before opening to the public. Get an audit before large LP money.
