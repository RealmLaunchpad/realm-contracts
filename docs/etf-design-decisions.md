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
| NAV-priced venue in `RealmAssetsWhitelist` | Not needed if JIT ships: `slot0` then tracks the last trade and a standard V4 listing works |
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
- Known leak: deposits price new shares on the live holdings only, yet every share redeems its slice of a sunset asset's balance in kind, so a deposit made after the sunset (flash loan, `redeemInKind`, sell the live slice) takes part of that balance for free. Accepted: sunset is for tokens that can no longer move, and a token whose transfers revert leaks nothing. Sunsetting a token that still transfers (a malicious or mistaken owner) cuts NAV and opens this leak.
- Companion `reinvest()`: USDG that lands in the vault outside a deposit (a cash payout for an acquired stock, an airdrop) is uncounted today. Buying the live holdings pro-rata with it, minting no shares, hands it to holders.
- `reinvest()` is keeper-gated, not permissionless: it trades the holders' USDG with no floor, so a public caller could push a pool, reinvest into it and unwind in one transaction (the rebalance attack). No minimum amount: it mints no shares, so `MIN_SLICE` has nothing to protect; a holding whose slice rounds to 0 is not bought.

## Price display

With JIT liquidity the pool manager's `Swap` events and `slot0` carry the trade price, so scanners and the indexer price the ETF like any token. Buys print slightly above NAV and sells slightly below (component slippage): a normal spread. NAV per share stays available as a view, `convertToAssets(1e18)`, for an optional premium/discount display in the frontend.

## Scanner visibility: JIT liquidity

Without JIT, the ETF/USDG hook pool holds no liquidity and `beforeSwap` takes the whole input, so the pool manager emits its `Swap` for that pool with zero amounts and an unchanged price: the USDG <-> ETF leg is invisible to scanners. A standing position (Lots' approach) needs hook-owned capital and is not wanted. Built instead: JIT liquidity plus OpenZeppelin's `HookSwap` event. Sizing, rounding and proofs: `docs/etf-jit-math.md`.

Mechanics of a buy (exact input A USDG):

1. `beforeSwap`: take A USDG on credit, deposit, get S shares.
2. Move the pool price, with a zero-liquidity self-swap (hooks skip their own calls), to the edge of a one-tick range next to the execution price A/S. At most `MAX_WALK_TICKS` (~50%) per swap, since the core walks an empty pool one 256-tick bitmap word per loop; farther than that, the price moves that far and this swap goes without JIT.
3. Add a one-tick single-sided position holding the shares, sized so the curve fills all but a few raw units of the trade within it.
4. Return a `beforeSwap` delta covering the part the curve will not fill: the core curve swaps the rest against the position, so the pool manager emits a real `Swap` and `slot0` ends at ~A/S. `HookSwap` reports the hook's part.
5. `afterSwap`: check the curve filled exactly the predicted amounts (`JitMismatch` otherwise) and remove the position. Removal rounds a few raw units down: the swapper absorbs them on the side the hook does not specify; on the side it does, `USDG_BUFFER` / `SHARES_BUFFER` cover them.

Sells mirror it with a USDG position (`redeemOnCredit`, then the received shares are locked behind the hook's claims). Exact-output buys mirror it with the exact-output mint. No JIT (the hook fills the whole trade, the curve swaps 0) with a protocol fee on the pool, a trade the math cannot place, or a swapper's price limit inside the range.

Price behaviour: the step-2 move emits an extra zero-amount `Swap` at ~the trade price; scanners that skip zero-amount swaps ignore it, and those that read its price see a sane one. Between trades `slot0` holds the last trade price and in-range liquidity is 0, so scanners still report ~$0 liquidity in this pool; only standing capital would change that.

LP fees: the pool's LP fee is 0 (the hook rejects any other pool key): the trader already pays every component pool's fee.

Gas (measured, 3-asset ETF): JIT adds 172k-244k per trade, +29-34%; see `docs/etf-jit-math.md`. Hook permissions: `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`.
