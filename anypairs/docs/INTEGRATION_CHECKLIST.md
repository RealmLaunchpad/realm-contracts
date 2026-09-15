# INTEGRATION_CHECKLIST.md — Realm AnyPairs: what the frontend and indexer must handle

**Scope.** The contract surface of the Realm AnyPairs V4 stack on Robinhood Chain (chainid 4663): what exists, what
changed, and what the Realm frontend and indexer must do about it. It does not describe any server.

**Nothing is deployed yet.** Every address is a placeholder until `docs/DEPLOY_UNIFIED.md` has been run.

**Cite names, not line numbers.** Everything below points at a greppable function, constant, error, event or struct
field; line numbers drift the moment anyone edits `src/`.

**Unaudited.** The stack derives from an audited codebase, but the changes in §0b-2 (rounds 105–108), §0d, §0e and §0g
are new and have not been audited.

---

## 0. The stack, and what changed from the previous generation

Read this before §1. Everything after it assumes it.

### 0a. It is EIGHT contracts, not nine

| # | contract | kind |
|---|---|---|
| 1 | `RealmAnyPairsSplitLib` | library (linked) |
| 2 | `RealmAnyPairsV4TokenDeployer` | library (linked) |
| 3 | `RealmAnyPairsV4PairTrackerDeployer` | library (linked) |
| 4 | `RealmAnyPairsV4MultiPairTrackerDeployer` | library (linked) |
| 5 | `RealmAnyPairsInSwapRegistry` | contract |
| 6 | `RealmAnyPairsTaxHookPairImmutable` | contract (CREATE2, mined flags) |
| 7 | `RealmAnyPairsV4PairLpLockerImmutable` | contract |
| 8 | `RealmAnyPairsV4UnifiedLauncher` | contract |

Deploy order is in `docs/DEPLOY_UNIFIED.md`. **`RealmAnyPairsLegRouteRegistry`, `McapAutoPricing` and `McapPricing` are DELETED** — they are
not deployed, not linked, and not referenced by any contract in the stack.

Per-launch contracts (`RealmAnyPairsTokenDividend`, `RealmAnyPairsTokenPlain`, the trackers — basket launches use
`RealmAnyPairsDividendTrackerAutoBasket`, §0g) are deployed by the launcher at launch time and are not part of the eight.

> **Grep trap.** `src/RealmAnyPairsV4PairLauncherImmutable.sol` is still present in `src/` because
> older tests compiled against it. **It is not deployed.** It
> still declares the whole deleted surface listed in §0b, so a "does this symbol still exist?" grep
> across `src/*.sol` will find those names and mislead you. Check
> `src/RealmAnyPairsV4UnifiedLauncher.sol` and `src/RealmAnyPairsTaxHookPairImmutable.sol` specifically — and note
> that in those two files every deleted name that still appears appears **only inside comments that
> record its removal** (`grep -n` and read the line; none of them is code).

### 0b. REMOVED ABI SURFACE — diff your call sites against this list

Every symbol here existed on the previous generation and **does not exist on the new stack**. A call
to any of them reverts (no fallback exists on either contract), and a `.call()` from ethers/web3/viem
fails rather than returning a default. Grep your codebase for each one.

| removed symbol | was on | replacement |
|---|---|---|
| `pairAllowed(address)` | launcher | **none — every quote is permitted now** |
| `setPairAllowed`, `setPairsAllowed` | launcher | none |
| `pairMagnitude(address)`, `setPairMagnitude` | launcher | none |
| `readyQuoteCount()` | launcher | **none.** See the warning below. |
| `usdg()`, `setUsdg(address)` | launcher | none |
| `defaultTargetMcapUsdg` | launcher | none |
| `launchTick()` (the global default) and `setLaunchTick(int24)` | launcher | **the caller passes the tick per launch — §0c** |
| `setV3Factory(address)` | launcher | `v3Factory` is now an immutable constructor argument |
| `autoPricing`, `targetMcap`, `manualTick` (per-launch pricing inputs) | launcher | `LaunchParams.launchTick` — §0c |
| `accruedEth(bytes32)` | old ETH-only hook | `accruedQuote(bytes32)` on the one hook |
| `InsufficientGasForFeed()` (error) | hook | **removed from the ABI.** It was declared but never thrown; the round-5 payout ring deleted its throw sites. Decoding it is now dead code. |
| `LegAssetNotCurated`, `curatedLegFee`, the whole `RealmAnyPairsLegRouteRegistry` surface | route registry | contract deleted |
| `McapPricing` / `McapAutoPricing` library calls | pricing libs | contracts deleted |
| `referralSplitter()`, `setReferralSplitter(address)` | hook | **none — referrals are native, see below** |
| `ReferralRouted(bytes32,address,uint256)` (event) | hook | `ReferralCredited(bytes32,address,address,uint256)` |
| `ReferralSplitterNotSet()` (error) | hook | removed — the renounce gate has four conditions now, not five |
| `pushReferral(address,address,address,uint256)` | hook | none — nothing is pushed; the cut is a ledger credit |
| `ReferralSplitterSet(address)` (event) | hook | none |

> ### ⚠ ROUND 83 — TWO REFERRAL SYMBOLS CHANGED RATHER THAN VANISHED, AND BOTH FAIL SILENTLY
>
> Everything else in the table above reverts loudly when you call it. These two do not.
>
> * **`markReferred(PoolKey)` → `markReferred(PoolKey,address)`.** Same name, different selector.
>   An old-ABI caller gets a bare revert with no data — indistinguishable from any other failure.
> * **`PoolReferred` gained a third indexed argument** (`referrer`), so the event signature — and
>   therefore **topic0** — changed: `PoolReferred(bytes32,address)` → `PoolReferred(bytes32,address,address)`.
>   An indexer filtering on the old hash matches **nothing**, forever, with no error and no gap in
>   its logs. It simply reports that no coin was ever referred.
>
> **The referral model itself changed, not just the ABI.** There is no sink contract. The launcher
> passes the referrer to `markReferred`, the hook screens it and stores it one-shot in
> `referrerOf(poolId)`, and every distribution credits `REFERRAL_BPS` (10%) of the **platform's**
> cut to `owed[referrer][quote]`. The creator's share is untouched. The referrer claims through the
> ordinary pull ledger — `claim(token, minWethOut)` / `claimTo(...)` — exactly like a creator or a
> split recipient. There is no settle window and nothing to settle.

> ### ⚠ `readyQuoteCount()` has NO replacement, and a UI reading it will break
>
> A frontend that calls `readyQuoteCount()` (or iterates `pairAllowed`) to populate a "which quote
> can I launch against" dropdown has nothing to migrate to, **because there is no longer a curated
> quote list at all — every ERC20 is a permitted quote.** The only remaining per-quote checks are
> arithmetic, applied at launch time inside `RealmAnyPairsV4UnifiedLauncher._requireSaneQuote`:
>
> * `QuoteIsWeth()` — the quote is WETH (use the native path instead);
> * `QuoteSupplyTooLarge()` — `IERC20(quote).totalSupply() > MAX_QUOTE_TOTAL_SUPPLY`;
> * `QuoteImpersonatesCoin()` — the quote duck-types as a coin this launcher itself minted
>   (`ICoinLauncher(quote).launcher() == launcher`).
>
> There is no view that enumerates acceptable quotes and none can exist, since the set is "almost
> every ERC20". Build the dropdown from your own list, not from the chain.

### 0b-2. CHANGED AND ADDED ABI — feature rounds 91–101 (2026-09-13)

§0b lists what was **removed**. These rounds removed nothing an integrator calls, but they **changed the encoding of
every launch entrypoint** and added four features. A caller that re-encodes against the new ABI gets a clean revert on a
mistake; a caller holding a **stale ABI JSON** encodes the old tuple and every launch reverts with no useful data.

**Every launch params struct gained leading fields, in this order, before `name`:**

| field | type | meaning |
|---|---|---|
| `vaults` | `VaultParams[]` `{beneficiary, bps, cliffSecs, vestSecs}` | creator vesting vaults — at most 5, together at most 20% of supply, cliff ≤ 365 days, vesting ≤ 4 years, cliff ≤ vesting, and **cliff ≥ the max-wallet window** when the coin has one (`VaultCliffInsideMaxWallet`). Empty = none. |
| `devBuyRecipients` | `address[]` | split the dev buy's coin across up to 10 wallets. Empty = all to the creator. |
| `devBuyBps` | `uint16[]` | shares, summing to 10,000, none zero; the last recipient takes the rounding remainder. Refused as `BadDevBuySplit`: more than 10 recipients, a length mismatch, a duplicate, or a recipient that is zero, the locker, the PoolManager, the coin, the pool's hook, or the calling launcher unless it is the creator (round 97). |

The four quote-paired families also carry a sniper `whitelist` (≤ 50 wallets; skips max buy and max wallet, never the
trading delay or launch tax); the native families carry it in `tax.whitelist`. **The whitelist is part of the token's
init code, so it is part of the coin's address.**

**The salt is mandatory and must be MINED.** Every coin address must end in `0x1110`; the token deployer reverts
`InvalidTokenAddress(token)` otherwise, with no zero-salt fallback. The CREATE2 salt is `keccak256(caller, userSalt)`,
so a salt is valid only for the exact **caller**, **launcher**, and token init code (name, symbol, supply, creator,
max-wallet settings, whitelist). Mine with the launcher's own views:
`tokenInitCodeHash(dividend, name, symbol, totalSupply, creator, maxWalletBps, maxWalletMins, tradingDelaySecs, whitelist)`
then `predictTokenAddress(caller, initCodeHash, userSalt)` until the result ends in `tokenSuffix()`.

| added | on | notes |
|---|---|---|
| `quoteDevBuy(...)`, `maxDevBuy(...)` | unified launcher | preview a dev buy's coin out and the largest dev buy for given launch settings (view) |
| `launchBuyFee(buyBps, launchTaxBps, launchTaxSecs, amount)` → `(fee, fillCeilBps)` | hook | what a buy of `amount` pays at launch, with the launch-tax ramp applied (view) |
| `tokenInitCodeHash`, `predictTokenAddress`, `tokenSuffix`, `tokenDeployer` | both launchers | salt mining, above |
| `proposeCreator(coin, to)`, `cancelCreatorProposal(coin)`, `acceptCreator(coin)` | hook | two-step creator hand-off across every pool of a coin; the new creator must accept; the new creator may not be zero, the hook or the PoolManager (`SelfAddress`, round 98), and the admin `setTokenCreator` refuses the same. A proposal is void after any creator change on any of the coin's pools (round 97) |
| creator split (`recipients`/`splitBps` at launch; `setCreatorSplit`, `adminSetCreatorSplit`) | hook | ROUNDS 98-101: reverts `BadSplit()` if a recipient is an allowlisted launcher, the pool's own coin, any coin already configured on this hook, a Realm AnyPairs LP locker (a launcher-reported `isSeeder` since round 99, and any contract with the locker's shape since round 101 -- so a locker rotated into a launcher is refused before its first launch), or a rewards tracker this hook funds that cannot book the pool's quote -- a tracker whose `quote()` is a different asset, a native tracker named by an ERC20 pool, or a multi-basket tracker whose denominations do not include the pool's quote (always refused on a native pool; round 100) -- besides zero / the hook / the PoolManager / a zero share / a sum other than 10,000. A tracker paying the pool's own quote (this pool's or another's) is allowed. Every check applies at store time only. NOT caught (round 101, documented): an address that only LATER becomes a Realm AnyPairs coin, an allowlisted launcher or an LP locker -- e.g. a predicted CREATE2 address named before launch keeps being paid after launch, losing the creator's own share; rewrite the split once the coin exists. |
| `LaunchTooLarge()` (error) | unified launcher | round 102: `launchMultiPair` reverts when `pairCount × (16, or 25 on a rewards launch, + creator-split recipients) > 775` (~24.8M gas). Cannot bind at the default 10 pools; at 25 pools a launch admits at most 15 recipients (6 with rewards). Refuse those shapes in the UI. |
| `isSeeder(address)` | hook | round 99: true for an LP locker a launcher reported at `configurePool`; refused as a creator split recipient (view) |
| `renounceCreator(coin)` | hook | permanent for the creator; requires a creator split on every pool (`RenounceNeedsSplit`). **The admin can still CTO it, per pool** (`setTokenCreator` clears the renounce on that pool only); `creatorOfCoin` reads renounced until pool 0 is reassigned. |
| `coinPools(coin)`, `creatorOfCoin(coin)` | hook | trackers now read the creator through `creatorOfCoin` |
| `launch(..., address[] recipients, uint16[] bps)` (10-arg overload) | locker | the split dev buy; the 8-arg `launch` is unchanged |
| `vaultImplementation()` | both launchers | each vault is an EIP-1167 clone of it; the implementation itself is locked |
| `RealmAnyPairsCreatorVault.vested()/claimable()/claim()` | each vault | only the beneficiary claims |
| `rescue(token, to, amount)` | hook (admin), locker and launchers (owner/admin) | hook: never a pool's coin or quote, never any configured WETH (`RescueForbiddenAsset`), not while the PoolManager is unlocked; admin only; `to` never zero or the hook; native ETH refused once a native pool exists, and also until `setSwapConfig` sets a non-zero WETH; locker: never more than `availableOf` (`RescueExceedsAvailable`), not while unlocked, `to` never zero, the locker or the PoolManager (`BadRefundDestination`) |
| `rescue(asset)` → `amount` | each coin (`RealmAnyPairsTokenPlain`, `RealmAnyPairsTokenDividend`) | ROUND 105. **Permissionless.** Sends the coin contract's whole balance of `asset` — its own coin or any other ERC20 sent to the coin's address by mistake — to the coin's `launcher`, never anywhere else; the launcher's owner/admin `rescue` then returns it. Reverts `NothingToRescue()` on a zero balance. Moves only `address(this)`'s balance, so it is not a privileged function and cannot touch a holder. Native ETH is not handled (the coin has no payable entry point). Emits the same `Rescued(token, to, amount)` topic as every other rescue. **This changes the coin's bytecode, so it changes every token init code hash — re-mine every salt against the new `tokenInitCodeHash`.** |
| `setV4Route(quote, PoolKey[] hops, maxIn)`, `poke(quote)`, `v4RouteOf(quote)`, `samplesOf(poolId)`, `sampleStatus(poolId)` | platform fee converter | ROUND 105. Converts a quote over **Uniswap V4** pools (1–3 hops) ending in WETH or native ETH; a quote has either a V3 route (`setRoute`) or a V4 one, and setting one clears the other. V4 keeps no price history, so the converter records its own: `poke` (permissionless, unreimbursed) and every `convert` write at most one slot0 sample per pool per 450 s; a pool prices only with ≥ 4 samples younger than 1 h spanning ≥ 1,350 s, using their **median** tick; a new sample more than 300 ticks from an established median is refused (`SampleRefused`), and a spot price that far from it skips the conversion with the new reason **`6` = `SKIP_PRICE_MOVING`**. Route pools may not carry the Realm AnyPairs hook. **Constructor gained a 9th argument, `poolManager`** (zero disables V4). |
| basket reward routes (`RealmAnyPairsDividendTrackerBasket`, `…EthBasket`, `…MultiBasket`) | each basket tracker | ROUND 106. **Routes are discovered at conversion time**, not fixed at construction: each claim picks the deepest pool between the reward input and the leg asset across V3 (fee 100/500/3000/10000) and **hookless V4** (fee/tickSpacing 100/1, 500/1, 500/10, 2500/25, 3000/60, 10000/200, 30000/200; the ETH basket also probes native-ETH V4 pools). A basket leg with no pool **no longer reverts the launch** (`NoRouteFound` is gone from construction); its conversion falls back exactly as a dead route always did — raw input under `claimAtAnyPrice`, `LegMinOutUnmet` under a named floor. `basketLeg(...)` now reports the route a conversion would take **right now**: a 43-byte V3 path, a 160-byte ABI-encoded V4 `PoolKey`, or empty. V4 pools behind a custom hook cannot be discovered on-chain. The PoolManager is refused as a claim recipient. |
| `claimWithRoutes(minOuts, routes)`, `claimToWithRoutes(to, minOuts, routes)` (Basket, EthBasket); `claimWithRoutes(minOutsPerDenom, routesPerDenom)`, `claimToWithRoutes(to, minOutsPerDenom, routesPerDenom)` (MultiBasket) | each basket tracker | ROUND 107. **Routes may be SUPPLIED by the front end** at claim time, one per leg, indexed exactly like `minOuts`. An **empty** entry means *discover it* (round 106). A non-empty entry is the same encoding `basketLeg` reports: a 43-byte V3 path `abi.encodePacked(input, fee, asset)` or an ABI-encoded V4 `PoolKey` (160 bytes) **including its hook** — the only way to reach a V4 pool behind a custom hook, which cannot be discovered on-chain (every live NVDAx3L/USDG and SPCX market on Robinhood Chain is hooked, measured 2026-09-14). Every supplied route is validated **before anything is paid**: right two tokens (the ETH basket also accepts a native-ETH pool), a live pool (V3: exists on the factory; V4: initialized), and never through the tracker's own feeder hook — else `BadRoute()`; a routes array of the wrong length is `BadRoutes()`. The claimer's `minOuts` still bound every fill. The existing `claim*` entry points are unchanged and discover every leg. **Front ends should index V4 `Initialize` events for each reward asset, pick the deepest live pool (hooked or not), and pass it here.** |
| round 107 — fork proof (Robinhood Chain mainnet, block ~62.73M) | `test/fork/Round107RobinhoodFork.t.sol`: auto-discovery finds no route to NVDAx3L (every stock pool is hooked); a frontend-supplied PoolKey for the hooked NVDAx3L/USDG pool (hook 0x5dBeE309…C5c7) paid a holder 7.96 NVDAx3L for 10 USDG in rewards, claim gas 197,897 (under the 450k per-leg cap). The public RPC blocks Foundry's user agent (Cloudflare 403) — run it through a relay or a private RPC. |
| round 108 — auto-converting rewards | Basket launches deploy `RealmAnyPairsDividendTrackerAutoBasket`: fees credited to holders as pending at arrival, converted by the hook after swaps, pushed in-swap. Holders: `claim`, `claimPending` (instant, in the quote), `claimAs` (one token incl. ETH, own routes/mins). Creator: `setRoute`, `setSlippageBps`, `setFallbackDelay`, `setMinConvert`. See §0g. |
| `setRates` (creator) | hook | ROUND 106. No longer downward-only: section 0e. `adminSetRates` still is. |
| `setPlatformRates(share, floor, cap)`, `platformShareBps()`, `platformFloorBps()`, `platformCapBps()` | hook | ROUND 106. Platform fee inside the trader's total, snapshotted per pool: section 0d. |

**New events an indexer must subscribe to when this stack is wired:** `DevBuyDistributed(token, recipients[], amounts[])`
(locker), `CreatorVaultCreated(token, vault, beneficiary, amount, cliff, end)` (launchers), `VaultClaimed(beneficiary, amount)`
(each vault — emitter is the vault), `CreatorProposed` / `CreatorProposalCancelled` / `CreatorRenounced` and
`SniperWhitelistSet` (hook), and `Rescued(token, to, amount)` (hook, locker, launchers, and — ROUND 105 — each coin). ROUND 105 also adds, on the
platform fee converter, `V4RouteSet(quote, hops[], maxInPerCall)`, `SampleRecorded(poolId, tick, time)` and
`SampleRefused(poolId, tick, medianTick)`, plus `ConvertSkipped` reason `6`; and **`PoolSeeded` changed shape** (it gained
an indexed `poolId`; new topic0 in §2). ROUND 106 adds, on the hook, `PlatformRatesSet(shareBps, floorBps, capBps)` and
`PoolPlatformRates(poolId, shareBps, floorBps, capBps)` — the latter is each pool's fee schedule, emitted at launch. The existing `TokenCreatorSet`
still fires when a hand-off completes, once per pool of the coin. **A pending proposal can also end WITHOUT
`CreatorProposalCancelled`:** `CreatorRenounced` deletes it, `TokenCreatorSet` from `acceptCreator` consumes it, and after an
admin `setTokenCreator` it stays stored but reverts `StaleCreatorProposal` if accepted. Clear pending-proposal state on all
three. Vault supply is **excluded from rewards** on every tracker, and the pool is seeded
with `totalSupply` minus the vault amounts — `TaxLaunch` / `PairLaunch` still report the coin's full `totalSupply`.

### 0c. THE LAUNCH TICK IS NOW THE CALLER'S JOB — the biggest integrator-facing change

`launchTick` is the **final field** of `LaunchParams` (and of `RewardsLaunchParams`, and per pool in
`MultiLaunchParams.pairs`), typed `int24`, **supplied on every launch**. The global default and its
setter are gone; a UI that launched without supplying a tick **cannot launch at all** until it
computes and passes one.

* **Semantics: QUOTE PER COIN.** `price = 1.0001^launchTick`, quote units per coin unit, both raw.
  A HIGHER number is a more expensive coin, on every family including native ETH. **Do not negate
  it for token ordering.** Native ETH is `address(0)`, so a native pool is always
  (ETH = currency0, coin = currency1) and the pool-native tick is the negation of the one you pass;
  the contract applies that itself from `coinIsC0` inside `_finishLaunch`. Passing an
  already-negated tick prices the coin at the reciprocal of what you meant.
* **What is validated — and only this.** `_checkedTick` enforces two things and nothing else:
  the tick lies strictly inside the usable band (`_minUsable()` < tick < `_maxUsable()`, i.e. the
  `TICK_SPACING`-truncated `TickMath` bounds), and it is an exact multiple of
  `TICK_SPACING` (`= 200`). Both failures revert the **same** error:

  ```solidity
  error BadLaunchTick();   // grep -n 'error BadLaunchTick' src/RealmAnyPairsV4UnifiedLauncher.sol
  ```

  `BadLaunchTick` replaces the whole family the derived-pricing surface used to throw
  (`BadManualTick`, `McapTickOutOfRange`, `BadTargetMcap`, `PairNotAllowed`, `PairMagnitudeUnset`)
  — one way to price a launch, one way for it to be malformed.
* **NOTHING ON CHAIN SECOND-GUESSES THE PRICE.** There is no sanity band, no USD reference, no
  mcap target. A tick that is aligned and in range is accepted however absurd the resulting price
  is. Round off to `TICK_SPACING` **in the UI**, and show the user the price the tick implies before
  they sign — an off-by-one-spacing round trip is a 2% price error and an off-by-a-digit tick is a
  dead coin.

### 0d. THE FEE MODEL — ROUND 106: the platform fee is INSIDE what the trader pays

```
total    = max(effective creator rate, platformFloorBps)
platform = min(total, max(platformFloorBps, min(platformCapBps, total × platformShareBps / 10000)))
creator  = total − platform
```
(`grep -n '_totalBps\|_platformBps\|platformShareBps' src/RealmAnyPairsTaxHookPairImmutable.sol`, and `src/RealmAnyPairsFeeMath.sol`)

**The trader pays the creator's effective rate, never less than the platform floor, and the platform's cut comes out
of that.** A 5% coin costs the trader 5.00%, never more. A 0% coin still pays the floor, all of it to the platform.

| creator rate (per side) | **trader pays** | platform | creator pool |
|---|---|---|---|
| 0% | **0.20%** (floor) | 0.20% | 0% |
| 0.5% | **0.50%** | 0.20% | 0.30% |
| 1% | **1.00%** | 0.20% | 0.80% |
| 3% | **3.00%** | 0.60% | 2.40% |
| 5% | **5.00%** | 1.00% (cap) | 4.00% |
| 30% launch ramp | **30.00%** | 1.00% (cap) | 29.00% |

(defaults: share 20%, floor 0.20%, cap 1.00%)

**This reverses rounds 6–105, where the platform fee was ADDED on top** (a 5% coin cost the trader 6.00%). Every
surface that renders "you pay X% + platform", adds a platform fee to the tax, or sizes slippage from `tax + platform`
**is now wrong by the platform fee** and must drop the addition.

**Configurable, snapshotted per pool.** The hook's `platformShareBps` / `platformFloorBps` / `platformCapBps` are set by
the owner/admin with `setPlatformRates(share, floor, cap)` — bounds: share 1000–3000, floor ≤ 100, floor ≤ cap ≤ 300,
else `BadPlatformRates()`. `configurePool` copies them into the pool's `TaxConfig`, so **a change prices only coins
launched after it**; no live coin is ever repriced. Events: `PlatformRatesSet(share, floor, cap)` on a change,
`PoolPlatformRates(poolId, share, floor, cap)` at every launch — index the latter, it is the pool's fee schedule.

**Views to render:**

| view | returns |
|---|---|
| `totalFeeBpsOf(PoolId,bool isBuy)` | **what the trader pays, in bps of the trade — the number to show.** The platform fee is inside it. |
| `platformFeeBpsOf(PoolId,bool isBuy)` | the platform's slice, in bps of the trade (inside the total, not added to it). |
| `platformBpsOf(PoolId,bool isBuy)` | the platform's share **of what the trader paid**, bps; `0` on a side that charges nothing. |
| `creatorPoolBpsOf(PoolId,bool isBuy)` | complement; `platformBpsOf + creatorPoolBpsOf == BPS` whenever the side charges anything. |
| `configOf(PoolId)` | now also returns the pool's `platformShareBps`, `platformFloorBps`, `platformCapBps`. |

**ABI removed:** public constants `MIN_PLATFORM_BPS`, `MAX_PLATFORM_BPS`. **ABI added:** `platformShareBps()`,
`platformFloorBps()`, `platformCapBps()`, `MIN_PLATFORM_SHARE_BPS`, `MAX_PLATFORM_SHARE_BPS`, `MAX_PLATFORM_FLOOR_BPS`,
`MAX_PLATFORM_CAP_BPS`, `setPlatformRates`, `BadPlatformRates()`, and the two events above. Both getters read the
**effective** rate, so they move during a launch ramp.

New platform/creator settlement entry points on the hook, all permissionless:

* `claimPlatform(PoolId)` — settles the platform's cut for one pool; reverts `NothingAccrued()` if
  there is nothing accrued **and** nothing parked in the payout ring.
* `claimPlatformMany(PoolId[])` → `(paidPools, skippedPools)` — one transaction for many pools,
  which is what you want on a chain that rejects gapped nonces. Batch size is bounded by
  `MAX_CLAIM_BATCH`; a bad pool is skipped (`PlatformClaimSkipped` event), never reverted.
* `claimPlatformOne(PoolId)` — **self-call trampoline for the batch above. `OnlySelf()`. Do not
  call it externally.**
* `claimCreator(PoolId)` — settles only the creator/rewards portion, leaving the platform's cut
  accrued and still claimable.

### 0e. Rates move BOTH WAYS for the creator — ROUND 106

`setRates` accepts any per-side value within the cap, **up or down** — the round-6 downward ratchet no longer binds the
creator. **A raise applies to the very next swap**, with no delay, so read `totalFeeBpsOf` at quote time and size slippage
from it. The admin override `adminSetRates` is still **downward-only** (`RateNotLowered()`), so nobody but the creator can
raise a creator's rate.

* `MAX_SIDE_BPS_LIMIT = 500` — the hard, immutable ceiling (5% per side). The mutable `maxSideBps`
  **starts at 500**, so there is no headroom above it and `setMaxSideBps` can only tighten
  (`SideCapExceeded()` above the limit).
* `FILL_TOLERANCE_BPS = 2000` — **NOT A RATE. Never render it as one.** It is `afterSwap`'s
  partial-fill sanity ceiling only (`FillTooSmallForTax()`); no setter accepts it and no coin is
  ever taxed at it. It and `MAX_SIDE_BPS_LIMIT` were deliberately split out of one symbol; treating
  them as interchangeable is how a "20% max tax" gets rendered.
* `MAX_LAUNCH_TAX_BPS = 3000` and `MAX_LAUNCH_TAX_SECS = 3600` — unchanged. The launch ramp is
  deliberately allowed above `MAX_SIDE_BPS_LIMIT` because it decays.

### 0f. Renounce readiness — what `renounceOwnership` requires

`_requireRenounceReady` must pass before `renounceOwnership`. Check each condition by hand first:

* **hook** (`RealmAnyPairsTaxHookPairImmutable`): `launcherCount != 0` (`NoLauncherWhitelisted`);
  `admin != 0` (`AdminZero`); `weth != 0 && swapRouter != 0` (`SwapConfigUnset`);
  `inSwapRegistry != 0` (`InSwapRegistryNotSet`). **Four conditions.** Round 83 removed a fifth,
  `referralSplitter != 0`, together with the sink it pointed at — referrals are native now.
* **locker** (`RealmAnyPairsV4PairLpLockerImmutable`): `launcherCount != 0` (`LauncherNotSet`) — that is
  the whole check.
* **launcher** (`RealmAnyPairsV4UnifiedLauncher`): exactly `pairTaxHook.isLauncher(this)` and
  `pairLpLocker.isLauncher(this)` (`LauncherNotAllowlisted`) — **nothing else.**

Each is a legal live state while the owner still holds the key and an unrecoverable one after
renounce, which is the entire reason the check exists.

---

### 0g. ROUND 108 — rewards convert and auto-send themselves (no keeper)

**What changed.** Every basket launch of `RealmAnyPairsV4UnifiedLauncher` (pair basket, native basket, multi-pair) now deploys **`RealmAnyPairsDividendTrackerAutoBasket`** instead of `...DividendTrackerBasket` / `...EthBasket` / `...MultiBasket`. Launch params are unchanged. The old trackers stay in the tree, untouched, but are no longer deployed by the unified launcher.

**How rewards flow.**
1. The hook feeds the rewards slice in the pool's quote (native ETH is wrapped to WETH). A leg paid in the quote itself is booked to holders at once. Every other leg's share is credited to holders **immediately, as pending quote, by their balances at that moment** — a later buyer never shares in an earlier fee.
2. After **every swap** the hook calls `tracker.convertStep()` (650k gas cap, failure-isolated; `TaxConfig.rewardsAutoConvert` is set when the tracker answers `autoConvertsRewards()`). It converts one leg's whole pending pool into the asset; every holder's pending share becomes the asset at that rate. **When there is nothing to convert, the same call pushes rewards to holders in-swap.** Anyone may call `convertStep()` / `convert(steps)`.
3. Holders are paid in the assets themselves: auto-pushed (that post-swap call, and the coin's transfer poke out of swap), or pulled.

**Holder manual options (always available, out of swap).**
- `claim()` / `claimTo(to)` / `claimDenominations(to, denoms)` — each reward in its own token, no swaps.
- `claimPending(to)` — take your pending share of every not-yet-converted leg **instantly, in the quote**, plus everything else owed. Only your share leaves the pool.
- `claimAs(to, tokenOut, routes[], minOuts[], withPending)` — take everything as **one token**: USDG, the quote, any ERC-20, or native ETH (`tokenOut = address(0)`). `routes[i]` / `minOuts[i]` are indexed like `denominations(i)`; a route is a 43-byte V3 path or an ABI-encoded V4 `PoolKey` (empty = discover). A denomination that fails reverts the claim if its min is non-zero, else is paid in its own token. `withPending = true` pulls pending shares first.

**Exact accounting — the cost.** Each converting leg keeps an index and a list of conversions ("epochs"); a holder's position is settled on every balance change in O(1) per leg. This adds **~80k gas of stipend per converting leg** to every coin transfer (`balanceSyncGas = 170k + 34k × denominations + 80k × converting legs`; measured coldest settle 266k at 3 legs × 3 conversions vs 546k published). The constructor reverts `TooHeavy` above the coin's 1.1M ceiling — **about 7 converting legs** for a single-quote coin.

**Slippage.** Conversion must return ≥ `spot × (1 − slippageBps)`, spot = the route pool's current price net of its LP fee. Default 3%, creator-settable 0.1%–20% (`setSlippageBps`). Bounds price impact; does **not** stop sandwiches (accepted).

**Routes.** The creator stores a leg's route with `setRoute(input, asset, route)` (validated; empty = discover). **Hooked pools — every tokenized-stock pool on Robinhood — need a stored route**; the frontend should call `setRoute` right after launch. `legInfo(id)` shows pool, conversions, failure clock and route in use.

**Fallback.** A leg failing for `fallbackDelay` (creator-settable 1h–7d, default 1d) resolves its pool into the quote (`ConversionFallback`). Out-of-gas attempts do not start the clock. Holders never have to wait for it: `claimPending` is instant.

**Fork finding (Robinhood mainnet, two runs ~block 62.73M).** The NVDAx3L/USDG hooked pool fills at **86–90% of spot** (10 USDG and 0.1 USDG, the better size differed between runs), so the hook fee vs. depth split is not established — only that this pool costs ~10–14%. **The default 3% band refuses it.** At 20% it converts inside an unlock (314k gas). A creator rewarding in such a stock must raise `slippageBps`, or holders use `claimPending`.

**Behaviour differences vs the old trackers.** A WETH leg is paid as WETH (or use `claimAs(..., address(0), ...)` for ETH). Denominations = reward assets + quotes, max 25. `claimWithMinOuts` / `claimWithRoutes` / `basketLeg` do not exist here.

**ABI (tracker).** Functions: `convertStep`, `convert`, `claim`, `claimTo`, `claimDenominations`, `claimPending`, `claimAs`, `process`, `processHolders`, `sync`, `pokePending`, `setRoute`, `setSlippageBps`, `setFallbackDelay`, `setMinConvert`, `setMinEligible`; views `claimableOf(account, denomination)`, `claimableAll`, `pendingOf(account, legId)`, `legCount`, `legInfo(legId)`, `basketOf(input)`, `routeOf`, `failingSince(legId)`, `epochCount(legId)`, `buffered`, `unattributed`, `credited`, `slippageBps`, `fallbackDelay`, `denominations`, `inputs`, `balanceSyncGas`, `autoConvertsRewards`. Events: `Converted(legId, input, asset, amountIn, amountOut)`, `ConversionFailed(legId, input, asset, amountIn)`, `ConversionFallback(legId, input, asset, amount)`, `PendingCredited(input, amount)`, `PendingPulled(account, legId, amount)`, `RewardClaimed(account, asset, amount)`, `LegSwapFailed(account, denomination, tokenOut, amount)`, `RewardsDistributed`, `SlippageSet`, `FallbackDelaySet`, `RouteSet`, `MinConvertSet`.

**Tests.** `test/Round108.t.sol` (31), `test/Round108Hook.t.sol` (2: a swap converts, the next swap pushes the stock in-swap), `test/fork/Round108RobinhoodFork.t.sol` (3). Unaudited.

### 0h. THE COMPLETE LAUNCH ENTRYPOINT MATRIX — all **sixteen**, by family and variant

**R13 finding, and why this table exists rather than a sentence.** Two of this stack's production
defects were the same shape: the contract could do the thing and the caller never found out.
V4-pair rewards/basket launches dropped logo URLs because the frontend called the variant it knew
about; and `launchMultiPair` had no `*WithMeta` variant at all, so multi-pair logos and socials were
permanently unpublishable. Round 12 fixed the second by ADDING `launchMultiPairWithMeta` — and R13
found that the new function was named in **no** document an integrator reads, and neither were nine
of the other fifteen. A function a frontend cannot discover is, from the frontend's side,
indistinguishable from one that does not exist. So the fix for a missing variant is not complete
until the variant is written down here.

| family | plain | + metadata | + referrer | + both |
|---|---|---|---|---|
| **native** (ETH pool) | `launch` | `launchWithMeta` | `launchRef` | `launchWithMetaRef` |
| **native-rewards** | `launchRewards` | `launchRewardsWithMeta` | `launchRewardsRef` | `launchRewardsWithMetaRef` |
| **pair** | `launchPair` | `launchPairWithMeta` | *(in params)* | *(in params)* |
| **pair-rewards** | `launchPairRewards` | `launchPairRewardsWithMeta` | *(in params)* | *(in params)* |
| **pair-basket** | `launchPairRewardsBasket` | `launchPairRewardsBasketWithMeta` | *(in params)* | *(in params)* |
| **multi-pair** | `launchMultiPair` | `launchMultiPairWithMeta` | *(in params)* | *(in params)* |

**Why the referrer column is asymmetric, and why that is correct rather than a gap.** The two native
families take their params as `LaunchParams` / `RewardsLaunchParams`, neither of which carries a
`referrer` field, so naming a referrer needs a second argument and therefore a second entrypoint —
hence `…Ref` and `…WithMetaRef`. The four quote-paired families carry `referrer` **inside** their
params struct (`PairLaunchParams.referrer`, `PairRewardsLaunchParams.referrer`,
`PairRewardsBasketLaunchParams.referrer`, `MultiLaunchParams.referrer`), so a `…Ref` variant there
would be a duplicate entrypoint taking the same value twice. Sixteen is the complete set; there is
no seventeenth to add.

**Metadata is an EVENT, not storage.** Every `*WithMeta` variant emits `V4TokenMeta(token, creator,
image, banner, description, website, twitter, telegram)` and writes nothing — there is no setter and
no getter, on any of the eight contracts. An indexer that does not read `V4TokenMeta` will show the
coin with no logo for ever, and re-emitting is impossible because the entrypoint is a launch. This is
the mechanism behind both production defects above; treat a missing `V4TokenMeta` subscription as a
data-loss bug, not a cosmetic one.

**Every one of the sixteen is `external payable nonReentrant` with no access control** — which is why the
launcher is allowlisted on the hook and locker only as the LAST wiring step (`docs/DEPLOY_UNIFIED.md`).

---

## 1. Frontend

| area | what to do | section |
|---|---|---|
| stack addresses | one launcher, one hook, one locker serve every family (native ETH and ERC-20 quotes). Anything that loops over an "eth stack" and a "pair stack" must de-duplicate by address. | §0a |
| launch forms | pass `launchTick` (quote per coin, a multiple of 200) on every launch; mine the coin salt so the address ends in `0x1110`; fill the leading `vaults`, `devBuyRecipients`, `devBuyBps` fields and the sniper `whitelist` | §0b-2, §0c |
| quote picker | every ERC-20 is a permitted quote; keep the list in the app (nothing on chain enumerates it) | §0b |
| metadata | launch through the `*WithMeta` variants; metadata exists only as the `V4TokenMeta` event | §0h |
| fee display | show `totalFeeBpsOf(poolId, isBuy)`; the platform fee is **inside** it, never added on top | §0d |
| creator settings | `setRates` moves both ways and a raise applies to the next swap; admin overrides only lower | §0e |
| creator hand-off | `proposeCreator` / `acceptCreator` / `cancelCreatorProposal`, `renounceCreator` | §0b-2 |
| referrals | native to the hook: `referrerOf(poolId)` is keyed by pool id; credits sit in `owed(referrer, quote)` and are claimed with `claim(token, minWethOut)` | §0b |
| reward baskets | right after a basket launch, call `setRoute(input, asset, route)` for every leg whose best pool has a custom hook (every tokenized stock) — find the deepest live V4 pool from `Initialize` events; expose `setSlippageBps` and `setFallbackDelay` to the creator | §0g |
| holder rewards | show `claimableOf` and `pendingOf`; offer `claim`, `claimPending` (instant, in the quote) and `claimAs` (everything as one token, native ETH included, with routes and minimums the app computes) | §0g |
| multi-pair | only offer `launchMultiPair*` once the indexer handles §2's multi-pool schema | §2 |

**Never drop a deployed stack from the app.** A V4 pool is keyed by its hook; removing a generation orphans every coin on it.

## 2. Indexer

**Subscribe to** every event named in §0b-2, §0d and §0g, plus `TaxLaunch`, `PairLaunch`, `RewardsLaunch`,
`V4TokenMeta`, `MultiPairLaunch`, `PoolSeeded`, `SwapObserved`, and the PoolManager's `Initialize` and `Swap`.

**Changed signatures — a filter on an old topic0 matches nothing, silently:**

| event | topic0 |
|---|---|
| `MultiPairLaunch(address,address,uint256,uint256,uint256)` | `0x8fe4b1658c014bac60d0dce9e3d47c70be1af73d274e62013fdbb5ccb9f2de1a` |
| `PoolSeeded(address,address,bytes32,uint16,int24,uint256)` | `0x8901be2fdc857ebba5295d687e81be94dacdb760a0c5e11cfec621e5bf3ecc8e` (round 105 added the indexed `poolId`) |
| `PoolReferred(bytes32,address,address)` | gained an indexed `referrer` (round 83) — compute with `cast keccak` |

Verify any topic0 with `cast keccak "<signature>"`.

**Multi-pair coins need a multi-pool schema.** A `launchMultiPair` coin has N pools; each emits `PoolSeeded(token,
quote, poolId, weightBps, launchTick, poolSupply)`, and pool 0 also emits the ordinary `TaxLaunch` / `PairLaunch`. A
one-pool-per-token schema records it as a normal coin and gets it wrong: price and market cap describe one pool's
share of the supply, trades from every pool merge, and N−1 pools are invisible. Before showing multi-pair coins:

1. store pools per token from `PoolSeeded` (the `poolId` comes straight from the event);
2. key trades by `poolId` (the PoolManager's `Swap` and the hook's `SwapObserved` both carry it);
3. compute market cap across a token's pools, weighted;
4. treat `MultiPairLaunch` as the ingest trigger.

`launchMultiPair*` is permissionless and cannot be switched off on chain, so until that ships, alert on every
`MultiPairLaunch` and hide the coin.

**Rewards.** Basket coins use `RealmAnyPairsDividendTrackerAutoBasket` (§0g). Index `Converted`, `ConversionFailed`,
`ConversionFallback`, `PendingCredited`, `PendingPulled`, `RewardClaimed`, `RouteSet`, `SlippageSet` and
`FallbackDelaySet`. Rewards are per denomination (each reward asset and each quote), not one quote per coin.

## 3. Order of operations

1. Deploy and wire (`docs/DEPLOY_UNIFIED.md`). The launcher is allowlisted last, so the stack is inert until then.
2. Smoke-test every launch family on a throwaway wallet, including a basket launch with a stock leg and `setRoute`.
3. Point the indexer at the new addresses and §2's events **before** the app can launch on them.
4. Ship the app changes with the stack hidden: fee display (§0d), `launchTick` (§0c), salt mining (§0b-2), reward routes
   and the new claim buttons (§0g).
5. Unhide the stack. Keep multi-pair hidden until §2's schema ships.
