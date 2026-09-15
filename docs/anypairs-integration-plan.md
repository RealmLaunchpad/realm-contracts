# AnyPairs integration: decisions and plan

Status: agreed 2026-09-15. **Phase 0 and Phase 1 implemented 2026-09-16** (see §5); phases 2-4 not
started. Realm is not on mainnet yet, so every Realm contract may change except `RealmHook` (already
whitelisted by Uniswap).

## 1. Outcome

`anypairs/` is a parallel 14k-line stack with its own token, hook, locker, trackers and dependency pins.
Every feature it has exists in Realm in an audited, pull-based, layout-checked form. We port the **venue**
(direct Uniswap V4 launch, any quote, one-sided seed, multi-pair) into the Realm contracts and delete
`anypairs/` (and its four submodules) once the venue is merged. Ideas adopted from it:

- caller-supplied launch tick (quote per coin, multiple of the tick spacing) and a token-side single-sided band
- fees taken on the quote leg whichever side of the pool it sorts on
- pool identity resolved per pool inside the hook
- sniper protection applied to DEX buys after launch

## 2. Target architecture

| Role | Contract | Notes |
|---|---|---|
| Venue factory | `RealmFactoryUniV4Direct` (UUPS, extends `RealmFactoryAbstract`) | validation, clone, salt namespacing, vaults, fee shares, events. No curve, no launchpad. |
| Venue graduator | `RealmDirectGraduatorUniV4` (non-upgradeable, holds seed NFTs forever) | same `IRealmGraduator` shape plus `HOOK_ADDRESS()` / `LIQUIDITY_ADDER()`. `initialize()` creates the pool(s) at the caller's tick; `graduateToken()` calls `markGraduated()`, seeds the band(s), runs the dev buy. |
| Token | the existing two impls (`RealmToken`, `RealmTaxableTokenUniV4`) + `RealmDividendLogicUniV4` | graduated from birth through the normal `markGraduated()`. Money path keyed by quote. |
| Hook | `RealmHook` for native pools (unchanged); new `RealmHookAnyPair` for ERC20-quoted pools | `RealmHookAnyPair` = `RealmSwapHook` generalised: resolves which side is the token via `quote()`, caches per pool id, takes fees in the quote. |
| Money path | `accrueFees()`, `EarningsAllocation`, `SwapLpFeeRouter`, `RealmMasterFeeHandler`, `RealmDividendSwapRegistry`, `RealmUniv4BuyBacks`, `RealmUniV4LiquidityAdder` | every "native" seam becomes "asset", `address(0)` meaning native. |

Token roles for the venue: `launchpad = address(0)` (mint target falls back to `graduator`, so the venue never
inherits the launchpad's infinite allowance), `graduator = RealmDirectGraduatorUniV4`, `pair = PoolManager`.

## 3. Decisions

| # | Decision | Choice | Why |
|---|---|---|---|
| D1 | Hook for ERC20 quotes | new `RealmHookAnyPair`; `RealmHook` keeps every native pool | `RealmHook` is whitelisted and must not change. ERC20 pools trade from Realm's UI regardless; from the Uniswap app once the new hook is whitelisted. |
| D2 | Fee formula | ours: trader pays `lpFee + tax`; LP fee 30% treasury / 70% creator; tax 100% creator | keeps LP/tax separation; one formula for every venue. No referrals. |
| D3 | Supply | fixed `1e27` | Realm invariant; sniper constants, quoter and salt tooling untouched. |
| D4 | Dev buy | in-tx zap: ETH → quote through caller-supplied V4 `PoolKey[]` hops with `minQuoteOut`, then quote → token, all inside the graduator's own `unlock` | one transaction at deploy, no V3 router, no universal router. Native pools skip the first hop. Multi-pair: dev buy on the one pool the creator picks (`devBuy.pairIndex`). |
| D5 | Sniper window | protection lasts until the window ends regardless of graduation, for both venues | one rule. Buy source becomes `from == launchpad || from == pair`; sells exempt `to == pair`. |
| D6 | ERC20 treasury share | pushed to `RealmTreasuryRouter`; add owner `sweep(asset)` | voting stays ETH-only. A keeper-gated `convert(asset, minOut)` can be added later. |
| D7 | Dividend payout | keeper conversion (unchanged) + round-robin push of credited balances on pool transfers | conversion needs a slippage-protected `minOut`; payout does not. Push is try/catch, fixed stipend, debit-first, transient lock; can raise gas, can never revert a transfer. |
| D8 | Creator fee handler | `RealmMasterFeeHandler` multi-asset, direct receivers supported for ERC20 too | creators receive the pool's quote. Direct forward is a `safeTransfer` in try/catch with claimable fallback, same as ETH today. |
| D9 | Multi-pair | supported; buffers keyed by quote from the start | one token, N pools, N quotes, supply split by weight. Designing single-quote first would force a second refactor. |

## 4. Dropped from anypairs

| Feature | Why |
|---|---|
| epoch trackers / AutoBasket | ~80k gas per leg per transfer, 1.3k lines; our accumulator covers it |
| in-swap conversion | sandwichable, 650k gas per swap; conversion stays keeper-gated |
| in-swap pushes + payout ring + `InSwapRegistry` | violate pull-over-push; registry only exists because of the pushes |
| platform fee converter + V4 median oracle | treasury handled manually (D6) |
| trading delay | computable randomness; sniper window covers it |
| referral ledger | not wanted |
| creator handoff / CTO | admin override is a trust surface; token ownership is already two-step |
| `V4TokenMeta` event | metadata goes through the API before broadcast |
| V3 `SwapRouter02` dependency, linked libraries, `via_ir` | not needed by the ported design |

## 5. Plan

### Phase 0: make room (no behaviour change) — DONE
- ✅ Moved `processBurn()` / `processLiquidity()` from `RealmTaxableTokenUniV4` into `RealmDividendLogicUniV4`. The token's shared constants, the liquidity-wall memory and the four errors moved to `RealmTaxableTokenUniV4Base` so both sides see them. `processBurn` burns through an EXTERNAL `ERC20Burnable(address(this)).burn()` rather than `_burn`, which would have dragged `RealmToken._update` (anti-sniper + dividend tracking, ~7.4 KB) into the extension; `burn`/`burnFrom` are stubbed `NotAToken` there for the same reason. Token 23,266 -> 19,456 B; extension 19,924 -> 21,244 B.
- ✅ Generalised `RealmUniV4LiquidityAdder` to `addSingleSided(key, currency, amount, range, nftReceiver, excessReceiver)`; the three native entry points are wrappers. The ERC20 side pulls from the caller, settles through Permit2 and returns the rounding remainder. Constructor gained `permit2` — redeploy needed.
- ⏸️ `anypairs/` NOT deleted (still its author's call).

### Phase 1 implementation notes (what differs from the plan above)
- The graduator names NO factory. A launch is authorised by `initialize`'s caller being the token
  itself, which removes the constructor cycle (factory needs graduator, graduator needs factory) and
  is the check that actually matters: without it a front-runner could pre-create a pending launch's
  pool and brick it with `PoolAlreadyInitialized`. `prepare` is therefore open (transient-only) and
  `graduateToken` is reachable only in the same tx as its `initialize`.
- There is NO graduation fee on this venue: the only ETH in the transaction is the creator's own dev
  buy, and a cut of that is a launch fee under another name. `TokenGraduated.ethAmount` is the dev buy.
- The dev buy requires the swap to consume the whole `msg.value` (`DevBuyNotFilled`) instead of
  refunding a remainder — nothing can strand, and the creator keeps their ETH on a revert.
- `RealmFactoryAbstract` was split as planned; the new curve layer is `RealmFactoryCurveAbstract` and
  adds no storage, so the live factory proxies' layout is unchanged.
- `RealmTaxableToken.rescueTokens` / `setTaxBps` now read the launchpad owner through
  `_launchpadOwner()`, which returns 0 for a zero launchpad instead of reverting on a codeless address.
- Deploy scripts / manifests / envio configs for the new venue are NOT done.

### Phase 1: direct launch, native quote, single pool — DONE
- `RealmDirectGraduatorUniV4`: `prepare()` factory-only via transient storage, read back in `initialize()`; tick validated as aligned and strictly inside the usable band, nothing else; seed liquidity checked against `tickSpacingToMaxLiquidityPerTick`; dev buy as an in-callback swap.
- `RealmFactoryUniV4Direct`: final ABI from day one: `createToken(setup, pairs[] {quote, weightBps, launchTick}, taxCfg, sniperCfg, vaults[], devBuy {pairIndex, route, minQuoteOut}, referral)`; phase 1 accepts one native pair. Split `RealmFactoryAbstract` so curve resolution, `LAUNCHPAD.launchToken()` and the launchpad buy live in a curve-only layer.
- Token: mint-target fallback, sniper buy source / sell exemption / window gate (D5).
- `UniswapV4PoolConstants.realmPoolKey(token, quote, hook)` sorted; native overload kept.
- Events: reuse `TokenCreated`, `LpFeeBpsSet`, `CreatorVaultsCreated`, `BuyOnDeploy`, `TokenReferral`, `PairInitialized`, `TokenGraduated`; add `PoolSeeded(token, quote, poolId, weightBps, tick, liquidity)`. Update `docs/events-per-entry-point.md`; envio configs append-only.

### Phase 2: ERC20 quotes (money path keyed by quote)
- Token: `quotes[]` + `mapping(quote => buffers)` for burn, liquidity and dividend pending, appended to `RealmTaxableTokenUniV4Base` (no slot shift). `accrueFees(asset, amount)` pulls from the caller and requires a registered quote; native `accrueFees()` stays.
- Keeper calls take the quote: `processBurn(quote, minOut)` buys back in that quote's pool; `processLiquidity(quote)` walls in that pool; `processDividends(assetIndex, quote, minOut, holders[])`.
- `RealmMasterFeeHandler`: `depositFees(token, asset, amount)`, per-asset accumulators and claims, direct receivers via try/catch transfer (D8).
- `SwapLpFeeRouter`: ERC20 overload of `depositLpFees()`; treasury share to `RealmTreasuryRouter`, which gains `sweep(asset)` (D6).
- `RealmHookAnyPair` (D1): per-pool token/quote resolution, exact-in/out matrix mirrored for token-as-currency0, fees taken in the quote, routed through the ERC20 overloads.
- `RealmDividendSwapRegistry`: `swapToAsset(source, asset, amountIn, minOut, to)`; routes validated from the quote; asset == quote is passthrough.
- `RealmUniv4BuyBacks`: sorted key, `zeroForOne = quoteIsC0`, ERC20 settlement. Liquidity adder settles ERC20.
- Launch sanity on a quote: not WETH (use native), not a Realm token, has `decimals()`, not fee-on-transfer (measured at first use).
- Chain retargeting: add new files to the `_taxtoken` sed list; chain-id assert in impl constructors.

### Phase 3: multi-pair
- Factory accepts up to `MAX_PAIRS = 3` pairs, weights sum to 10,000, no duplicate quote; graduator initialises and seeds N pools; hook per pool (`RealmHook` if native, `RealmHookAnyPair` otherwise).
- Indexer: pools per token from `PoolSeeded`, trades keyed by pool id, market cap weighted across pools. Frontend hides multi-pair until the schema ships.
- `RealmQuoter`: tick → price preview.

### Phase 4: round-robin payout (D7)
- Holder set in the token maintained on threshold crossings; push of credited balances on pool transfers with a small budget; keeper `processDividends(holders[])` and `claimDividends()` unchanged.

## 6. Invariants kept

- Nobody receives ETH or tokens unless they claim, except the treasury and stipend-bounded dividend pushes that can never revert the caller.
- `TOTAL_SUPPLY = 1e27`, CREATE2 salt `keccak256(msg.sender, salt)`, address suffix `0xeeaa`.
- `RealmHook` bytecode and address untouched.
- `just check-dividend-layout` after every change under `src/tokens/`.
- Factory `createToken()` overloads and public views are append-only.

## 7. Open points

- none on pairs: `MAX_PAIRS = 3`, dev buy on the creator-chosen pair only.
- Whether ERC20-pool fees should later be auto-converted to ETH for the treasury (keeper `convert()` on the router).
- Uniswap whitelisting of `RealmHookAnyPair`: approved, file the request once deployed.
