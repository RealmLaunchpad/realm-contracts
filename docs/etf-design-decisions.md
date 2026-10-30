# ETF design decisions and open items

Decisions on `RealmEtf*` (`src/etf/`) taken while comparing with Lots (lotsonchain.com, a Robinhood-chain basket protocol). Core requirement: ETF shares must be pairable as a quote asset for Realm tokens.

## Status

| Item | Status |
|---|---|
| Rebalance modes (`FIXED` / `REBALANCE` / `FLEXIBLE`) | Built |
| Keeper-executed rebalances at a random time | Built (propose/execute on chain; the random timing is keeper policy) |
| `sunset()` + `reinvest()` for dead components | Built (`reinvest` keeper-gated, see below) |
| JIT liquidity in the hook pool + `HookSwap` event | Built; math and proofs in `docs/etf-jit-math.md` |
| `redeemInKind` reverts on a failed transfer; explicit `skipMask` to forfeit | Built (4-arg `redeemInKind` overload) |
| Exact-output BUYS through the hook (ERC-4626 `mint()`) | Built |
| Exact-output SELLS | Stay reverting (`ExactOutputNotSupported`) |
| 0.05% exit fee to the creator, in shares (`EXIT_FEE_BPS`, `ExitFeeCharged`) | Built: the fee shares move to the creator instead of being redeemed, so NAV per share is unchanged; no USDG accounting, no claim, no `reinvest` conflict, and a USDG-frozen creator cannot block exits. None while ownership is renounced |
| NAV-priced venue in `RealmAssetsWhitelist` | Built (`Venue.VAULT`): ETF shares as launch quotes are priced at NAV through USDG. `RealmEtfFactory` (a whitelist approver) lists every ETF it creates with a hook, no human review: its depth is its components', already vetted in `RealmEtfAssets`; approvers can still delist one. The hook pool's `slot0` is unsafe to price from: it only re-prints the last fill, so a price pushed there (component pools flash-pushed around a ~1 USDG trade) stays until the next trade, with no arbitrage to pull it back, and a keeper refresh would snapshot it |
| Fair-mark (NAV) display | Optional frontend view, no contract change |

## Rebalance modes

One immutable mode per ETF, chosen at creation, so depositors pick their trust level:

- `FIXED`: the creator can change nothing; weights drift with prices only.
- `REBALANCE`: the creator rebalances among the ETF's ORIGINAL assets only. The original set is recorded at creation, so an asset sold to zero can be bought back.
- `FLEXIBLE`: rebalance plus new assets, from `RealmEtfAssets`-listed assets only.

## Rebalance manipulation risk

**The attack.** Before intents, the creator called `rebalance` directly with their own `minOut`. In one transaction they could push the target pool (flash loan), rebalance into the pushed price, and unwind, keeping the difference. Deep pools do not stop this: a flash loan supplies the capital, and the vault's loss scales with the rebalance size, not the attacker's capital.

**Mitigation: propose, then a keeper executes at a random time.** The creator proposes a rebalance; a keeper executes it at an unpredictable moment within the next hour. Effects:

- Flash loans no longer work: they live inside one transaction, and the attacker cannot know the execution block.
- To profit, the attacker must hold a pushed price across many blocks (100 ms blocks, so ~36,000 in an hour) while arbitrageurs trade it back. On deep pools that costs far more than the rebalance can yield.
- No public mempool on Robinhood, so the keeper transaction cannot be front-run.
- The creator submits only an intent: sell a share (bps) of asset A's holding for as much asset B as possible. No `minOut` from the creator. Bps, not an amount, so deposits and redemptions in between do not make the intent stale.
- The keeper executes with `minOut = 0` (no public mempool, so no sandwich). Partial fills still revert (`InsufficientLiquidity`). The keeper quotes off-chain first and defers execution if the impact looks wrong (drained or pushed pool); that check lives in the keeper, not the contract.

**Residual risk.** A creator can still back-run the keeper's rebalance to capture its own price impact. That is bounded by the rebalance's slippage on a deep pool. If needed, cap the size of each executed rebalance (or split it into chunks) so the impact per execution stays small.

**Asset eligibility follows the mode.** `REBALANCE` and `FLEXIBLE` ETFs may only hold very liquid assets (stricter depth tier), since holding a manipulated price over time is only expensive on deep pools. `FIXED` ETFs have no rebalances to manipulate and may use a wider asset list.

## In-kind redemption

`redeemInKind` reverts when any transfer fails (paused token, blacklisted receiver). The 4-arg overload takes a `skipMask` of assets the redeemer explicitly forfeits: their slice stays in the vault for the remaining holders. An earlier version skipped failed transfers silently, so a user redeeming during a TEMPORARY pause lost that asset for good without choosing to.

## Exact-output trades

- Buys: to mint exactly N shares, each holding must grow by `ceil(N * balance_i / supply)`. Buy those exact amounts with exact-output swaps (V3 and V4 both support it); the USDG paid is the sum. This implements ERC-4626 `mint()` and lets the hook accept exact-output buys, which routers need for "buy exactly N Realm tokens" through the ETF.
- Hook flow: the USDG input is the unspecified side and only known after `mint`, so the hook `take`s twice `mint`'s spot estimate plus `MINT_LOAN_PAD` (1 USDG), `mint` pulls each leg's cost from the hook, and the hook settles the rest straight back. Not the pool manager's whole balance: a component pool's hook that moves USDG mid-swap would find none. Ceiling: the pool manager must hold the mint's cost in USDG (the exact-input buy has the same kind of ceiling), and fees plus impact past 2x revert.
- Sells: exact USDG out has no one-pass solution (oversell, then buy shares back). Not built.

## Dead component (agreed)

If one asset can never trade again (stock delisted or acquired, token permanently paused), every deposit, USDG redemption and hook swap reverts, since each trades every holding. Only `redeemInKind` works. The creator cannot rebalance out: that trades through the same dead route. A broken POOL is already fixable by replacing the route in `RealmEtfAssets`; a dead TOKEN is not.

Fix:

- `sunset(asset)` on `RealmEtfAssets`, owner (cold multisig) only, one-way. A sunset asset is excluded from deposits, USDG redemptions and `totalAssets`, but stays in `redeemInKind`, so a revived token still reaches holders.
- Known leak: deposits price new shares on the live holdings only, yet every share redeems its slice of a sunset asset's balance in kind, so a deposit made after the sunset (flash loan, `redeemInKind`, sell the live slice) takes part of that balance for free; with every asset sunset, `mint()` buys nothing and takes it for 0 USDG. Accepted: sunset is for tokens that can no longer move, and a token whose transfers revert leaks nothing. Sunsetting a token that still transfers (a malicious or mistaken owner) cuts NAV and opens this leak.
- Companion `reinvest()`: USDG that lands in the vault outside a deposit (a cash payout for an acquired stock, an airdrop) is uncounted today. Buying the live holdings pro-rata with it, minting no shares, hands it to holders.
- `reinvest()` is keeper-gated, not permissionless: it trades the holders' USDG with no floor, so a public caller could push a pool, reinvest into it and unwind in one transaction (the rebalance attack). No minimum amount: it mints no shares, so `MIN_SLICE` has nothing to protect; a holding whose slice rounds to 0 is not bought.

## Price display

With JIT liquidity the pool manager's `Swap` events and `slot0` carry the trade price, so scanners and the indexer price the ETF like any token. Buys print slightly above NAV and sells slightly below (component slippage): a normal spread. NAV per share stays available as a view, `convertToAssets(1e18)`, for an optional premium/discount display in the frontend.

## Scanner visibility: JIT liquidity

Without JIT, the ETF/USDG hook pool holds no liquidity and `beforeSwap` takes the whole input, so the pool manager emits its `Swap` for that pool with zero amounts and an unchanged price: the USDG <-> ETF leg is invisible to scanners. A standing position (Lots' approach) needs hook-owned capital and is not wanted. Built instead: JIT liquidity plus the `HookSwap` event of Uniswap's `IAggregatorHook`, which the hook implements in full (`quote` from the ETF's previews, `pseudoTotalValueLocked` = NAV in USDG and share supply, `AggregatorPoolRegistered` at pool creation) so Uniswap's routing and indexing can treat the pool like its own aggregator hooks. It does not implement `protocolFeeFlags`: self-reporting the aggregator flag puts the pool in Uniswap's aggregator fee family (40 pips per direction on Robinhood, 2026-10-22), and any protocol fee turns JIT off. Sizing, rounding and proofs: `docs/etf-jit-math.md`.

Mechanics of a buy (exact input A USDG):

1. `beforeSwap`: take A USDG on credit, deposit, get S shares.
2. Move the pool price, with a zero-liquidity self-swap (hooks skip their own calls), to the edge of a one-tick range next to the execution price A/S. At most `MAX_WALK_TICKS` (~50%) per swap, since the core walks an empty pool one 256-tick bitmap word per loop; farther than that, the price moves that far and this swap goes without JIT.
3. Add a one-tick single-sided position holding the shares, sized so the curve fills all but a few raw units of the trade within it.
4. Return a `beforeSwap` delta covering the part the curve will not fill: the core curve swaps the rest against the position, so the pool manager emits a real `Swap` and `slot0` ends at ~A/S. `HookSwap` reports the hook's part.
5. `afterSwap`: check the curve filled exactly the predicted amounts (`JitMismatch` otherwise) and remove the position. Removal rounds a few raw units down: the swapper absorbs them on the side the hook does not specify; on the side it does, `USDG_BUFFER` / `SHARES_BUFFER` cover them.

Sells mirror it with a USDG position (`redeemOnCredit`, then the received shares are locked behind the hook's claims). Exact-output buys mirror it with the exact-output mint. No JIT (the hook fills the whole trade, the curve swaps 0) with a protocol fee on the pool, a trade under `MIN_JIT_USDG` (1 USDG, so dust trades priced mostly by `MIN_SLICE` and rounding cannot move `slot0`), a trade the math cannot place, or a swapper's price limit inside the range.

Price behaviour: the step-2 move emits an extra zero-amount `Swap` at ~the trade price; scanners that skip zero-amount swaps ignore it, and those that read its price see a sane one. Between trades `slot0` holds the last trade price and in-range liquidity is 0, so scanners still report ~$0 liquidity in this pool; only standing capital would change that.

LP fees: the pool's LP fee is 0 (the hook rejects any other pool key): the trader already pays every component pool's fee.

Gas (measured, 3-asset ETF): JIT adds 172k-244k per trade, +29-34%; see `docs/etf-jit-math.md`. Hook permissions: `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`.

## Gas cost per asset count

Measured 2026-10-23 on a Robinhood-mainnet fork (block 92,800,000, real rStock pools), each call its own transaction (`--isolate`), trades through v4-core's `PoolSwapTest` router. Assets: 3 = SPY, META (V4) + NVDA (V3); 10 = SPY, META, TSLA, AAPL, TSM (V4) + NVDA, QQQ, AMZN, GOOGL, MSFT (V3).

| | Plain V4 swap (SPY, no hook) | 3 assets | 10 assets | Per extra asset |
|---|---|---|---|---|
| `deposit()` 1000 USDG | - | 497k | 1.38M | ~126k |
| Hook buy, 100 USDG | 189k (1x) | 741k (3.9x) | 1.60M (8.4x) | ~122k |
| Hook sell | - | 686k (3.6x) | 1.51M (8.0x) | ~117k |

Cost is linear in the number of live assets: every deposit, redemption and hook trade values and swaps each one. A hook trade carries ~370k of fixed overhead (the shares-pool swap, JIT, valuation) on top, which is why 3 assets cost more than 3 plain swaps. An extra asset costs less than a whole plain swap, since the transaction and router overhead is paid once.

In USD (ETH at $2,407, average gas over 2026-09-23 to 2026-10-23), a 10-asset hook buy costs ~$0.09 on Robinhood (0.0235 gwei), ~$0.08 on Arbitrum (0.020 gwei, L1 data fee negligible) and ~$1.54 on Ethereum mainnet (0.40 gwei base + tip; ~$11 at the month's 2.7 gwei peak).
