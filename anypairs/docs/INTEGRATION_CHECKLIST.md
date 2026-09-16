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
| 5 | `RealmAnyPairsInSwapRegistry` | contract |
| 6 | `RealmAnyPairsTaxHookPairImmutable` | contract (CREATE2, mined flags) |
| 7 | `RealmAnyPairsV4PairLpLockerImmutable` | contract |
| 8 | `RealmAnyPairsV4UnifiedLauncher` | contract |

Deploy order is in `docs/DEPLOY_UNIFIED.md`. **`RealmAnyPairsLegRouteRegistry`, `McapAutoPricing` and `McapPricing` are DELETED** — they are
not deployed, not linked, and not referenced by any contract in the stack.

Per-launch contracts (`RealmAnyPairsTokenDividend`, `RealmAnyPairsTokenPlain`, the trackers — basket launches use
`RealmAnyPairsDividendTrackerAutoBasket`, §0g) are deployed by the launcher at launch time and are not part of the eight.

> **Grep trap (RESOLVED, round 17).** `src/RealmAnyPairsV4PairLauncherImmutable.sol` used to sit in `src/`
> undeployed, re-declaring the whole deleted surface listed in §0b and misleading any "does this symbol still
> exist?" grep. **It has been deleted.** The trap is gone, but the habit is still right: check
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
| `referralSplitter()`, `setReferralSplitter(address)` | hook | **none — REFERRALS WERE REMOVED ENTIRELY in audit round 12.** The four rows here describe a migration to a feature that no longer exists; see the round-12 third pass. |
| `ReferralRouted(bytes32,address,uint256)` (event) | hook | none — its round-83 replacement `ReferralCredited` was itself removed in round 12 |
| `ReferralSplitterNotSet()` (error) | hook | removed — the renounce gate has four conditions now, not five |
| `pushReferral(address,address,address,uint256)` | hook | none — nothing is pushed; the cut is a ledger credit |
| `ReferralSplitterSet(address)` (event) | hook | none |

> ### ⚠ ROUND 83 — TWO REFERRAL SYMBOLS CHANGED RATHER THAN VANISHED, AND BOTH FAIL SILENTLY
>
> **SUPERSEDED BY AUDIT ROUND 12: REFERRALS NO LONGER EXIST AT ALL.** The whole block below, and the four referral
> rows in the table above it, describe a migration to a feature that has since been deleted — `markReferred`,
> `referrerOf`, `REFERRAL_BPS`, `PoolReferred`, `ReferralCredited` and the launcher's six `*Ref` entry points are all
> gone. Nothing here is callable and none of these events can fire. Kept as the record of what was removed; read the
> round-12 third-pass section at the end of this document for what actually ships.
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
| `setV4Route(quote, PoolKey[] hops, maxIn)`, `v4RouteOf(quote)` | platform fee converter | ROUND 105, reworked after audit round 1. Converts a quote over **Uniswap V4** pools (1–3 hops) on the **admin's trusted route**, ending in WETH or native ETH; a quote has either a V3 route (`setRoute`) or a V4 one, and setting one clears the other. The V4 floor is each hop's **current** pool price less its LP fee, composed, less 3% — no price history, no sampling, no bot. It bounds price impact only: a sandwich inside the band is accepted, and `maxIn` bounds what one quote converts **per block** (not per call — audit round 2: looping `convert` in one transaction multiplied a sandwich), after which `convert` skips with reason **`7` = `SKIP_BLOCK_CAP`**. `poke`, `samplesOf`, `sampleStatus`, the sample events and skip reason `6` were removed. Route pools may not carry the Realm AnyPairs hook. **Constructor gained a 9th argument, `poolManager`** (zero disables V4). |
| basket reward routes (**ROUND 17: `…TrackerBasket`, `…EthBasket` and `…MultiBasket` are ALL deleted. The surviving basket tracker is `RealmAnyPairsDividendTrackerAutoBasket`, whose holder-side equivalent of everything below is `claimAs(to, tokenOut, routes, minOuts, withPending)`; automatic conversion uses the ADMIN-STORED route only and never discovers — audit round 11.**) | the auto-basket tracker | ROUND 106, HISTORICAL. **Routes are discovered at conversion time**, not fixed at construction: each claim picks the deepest pool between the reward input and the leg asset across V3 (fee 100/500/3000/10000) and **hookless V4** (fee/tickSpacing 100/1, 500/1, 500/10, 2500/25, 3000/60, 10000/200, 30000/200; the ETH basket also probes native-ETH V4 pools). A basket leg with no pool **no longer reverts the launch** (`NoRouteFound` is gone from construction); its conversion falls back exactly as a dead route always did — raw input under `claimAtAnyPrice`, `LegMinOutUnmet` under a named floor. `basketLeg(...)` now reports the route a conversion would take **right now**: a 43-byte V3 path, a 160-byte ABI-encoded V4 `PoolKey`, or empty. V4 pools behind a custom hook cannot be discovered on-chain. The PoolManager is refused as a claim recipient. |
| `claimAs(to, tokenOut, routes, minOuts, withPending)` — auto-basket | the auto-basket tracker | ROUND 107, **RE-POINTED IN ROUND 17.** `claimWithRoutes` / `claimToWithRoutes` are **gone**: they belonged to `…TrackerBasket`, `…EthBasket` and `…MultiBasket`, all deleted. **Front ends must call `claimAs`**, which carries the same idea — one route and one minimum per entry, indexed like `denominations()` rather than like a leg list, an EMPTY entry meaning *discover it* (allowed only with a non-zero minimum; discovery at any price is refused), and a non-empty entry being the same encoding as before: a 43-byte V3 path or a 160-byte ABI-encoded V4 `PoolKey` INCLUDING its hook, which is still the only way to reach a hooked pool. `tokenOut` takes everything as ONE token (`address(0)` = native ETH via WETH). See §0g. **Routes may be SUPPLIED by the front end** at claim time, one per leg, indexed exactly like `minOuts`. An **empty** entry means *discover it* (round 106). A non-empty entry is the same encoding `basketLeg` reports: a 43-byte V3 path `abi.encodePacked(input, fee, asset)` or an ABI-encoded V4 `PoolKey` (160 bytes) **including its hook** — the only way to reach a V4 pool behind a custom hook, which cannot be discovered on-chain (**CORRECTED IN AUDIT ROUND 17 — the earlier claim here, "every live NVDAx3L/USDG and SPCX market on Robinhood Chain is hooked, measured 2026-09-14", is FALSE.** What 2026-09-16 actually measures, re-verified independently against an archive node: the deepest — and only live — USDG/NVDAx3L market on that chain is **HOOKLESS**, at fee 3000 / tickSpacing 30, in-range liquidity ~9.55e18. Of the seven tiers the old discovery table probed, `(500, 10)` and `(2500, 25)` are initialized with ZERO liquidity and the other five were never initialized at all. Note the shape of the error, because it recurs: the 2026-09-14 figure was almost certainly true of the tiers that were LOOKED AT and was then generalised to every market that EXISTS — a claim about the probe presented as a claim about the chain. `(3000, 30)` has since been added to `RouteLib._bestV4`, so holder-side discovery reaches that market; a hooked pool still cannot be discovered on any tier, and supplying the `PoolKey` is still the only way to reach one). Every supplied route is validated **before anything is paid**: right two tokens (the ETH basket also accepts a native-ETH pool), a live pool (V3: exists on the factory; V4: initialized), and never through the tracker's own feeder hook — else `BadRoute()`; a routes array of the wrong length is `BadRoutes()`. The claimer's `minOuts` still bound every fill. The existing `claim*` entry points are unchanged and discover every leg. **Front ends should index V4 `Initialize` events for each reward asset, pick the deepest live pool (hooked or not), and pass it here.** |
| round 107 — fork proof (Robinhood Chain mainnet, block ~62.73M); **re-pointed onto `claimAs` in round 17** | `test/fork/Round107RobinhoodFork.t.sol`: auto-discovery finds no route to NVDAx3L (every stock pool is hooked); a frontend-supplied PoolKey for the hooked NVDAx3L/USDG pool (hook 0x5dBeE309…C5c7) paid a holder 7.96 NVDAx3L for 10 USDG in rewards, claim gas 197,897 (under the 450k per-leg cap). The public RPC blocks Foundry's user agent (Cloudflare 403) — run it through a relay or a private RPC. |
| round 108 — auto-converting rewards | Basket launches deploy `RealmAnyPairsDividendTrackerAutoBasket`: fees credited to holders as pending at arrival, converted by the hook after swaps, pushed in-swap. Holders: `claim`, `claimPending` (instant, in the quote), `claimAs` (one token incl. ETH, own routes/mins). Platform admin: `setRoute`, and — since audit round 9 — `setSlippageBps`, `setFallbackDelay`, `setMinConvert`, `setMinPoke`. Creator: `setMinEligible` only. See §0g. |
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
  `referralSplitter != 0`, together with the sink it pointed at. (Audit round 12 then removed referrals entirely, so neither the splitter nor its native replacement exists.)
* **locker** (`RealmAnyPairsV4PairLpLockerImmutable`): `launcherCount != 0` (`LauncherNotSet`) — that is
  the whole check.
* **launcher** (`RealmAnyPairsV4UnifiedLauncher`): exactly `pairTaxHook.isLauncher(this)` and
  `pairLpLocker.isLauncher(this)` (`LauncherNotAllowlisted`) — **nothing else.**

Each is a legal live state while the owner still holds the key and an unrecoverable one after
renounce, which is the entire reason the check exists.

---

### 0g. ROUND 108 — rewards convert and auto-send themselves (no keeper)

**What changed.** Every basket launch of `RealmAnyPairsV4UnifiedLauncher` (pair basket, native basket, multi-pair) now deploys **`RealmAnyPairsDividendTrackerAutoBasket`** instead of `...DividendTrackerBasket` / `...EthBasket` / `...MultiBasket`. **Launch params gained one field in audit round 11: `basketRoutes`** (`bytes[]`, or `bytes[][]` on the multi-pair launch), parallel to `basket` / `rewardBaskets` — the route each leg converts through, chosen by the creator at launch. See the round-11 section at the end of this document. The old trackers stay in the tree, untouched, but are no longer deployed by the unified launcher.

**How rewards flow.**
1. The hook feeds the rewards slice in the pool's quote (native ETH is wrapped to WETH). A leg paid in the quote itself is booked to holders at once. Every other leg's share is credited to holders **immediately, as pending quote, by their balances at that moment** — a later buyer never shares in an earlier fee.
2. After **every swap** the hook calls `tracker.convertStep()` (650k gas cap, failure-isolated; `TaxConfig.rewardsAutoConvert` is set when the tracker answers `autoConvertsRewards()`). It converts one leg's whole pending pool into the asset; every holder's pending share becomes the asset at that rate. **When there is nothing to convert, the same call pushes rewards to holders in-swap.** Anyone may call `convertStep()` / `convert(steps)`.
3. Holders are paid in the assets themselves: auto-pushed (that post-swap call; since audit round 7 non-converting trackers get the same post-swap push via `process`, see below), or pulled. The coin's own transfer poke still exists but needs ≥940k gas left, so wallets rarely reach it.

**Holder manual options (always available, out of swap).**
- `claim()` / `claimTo(to)` / `claimDenominations(to, denoms)` — each reward in its own token, no swaps.
- `claimPending(to)` — take your pending share of every not-yet-converted leg **instantly, in the quote**, plus everything else owed. Only your share leaves the pool.
- `claimAs(to, tokenOut, routes[], minOuts[], withPending)` — take everything as **one token**: USDG, the quote, any ERC-20, or native ETH (`tokenOut = address(0)`). `routes[i]` / `minOuts[i]` are indexed like `denominations(i)`; a route is a 43-byte V3 path or an ABI-encoded V4 `PoolKey` (empty = discover). A denomination that fails reverts the claim if its min is non-zero, else is paid in its own token. **An empty route with a 0 minimum is never swapped** (a discovered pool can be planted at any price): that denomination is paid in its own token. The app should always send a real minimum or a route. `withPending = true` pulls pending shares first.

**Exact accounting — the cost.** Each converting leg keeps an index and a list of conversions ("epochs"); a holder's position is settled on every balance change in O(1) per leg. This adds **~80k gas of stipend per converting leg** to every coin transfer (`balanceSyncGas = 170k + 34k × denominations + 80k × converting legs`; measured coldest settle 266k at 3 legs × 3 conversions vs 546k published). **Product cap (audit round 4): at most 546k of stipend** (`MAX_AUTO_SYNC_GAS`) — one quote plus **3 converting reward tokens**; direct quote-paid shares do not count toward the 3. The tracker constructor reverts `TooHeavy` above it and the launcher refuses the launch first with `BasketTooHeavy`. The cap keeps the hook's platform-wide gas reserve (below) small.

**Pool fee.** Since audit round 12 every Realm pool has `fee == 0`; a Realm `PoolKey` built with 3000 will not initialize. External ROUTE pools keep their own fees and are unaffected.

**Slippage.** Conversion must return ≥ `spot × (1 − band)`, spot = the route pool's current price net of its LP fee. **Audit round 9: the band is platform-admin-set, its default is 4900 bps (49%) and its ceiling 5000 bps.** Since audit round 11 it applies to every automatic conversion, because every automatic conversion now goes through a stored route (`DISCOVERED_SLIPPAGE_BPS` is gone with discovery). (Before round 9: default 3%, creator-settable 0.1%–20%.) Bounds price impact; does **not** stop sandwiches (accepted). Because the floor reads the live spot, a caller who moves the route pool in the same transaction moves the floor with it: an auto-conversion can be sandwiched well past the band (audit round 6 measured up to ~97% of that leg's unconverted pool on a fee-0 pool, in or out of a swap). Accepted by design — no TWAP, oracle or keeper. The exposure per conversion is the fees accrued since that leg last converted (conversions run on most trades); holders who want a guaranteed rate use `claimPending` or `claimAs` with their own `minOut`.

**Routes.** The **platform admin** (the hook's `admin()`) stores a leg's route with `setRoute(input, asset, route)` (validated); anyone else reverts `NotPlatformAdmin`. **Audit round 9: a leg with no stored route falls through to DISCOVERY**, which may only use a pool this tracker saw qualify in an EARLIER block — see the round-9 block below for the rule, the veto and what is still open. A stored route still wins outright, is the only way to reach a hooked pool, and is the only route quoted on the wide band. Never the creator: conversion prices against the route pool's own spot, so whoever picks the pool could pick one they priced and drain holders' pending rewards. **Hooked pools — every tokenized-stock pool on Robinhood — need a stored route**, which Realm sets per stock. `legInfo(id)` shows pool, conversions, failure clock and route in use.

**In-swap safety.** Inside a trader's swap, a conversion on any venue (V4 or V3) runs only if the hook allows in-swap payouts for that input, and it must leave no PoolManager delta or pending `sync` open (the tracker's own deltas are zero, the global nonzero-delta count is unchanged and the synced-currency slot is empty); otherwise it reverts `OpenDelta` / `InSwapDenied` inside its own frame and the trade goes through. Conversion and `claimAs` credit only the output the swap itself reported, so tokens pushed in during a swap are never paid to the claimer. The in-swap **reward push** gets the same delta check: a reward token whose transfer leaves a PoolManager delta open has that push reverted, never the trade. The hook withholds enough gas after its in-swap work for a coin's own post-swap transfer, and it does so on **every pool for the heaviest coin configured on the hook** (`maxCoinTail`, raised at `configurePool` / `adminSetRewardsTracker`, event `MaxCoinTailSet`): in a multi-hop trade an earlier pool cannot see a later hop's coin, so each pool leaves room for the heaviest one. **Audit round 5:** each in-swap step also leaves room for later Realm hops in the same unlock (`SWAP_HOP_GAS` 150k × `SWAP_HOPS_COVERED` 2 = 300k; the costliest idle hooked hop measured 140k). Gas sweeps at 5k steps from 400k to 5M show no band with **up to 3 hooked hops between a working pool and the heaviest coin's pool**; a route with more hooked hops can still revert in a narrow gas range. Covering 3 hops in the reserve itself would cost 450k. The pool's own tail always reads the coin's `syncGasParams()` (a `RealmAnyPairsTokenPlain` without a tracker reports zeros), and `RealmAnyPairsTokenPlain.attachTracker` calls the hook's permissionless `refreshCoinTail(coin)` (100k cap, never starved), so attaching a tracker coin-side before or after `adminSetRewardsTracker`, or without it, raises `maxCoinTail`. Anyone can call `refreshCoinTail` for a coin with a configured pool; it only ever raises the reserve. In-swap work (auto-send, conversion, buyback, LP) therefore runs when a trade carries that reserve on top of the step's own gas; coin-moving steps also forward the coin's extra balance-sync gas. A coin's own best-effort reward push on a transfer runs only with ≥940k gas left, so the router's next coin transfer always keeps its debit floor (audit round 6), and `attachTracker` refuses trackers heavier than the launcher's 546k cap (`TrackerTooHeavy`). Frontends that want in-swap payouts can add `autoDistributeGasNeed(PoolKey)` to the wallet's estimate — nothing breaks without it, the work just runs on a later trade. The native rewards `feed` only wraps ETH to WETH; the WETH is booked by the `convertStep` the hook runs right after.

**Audit round 7 — auto-send restored for every tracker, reflections included.**
- **Post-swap rewards step for non-converting trackers.** After every swap the hook now calls `tracker.process(650_000)` (650k cap, the same `REWARD_CONVERT_GAS` as `convertStep`, low-level and failure-isolated). This runs for any pool with a rewards tracker that does not answer `autoConvertsRewards()`: the ETH `RealmAnyPairsDividendTracker`, `RealmAnyPairsDividendTrackerQuote` (USDG/WETH and reflections), and the legacy `...Basket`. The precheck is `gasleft() >= 650k + tail`, the same global coin-tail and hop reserve as every other in-swap step. It runs last, after auto-distribute, buyback, LP and reflect; for AutoBasket pools the same slot calls `convertStep()` as before.
  - Since round 6 the coin's own poke needs ≥940k and practically never runs under wallet estimates. That left these trackers claim-only; this step is now the auto-send path.
  - The trackers keep their own in-swap guards: the ETH tracker pays only codeless holders while locked, and quote trackers ask `inSwapAllowed(quote)`.
  - New: the Quote, Basket and MultiBasket `pushReward` revert `OpenDelta` inside an unlock when the transfer changed the PoolManager's nonzero-delta count or left a `sync` pending, as AutoBasket already did. The push fails, the trade does not.
- **Views.** Both `autoDistributeGasNeed` views now return `max(redeem need, 650k + tail)` on any pool with a rewards tracker, so a frontend that adds the view to the wallet estimate also gets the rewards step. Without it the trade still succeeds and the push waits for a later trade or a claim.
- **Reflection push stipend.** A tracker paying in the coin itself (`quote == token`, `rewardsInCoin`) previously capped every push at 170k. The coin's transfer needs `minDebit` (250k), so every push reverted. The stipend for a push of the coin is now `minDebit + minDebit/63 + 70_000`, with `minDebit` read live from `coin.syncGasParams()` once per `process` call.
  - Measured worst cases (cold storage, inside an unlock, max wallet live, recipient's credit sync landed): 305,500 gas at `minDebit` 250k, a 51.5k overhead, against a 323,968 stipend. AutoBasket with the coin as a denomination, at the heaviest `minDebit` 571,015: 631,000 gas against 650,078.
  - Foreign quotes keep 170k.
  - A call that cannot fit one full push (stipend + 40k) pushes nothing rather than attempt a doomed push. The coin's own 300k transfer poke therefore no longer burns 300k on a reflection tracker: a whole 3M-gas holder transfer, poke included, measured 123,186 gas.
  - Each 650k post-swap step pushes about 3 reflection holders, about 6+ USDG or ETH holders.
  - A `TokenPlain` reflection tracker built before `attachTracker` reads `minDebit` 0 (170k) and picks up the floor once attached.
- **Residual limits.**
  - AutoBasket coin legs are never pushed in-swap. A basket leg (or a donation) denominated in the coin itself needs a ~650k push stipend, which the 650k step cannot fit, so that denomination is skipped there without a failed call. It is pushed by a permissionless `process` with ≥ ~750k gas, or claimed.
  - The coin's own transfer poke (300k) still cannot push reflections; trades do.
  - Wallet estimates settle on the deferral path, so in-swap pushes need the frontend to add `autoDistributeGasNeed(PoolKey)`.
- **Tests.** `test/audit/R7Reg.t.sol`: the auditor's PoC flipped; stipend measurements; auto-push in-swap for ETH, USDG and reflection coins at estimate + view, skipped at the estimate; the `OpenDelta` guard with a control; accounting invariants; single-hop sweeps; 2- and 3-hop sweeps through these coins; and a reflection coin followed by the heaviest coin, with no gas band. The coins' `PROCESS_GAS` (300k) and `PROCESS_FLOOR` (940k) are unchanged, so the round-6 two-coin band regression stands as is.

**Audit round 8 — reward work can never revert a trade, and a paid poke guarantees delivery.**

- **Gas bands: the push reserves, the credit does not, and narrow bands are ACCEPTED.** Round 8 first gave the optional credit in `_update` the same reserve the optional push has. That was **reverted**: the auditor proved a one-deep reserve cannot close gas bands in general — it covers only the immediately next mandatory debit, so a router doing even ~60k of its own work between two coin legs re-opens one (measured **172,500 wide**) — while the reserve itself tripled the credit threshold to 881,015, above every wallet gas estimate, so ordinary buyers stopped being registered at all.
  - **`minNotify` is back to the r7 rule:** flat `MIN_NOTIFY_GAS = 175,000`, formula path `stipend + stipend/63 + 12,000` (245,650 on a flat coin, 566,666 on the heaviest). It is **below `minDebit` on every launchable coin**, so any transfer that clears the mandatory debit floor also registers the recipient. Ordinary buys register again.
  - **`PROCESS_FLOOR` stays 940,000** for the optional push: `PROCESS_GAS × 64/63 + pre-call work + TAIL_RESERVE (631,015)`. The asymmetry is deliberate and documented in the source: **skipping a push misallocates nothing** (delivery is covered by the hook's in-swap step and by the trackers' paid `distributeFor`), while **skipping a credit misallocates rewards**.
  - **Accepted residual:** narrow gas ranges exist in multi-coin and aggregator batches where *more* gas reverts than less. The **mandatory debit is the only revert** a coin adds, and it is unchanged. `test/audit/R8Reg.t.sol` keeps the auditor's PoCs asserting the band **is** there (`*_acceptedBand`), so a future change that moves one is noticed.
  - **Registration gas (F5):** the number an integrator should surface is `syncGasParams().minNotify` — the gas a buyer's transfer needs for the buyer to be registered for rewards. Below it the transfer still succeeds and nothing accrued is lost; the recipient's tracked balance simply lags until their next large-gas transfer, any claim, the permissionless `syncBalance`/`syncBalances`, or a paid `distributeFor(gasBudget, toSync)`.
  - **Trackers no longer depend on that credit at all.** A payout denominated in the coin itself (a reflection `...Quote` tracker, or an AutoBasket leg or donation in the coin) repairs the recipient's `trackedBalance` inside the tracker, right after the transfer, on both the push and the claim paths.

- **Buffered income is released in PROPORTION to registered supply (F3, High).** In every tracker that buffers income while `eligibleSupply < minEligibleFloor` (ETH, Quote, AutoBasket, and the legacy Basket / EthBasket / MultiBasket), `pending` used to be released **in full** to whoever happened to be registered at release time: a holder with 0.01% of the float could `syncBalance` + `pokePending` and take ~99.75% of it.
  - Each release now books `pending × (eligibleSupply − highWater) / (totalSupply − highWater)` and keeps the rest buffered, where `highWater` is the `eligibleSupply` already served (`pendingReleasedSupply`, per denomination on the multi-denomination trackers). The result is **path-independent**: once registrations reach `e`, exactly `pending₀ × e / totalSupply` has been booked, however many times and in however many transactions the release ran — so **grinding `pokePending` buys nothing**.
  - `reserve` is untouched (it always backed booked and buffered income alike) and `totalDistributed` grows by exactly what is booked, so `sum(claimable) + pending ≤ reserve ≤ balance` holds throughout.
  - **Nothing strands on division:** the final release — everything registered, an unreadable supply, or `RESCUE`-independent `PENDING_SETTLE_DELAY` (30 days) with no further registration — takes the remainder including rounding dust. The clock is only pushed forward by a release that actually booked something, so it cannot be ground away.
  - **Residual, by design:** the first registrant keeps the tranche it was the only eligible holder for. Its head start is bounded by one proportional slice (0.5 of a 10 ETH buffer in the regression, against 9.999999 before).

- **The 546,000 stipend cap now has ONE definition (F4).** `RealmAnyPairsGasLib.MAX_TRACKER_STIPEND` — a constants-only library, nothing deployed — is used by `AutoBasket.MAX_AUTO_SYNC_GAS`, `RealmAnyPairsTokenPlain.attachTracker`, the unified launcher's `BasketTooHeavy` check, and now **`RealmAnyPairsTokenDividend.initTracker`, which previously only clamped an over-cap stipend instead of refusing it** (`TrackerTooHeavy`). Every gas floor in the coins and the hook's per-pool `maxCoinTail` is derived from this number, so the copies must not drift.

- **Launch caps now bind contracts (adversarial Medium).**
  - **Max wallet.** `_checkMaxWallet` used to return early for **any** recipient with code, so the cap never applied to a contract — or to an EIP-7702 delegated EOA, which has code too (measured: a contract sniper at 4.5× the cap while an EOA was stopped at the cap). The blanket exemption is replaced by an explicit allowlist: the **V4 PoolManager**, the **platform swap router** (both read from the launcher at construction by bounded staticcall — *not* constructor arguments, so CREATE2 vanity addresses are unchanged), the **launcher**, its **LP locker**, the coin's **tracker**, the launch-time `maxWalletExempt` list, and any contract receiving **inside the deploying transaction** (creator vaults, the locker's dev-buy payout). **Everything else with code obeys the cap exactly like an EOA — smart-contract wallets included. That is the point of the feature.**
  - **Max buy.** The per-transaction counter was keyed on the **pool**, so a coin with several pools had its cap multiplied by its pool count (measured 1.60e22 against a 1.0e22 cap over two pools). It is keyed on the **coin** now, which aggregates every pool of that coin in one transaction at no extra gas. It stays **transient and per transaction** rather than persistent per `tx.origin` per block: a persistent counter would add a cold SSTORE (~22,100 gas, ~5,000 warm) to every guarded swap for the whole launch window and would still be defeated by a second EOA. Cross-transaction accumulation is max wallet's job, and max wallet now binds contracts.

- **The hook's own LP position fees no longer strand (informational).** `addLiquiditySelf` takes back the quote-side leftovers and earned fees of the hook's full-range position; they used to land on the hook with no accumulator, and `rescue` refuses pool assets, so they could never reach anyone. They are now credited back to that pool's **auto-liquidity pot** (`lpPot`, event `AutoLiquidityFeesRecycled`) — the pot the operation came out of, so the next add re-deploys them, with no new withdrawal surface. The coin side already went to `BURN_SINK`. The pot restore in `_maybeAddLiquidity` / `runAddLiquidity` is now additive, so a recycled credit is not overwritten.

- **`_distribute` clamps `received` to `amount`** (informational): the hook never credits more than it took, whatever else landed on it during the take.

- **`distributeFor(uint256 gasBudget)` — the permissionless PAID poke.** Added to **`RealmAnyPairsDividendTracker` (ETH), `RealmAnyPairsDividendTrackerQuote` and `RealmAnyPairsDividendTrackerAutoBasket`** — the trackers themselves, not a new contract: they hold the rewards and the ledger, so the fee can be skimmed from a delivery without touching `reserve`. **Launcher wiring is unchanged.** The legacy `...Basket` / `...EthBasket` / `...MultiBasket` trackers (no longer deployed by the unified launcher) did not get it.
  - Anyone may call it. It is `nonReentrant` and **refused inside a V4 unlock** (`NotDuringSwap`), so it can never touch an in-flight swap.
  - It books any un-booked income first, then pushes rewards round-robin through exactly the path `process` uses. On AutoBasket it also runs one `convertStep` first, so one call converts a leg and pushes in the same transaction.
  - **Two forms:** `distributeFor(gasBudget)` and **`distributeFor(gasBudget, address[] toSync)`**, which REPAIRS each listed address (`_syncBalance`) before anything is distributed. This is the answer to the deferred credit above: a fresh buyer is not in the holder ring, and `toSync` puts them in it AND pays them **in the same call**, because the repairs run before the income is booked / attributed. At most **`MAX_POKE_SYNC` = 64** addresses (`TooManyToSync` above it). Each repair is gas-capped at the tracker's own `balanceSyncGas` and isolated in `try/catch`, so a junk, excluded or codeless entry is skipped and can never fail the poke; a repair that cannot get its full stipend is skipped rather than attempted. The gas the repairs spend is **charged against `gasBudget`**. All repairs finish before the ring starts walking, so it sees one stable holder set, and the cursor is re-clamped against the new length — a grown set is reached in the same pass, a shrunk one restarts, and nothing is read out of range.
  - **Repairing alone earns nothing.** The fee is still only a share of rewards *actually delivered*, so a poke that only syncs reverts `NothingDelivered` and pays zero — a searcher syncs buyers precisely because it makes them deliverable in that same call. To register a holder for free and with no delivery, the permissionless `syncBalance(account)` / `syncBalances(accounts[])` are unchanged.
  - **Returns** `(pushed, fee)` on the ETH and Quote trackers, `(pushed, worked)` on AutoBasket.
  - **No work means no payment, and the call SUCCEEDS with `pushed == 0`.** It deliberately does not revert: anyone could otherwise front-run a searcher with the free `process()` / `convertStep()` and burn their gas at will (audit round 8, Low). A sync-only poke therefore also lands its repairs.
  - **A push is only ever paid on a delivery that actually happened.** Every payout measures what arrived at the recipient and reverts `ZeroDelivery` when it is nothing, rolling the debit, the `_spend` and the fee accrual back together. `safeTransfer` accepts a token that returns true and moves nothing (a compliance soft-blocklist, a 100% fee-on-transfer token, a proxy upgraded to a no-op); without the guard the holder was debited anyway, the value sat above `reserve`, the next sync re-booked it as fresh income and the poker was paid 2% again on every round — **702.4 of a 1000-token pool in one transaction**. The fee stays a share of the **nominal** amount, which is exactly `POKE_FEE_BPS` of what lands under a fee-on-transfer token because the fee's own transfer pays the same token fee.
  - `gasBudget` is advisory: the ring is bounded by `gasleft()` and by one pass over the holder set, so an absurd budget buys nothing.

- **Who pays what.** The fee is `POKE_FEE_BPS = 200` (2%) of what that call actually delivered — an immutable constant on all three trackers, matching `RealmAnyPairsPlatformFeeConverter.MAX_REIMBURSE_BPS`. There is no setter. It is paid **in the reward token being delivered** (ETH, the quote, or each AutoBasket denomination), never swapped, so no price oracle is involved. It is **skimmed from the delivery**: holders fund their own delivery.
  - **Ledgers stay exact.** The debit is the FULL amount — `withdrawnRewards` and `reserve` both move by it — and the recipient receives `amount - fee`. `balance >= reserve` and `sum(claimable) <= what is held` hold throughout, and a reverted push rolls its skim back with it.
  - **`RewardClaimed` reports NET on all three trackers** — what the recipient actually received, measured at the recipient on the ERC-20 trackers and exact by construction on the ETH one (a successful `call{value:}` is proof the ETH moved). Gross is `RewardClaimed + PokePaid`. New events: `PokePaid(caller, amount)` on the ETH and Quote trackers, `PokePaid(caller, denomination, amount)` on AutoBasket, plus `MinPokeSet`.
  - **Manual claims never pay a fee:** `claim`, `claimTo`, `claimDenominations`, `claimPending` and `claimAs` are all gross.
  - **In-swap pushes stay free:** the hook's post-swap `process` / `convertStep` and the coin's `_update` poke skim nothing. The skim is armed by transient state set only inside `distributeFor`.

- **Threshold.** A push is paid on only if its amount clears a per-denomination minimum: `minPoke` (ETH and Quote trackers) or `minPokeOf(denomination)` (AutoBasket). A push below it still happens, in full, for free. Creator-settable — `setMinPoke(amount)` / `setMinPoke(denomination, amount)`, the shape of `setMinConvert`: unbounded, default 0. Raising it only removes the searcher's incentive; it can never withhold a holder's reward, and `claim` and the hook's in-swap push are unaffected.

- **Anti-abuse.** A self-poke that pays only the attacker's own address pays them 2% of their own rewards — harmless. Repeated pokes are bounded by real work (`NothingDelivered`) and by the threshold. A hostile reward token is contained by the existing per-push gas caps and `try/catch`: a failing push is skipped, its debit rolls back, the holder stays fully claimable, and the poke still pays for the pushes that landed; a token that refuses every push reverts the whole poke and pays nothing. Reentry from a reward token is refused by `nonReentrant`.

- **Residual limits.** The poke is economic only where 2% of the delivered rewards beats gas, so dust books still wait for a trade or a claim — and that is also the bound on `toSync`: registering a buyer pays only if it makes rewards deliverable in the same call. A creator can set `minPoke` high enough to remove the incentive entirely (delivery then falls back to trades and `claim`, exactly as before round 8). AutoBasket coin-denominated legs are still skipped by the 650k in-swap step and need a poke or a claim.

- **Tests.** `test/audit/R8Reg.t.sol` and `test/audit/R8Reg2.t.sol`: the auditor's R7Band PoCs verbatim and flipped; the reserve constants and the credit and push costs measured; 1–3 hop mixed-flavor V4 sweeps; and, per tracker, a paid poke, the no-work revert, below-threshold non-payment, fee-free manual claims, fee-free in-swap pushes, the in-unlock refusal, solvency over mixed poke / claim / in-swap / income sequences, and a hostile reward token. For `toSync`: a deferred buyer registered and paid in the same call (with a no-`toSync` control that skips them), junk and gas-starved entries skipped with the poke still paying, the 64-address cap, sync-with-nothing-to-deliver paying nothing, the in-unlock refusal, and ring consistency — ten holders joined and one removed mid-call, then the ring walked with a 1-gas budget until everyone owed is paid exactly once. `R8Reg2.t.sol` carries the zero-delivery PoCs flipped (no fee, no count, no ledger movement; the 60-call atomic grind extracting nothing; one silent holder among several not stopping the rest; a fee-on-transfer token still paying exactly 200 bps of what landed), the F3 proportional release and its settle-after-delay, the F4 cap at the boundary, max wallet binding contracts, and the two rescue paths with every gate and invariant.

**Admin rescue on the reward trackers (round 8 scope addition, PRIVILEGED — pending its own audit pass).** Two paths on `RealmAnyPairsDividendTracker`, `...Quote` and `...AutoBasket`, both gated on the **platform admin** (the hook's live `admin()`, the key `setRoute` uses, so they survive a creator renounce), both `nonReentrant`, and both refused inside a V4 unlock. **Neither can reduce anyone's claimable balance or take `reserve`.**

1. **Stray-token rescue — always available.** `rescueStray(asset, to, amount)` on the ETH and Quote trackers; `adminRescue(asset, to, amount, false)` on AutoBasket (one entry point there purely to keep its dispatcher inside solc's stack budget; the events still distinguish the two paths). Refuses the asset the tracker pays in, the coin, every denomination and every input, and native ETH — so `reserve`, `buffered` and every claimable balance are out of reach **by construction**. Event: `Rescued(token, to, amount)`.
2. **Dead-coin sweep — timeout-gated.** `sweepStranded(to, amount)` / `adminRescue(denomination, to, amount, true)`. Takes only income that stranded because eligible supply never crossed `minEligibleFloor`: `pending[...]`, plus `unattributed[...]` on AutoBasket. Allowed only when **both** hold: eligible supply is **still** below `minEligibleFloor`, **and** `RESCUE_DELAY` (**180 days**) has passed since `lastActivityAt` — the last distribution (`_book`) or the last successful payout (`_spend`), whichever is later, stamped from deployment so the clock always runs. Refused with `NotStranded` otherwise, and with `AmountExceedsStranded` above the buffer. Each buffer moves **with its own backing** (`pending` with `reserve`, `unattributed` with `buffered`), so `balance ≥ reserve` and `sum(claimable) ≤ what is held` survive the sweep. Booked rewards are unreachable: `pending` and `unattributed` are exactly the parts no holder has a claim on. Event: `StrandedSwept(token, to, amount)`.

`unattributed[input]` now carries the same "permanently unrecoverable if eligible supply never returns above the floor" disclosure `pending` always had — and the sweep is the recovery path for both.

**Fallback.** A failing leg keeps being retried, on two clocks; either completing resolves its pool into the quote (`ConversionFallback`), and a successful conversion clears both. **Fast clock** (`failingSince`): once `fallbackDelay` (creator-settable 1h–7d, default 1d) has passed since its first real failure and it fails again. **Slow clock** (`staleSince`, audit round 6): any failure, once 7 days have passed since the first failure with no success — so a route broken in a way the fast clock cannot tell apart from griefing (a paused asset, a halted stock hook, an empty V3 pool) still resolves; the flip side, accepted, is that anyone can make a leg that nothing converted for a week fall back (holders are still paid in full, in the quote). `setRoute` clears both clocks for its leg. Forcing a fast fallback is not fully preventable without a price reference, and is accepted: on a fee-0 route a same-transaction price push, or dust ticks added inside the caller's own unlock so the conversion burns its whole budget, cost a few wei of rounding. A fallback moves no value — holders are paid the pending pool in full, in the quote. On the fast clock a failure counts only when the route itself refused (a known route error: `NoRouteFound`, `NoPrice`, `BelowMinOut`, `OpenDelta`, `InSwapDenied`, `PartialFill`, `BadRoute` — except a price refusal (`BelowMinOut`, `NoPrice`, `PartialFill`) inside someone else's unlock, where a caller can move a fee-0 V4 route pool with flash-accounted swaps for rounding), or when the attempt had the full 350k conversion budget **and burnt at least 7/8 of it** (the route genuinely needs more gas). Any other revert does not count — router strings such as a locked V3 pool's `LOK`, wrapped hook or token reverts, and failures a caller provokes from its own unlock or flash callback (audit round 5) — and neither does running out of a shorter budget, so nobody can force a working route to fall back by choosing a gas limit, donating dust, adding dust liquidity ticks or reverting the swap for free. Conversions pass no router floor; a price shortfall surfaces as the tracker's own `BelowMinOut`. Forcing one by pushing the route price costs the pool's fees and gains nothing: holders are paid the pending pool in full, in the quote. Admin routes should stay well under ~300k gas. The hook's in-swap call forwards the full budget (except possibly the very first feed of a heavy basket, which then counts as a soft failure). Holders never have to wait for it: `claimPending` is instant.

**Fork finding (Robinhood mainnet, two runs ~block 62.73M).** The NVDAx3L/USDG hooked pool fills at **86–90% of spot** (10 USDG and 0.1 USDG, the better size differed between runs), so the hook fee vs. depth split is not established — only that this pool costs ~10–14%. **The default 3% band refuses it.** At 20% it converts inside an unlock (314k gas). A creator rewarding in such a stock must raise `slippageBps`, or holders use `claimPending`.

**Behaviour differences vs the old trackers.** A WETH leg is paid as WETH (or use `claimAs(..., address(0), ...)` for ETH). Denominations = reward assets + quotes, max 25. `claimWithMinOuts` / `claimWithRoutes` / `basketLeg` do not exist here.

**ABI (tracker).** Functions: `convertStep`, `convert`, `claim`, `claimTo`, `claimDenominations`, `claimPending`, `claimAs`, `process`, `processHolders`, `sync`, `pokePending`, `setRoute` (platform admin), `setSlippageBps`, `setFallbackDelay`, `setMinConvert`, `setMinEligible`; views `claimableOf(account, denomination)`, `claimableAll`, `pendingOf(account, legId)`, `legCount`, `legInfo(legId)`, `basketOf(input)`, `routeOf`, `failingSince(legId)`, `epochCount(legId)`, `buffered`, `unattributed`, `credited`, `slippageBps`, `fallbackDelay`, `denominations`, `inputs`, `balanceSyncGas`, `autoConvertsRewards`. Events: `Converted(legId, input, asset, amountIn, amountOut)`, `ConversionFailed(legId, input, asset, amountIn)`, `ConversionFallback(legId, input, asset, amount)`, `PendingCredited(input, amount)`, `PendingPulled(account, legId, amount)`, `RewardClaimed(account, asset, amount)`, `LegSwapFailed(account, denomination, tokenOut, amount)`, `RewardsDistributed`, `SlippageSet`, `FallbackDelaySet`, `RouteSet`, `MinConvertSet`. Errors added in audit rounds: `OpenDelta`, `InSwapDenied`, `NotPlatformAdmin` (tracker), `BasketTooHeavy` (launcher). Constant: `MAX_AUTO_SYNC_GAS`. Hook additions: `maxCoinTail`, `MaxCoinTailSet(tail)`, `autoDistributeGasNeed(PoolKey)`, `refreshCoinTail(coin)` (audit round 5). Old basket trackers: a zero-floor leg with no supplied route pays the raw quote/ETH instead of discovering a pool, and a V3 leg must spend its exact input (`PartialFill`).

**Tests.** `test/Round108.t.sol` (31), `test/Round108Hook.t.sol` (2: a swap converts, the next swap pushes the stock in-swap), `test/fork/Round108RobinhoodFork.t.sol` (3), and `test/audit/R1Reg*.t.sol` (12: each audit-round-1 attack, now failing). Internally audited in rounds; not externally audited.

### 0h. THE COMPLETE LAUNCH ENTRYPOINT MATRIX — all **fourteen**, by family and variant

**R13 finding, and why this table exists rather than a sentence.** Two of this stack's production
defects were the same shape: the contract could do the thing and the caller never found out.
V4-pair rewards/basket launches dropped logo URLs because the frontend called the variant it knew
about; and `launchMultiPair` had no `*WithMeta` variant at all, so multi-pair logos and socials were
permanently unpublishable. Round 12 fixed the second by ADDING `launchMultiPairWithMeta` — and R13
found that the new function was named in **no** document an integrator reads, and neither were nine
of the other fifteen. A function a frontend cannot discover is, from the frontend's side,
indistinguishable from one that does not exist. So the fix for a missing variant is not complete
until the variant is written down here.

| family | params struct | plain | + metadata |
|---|---|---|---|
| **native** (ETH pool) | `LaunchParams` | `launch` | `launchWithMeta` |
| **native-rewards** | `RewardsLaunchParams` | `launchRewards` | `launchRewardsWithMeta` |
| **native-basket** | `RewardsBasketLaunchParams` | `launchRewardsBasket` | `launchRewardsBasketWithMeta` |
| **pair** | `PairLaunchParams` | `launchPair` | `launchPairWithMeta` |
| **pair-rewards** | `PairRewardsLaunchParams` | `launchPairRewards` | `launchPairRewardsWithMeta` |
| **pair-basket** | `PairRewardsBasketLaunchParams` | `launchPairRewardsBasket` | `launchPairRewardsBasketWithMeta` |
| **multi-pair** | `MultiLaunchParams` | `launchMultiPair` | `launchMultiPairWithMeta` |

**AUDIT ROUND 13 — THIS TABLE WAS WRONG IN BOTH DIRECTIONS, AND THAT IS THE POINT OF THE NOTE ABOVE IT.** It listed
four `…Ref` / `…WithMetaRef` entry points that audit round 12 **deleted with the referral feature**, and it omitted
the **native-basket family entirely** — `launchRewardsBasket` and `launchRewardsBasketWithMeta` are real, shipped
entry points that appeared in no integrator-facing document. So the table simultaneously advertised four functions
that do not exist and hid two that do. It has been rebuilt by enumerating `external` functions on
`RealmAnyPairsV4UnifiedLauncher` rather than by editing the old rows, because the omission proved the old rows were
not derived from the source in the first place.

**Fourteen is the complete set: seven families x {plain, +metadata}.** There is no referrer variant and no `referrer`
field in any params struct — referrals were removed in audit round 12; see the third-pass section at the end of this
document for the removed surface and the migration.

**Metadata is an EVENT, not storage.** Every `*WithMeta` variant emits `V4TokenMeta(token, creator,
image, banner, description, website, twitter, telegram)` and writes nothing — there is no setter and
no getter, on any of the eight contracts. An indexer that does not read `V4TokenMeta` will show the
coin with no logo for ever, and re-emitting is impossible because the entrypoint is a launch. This is
the mechanism behind both production defects above; treat a missing `V4TokenMeta` subscription as a
data-loss bug, not a cosmetic one.

**Every one of the fourteen is `external payable nonReentrant` with no access control** — which is why the
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
| referrals | **REMOVED in audit round 12.** There is no `referrerOf`, no referral cut and no `*Ref` entry point. Do not build a referral UI against this stack. | round-12 third pass |
| reward baskets | **The CREATOR picks each leg's route at LAUNCH** (`basketRoutes`, parallel to `basket`); after launch only Realm's admin can change one (`setRoute(input, asset, route)`). There is no discovery — a leg with no route is paid out in the input. Your launch form must let the creator name a pool per leg (pre-fill the deepest live V4/V3 pool from `Initialize` / `PoolCreated` events) and must say plainly that the pool they name prices every future conversion of that leg. **Round 12 (L-1): `basketRoutes` must be empty, or hold exactly one entry per basket leg — including an EMPTY placeholder for any direct leg (asset == input). Any other length now reverts the launch.** **Since audit round 9 the app exposes NO conversion knob to the creator**: `setSlippageBps`, `setFallbackDelay`, `setMinConvert` and `setMinPoke` are platform-admin-only, and the creator keeps only `setMinEligible` | §0g |
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
| ~~`PoolReferred`~~ | **REMOVED (round 12).** Cannot fire. Drop the subscription; see also `ReferralCredited`. |

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

**Audit round 9 — the reward knobs belong to the platform, and routes discover themselves under a cross-block rule on both existence and PRICE.**

*Three passes. The first moved every conversion knob to the platform admin and widened the slippage band. The second and third were adversarial: they broke route discovery twice and found a max-wallet bypass, a free way to start a leg's fallback clock, and two release bugs. What ships is below, including what is still open.*

- **Every knob that prices or schedules a conversion is PLATFORM-ADMIN-only** (the hook's live `admin()` — the key `setRoute` already used, so it survives a creator renounce). Every refusal is a named error:

  | knob | before | now | refusal |
  |---|---|---|---|
  | `AutoBasket.setSlippageBps` | creator, default 300 bps, max 2000 | **admin**, default **4900**, range 10–5000 | `NotPlatformAdmin` / `BadSlippage` |
  | `AutoBasket.setFallbackDelay` | creator | **admin** (range 1h–7d unchanged) | `NotPlatformAdmin` |
  | `AutoBasket.setMinConvert` | creator | **admin** | `NotPlatformAdmin` |
  | `setMinPoke` (AutoBasket, Quote, ETH tracker) | creator | **admin**; default stays 0 | `NotPlatformAdmin` |
  | `setMinEligible` (all six trackers) | creator | **creator, unchanged**, capped at 1% of supply | `NotCreator` |

  - **Why 4900.** The floor is read from the route pool's own live spot, so the band never stopped a sandwich — a sandwicher sets the spot it is measured against. A tight band mostly produced `BelowMinOut`, which resolves the leg into the **input** instead of the asset the holder was promised. The platform accepts the wider sandwich exposure so conversions land. Measured at 49% (`R6Reg`): an out-of-lock sandwich on a fee-0 route now converts at the sandwiched price rather than forcing a fallback, with the holder's credit floored at 51% of spot.
  - **`minEligible` is capped at 1% of total supply in ALL SIX trackers** (re-verified at the boundary): every launcher seeds `minEligibleFloor = totalSupply / 1e4` and every tracker caps at `floor × 1e2`.

- **`TaxHook.setAutoThreshold` (creator) is capped on a RAISE**: at most 1% of that pool's quote-side depth, read at call time (the virtual reserve of the pool's own in-range liquidity). A **lowering is never gated**; if depth reads **zero** a raise is **refused**, not defaulted (`NoQuoteLiquidity`); over the cap is `AutoThresholdAboveCap`. The platform default and `adminSetAutoThreshold` stay uncapped.

> **SUPERSEDED BY AUDIT ROUND 11 -- on-chain route discovery no longer exists.** Everything in this bullet describes machinery that has been REMOVED. It is kept as the record of why. Read the round-11 section at the end of this document for what actually ships.

- **AUTOMATIC ROUTE DISCOVERY IS ON**, under a **cross-block persistence rule**. Precedence: stored admin route (any venue, hooked pools included) → discovery → no conversion. Discovery probes four V3 fee tiers and seven **hookless** V4 fee / tick-spacing combinations; **a hooked pool is never discovered**, so a discovered route can never reach the feeder's own pools. (**AUDIT ROUND 17 corrects the conclusion this bullet drew from that** — "a tokenized stock still needs a stored route". Two things are wrong with it. The premise was wrong: the only live USDG/NVDAx3L market on Robinhood Chain is hookless, at fee 3000 / tickSpacing 30, and that tier is now in `RouteLib._bestV4`'s table — so HOLDER-SIDE discovery, which is all `claimAs` with an empty entry does, reaches a tokenized stock without any stored route. And the word "needs" was always too broad for the other half: AUTOMATIC conversion does not discover at all, on any tier, hooked or not. It converts through the ADMIN-STORED route or it does not convert — that is round 11's deliberate design and round 17 did not change it. So: a stored route is no longer needed for a holder to claim into a tokenized stock, and is still REQUIRED for the leg to convert automatically.)
  - **THE RULE: a pool may be used — as the route OR as a voter — only if this tracker already saw it clear `MIN_DISCOVERED_LIQUIDITY` in an EARLIER block, AND it is still within `CORROBORATION_BPS` of a price recorded in an earlier block** (`poolObs`). A pool seen for the first time is recorded and refused **softly** (`FirstSighting`): nothing converts, and **no clock moves**, so it cannot wedge a leg — the next block retries. Two earlier designs were broken by pools created and rigged inside one transaction; forcing a pool to persist across a block boundary means a mispriced pool with real liquidity sits exposed to arbitrage.
  - **THE VETO**: a pool that qualified in an earlier block and reads **below the floor now** does not fall silent — it **refuses the whole discovery** (`PoolSilenced`). That closes "push the honest pool out of its range, then drain".
  - **Kept**: the liquidity floor (`MIN_DISCOVERED_LIQUIDITY = 1e12`), the size cap (`DISCOVERED_MAX_POOL_BPS = 100`, i.e. 1% of the route pool's input-side depth per step), corroboration (at least two usable pools agreeing within `CORROBORATION_BPS = 500`), and the tight `DISCOVERED_SLIPPAGE_BPS = 300` for discovered routes only.
  - **Gas**: the route is resolved in `discoverSelf`, a gas-capped self-call made **outside** the capped `convertSelf` frame, and handed in through transient storage — so probing (measured up to ~106k) no longer eats a tick-crossing conversion's headroom. `CONVERT_GAS_MAX` stays 350,000 and the hook's `REWARD_CONVERT_GAS` stays 650,000; a discovery-backed step still converts inside the hook's 650k on a 2-pool, a 7-pool and a both-venues-probed pair.

- **ACCEPTED RISK, plainly.** An asset whose markets are thin, or that someone will hold mispriced across blocks against arbitrage, can be converted badly. The bound per step is the leg's pending pool and 1% of the route pool's depth; per day it is that leg's fee **stream**; it never reaches holder balances, the LP or the launch principal. Choosing such a reward asset is the creator's risk, and `setRoute` overrides discovery for any leg in the same block.

> **SUPERSEDED BY AUDIT ROUND 11 -- on-chain route discovery no longer exists.** Everything in this bullet describes machinery that has been REMOVED. It is kept as the record of why. Read the round-11 section at the end of this document for what actually ships.

- **THE PRICE PERSISTS TOO — and that closed the last High.** Existence-persistence alone was not enough: a planter who OWNS all the liquidity in two hookless pools could leave them at the FAIR price for a block (nothing for an arbitrageur to take), then in ONE transaction push both to a rigged price, call the permissionless `convertStep`, and push them back — every swap against their own liquidity, so the fees returned to them and the only real cost was gas. Measured before the fix: 1000e18 of holder income spent for 3.99e18 of asset, 996e18 of profit.
  - **The rule now:** alongside the first-qualified block, the tracker records the pool's `sqrtPriceX96` and the block it was observed in (one packed slot: 160 + 48 + 48). A pool may route or vote only while its CURRENT price is within `CORROBORATION_BPS` of a price this tracker recorded in an EARLIER block. A rig applied inside the attack transaction cannot match a record it did not write, so the discovery is deferred and nothing converts.
  - **Recovery:** the record re-anchors to the current price on EVERY sighting in a later block — in tolerance or not. So an honest pool that makes a genuine move larger than the tolerance is deferred for exactly one block and then converts again; without the re-anchor its record could never catch up and the pool would strand for ever. It gives an attacker nothing, because converting at a rigged price still requires that price to be RECORDED in an earlier block AND still standing now — i.e. the pool held mispriced across a block boundary.
  - **Deferral is soft**: `PriceMoved` never advances the fast clock, so ordinary volatility cannot burn a leg's fallback delay. The slow clock still runs, so a pair that is never in tolerance still resolves into the input.
  - **Counter 1 — rig, hold a block, convert.** This is the accepted residual below: it works, but the pool must sit mispriced across a block where anyone may arbitrage it against the planter's own liquidity. Measured (`R9Reg`), holding the mispricing for one block leaves an arbitrageur more than one step can extract.
  - **Counter 2 — walk the record a tolerance-step per block.** Bounded to one step (~9–10% in price) per BLOCK, and every block the pools are mispriced against the real market. Measured over an 8-block walk (`R9Reg.test_R9_counter_walkingTheRecordCostsMoreThanItTakes`): the walk moved the price 7,200 ticks (~2.05×) and extracted 160e18 of input for which holders still received 108.7e18 of asset — while the arbitrage left standing at the end was **131,372e18**, roughly 2,500× the value taken. Walking costs far more than it takes.
  - **Counter 3 — honest volatility.** A real 20% one-block move on the whole market defers the conversion for one block and then converts, with the fast clock untouched (`R9Reg.test_R9_counter_honestVolatilityDefersThenConverts`).

- **ACCEPTED RESIDUAL (griefing, not theft):** one dust pool just over the floor, priced outside `CORROBORATION_BPS` and held across a block, denies discovery for that pair for as long as it lives. The leg then resolves into the input and holders are whole; `setRoute` overrides it.

- **Max wallet and max buy were bypassed via V4 claim tokens (High, fixed).** `_checkMaxWallet` only runs in the coin's `_update`, so a V4 buy taken as ERC-6909 claims (`PoolManager.mint`) never touched it — measured 15.8× the cap held with `balanceOf` at zero. The hook now accumulates bought coin per `(coin, tx.origin)` in **persistent** storage while the coin's max-wallet window is live, and refuses once the total would exceed the cap (`MaxWalletAccumulated`). `tx.origin` is the key because the recipient is not knowable at that point (delivery happens later, by `take`, `mint` or a liquidity position); infrastructure is never `tx.origin`, so the PoolManager, the routers, the locker and the launcher cannot be caught, the launch transaction is exempt, and the coin's own `maxWalletExempt` allowlist is honoured (read only on the failure path). **Cost:** one cold SSTORE (~22,100) the first time an origin buys that coin, warm (~2,900) after; once the window lapses the cached entry is zeroed and the check is one zero SLOAD for the rest of the coin's life. **Accepted:** the total does not fall on sells, so during the window one EOA may buy at most one cap in total, even across a sell and re-buy.

- **A free flash-tick-spam could start a leg's fast clock (Medium, fixed).** A conversion that exhausts its budget reverts with EMPTY returndata, which no classifier can call a price refusal, so the `locked` carve-out never covered the gas arm. From inside their own unlock an attacker added dust tick positions, called the free `convertStep`, and removed them: the attempt burnt 441,617 of a 350,000 budget, started the fast clock, and left the pool byte-identical. The gas arm is now gated on `!locked`. **Consequence:** a genuinely heavy route attempted only in-swap resolves on the SLOW clock (7 days) instead of the fast one; out of lock it is unchanged.

- **Two release bugs (fixed).**
  - **F3 (High):** `unattributed` — the converting-leg twin of `pending` — was released IN FULL to whoever was registered at that instant, so 0.01% of the float could take 100% of the buffer (measured 99.999999999999999999e18 of 100e18). `_attribute` now has exactly the shape of `_releasePending`: a per-input high-water mark and a share proportional to the attributable supply. Fresh income is still credited in full; only the BACKLOG is proportional.
  - **F4 (Medium):** the release denominator was the raw total supply, but `eligibleSupply` only counts non-excluded registered balances and the locker, hook, pools, tracker and coin are all excluded — so `elig >= supply` was unreachable and a permanent fraction was releasable only through the 30-day settle clock, which every release pushed forward. The denominator is now the **attributable** supply (total less `excludedSupply`, mirrored from the coin's own `setBalance` traffic and refreshable by the permissionless `syncBalance`), and the settle clock is pushed only by the FIRST release or a **material** one (≥ 1/16 of what is still buffered).

- **Low items (fixed).** `ZeroDelivery` added to `_transferDirect` in `Basket` and `MultiBasket` (`EthBasket` pays native ETH and needs none). The poke fee is now **`POKE_FEE_BPS` of the gross, scaled by the share that actually landed**, accrued after delivery is measured — a token routing part of its fee back to the tracker used to be charged twice (~3.9% at a 50% fee); a well-behaved token is unchanged at exactly 2%. `_attribute` carries index dust instead of crediting `legIn` for a part too small to move the per-share index. `_requireUnderMaxBuy` now RECORDS the per-transaction total before applying the whitelist/`cap == 0` exemptions, so an exempt origin's buy can no longer leave headroom for a second address in the same transaction. `autoDistributeGasNeed` SUMS the steps a pool actually runs instead of returning the largest one. `RealmAnyPairsDividendTracker.rescueStray`'s dead full-gas `to.call{value: 0}("")` is removed.

- **`SWAP_HOP_GAS` 150,000 → 210,000.** Re-derived against COLD measurements (a worst-case idle Realm hop is 185,501 cold against 159,645 warm) plus the mandatory max-wallet accumulator an idle hop now also pays. Costs 120,000 more RESERVE per trade — reserve only: a trader never supplies it; without it the in-swap work simply skips to a later trade.

- **Tests run with `isolate = true`** (the project's own `foundry.toml` requires it: transient guard state only clears at transaction boundaries). Several sweeps were calibrated WARM and are recalibrated here against cold accounting — which is how a real trade runs. **Running the ROUND-8 tree under isolation reproduces every one of these bands**, so they are pre-existing and were hidden by the warm harness, not introduced by round 9: the push credit band (now ~1.40M), `takeHeavyFirst` at 1 and 2 legs, the 3-hop flow, the 3-hooked-hop worst case, and the coin's 300,000 transfer stipend no longer clearing a 3-leg tracker's push floor (best-effort by design — a skipped push misallocates nothing). Each is pinned as an accepted band so a future change that moves one is noticed.

- **Tests.** `test/audit/R9Reg.t.sol` (45), plus the three auditors' harnesses carried in and flipped to assert the fixes: `AuditR9Disc.t.sol`, `R9AdvCorroboration.t.sol`, `R9AdvMaxWallet.t.sol`, `R9Guards.t.sol` (the six max-buy guard tests — the tree had none before), `R9GasSweep.t.sol`, `R9GasClass.t.sol`, `R9FlashClock.t.sol`.

**Audit round 10 — the persistence rule hardened, an emergency brake, and the LP locker.**

> **SUPERSEDED BY AUDIT ROUND 11 -- on-chain route discovery no longer exists.** Everything in this bullet describes machinery that has been REMOVED. It is kept as the record of why. Read the round-11 section at the end of this document for what actually ships.

- **CRITICAL, closed: the price record could be poisoned inside one block.** `_persistence` wrote the observed price before and regardless of the tolerance verdict, and treated a record written in the CURRENT block as validation. Two `convertStep()` calls in one block then drained a leg: the first poke wrote the RIGGED price and refused softly, the second found a same-block record and was declared usable **with no price comparison at all**. The attacker's pools were fair at every block boundary, so the cross-block arbitrage exposure the rule exists to impose never happened. Measured: 1000e18 of holder income for 1.005e18 of asset (0.1%), repeatable whenever pending accrues. A single poke was always refused, which is why 58 discovery tests missed it — they only ever poked once per block.
  - **The record is now two-stage.** `anchorTick`/`anchorBlock` is the ONLY thing a price is validated against and is only ever a value observed in a **strictly earlier** block; `pendingTick`/`pendingBlock` is this block's observation, inert until a block passes and then promoted, and written **at most once per block** so repeated pokes cannot walk it. Nothing written in the current block can validate anything. Stored as ticks (both venues return the tick in `slot0`, so it is free) — the whole record is one slot: 24 + 32 + 24 + 32 + 32 bits.
  - Regression: `test/audit/R10RegPersistence.t.sol`, and same-block repetition added to the discovery tests.
- **Price-silencing symmetry.** A previously-qualified pool that is out of PRICE tolerance now blocks the whole discovery (`PriceMoved`), exactly as one pushed thin does (`PoolSilenced`). Before, it only dropped out of the quorum, so an attacker could silence an honest corroborator by moving its price instead of thinning it. It is still a **deferral, never a counted failure**, so ordinary volatility costs a block and not a leg; the slow clock still resolves a pair that is never in tolerance.
- **The size cap now binds.** `DISCOVERED_MAX_POOL_BPS` measured full-range virtual reserves, which a narrow concentrated position does not hold, so "1% of depth" could be the entire pending pool. A step is now also bounded by what the pool can absorb before its price leaves the corroboration band — `dx = L·2^96·tol / (sqrtP·(BPS−tol))` for currency0 in, `dy = L·sqrtP·tol / (2^96·BPS)` for currency1 in — whichever bound binds first.

- **GLOBAL EMERGENCY BRAKES, by section (operator request).** `setPausedSections(mask)` — platform owner or admin, one write, **every pool at once**. Bits: `SECTION_AUTO_DISTRIBUTE`, `SECTION_AUTO_SEND` (the creator/split share), `SECTION_BUYBACK`, `SECTION_AUTO_LIQUIDITY`, `SECTION_REFLECT`, `SECTION_REWARDS`, `SECTION_PLATFORM_SEND` (the platform cut; it also covered the referral cut until round 12 removed referrals). A bit outside the set is refused (`BadSectionMask`); `PausedSectionsSet` carries the full new mask; 0 restores normal operation.
  - **Pausing only takes work OFF THE SWAP.** Every section has a safe deferral already: the distribution pot stays accrued; the creator and platform shares book to `owed[]` and stay claimable; the buyback, auto-liquidity and reflect pots stay booked for `runBuyback` / `runAddLiquidity` / `runReflect`; holders are pushed by a later swap, the coin's transfer poke, the paid `distributeFor`, or they claim. **Nothing here can stop a holder or a creator being paid** — claims, the pull ledger and every permissionless poke are outside the switch, and a trade never fails because a section is paused.
  - The rewards SLICE that funds a tracker is deliberately not pausable: it is an internal accrual to a contract, and routing it to `owed[]` would park it where the tracker cannot claim it.
  - This is the global counterpart to the per-pool `adminSetAutoSend` and to `inSwapRegistry`, which denies in-swap payouts per QUOTE token. **Note:** a native-ETH pool cannot be denied through the registry (`setDenied` rejects `address(0)`, and a native pool's quote *is* `address(0)`), so the section brake is the only switch that covers native pools.
  - Tests: `test/audit/R9Pause.t.sol`.

- **LP locker, `compound()` (two Mediums).** `compound()` is permissionless, so both findings were about a caller choosing the moment.
  - **Price-manipulated redeployment.** It sized the add against the CURRENT price, so a caller could move the price, deploy the carried fees at a ratio nobody else would accept, move it back, and trade through the liquidity they had just placed. `_priceAnchored` now requires the tick to be within `MAX_COMPOUND_TICK_DRIFT` (1000 ticks) of an observation from a **strictly earlier** block, with the same promote-once / stage-once shape as the discovery anchor. A refusal is a **deferral** (`CompoundDeferred`): the fees stay carried, exact and reserved, and deploy on a later block. `compound()` never reverts because of the guard — it has to stay callable.
  - **Fallback-range exhaustion.** The primary range's per-tick cap can be pinned cheaply (a very narrow band far from spot buys an enormous `L` for a tiny amount of one token), and `MAX_FALLBACK` is 4, so an attacker could get four bands registered away from the market — after which every compound, for ever, deposited fees into liquidity that cannot earn, with no removal path and no admin override. **Fixed by carrying instead**: when no range covers spot, `_pickRange` returns zero headroom and the fees stay carried. Carried fees are exact, fully reserved and deployed the moment any range is usable again (the primary un-pinning, the market returning to a band, or a new band opening at spot); out-of-range liquidity is idle **and** unrecoverable, so carrying strictly dominates. The other half is already closed by the anchor: a new band can only open at a price seen in an earlier block, so bands cannot be planted at an arbitrary tick inside one transaction.
  - Tests: `test/audit/R10RegLocker.t.sol` (7).

- **Dead code removed.** `RealmAnyPairsV4PairTrackerDeployer.deployEthBasketTracker` had **no caller anywhere**: the unified launcher's similarly-named internal helper reads the native basket's legs and builds an AUTO-basket tracker, which is what every basket launch has deployed since round 108. It was embedding a whole tracker's creation bytecode in the size-critical library for nothing — **18,774 bytes**. The `RealmAnyPairsDividendTrackerEthBasket` contract stays in the tree; the launcher still uses its `Leg` struct as a calldata type, which costs nothing. Four never-emitted events were also removed (`RewardsInCoin` on the hook; `ReferralNamingFailed`, `PoolReferralMarkFailed`, `PoolReferralMarkFailedForPool` on the unified launcher) — none appears in this document or in any test.
  - **`RealmAnyPairsV4MultiPairTrackerDeployer` is now REMOVED as well.** Its only function had no caller -- a multi-pair launch deploys the auto-basket tracker like every other basket launch -- and the unified launcher no longer checks for it. **This changes deploy day: THREE linked libraries, not four.** Do not deploy it, do not export `MULTITRKDEP`, do not pass it to `--libraries`; `DeployerLibraryMissing` now covers only `RealmAnyPairsV4TokenDeployer` and `RealmAnyPairsV4PairTrackerDeployer`. `docs/DEPLOY_UNIFIED.md` is updated and is the file to follow.
  - **`RealmAnyPairsDividendTrackerMultiBasket` is unreachable too, and deliberately left in place.** Nothing constructs it: every basket launch, multi-pair included, deploys `...AutoBasket`. But the unified launcher uses its `Leg` struct as the calldata type of `rewardBaskets` in the multi-pair launch params, and mirrors its `MAX_LEGS` / `MAX_TOTAL_LEGS` / `ABSOLUTE_MAX_DENOMINATIONS` bounds. Removing it means relocating that struct and those constants; the ABI encoding would not change (struct layout is position-based), but the launcher's param types and any consumer referring to the type by name would. It costs nothing to keep -- an unconstructed contract adds no bytecode to anything deployed -- so it stays until someone wants the tidy-up.

- **`fs_permissions` for `./artifacts`** restored in the project `foundry.toml`, so the project's own suite runs standalone.

**Audit round 10, second pass — the kill switch covers native, and the dead multi-pair library is gone.**

- **The in-swap kill switch now covers NATIVE-quote pools.** `address(0)` IS the native quote, but `RealmAnyPairsInSwapRegistry.setDenied` rejected it, so `_inSwapAllowed(address(0))` could never return false and the native payout paths never consulted the registry at all — a native pool was **the one coin type with no kill switch**. Fixed consistently:
  - `setDenied` / `setDeniedBatch` accept `address(0)`, meaning the native quote. Owner-only, and the deny/undeny round trip works.
  - The hook's native branches in `_payPlatformSlot` and `_payCreatorShare` now require `_inSwapAllowed(address(0))` as well as a codeless recipient. A denied native cut books to `owed[]` and stays claimable, exactly as a denied ERC-20 cut does.
  - The two native-paying trackers (`RealmAnyPairsDividendTracker` and `...EthBasket`) read the same live switch under `address(0)`, once per `process` call rather than per holder. A denied native quote pushes nobody in-swap; every holder keeps their full claim and `claim()` is never gated.
  - **On the `address(0)` ambiguity:** the only other `address(0)` in this path is the hook's own `inSwapRegistry == address(0)` ("no registry → allow everything"), which is a *registry* address rather than a quote, so the two readings never meet. Trackers whose `quote` is an ERC-20 (Quote, Basket, MultiBasket) pass that address through unchanged; a launcher never gives them a zero quote, so none of them can accidentally ask the native question.
  - Unchanged: the AutoBasket on a native pool converts and pays in **WETH**, a real ERC-20, so it is keyed on the WETH address — denying native does not deny WETH-quote pools, and vice versa.
  - Tests: `test/audit/R10RegNativeDeny.t.sol` (7).

- **`RealmAnyPairsV4MultiPairTrackerDeployer` removed.** See the round-9 cleanup note above for the details and the new three-library deploy sequence.

**Audit round 11 — on-chain route discovery is REMOVED. Routes are chosen at launch.**

*This round has one decision in it and several fixes around it. The decision is a product decision, not a patch.*

- **THE BLUNT ASSESSMENT, asked for and given: discovery cannot be made sound without an out-of-block price source.** Three rounds tried. Every version was broken by the same single move, and the move does not depend on any detail of the defence:
  - An automatic conversion has to price itself off the pool it is about to trade on. Whatever it reads, it reads at an instant the attacker chose, because `convertStep()` is permissionless and free to call.
  - The attacker therefore rigs the pool, pokes the converter, and un-rigs — **all inside one transaction, against their own liquidity**. The pool is honest at every block boundary, so no arbitrageur is ever exposed to the rigged price, nothing is paid to the market, and the only real cost is gas.
  - We answered that with a liquidity floor (defeated: fund the floor, it is a one-off cost), a size cap (defeated: a narrow concentrated position holds almost no depth, so "1% of depth" was the whole pending pool), cross-pool corroboration (defeated: own both pools), a cross-block existence rule (defeated: plant a block early), and a cross-block PRICE anchor (defeated twice — first by staging the rigged tick on the refused path, then by walking the anchor one tolerance per block). Each fix was correct about the specific bug and wrong about the shape of the problem.
  - The only thing that would actually fix it is a price the attacking transaction **cannot move**: a V3/V4 observation TWAP over several blocks, or an external oracle. That costs an oracle dependency, a per-pool cardinality requirement, gas inside a 350k-capped frame, and a hard failure mode for every asset whose pool is too young to have a TWAP — which is every newly listed tokenized stock, the exact case discovery existed to serve. **It is not worth it.** Say plainly that a route is a choice, and let a human make it.

- **WHAT SHIPS: routes are permissionless by design, and chosen, not found.**
  - **At launch, the creator names them.** Every basket launch param gains `basketRoutes` — `bytes[]` on `RewardsBasketLaunchParams` (native basket) and `PairRewardsBasketLaunchParams` (pair basket), `bytes[][]` (one array per pair) on `MultiLaunchParams` — in the **same order as `basket` / `rewardBaskets[i]`**. Each entry is an abi-encoded V4 `PoolKey` or a V3 path, validated at construction by exactly the same code as `setRoute` (`BadRoute` on a dead, malformed or feeder-owned pool), so a bad route **fails the launch** rather than sitting broken. The array must be **either empty or exactly as long as the basket** — see audit round 12 (L-1) below for the length rule and the three silent mis-assignments it closes.
  - **After launch only the platform admin may change one** (`setRoute`, `NotPlatformAdmin`). Deliberate: the route can be picked before anyone can buy, but it must not be flippable to a rigged pool once holders have accrued rewards.
  - **Any pool, any venue, hooked pools included. No allowlist, no approval, no vetting.** A tokenized stock's real market is a hooked pool; refusing hooked pools would refuse the product. Realm does not inspect, rank or approve the pools creators name.
  - **A leg with no route does not convert.** It fails with `NoRouteFound`, which is a route refusal — the fast clock runs and the leg resolves **into the input**, paid to holders in full. This is the pre-round-9 behaviour, restored exactly.

- **THE RISK THIS BUYS, in plain words — put this in your launch UI.** *Whoever picked the pool picked the price.* A creator who points a leg at a pool they own and have priced will sell that leg's rewards into their own pool, and nothing on-chain stops it. What bounds it: only that leg's **fee stream** is exposed — never holder balances, never the LP, never the launch principal — and **every holder has an opt-out that needs nobody's permission**: `claimPending(to)` takes your share in the INPUT at full value before any conversion runs, and `claimAs(to, tokenOut, routes, minOuts, withPending)` converts it through routes and minimums **you** choose. Tell buyers to inspect the routes before they buy; surface each leg's route pool, its depth and its price next to the reward asset.

- **What stops existing entirely.** These round-9/10 findings, accepted risks and residuals are not "fixed" — the code they describe is gone: the discovery probe and its four V3 / seven V4 combinations; the liquidity floor, the size cap and the absorb bound; cross-pool corroboration and its quorum; `PoolSilenced`, `PriceMoved`, `FirstSighting`, `Uncorroborated`, `ThinDiscoveredPool`, `DiscoveredSizeCap`; the `poolObs` price record, the anchor / pending / strike machinery and `VETO_WINDOW_BLOCKS`; the `discoverSelf` gas-capped pre-frame and its transient staging slots; `routeMissing`; and the round-10 "one dust pool denies a pair" griefing residual, which cannot happen when nothing is discovered. `RealmAnyPairsRouteLib` keeps `best` for the HOLDER-side `claimAs` only, where the caller sets their own minimum and bears their own risk.

- **`RealmAnyPairsTaxHookPairImmutable.beforeAddLiquidity` is NEW — the hook's mined flags change from `0x20CC` to `0x28CC`.** Deploy day: mine the hook address for the new value. `docs/DEPLOY_UNIFIED.md` is updated and is the file to follow.
  - **H-1 (High, fixed): max wallet was bypassed by a liquidity position.** Round 9 metered buys per `tx.origin` in `afterSwap`, but `modifyLiquidity` had no hook callback at all. A quote-only concentrated range on the side the price travels to on sells is a limit order: ordinary sell flow converts it to coin with **no swap by the attacker, no `afterSwap`, no meter entry and no ERC-20 transfer**, and withdrawing it as ERC-6909 claims skips the coin's `_checkMaxWallet` too. Measured **34,888e18 held against a 1e21 cap — 34.9x — with `boughtWhileCapped == 0` and `balanceOf == 0` throughout**.
  - **Fixed by refusing, not metering** (`LiquidityLockedDuringMaxWallet`): while a guarded pool's coin has a live max-wallet window, only the launch's LP locker and the launcher may add liquidity. Metering cannot work — a position's composition changes **passively** as the price moves through it, with no callback at any point, so an add/remove meter only ever sees the endpoints, and it would still have to cover partial removes, fee-only removes, adds that deposit coin and the ERC-6909 leg. **Once `maxWalletUntil` lapses the pool is open to any LP, for ever, with no further check.** The locker is whitelisted automatically inside `setLauncher` (it reads the launcher's `pairLpLocker()`), so a deploy cannot forget it; `setLpProvider(addr, bool)` is the manual escape hatch. Tests: `test/audit/R11AdvMaxWalletLp.t.sol` (3).

- **CRITICAL (LP locker, fixed): the compound price anchor could be poisoned across two blocks.** `_priceAnchored` staged the observed tick **before and regardless** of the drift check and promoted it with no bound relative to the existing anchor. Two blocks, one transaction each, pools fair at every block boundary: rig / poke (refused, but the rigged tick is staged) / un-rig; next block the rigged tick becomes the anchor; rig again and compound at a ratio nobody would accept. Measured 1000e18 -> 1.005e18. Now the pending tick is staged **only on the path that validated**, is promoted only if it is still within drift of the anchor it was measured against (so the anchor walks at most one tolerance per block), and a genuine larger move re-anchors only after `STRIKES_TO_REANCHOR` (3) sightings in **distinct** blocks that agree with each other. Tests: `test/audit/R11LockerPoison.t.sol`, `test/audit/R11AdvLocker.t.sol`.

- **M-1 (liveness half only, fixed): the pending high-water mark could not come down.** `pendingReleasedSupply` (and `attributedSupply` on the converting-leg twin) only ever moved up, so one spike in `eligibleSupply` — a flash inflation, or an honest whale who bought and later sold — pinned it above the real float **for ever**, every later proportional release computed zero, and the buffer could drain only through the 30-day settle arm, which punishes ordinary holders with no attacker involved. It now follows supply down. The first-registrant bound is untouched: the share is still `(elig - hw) / (supply - hw)`, so 0.01% of the float still earns 0.01% of the buffer.
  - **ACCEPTED RISK, stated as such: flash-inflated eligibility can take a larger slice of a pending buffer.** Someone who can make `eligibleSupply` spike for one transaction can register a bigger share of what is waiting than their real, held position deserves. Defending it properly needs time-weighted eligibility or previous-block supply — machinery that would tax every ordinary holder's transfer to stop an attack whose payoff is one buffer's proportional slice, never anyone's balance and never the principal. **We are not building it.** The exposure is a single pending buffer, bounded by the fee stream that filled it.

- **Suite.** 78 suites, **434 tests, all passing**, `isolate = true`. Discovery-only suites deleted: `AuditR9Disc.t.sol`, `R9AdvCorroboration.t.sol`, `R9GasSweep.t.sol`, `R9GasClass.t.sol`, `R9FlashClock.t.sol`, `R10RegPersistence.t.sol`, `R11AnchorPoison.t.sol`. `R9Reg.t.sol` trimmed from 45 tests to 20 (the 25 dropped tested discovery and nothing else). Four surviving assertions in `R2RegDiscoveryPoison.t.sol`, `R2RegTracker.t.sol` and `R1RegFoT.t.sol` were reverted to the pre-discovery expectation (a planted or unnamed pool is simply not a route, so the attempt is an ordinary `NoRouteFound` refusal that runs the fast clock). New: `test/audit/R11RegRoutes.t.sol` (10) — launch routes, hooked launch routes, refusal of a feeder-owned or dead route at launch, admin-only `setRoute`, routeless legs paying the input then converting once routed, "a pool nobody named is never used", and the rigged-route / opt-out trade stated as a test.

- **Sizes** (runtime bytes; limit 98,304 = 4x EIP-170, measured on Robinhood Chain 2026-09-16; see docs/DEPLOY_UNIFIED.md, all clear): `RealmAnyPairsV4PairTrackerDeployer` 75,660 · `RealmAnyPairsTaxHookPairImmutable` 55,453 · `RealmAnyPairsV4UnifiedLauncher` 42,713 · `RealmAnyPairsDividendTrackerAutoBasket` **37,524** (down from ~43,000 with discovery in it) · `RealmAnyPairsV4TokenDeployer` 28,583 · `RealmAnyPairsV4PairLauncherImmutable` 20,744 · `RealmAnyPairsV4PairLpLockerImmutable` 19,424. Launch **calldata** grows by the routes: one V4 route is a 160-byte abi-encoded `PoolKey`, so a worst-case 3-leg multi-pair launch across 3 pairs adds roughly 1.5KB — well inside a block, and no per-launch limit moves.

**Audit round 12 — the launch-route arrays are length-checked. 1 Low, 4 informational, no High or Medium.**

*Round 12 audited the round-11 route change itself: a hostile hook on a creator-chosen route pool (reentrancy into every entry point, open deltas, reverts, gas burns, in-lock variants) and the handling of the new launch-supplied arrays. The hook half found nothing — every hostile mode either fails only that conversion or is refused, and none of them bricks a trade. The array half found L-1.*

- **L-1 (Low, fixed): the launch-supplied `basketRoutes` arrays were never length-checked.** They align on **LEGS**, not on converting legs, and the constructor consumed them with `if (i < rs.length && rs[i].length != 0)` inside the `leg.asset != input` branch. Three silent failures followed, and **every one of them shipped a launch that looked healthy and quietly never converted**:
  - a **short** array left the tail routeless;
  - a **surplus** entry past the last leg was never read and therefore never validated — which made "a bad route fails the launch" true only for indices that happened to land on a converting leg;
  - a non-empty entry at a **direct** leg's index (a leg whose asset IS the input, which converts through nothing) was silently dropped rather than shifted — so a front end that omitted that leg's empty placeholder shifted every route by one and handed a **converting** leg nothing.

  In all three the only on-chain signal was an **absent `RouteSet` event**; the coin found out roughly a day later, when the leg hit its fallback clock and started paying out in the input, and only the platform admin could repair it.
- **The fix, and it is a revert at launch in every case.** The tracker constructor now requires `routes.length == 0 || routes.length == legs.length` (`RoutesLengthMismatch(given, expected)`), and a non-empty entry at a direct leg's index is **refused by index** (`RouteAtDirectLeg(input, legIndex)`) instead of dropped — which names exactly where the caller's array went wrong. The unified launcher additionally checks the multi-pair **outer** array (`basketRoutes.length == 0 || == pairs.length`, `RewardBasketsLengthMismatch`), a dimension the tracker cannot see.
  - **This is a length rule, not a "must route everything" rule.** An explicit empty entry still means "this leg has no route", which is a legitimate launch, and an entirely empty array still means "no leg has one".
  - **Front-end action:** send `basketRoutes` with **one entry per basket leg, including empty placeholders for direct legs**, or send an empty array. Anything else now reverts the launch.
  - Tests: the auditor's four PoCs inverted in `test/audit/R12AuditRoutes.t.sol` (25 tests total), each keeping the original finding in its comment.
- **Informational, all fixed.** A "REMOVED in round 11" comment had come to rest on `_holderLeg`, which is the live per-holder per-leg settlement store — an auditor would have read the most important mapping in the contract as dead state; it now documents what it actually is. `Q96` had no code references left and survived only because three comments used `{Q96}` as an anchor — deleted, comments re-anchored. Four comments still described guards that no longer exist ("none discoverable", "zero when the failure came from discovery", "both discovery guards", and `claimAs`'s "or discovered", which read as contradicting the header's "no on-chain discovery" and is now qualified as **holder-side only**). `setRoute`'s clock-clearing loop had a mis-indented closing brace left by the deleted `routeMissing` line.
- **Noted, no action — an assumption now visible in the code.** `RouteLib.supplied` refuses a V4 route only when the pool's hook equals **this tracker's own immutable feeder**. Correct while there is a single live tax hook. If a hook v2 is ever deployed, a tracker fed by hook A would accept a route through a pool hooked by hook B, since B is not *its* feeder. The auditor confirmed that stays contained — B cannot reach A's accounting, and the route is launch- or admin-chosen either way — but a comment at the check now says so, so whoever deploys a second hook re-reads it first.
- **Suite.** 79 suites, **459 tests, all passing**, `isolate = true`. Sizes unmoved: `DividendTrackerAutoBasket` 37,524 · `TaxHookPairImmutable` 55,453 · `V4UnifiedLauncher` 42,798 · `V4PairTrackerDeployer` 75,682. Limit ~98,000, all clear.

**Audit round 12, second pass — 0% pools, compounding deleted, and the buffer capture closed properly.**

- **EVERY REALM POOL IS NOW A ZERO-FEE POOL. `POOL_FEE` 3000 → 0**, still enforced on every pool by `_shape`
  (`key.fee != POOL_FEE` → `BadPoolFee`). `LP_FEE` on both launchers matches. **Integrators: a Realm `PoolKey` has
  `fee == 0`.** Any quote, route or pool-id derivation that hard-codes 3000 for a Realm pool is now wrong — a pool
  built at the old fee cannot even be initialised.
  - **Why.** The 0.30% existed for one purpose: to feed the LP locker's `compound()`, which reinvested accrued
    trading fees into the locked position. That function was the round-12 **Critical** — permissionless, it sized an
    add against LIVE spot with a large accumulated pot, on a price anchor whose FIRST caller could found it at any
    tick and which then walked a full `MAX_COMPOUND_TICK_DRIFT` per block, so the constant bounded the *rate* of
    movement and not its magnitude (measured: 1,751e18 of profit at a 50,000-tick rig, plus a permanent compounding
    wedge by planting all four fallback bands away from market). No fee → no pot → no function.
  - **This DELETES the Critical and the fallback-band wedge outright** rather than fixing them. The code they
    describe no longer exists: `compound()`, `_compound`, `_harvest`, `_pickRange`, `_spotRange`, `_isOpen`,
    `_headroomAt`, `Range`, `fallbackRanges`, `MAX_FALLBACK`, `FALLBACK_SPAN`, `FallbackRangeOpened`, `Compounded`,
    `CompoundClamped`, `CompoundOverspend`, `CompoundDeferred`, `_priceAnchored`, `_withinDrift`, `PriceAnchor`,
    `priceAnchor`, `MAX_COMPOUND_TICK_DRIFT` and `STRIKES_TO_REANCHOR` are all gone. The locker dropped from 19,477
    to **12,441** bytes.
  - **`compound()` was removed, not admin-gated.** With a zero-fee pool there is never a pot to reinvest, so a forced
    compound would do nothing; keeping the entry point would preserve the exact shape of the finding for no benefit.
  - **The `carried0`/`carried1` closure, worked out before deleting.** Those were NOT compounding-only: `_seed`
    credits its own rounding dust to them and reserves it, and `_compound` was the only consumer. Leaving them would
    have stranded that dust permanently — never deployable (nothing compounds) and never recoverable either, since
    `rescue` is bounded by `availableOf` = balance − `reservedOf`. So the mappings are gone **and the seed dust is no
    longer reserved**: it sits as ordinary available surplus that `rescue` can sweep. Strictly more recoverable than
    before. (`_takeMeasured` lived in the compound section but `_seed` uses it, so it stays.)
- **ACCEPTED CONSEQUENCES OF 0% POOLS — state these to creators.**
  1. **Locked liquidity no longer grows from trading fees.** The only thing that grows it is the tax's LP slice, via
     the hook's in-swap auto-liquidity step (untouched).
  2. **No third-party market maker has a fee incentive to add depth.** A Realm pool's depth is what the launch seeded
     plus what the LP slice adds, and nothing else. Do not expect organic LPs.
  3. **Moving the price of a Realm pool is CHEAPER**, because there is no fee toll on the round trip. Every sandwich
     and price-impact risk already accepted in this document is correspondingly cheaper for an attacker.
  - Verified: V4 accepts fee 0 (and does not couple fee to tick spacing — that is a V3 *factory* rule, so spacing 60
    is unaffected); the tracker's `_spotOut` ends `out * (1_000_000 - feePips) / 1_000_000`, which at `feePips == 0`
    is exact identity (and it mostly reads EXTERNAL route pools, which keep their own fees); the in-swap
    auto-liquidity step is unchanged. One measured shift: the `R8Reg` accepted **gas band moved down ~24,000**
    (~1,390,000 → ~1,366,000) because a zero-fee swap does not accrue LP fees; re-located by sweep and re-pinned at
    the original granularity rather than loosened.
  - Tests: `test/audit/R12RegZeroFee.t.sol` (4). Deleted: `R10RegLocker.t.sol`, `R11AdvLocker.t.sol`,
    `R11LockerPoison.t.sol` — they tested only deleted machinery.

- **HIGH, closed: the round-11 liveness fix had reopened the round-8 buffer capture, repeatably.** Round 11 let the
  release mark follow `eligibleSupply` DOWN and persisted that write even on the `r == 0` return. Round 8's guarantee
  ("once registrations reach *e*, exactly `pending0 * e / supply` has been booked, however many times this runs") was
  gone: drop eligible supply, poke, raise it again, and the SAME band paid out a second time. Measured by the auditor
  at **1% of the float extracting 951e18 of a 1000e18 buffer — 94x fair share**, across all three tracker shapes. The
  enabling primitive is that a transfer with tuned gas performs the mandatory debit and skips the credit, after which
  the permissionless `syncBalance` re-registers.
  - **The fix: ratchet on the FRACTION served, not on a supply LEVEL.** `pendingReleasedSupply` (and the AutoBasket's
    `attributedSupply`) become `pendingReleasedFrac` / `attributedFrac`, monotone, scaled by `RELEASE_ONE = 1e18`.
    Each release computes a LIVE target `elig / supply`; if it exceeds the ratchet, it pays
    `p * (target - served) / (ONE - served)` and raises the ratchet. No write happens on the `r == 0` path at all.
  - **Why this holds BOTH properties, which a plain revert to a monotone mark does not.** *Path independence*:
    lowering eligible supply lowers the target, which pays nothing and records nothing, so returning to a previous
    level gives `target == served` and `r == 0` — total released depends only on the highest fraction ever reached,
    never on the route. *Liveness*: a monotone ABSOLUTE mark froze because a spike pinned a supply level honest
    growth might never exceed again; a fraction cannot be pinned that way, because the denominator is live — if
    attributable supply shrinks (burns, new exclusions) the target rises on its own and the remainder becomes
    payable. *Round-8 first-registrant bound*: unchanged — 0.01% of the float sets `target = 0.0001e18` and takes
    0.01% of the buffer.
  - Measured after the fix: the auditor's 300-cycle attack extracts **10.1e18 of 1000e18 — the honest ~1% share**,
    down from 951e18. Tests: `test/audit/R12AdvBufferExtraction.t.sol` — the auditor's PoC carried in unchanged, plus
    one test per property (`releaseIsPathIndependent`, `oneSpikeDoesNotKillTheProportionalLane`,
    `firstRegistrantTakesOnlyItsShare`).

- **MEDIUM, closed: a max-wallet-only launch could revert itself.** `configurePool` counts an armed max wallet as a
  guard (`hasGuards_` calls `_cacheMaxWallet` first), but the arming site still enumerated
  `maxBuyBps || launchTaxBps || tradingOpensAt` and so never called `_markLaunchTx` for a launch whose ONLY guard is
  max wallet. That launch then ran the full per-buy path with the exemption unreachable and metered its own dev buy
  against the launching EOA — **a dev buy above the cap reverted the launch outright.** Not a bypass: a brick. Now
  armed on `nc.hasGuards`, so the two conditions are the same condition. Regression:
  `test/audit/R12RegMaxWalletOnlyLaunch.t.sol`, which drives configure + seed + dev buy in ONE transaction (the
  exemption is per-transaction and the project runs `isolate = true`), and which I verified fails with
  `MaxWalletAccumulated()` when the fix is reverted.

- **LOWS, closed.**
  - **`buybackPot` / `reflectPot` were ASSIGNED, not added.** Both are zeroed before their gas-capped self-call and
    restored afterwards — but with `=`, so a credit booked WHILE the call ran (a nested swap on the same pool
    reaching `buybackPot[id] += toBuyback` in the fee split) was overwritten and that quote stranded for good
    (`rescue` refuses pool assets). The LP sites had always used `+=`; these four now do too.
  - **`setAdmin(address(0))` after renounce** is refused on the launcher and the locker
    (`AdminWouldBeUnrecoverable`). Once ownership is renounced the admin is the only remaining authority, so clearing
    it would permanently freeze configuration and rescue — and would leave the locker unable to ever admit a
    replacement launcher while holding every locked LP position. Rotating to a NEW admin is still allowed; only the
    one-way trip to nobody is closed.
  - **`RealmAnyPairsPlatformFeeConverter` had no rescue**, while its header claimed "nothing to strand". Wrong twice:
    a quote pushed here with no configured route has no path out at all, and a V4 conversion ending in WETH can leave
    residual WETH. `rescue(token, amount)` is added — admin-triggered but paying **only to `treasury`**, which is
    where every converted fee already goes, so it adds no authority the admin did not already have through
    `setRoute`. The header is corrected.
  - **`markReferred` self-referral — REPORTED, and then DECIDED: the whole feature was removed.** See the round-12
    third-pass section below; what follows is the analysis that led to that decision. The screen refused
    `address(0)`, the coin, the creator, the quote, the hook, the PoolManager, the rewards tracker, any launcher and
    the burn sink — i.e. addresses that *cannot claim*, so that naming one would burn the referral share for the
    coin's life. It does **not** attempt to detect a creator referring themselves from a second EOA, and it cannot:
    the two addresses are unrelated on chain. A creator who does this takes the referral slice of the platform fee
    for the pool's life. **Whether that is a bug depends on what the referral programme is for.** If it pays for
    genuine distribution, this is leakage and belongs off chain (screening at the point the referral is issued);
    if it is effectively a discount a creator can claim by knowing about it, it is working as intended. No on-chain
    check can tell the two apart, so I have left it alone — tell me which it is.

- **BUILD REPRODUCIBILITY (see also the SETUP section of `docs/DEPLOY_UNIFIED.md`).** Dependencies are now pinned by
  commit hash in `dependencies.lock` and restored by `bash scripts/install-deps.sh`; the dead `v4-periphery` and
  `solmate` remappings are removed. Two `_finishLaunch` frames sat ONE stack slot inside the via-IR limit and were
  packed into a `FinishParams` struct — the tree previously compiled or failed depending on which copy of v4-core
  was on disk.

- **Suite: 80 suites, 456 tests, 0 failed**, project `foundry.toml`, pinned dependencies, `isolate = true`.

**Audit round 12, third pass — REFERRALS ARE REMOVED ENTIRELY.**

*Product decision, not a security fix. `markReferred` recorded a one-shot referrer per pool and `_distribute` paid it
10% of the PLATFORM cut for the life of the coin. Its screen could only refuse addresses that provably cannot claim
(the coin, creator, quote, hook, PoolManager, rewards tracker, launchers, burn sink); it could not tell a genuine
referral from a creator naming a second EOA they control, and no on-chain check can. The feature is deleted rather
than screened or moved off chain.*

- **BREAKING — SIX LAUNCHER ENTRY POINTS NO LONGER EXIST.** Anything calling these will revert with no matching
  function. Use the non-`Ref` twin, which is unchanged:

  | removed | use instead |
  |---|---|
  | `launchRef(LaunchParams,address)` | `launch(LaunchParams)` |
  | `launchWithMetaRef(LaunchParams,Meta,address)` | `launchWithMeta(LaunchParams,Meta)` |
  | `launchRewardsRef(RewardsLaunchParams,address)` | `launchRewards(RewardsLaunchParams)` |
  | `launchRewardsWithMetaRef(RewardsLaunchParams,Meta,address)` | `launchRewardsWithMeta(RewardsLaunchParams,Meta)` |
  | `launchRewardsBasketRef(RewardsBasketLaunchParams,address)` | `launchRewardsBasket(RewardsBasketLaunchParams)` |
  | `launchRewardsBasketWithMetaRef(RewardsBasketLaunchParams,Meta,address)` | `launchRewardsBasketWithMeta(RewardsBasketLaunchParams,Meta)` |

- **BREAKING — `address referrer` IS GONE FROM EVERY LAUNCH PARAM STRUCT** (`PairLaunchParams`,
  `PairRewardsLaunchParams`, `PairRewardsBasketLaunchParams`, `MultiLaunchParams` and their pair-launcher twins).
  These are ABI-encoded by position, so **a struct built for the old layout will decode into garbage** — regenerate
  bindings rather than hand-editing.
- **REMOVED FROM THE HOOK:** `markReferred(PoolKey,address)`, the `referrerOf(PoolId)` view, `REFERRAL_BPS`,
  `PAY_SLOT_REFERRAL`, the `PoolReferred` and `ReferralCredited` events and the `BadReferrer` error. Also removed from
  the unified launcher: the never-emitted `ReferralNamingFailed`, `PoolReferralMarkFailed` and
  `PoolReferralMarkFailedForPool` events, `_tryNameReferrerMulti`, and the `referred` flag threaded through the
  multi-pair seeding loop. **Indexers: drop every referral topic; none of them can ever fire again.**
- **THE PLATFORM CUT IS UNCHANGED, AND THE TRADER PAYS EXACTLY WHAT THEY PAID BEFORE.** This is the part worth being
  precise about. The referral slice was always carved OUT of `toPlatform` at distribution time
  (`toPlatform * REFERRAL_BPS / BPS`), never added on top, and `REFERRAL_BPS` appeared nowhere in the rate maths or in
  the `configurePool` snapshot. So removing it changes no rate, no fee, and no quote — the platform simply receives
  the whole of `toPlatform` instead of 90% of it on a referred pool. Nothing is left unassigned. Pinned by
  `test/audit/R12RegNoReferrals.t.sol`.
- **THE PAYOUT RING LOST EXACTLY ONE SLOT, AND IT WAS THE LAST ONE.** `PAY_SLOT_REFERRAL` was index 22, after the
  rewards slot, so **every earlier index is unchanged and no existing payee moved**: platform stays 0, the creator
  split recipients stay 1..20, rewards stays 21. Only `PAY_SLOTS` moves, 23 → 22, and `RING_PLATFORM` is now just the
  platform bit. `autoDistributeGasNeed` no longer counts a referral slot, so a referred pool's estimate drops by one
  `AUTO_DISTRIBUTE_PER_SPLIT` (28,000).
- **Tests.** `test/audit/R12RegNoReferrals.t.sol` (2) added. No test asserted referral BEHAVIOUR; two used it
  incidentally and were updated: `R5RegHook.t.sol`'s worst-case idle-pool fixture no longer names a referrer (its
  worst case is one ring slot cheaper as a result), and a stale comment in `R9Pause.t.sol`.
- **Build.** `_finishLaunch`'s `FinishParams` struct loses its `referrer` field. That frame was the round-12
  stack-too-deep fix, so it was re-verified after this change at `optimizer_runs` 200 **and** 100,000: clean at both.

**Audit round 13 — the release ratchet outlived its buffer, and three findings in the fee converter.**

- **HIGH + MEDIUM, one root cause, FIXED (and this one was mine).** `pendingReleasedFrac` and `pendingSettleAt`
  describe ONE buffer, and round 12 never cleared them when that buffer drained. A buffer taking the full-release
  branch (`elig >= supply` — the normal resting state of a healthy coin) pinned `served` at `RELEASE_ONE` for ever, so
  every LATER buffer inherited a ratchet it had never been measured against and `target > served` became unreachable:
  - **High** — with a stale PAST `settleAt`, a new buffer released IN FULL to whoever was registered at that instant.
    Measured: a holder of `minEligibleFloor` (0.01% of supply) taking **100% of a 100e18 second buffer, 10,000x fair
    share, repeatable every 30 days** because each capture re-stamped the clock. That is the round-8 High reproduced
    across buffers — so my round-12 statement that the first-registrant bound still held was **true within a buffer
    and false across buffers**.
  - **Medium** — with a stale FUTURE `settleAt`, a new buffer paid NOTHING even to a 99.99%-registered book until the
    inherited clock elapsed, then paid in full rather than proportionally: the round-11 liveness failure, back through
    a different door.
  - **Fix:** clear `pendingReleasedFrac` and `pendingSettleAt` the moment `pending` empties, in all six trackers, so
    every buffer starts from a clean ratchet and its own clock. In `AutoBasket._attribute` the reset is keyed on the
    value ACTUALLY STORED (`u - credit + _creditLegs(...)`), not on `u - credit`, because `_creditLegs` can carry dust
    back — keying it on the latter would clear the ratchet while income was still sitting there.
  - **Three properties now proved, not two:** path-independent within a buffer, the proportional lane survives a
    spike, and **a new buffer starts from a clean ratchet with the first-registrant bound intact**. Tests:
    `test/audit/R12AdvBufferExtraction.t.sol` (both auditors’ scenarios inverted) and
    `test/audit/R13AdvRatchetStuck.t.sol` (the adversarial auditor’s three, carried in as-is).

- **`RealmAnyPairsPlatformFeeConverter` M-1, FIXED: the V4 floor had no out-of-band anchor.** `_v4Floor` derived its
  entire floor from `getSlot0` on the very pool `_swapV4` was about to trade in, one instruction earlier, then applied
  `MAX_SLIPPAGE_BPS` to it — which bounds price impact WITHIN the swap and nothing else. The floor was a function of a
  number the attacker sets. The V3 twin `_twapFloor` is anchored on an 1800-second `observe()` TWAP, so this was an
  oversight rather than a decision.
  - **Fix: `v4FloorRate` — an admin-set minimum WETH-out per 1e18 of quote.** A V4 route with no floor configured
    does not convert (`SKIP_NO_FLOOR`) rather than converting unfloored. The spot-derived figure is still computed and
    can only make the floor STRICTER, never weaker.
  - **Why an admin rate and not an on-chain anchor.** Core V4 pools keep no observations — `observe()` is a hook
    feature, not a pool one — so there is no V4 equivalent of the V3 TWAP to read. A V3 TWAP on the same pair needs a
    V3 pool to exist for every routed quote, and often none does. The remaining option, a stored last-good price with
    a drift cap, is the shape this codebase has already tried three times (reward-route discovery, twice; the LP
    locker’s compound anchor, once) and that was broken every time by the same move: the founding observation is taken
    at a moment the attacker chooses. A rate a human sets out of band is the one anchor an attack transaction cannot
    move, and it matches what this contract already assumes — the admin picks the route, so the admin can price it.
  - **Also: V4 routes through 0-fee pools are refused** (`BadRoute`). With no LP fee the rig / convert / un-rig round
    trip costs nothing but gas.
  - **Operator action:** call `setV4FloorRate(quote, rate)` for every V4-routed quote before it can convert. Set it
    conservatively — it is a floor, not a target — and revisit when the pair moves materially.

- **L-1, FIXED: `rescue` was unbounded and its justification was false.** The comment claimed it "adds no authority the
  admin did not already have through `setRoute`". Wrong on three counts, and the auditor was right: route extraction
  pays a pool (losing most of the value to other LPs), is throttled per block, and on V3 is floored by the TWAP; a
  sweep had none of those. It also claimed an unlock check the function never had. `setTreasury(attacker);
  rescue(tok, bal); setTreasury(real)` was an atomic, admin-only drain at par. **The scope now matches the
  justification:** a token with a live route cannot be rescued at all (`HasLiveRoute`) — if a balance is convertible,
  the permissionless `convert` is how it leaves, priced and throttled. Only genuinely stranded balances (routeless
  quotes, residual WETH, stray ETH) are sweepable, which is the case that justified adding it.

- **L-2, FIXED: native `convert` paid the caller even when the treasury send failed.** The native branch returns
  before the per-block cap and a failed treasury send is deliberately non-fatal, so a treasury that reverts on receive
  let anyone loop `convert(address(0))` — even inside one transaction — collecting the reimbursement each time while
  the payout bounced straight back. The reimbursement is now gated on the send succeeding, which removes the loop
  without making a stuck treasury fatal: the ETH stays and the next call forwards it. **`GAS_OVERHEAD` 60,000 →
  40,000** at the same time — the extra 20,000 was an unconditional `20,000 * gasprice + tip` subsidy on every call,
  paid out of platform revenue.

- **Informational, fixed.** Dead code in the LP locker (`_liquidityForAmount0/1`, `_liquidityForAmounts`, `Q96`, and
  the `Pool` / `FullMath` / `StateLibrary` imports and `using` — their last real caller was `_compound`, removed in
  round 12); the locker’s title still claimed it compounds; `reservedOf` was documented as the sum of
  `carried0`/`carried1`, both removed in round 12 (it is now queued refunds only); four dangling `{...}` doc links
  that would break docgen; `unlockCallback` reverting `NotPoolManager()` for a bad opcode when the caller demonstrably
  IS the PoolManager (now `BadUnlockOp(op)`); `REF_NAME_GAS` referral residue in both launchers;
  `V4PairLauncherImmutable.setAdmin` missing the `AdminWouldBeUnrecoverable` guard its own header claimed parity with;
  and both launchers’ max-wallet NatSpec still saying "contracts are exempt", false since round 8.

- **DOC DRIFT, FIXED — and §0h was wrong in BOTH directions.** The canonical entry-point matrix listed four
  `…Ref` / `…WithMetaRef` entry points that round 12 **deleted**, and omitted the **native-basket family entirely**
  (`launchRewardsBasket`, `launchRewardsBasketWithMeta` — real, shipped, and in no integrator-facing document). It
  simultaneously advertised four functions that do not exist and hid two that do, and claimed "sixteen is the complete
  set". **It is fourteen: seven families x {plain, +metadata}.** The table was rebuilt by enumerating `external`
  functions on the launcher rather than by deleting the referral rows, because the omission proved the old rows were
  never derived from the source. Also corrected: the frontend row telling apps to call `referrerOf(poolId)`, the
  indexer row telling them to subscribe to `PoolReferred` (while a later section told them to drop referral topics),
  the renounce-gate prose, the `SECTION_PLATFORM_SEND` description, the §0b removed-ABI rows, and the round-12 entry
  that still called the `markReferred` self-referral question open.

- **One test strengthened.** `R12RegNoReferrals.t.sol` asserted the ring length against a literal computed in the test,
  which restates the constant rather than checking it — it would have passed just as happily if `PAY_SLOTS` had not
  moved. It now pins the bound behaviourally: `pendingPayout(id, 21)` succeeds and `pendingPayout(id, 22)` reverts.

- **BUILD, and this one matters more than it looks: the tree compiled or failed depending on how Foundry GROUPED the
  sources, and an incremental build masked a cold-build failure.** While verifying round 13 in a clean-room checkout,
  `forge build` failed with
  `Variable size_66 is 1 too deep in the stack [ ... expr_address_18 ... srcEnd src ... dst_1 ]` — the exact signature
  that opened the round-12 build investigation, and the half of it that round 12 did **not** actually fix. The same
  commit, the same pinned dependency commits and a byte-identical `foundry.toml` compiled cleanly in the working
  checkout and failed reliably in the clean one, because solc’s stack allocation depends on which sources land in a
  compilation unit together and Foundry’s grouping is not stable across checkouts or cache states.
  - **Consequence worth stating plainly: a green `forge test` in a warm tree was not evidence the tree builds.** The
    suite had been passing on incrementally-compiled artifacts while a cold build of the same sources failed.
  - **Root cause:** `_oneMultiBasket` (renamed `_oneInputBasket` in round 17) RETURNED an `InputBasket` struct by value, so the caller’s frame held the
    returned pointer, the loop index, the array and the params pointer across two calldata-to-memory array copies.
    One slot inside the limit.
  - **Fix:** it now fills a struct the caller already allocated, IN PLACE. That removes the return copy and gives the
    frame margin instead of leaving it one unlucky grouping from breaking. Verified with **three consecutive cold
    builds** in the clean room, plus the round-12 sweep at `optimizer_runs` 200 and 100,000.
  - **Process change this justifies:** treat `rm -rf cache out && forge build` in a fresh checkout as part of
    verification, not `forge test` alone. `scripts/install-deps.sh` plus a cold build is the reproducible check.

**Audit round 14 — the buffer release is REDESIGNED, not patched again, and the settle clock is deleted.**

- **THE DECISION. Four distinct defects were found in one mechanism across rounds 11-14** — the one-way mark (11),
  inheritance across buffers (13), the partial-release residue (14, F-1), and a clock armed against a dust buffer
  firing against a pool a thousand times larger (14, adversarial). **Every one of them paid out through the same
  branch: the settle clock's "release everything to whoever is registered right now".** Each fix was correct about its
  bug and wrong about the shape of the problem, so the mechanism was rebuilt rather than patched a fifth time.
  - **`pendingSettleAt`, `PENDING_SETTLE_DELAY` and `PENDING_SETTLE_MATERIAL_SHIFT` are GONE**, along with the
    full-release branch they fed. The same for `attributeSettleAt` on the AutoBasket's converting-leg twin.
  - **The fraction ratchet is gone too.** Each buffer now carries two ABSOLUTE counters: `pendingTotal` (everything
    ever added) and `pendingServed` (what has been paid out of it). The whole rule is
    `want = pendingTotal * elig / supply; r = want > pendingServed ? want - pendingServed : 0`, clamped to what is
    held, with both counters cleared when the buffer empties.
  - **Why that kills the class rather than the instance.** A top-up raises `pendingTotal`, so `want` grows with the
    buffer — the top-up attack disappears **by construction**, not by a restamp rule. `elig >= supply` needs no
    branch: it simply makes `want == pendingTotal`. Lowering `elig` lowers `want`, which pays nothing and writes
    nothing. There is no longer any path that pays out more than the registered book's proportional share.
  - **Measured before the fix** (adversarial PoC, carried in inverted): 100.000999e18 taken against 0.0999e18 fair —
    **1001x**, three cycles, self-re-arming. And (surface PoC) a fresh cohort at 17% paid **zero** of a 107 ether
    buffer because a departed holder had left the ratchet at 23%.
  - **Useful thing the surface auditor proved while there:** `_creditLegs`' dust carry-back is **unreachable** in this
    product (it needs `eligibleSupply > 2^128` while every launch path caps supply below 2^127). So the residue the
    old form left behind was never dust — it was the arithmetic floor of the proportional branch, i.e. the common
    case. The carry-back ordering is kept anyway, because it is correct either way.

- **THE TRADE THIS BUYS, and you asked me to check it rather than assert it.**
  - *(a) Can a residue be stranded beyond the sweep?* **Yes, in one case, and it is deliberate.** `_strandedUnlocked`
    requires the book to be UNDER `minEligibleFloor`, so a book that stays permanently part-registered **and** above
    the floor holds a residue that is neither payable (no new registration) nor sweepable. It is **not lost** — it
    stays reserved and is paid the instant anyone else registers — but nothing forces it out. That is the right way
    round: the residue belongs to the holders who have not registered, and paying it early to the ones who have is
    exactly the theft the clock kept enabling. A dead book still falls under the floor and the sweep still reaches it.
  - *(b) Does repeated poking inside one block still buy nothing?* **Yes, and it is pinned.** At fixed `elig` and
    `supply`, `want` is a pure function of `pendingTotal`, so the first poke sets `pendingServed = want` and every
    later poke computes `want <= done` and returns before writing. Test:
    `R14AdvClockTopUp::test_R14_repeatedPokesInOneBlockAreFree` (25 pokes, zero movement).
  - The three original properties still hold and are still pinned: path-independent under cycling, the proportional
    lane survives a spike, and every buffer starts from a clean ratchet with the round-8 first-registrant bound.

- **F-2 (Low, fixed): a sweep must clear the counters.** `sweepStranded` (base and Quote) and `adminRescue(sweep=true)`
  (AutoBasket, both the pending and unattributed pools) empty the buffer by writing it directly, and left the ratchet
  behind — so a swept-then-revived coin measured its next buffer against money that was gone.

- **BUILD REPRODUCIBILITY — what I actually reproduced, stated precisely.** Three symptoms have now been seen across
  reviewers: a solc-internal `Invalid IR ... Quote is not terminated` at an emitted `/// @src` comment, two hangs, and
  a `std::bad_alloc`; the second auditor's two cold builds both succeeded, and so do mine. **What I reproduced is the
  stack-depth variant, not the IR-quote one**, and I fixed a real frame for it (round 13). For the `/// @src` variant
  I applied the concrete fix anyway: every multi-line `if (...)` condition in the AutoBasket is now single-line
  (semantics and short-circuit order preserved exactly — no read hoisted above a guard that used to skip it), because
  the breaking snippets are precisely the multi-line spans. solc 0.8.31 could not be fetched in this environment
  (checksum mismatch from the mirror), so that avenue is untested. **Treat reproducibility as flaky-under-load rather
  than a hard break**, and keep the standing rule: `rm -rf cache out && forge build` **twice** in a fresh checkout.

- **Other fixes this round.**
  - **F-3 (Low):** the V4 floor failed open. `setRoute` / `setV4Route` now clear the rate (a route change
    invalidates a floor priced for the old route), and `MAX_FLOOR_RATE` bounds it, because `amountIn * rate` is
    unchecked and a fat-fingered rate would make `convert` **revert** rather than skip, breaking this contract's "a
    bad state is a skip, never a revert" contract.

- **THE V4 FLOOR RATE NEVER EXPIRES — product decision, and the trade is worth stating in full.** The round-14 fix
  expired a rate after 30 days (`MAX_FLOOR_AGE`, `SKIP_STALE_FLOOR`). **That was overruled and both are removed.** The
  reasoning: a silent halt of fee conversion is worse operationally than a stale rate, and a recurring admin task with
  a quiet failure mode is not wanted. An admin-set rate now stays valid until it is changed.
  - **What that costs.** The spot term is attacker-collapsible, so the admin rate is effectively the WHOLE floor. A
    rate left far BELOW market is exploitable **in proportion to how far the price has moved** — the auditor measured
    ~450 WETH of a 500 WETH balance taken against a rate a 10x move had outrun. It is bounded **per block** by
    `maxInPerCall` and **per conversion** by the 2% reimbursement cap, but it is **not bounded by time**. A rate left
    ABOVE market is harmless: the conversion simply skips.
  - **The mitigation is operational, and this is the part to wire up.**
    1. **`FloorBound(quote, floorOut, adminRate, adminBound)` is emitted on every V4 conversion**, saying which term
       actually bound. `adminBound == true` means the admin's number, not the market, is setting the price. **A run of
       those is the cue to re-price** — it is the tripwire that replaced the expiry, so alert on it.
    2. **`v4Floor(quote)` returns `(rate, setAt, setAtBlock, ageSeconds)`** in one read, so a dashboard can show a
       rate's age without the protocol needing a rule about it.
    3. **A route change clears the rate**, which is the one case where staleness is both most likely and most
       dangerous, and the only one the protocol can detect for itself. After `setRoute` / `setV4Route` the quote does
       not convert until the rate is set again.
  - **Re-price after any large move in the pair.** Nothing on chain will do it for you, and nothing on chain will
    stop a conversion priced against a number that has been left behind.
  - **F-4 (Low):** the launch-tx exemption read `to.code.length != 0`, exempting **any contract recipient** for the
    whole transaction — so a creator launching from a bundler could fan the dev buy across contract wallets above the
    cap, reopening round 8. It is now the two movements the comment actually named: `from == launcher ||
    from == devBuySource`. Both coins' stale "contracts are uncapped" NatSpec corrected.
  - **F-5 (Low):** `pushOwed` and `SplitLib.claimTo` zeroed the ledger, transferred, and measured saturating to zero —
    so a silent-failure token (a soft blocklist) destroyed the credit permanently. Both now **re-credit the
    undelivered remainder**, mirroring the trackers' `ZeroDelivery` guard without reverting.
  - **F-6 (Low):** `_payRewardsSlot`'s two `balanceOf` reads sat in the outer frame, so a quote whose `balanceOf`
    reverts for the tracker made `runPayouts`/`distribute` revert at slot 21 and unwind payments already made. Both
    reads are now bounded staticcalls; unmeasurable-but-successful reports the full amount rather than zero, because
    the money has left and crediting `owed[]` would pay it twice.
  - **F-7 (Low):** the rewards slot was the only push ignoring `inSwapRegistry`. Gated like the other two, and the
    comment justifying the exemption — contradicted by the function's own `owed[]` fallback — corrected.
  - **F-8 (Low):** `_fillCeilBps` widened with the raw `launchTaxBps` for ever, so a year after launch a short fill
    could clear an effective 30.9% against an advertised 5%. The widening now expires with the launch window.
  - **F-9 (Low):** `pushOwed` is permissionless for contract payees and strips their payout choice. Added
    `setNoPush(bool)` — self-service opt-out, default off, so existing sinks are unaffected.
  - **Three observations folded in:** `setLauncher` now probes **both** `pairLpLocker()` and `lpLocker()` (the pair
    launcher exposes the second, so its locker was never auto-whitelisted and a max-wallet launch through it would
    have reverted at the seed); `beforeAddLiquidity` now locks third-party liquidity for the **whole launch-guard
    window**, not just the max-wallet one, because a single-sided limit range dodges a max BUY and a launch TAX just
    as well as it dodges a max wallet; and the F-10 dead declarations and stale comments are cleared.

- **Suite: 84 suites, 468 tests, 0 failed.** Two adversarial tests were REMOVED rather than fixed
  (`R13AdvRatchetStuck`'s `test_secondBufferIsStillProportional` and
  `test_laterBufferStillPaysAPartiallyRegisteredBook`): both drove the buffer through the 30-day clock, which no
  longer exists, and the properties they protected are covered on fixtures built for the new rule. The file carries a
  note saying so and where each property now lives.

**Audit round 15 — two Mediums, both inside my own fixes from the previous two rounds.**

- **F-1 (Medium, fixed): a PARTIAL sweep broke the redesign's core invariant.** The round-14 redesign rests entirely on
  `pending == pendingTotal - pendingServed`, and every write maintains it **except the sweep**, which writes `pending`
  directly. Round 14's fix cleared the counters only when the sweep EMPTIED the buffer, so after a partial sweep
  `pendingTotal` still counted money that was gone: `want = pendingTotal * elig / supply` was computed against a pool
  that no longer existed, and the `r > p` clamp bounded the payout only by the remainder — so an arbitrarily small
  `elig` was owed an arbitrarily large fraction of it. **Measured: 100 ETH buffered, 99.9 swept, a holder of 0.0999%
  of the float taking 99.9% of the 0.1 remainder — 1000x fair.**
  - **No bad admin is needed.** `sweepStranded` reverts only if `amount > pending`, and `pending` grows while the book
    is dead (`_receive` buffers below the floor **without** stamping `lastActivityAt`), so an honest
    `sweepStranded(to, pending())` silently becomes a partial sweep if a feed lands first. Chunked sweeps do it on
    purpose. My round-14 fix and its test only ever covered the full-sweep case.
  - **Fix: rebase unconditionally rather than clear conditionally** — `pendingTotal = leftAfterSweep;
    pendingServed = 0;` — at all four sites: `RealmAnyPairsDividendTracker.sweepStranded`, `Quote.sweepStranded`, and
    **both halves** of `AutoBasket.adminRescue` (`pending`/`pendingTotal` and `unattributed`/`attributedTotal`). The
    swept money is gone and nobody was served out of it, so the remainder is honestly a fresh buffer.

- **F-2 (Medium, fixed): the round-14 re-credit measured the wrong side.** `SplitLib.claimTo` and `pushOwed` credited
  back `amount - delivered` with `delivered` read from the **recipient's** balance increase — but the hook's balance
  falls by what **left**. On a fee-on-transfer quote those differ by the fee, so tokens that genuinely left and could
  never be delivered went back on the ledger as a live claim. **Repeat-claiming drew `A / (1 - f)` out of the hook per
  cycle: measured, an attacker owed 100e18 received 100e18 while consuming 111.11e18, leaving the next payee's 100e18
  entry backed by 88.89e18 and their claim reverting until new income arrived.** Permissionless, repeatable, no admin.
  - **Fix: measure this contract's own balance DECREASE** — `before = balanceOf(address(this))`,
    `delivered = before > after ? before - after : 0`. That is correct in both cases the re-credit exists for: the
    full `amount` for a fee-on-transfer quote (the fee is not ours to re-credit, and re-crediting it was the bug) and
    `0` for the soft-blocklist case round 14 set out to fix.
  - It is also immune to a recipient that moves its own balance **during** the transfer — the same flaw with direct
    theft instead of grief, for an ERC777/1363-style quote with an attacker-chosen `to`. Worth noting explicitly:
    **the `InSwapRegistry` kill switch does not cover the pull ledger**, so nothing else was standing behind this.
  - `SplitLib.claimTo` is an `external` library function delegatecalled from the hook, so `address(this)` there is the
    hook — the same assumption the function's existing `to == address(this)` guard already relies on.

- **TEST COUNTS — reported both ways from now on.** The gap between my figures and the auditors' was exactly the
  **5 fork tests** in `test/fork/`, which I had been including and they had not. This round: **476 total / 471
  excluding forks** (previous round was 472 / 467, which reconciles with the 467 both auditors measured). Both PoCs
  are carried in inverted, each keeping the original finding and its measured numbers in its comment, and each
  renamed to describe the invariant it now pins rather than the attack it used to demonstrate.

**Audit round 15, second pass — a launch-breaking HIGH from three clocks that disagreed, and the push-side twin of F-2.**

- **F-1 (HIGH, fixed): the launch-tax window and its two bounds were anchored to DIFFERENT clocks, which bricked
  buying and opened the liquidity lock.** `_effectiveBps` deliberately charges the decaying premium over
  `[tradingOpensAt, tradingOpensAt + launchTaxSecs)` so a trading delay does not eat the window — but the round-14
  fill ceiling and the round-14 liquidity lock both computed `launchTime + launchTaxSecs`. Since
  `tradingOpensAt = launchTime + 1 + (jitter % tradingDelaySecs)`, that left a `delay`-second gap where the premium is
  still CHARGED while the ceiling has narrowed back to 2100 and the lock is already off.
  - **BUYING BRICKS.** Measured at `buyBps 100`, `launchTaxBps 3000`, `launchTaxSecs 20`, `tradingDelaySecs 60`
    (delay 57): at the first legal second of trading `effectiveBps == 3000` against `ceilBps == 2100`, so a
    **fully-filled** 1e18 buy reverts `FillTooSmallForTax` — at 100% fill, because on the `beforeSwap` path
    `total == requested` exactly. **With `delay >= launchTaxSecs` the entire tradable window is bricked** and the pool
    cannot be bought at all until the premium decays under 21%. A 60s delay with a 30s launch tax is an ordinary
    advertised configuration, so this is roughly half of launches that use both features.
  - **AND IT REOPENED THE ROUND-11 H-1 DODGE.** For those seconds the lock's launch-tax clause had expired while the
    tax was still charged, so a sniper could place a single-sided quote-side range below spot, let ordinary sells walk
    the price through it, and acquire coin at 0% launch tax with no swap of their own.
  - **Fix: one clock.** `_launchTaxEndsAt(c)` returns `(tradingOpensAt != 0 ? tradingOpensAt : launchTime) +
    launchTaxSecs` and both sites read it, so all three agree with `_effectiveBps`. `launchBuyFee` needs no change —
    it is a launch-instant quote, where both anchors agree. Regression covers a delay both **shorter and longer** than
    the launch-tax window, and asserts the lock stays live across the whole charged window (through a
    non-whitelisted router, so the lock rather than the fixture's own seeding route is what is tested).

- **F-2 (Medium, fixed): the shortfall rule was missing on the in-swap ring pushes — the push-side twin of the pull
  ledger bug fixed earlier this round.** `pushSplit`, `_payCreatorShare`, `_payPlatformSlot` and `_payRewardsSlot`
  measured the RECIPIENT's balance, used it only for an event, and never re-credited `amt - delivered`; `owed[]` was
  reached only on a revert, never on a short delivery. **Measured: a 2.4e19 creator slice vanishing** — payee balance
  0, `owed` 0, ring slot cleared, `accruedQuote` zeroed so `_distribute` can never re-book it, the quote sitting on
  the hook, and `rescue` refusing it as `RescueForbiddenAsset`. **Permanently unrecoverable by anyone.**
  - **Fix:** `pushSplit` measures this contract's own balance DECREASE and returns it; all three call sites re-credit
    the remainder. `_payRewardsSlot` likewise — its round-14 measurement was tracker-side, which is wrong for the same
    reason and additionally wrong because the tracker legitimately moves the quote onward inside `feedToken`.

- **F-3 (Low, fixed):** `setPairLpLocker` rotated the locker without registering it as an LP provider. `isLpProvider`
  is written only by `setLauncher`, which probes the locker accessor at allowlist time; rotating afterwards changed
  the answer and nothing re-registered it, so every GUARDED launch would revert `LiquidityLockedDuringMaxWallet` at
  the seed while unguarded launches kept working — reading as a parameter problem rather than a wiring one. Now
  requires `pairTaxHook.isLpProvider(address(newLocker))`, mirroring how `setPairTaxHook` already self-heals.
- **F-4 (Low, fixed):** `v4FloorRate` survived route REMOVAL — both setters cleared it only in their non-empty body,
  so after `setV4Route(Q, [], 0)` the rate and its timestamp persisted and `v4Floor(Q)` reported a live-looking rate
  with a growing age for a quote with no route. Not exploitable, but `FloorBound` / `v4Floor` monitoring is the entire
  replacement for the expiry we removed, so it must not lie. The clear is hoisted above both early returns.
- **F-5 (Low, fixed):** `MAX_FLOOR_RATE` was ~8 orders of magnitude tighter than the bound it claimed, and the comment
  was wrong — `amountIn * rate` is plain CHECKED arithmetic, so the failure was a revert, not a wrap, and the real
  overflow point given `maxInPerCall <= int128.max` is ~6.8e38. The consequence was real: the unit is wei of ETH per
  1e18 BASE UNITS, so a 6-decimal quote worth more than ~1 ETH per whole token **could not be given a correct floor at
  all** — the setter reverted and the admin's only option was a rate below market, the exact direction already
  accepted as exploitable. Raised to 1e38 (still ~6.8x under the overflow point) and the comment corrected.
- **Informational:** `FloorBound` now fires AFTER the swap, not before the unlock — it was also firing on conversions
  that then skipped, and since it is the whole replacement for the removed expiry a monitor must not be counting
  attempts that never converted. Plus the locker's write-only `PoolInfo.tickLower/tickUpper` marked as such.

- **TWO ITEMS REPORTED, NOT ACTED ON — these need a decision.**
  1. **[DONE — ROUND 17] `deployBasketTracker` has no production caller.** Only the test-harness launcher reaches it, so the deployed,
     salt-linked library embeds an 863-line tracker nothing launches — the same situation `deployEthBasketTracker` was
     removed for in round 10. **If it goes, it must go BEFORE init-code hashes are published**, because removing it
     changes the library's bytecode and therefore every dependent's linked address. Say the word and I will remove it;
     I have not, because doing it after a hash is published is worse than not doing it.
  2. **[DONE — ROUND 17, removed] `RealmAnyPairsV4PairLauncherImmutable` claims guard parity with production but does not have it.** No
     `basketRoutes`, deploys `Basket` rather than `AutoBasket`, no `BasketTooHeavy` check, and it validates liquidity
     AFTER `configurePool`. So **route selection — the centrepiece of the current threat model — is untested through
     that harness.** Either bring it to parity or drop the parity claim from its header; it is not deployed, so this is
     about whether it is a trustworthy test surface.

- **Noted for the record, falsified:** a subagent claim that the hook is not its own `isLpProvider` and would revert
  its own auto-liquidity is WRONG — v4-core's `noSelfCall` means the hook's own `modifyLiquidity` never invokes
  `beforeAddLiquidity`. Do not re-tread it.

- **Suite: 481 total / 476 excluding the 5 fork tests.** Both counts reported from here on.

**Audit round 16 — a regression the round-15 fix introduced, and the fourth instance of liquidity-lock clause drift.**

- **F-2 (HIGH, fixed): the round-15 sweep rebase discarded the monotone high-water mark.** Round 15 rebased a sweep to
  `pendingTotal = leftAfterSweep; pendingServed = 0`. That restores `pending == pendingTotal - pendingServed`, which is
  all round 15 checked — but it **throws away `pendingServed`, the only thing preventing a cohort being paid twice out
  of the same buffer**, which is the round-8 guarantee `_releasePending` is documented on. The comment's premise
  ("nobody was served out of it") is false whenever `pendingServed > 0`, i.e. after any partial release.
  - **Measured, with an HONEST admin.** Float 1e23, attacker holds exactly 50%. Book dead, 100e18 buffers; the
    attacker syncs, pokes and claims its exactly-fair 49.999999999999999999e18 (`pendingServed = 50e18`); moves the
    stake out using only the mandatory debit gas so `eligibleSupply` falls to 0 (the credit is skippable by design);
    180 days later an ordinary admin sweeps what looks like a dead book, and `pendingServed` resets to 0; the attacker
    moves the stake back and draws **+24.5e18 it has already been paid for**. Total 74.5e18 of a 99e18 pool against a
    fair 49.5e18 — and **the other half of the float is halved**, 24.5e18 instead of 49.5e18. Native tracker the same
    shape. **A one-wei sweep unlocks the entire second helping**, because the reset was unconditional on sweep size.
  - **Fix: subtract, and leave the mark alone.** `pendingTotal -= amount`, with `pendingServed` untouched.
    Algebraically `pendingTotal - amount == pendingServed + leftAfterSweep`, so round 15's invariant holds exactly;
    and because `want = pendingTotal * elig / supply` can only SHRINK when `pendingTotal` shrinks, an already-served
    cohort still computes `want <= done` and draws nothing. **Both invariants are preserved rather than one being
    traded for the other** — which is what the round-15 form did. Both counters are cleared only when the buffer is
    genuinely empty, matching `_releasePending`. Applied at all four sites, including both `adminRescue` branches.
  - The round-15 partial-sweep regressions still pass unchanged, so this satisfies both rounds at once.

- **F-1 (HIGH, fixed): the liquidity lock did not cover `maxBuyBps`, the one launch guard with no window.** The
  round-14 comment asserted "the lock now covers every launch guard's window". It did not. `maxBuyBps` has no window
  at all — `_guardsFor` resolves it once into `maxBuyAmount` and `_requireUnderMaxBuy` enforces it for the life of the
  pool — so a launch guarded ONLY by `maxBuyBps` satisfied none of the three clauses at **any** timestamp, including
  the launch second. The round-11 H-1 route was open from block one.
  - **Measured:** supply 1e24, `maxBuyBps 10` (the `MIN_MAX_BUY_BPS` floor, cap 1e21), no max wallet, no launch tax,
    no delay. In the **same second as the launch**, a quote-only range below spot funded with 38,692.887e18 quote,
    filled by ordinary sell flow, taken as ERC-6909 claims: **173,917.431e18 coin against an advertised permanent cap
    of 1.000e21 — 173.9x** — with **zero** buy tax paid against 1,934.644e18 owed, and `boughtWhileCapped` and
    `coin.balanceOf` both 0 throughout.
  - **Fix: one function, not a fourth clause.** All four clauses are now in `_liquidityLockedUntil(c, coin)` beside
    `_launchTaxEndsAt`, and `beforeAddLiquidity` asks it one question. **Clause drift is what rounds 11, 14 and 15
    each independently found, and F-1 is the fourth instance** — a fourth ad-hoc clause would have been the fifth.
    Max buy contributes `MAX_BUY_LOCK_SECS` (300s) from `tradingOpensAt` (or `launchTime`), the same constant
    `setMaxBuy` already uses to mean "the advertised cap governs real trading".
  - **What this deliberately does NOT do**, and the auditor was right to caveat it: `maxBuyAmount` never expires, so
    LP-based acquisition is inherently available on every pool once the windows lapse, and locking liquidity for ever
    is not an option — a pool has to become an ordinary pool. The defect was specifically that a maxBuy-only launch
    had **no lock during the anti-snipe period the feature exists for**. The regression asserts both halves: refused
    during the window, permitted after it.

- **Carried in as regressions:** the auditor's five files (`R16TrackSweepRatchet`, `R16TrackSweepRatchetNative`,
  `R16HookMaxBuyLp`, `R16HookTaxWindow`, `R16GasReentry`), the first three inverted and renamed to describe the
  invariant they pin, each keeping the original finding and its measured numbers in its comment.
  `R16HookTaxWindow`'s **7 second-by-second sweeps across 7 configurations** (both clock-mismatch directions) are kept
  as-is — they are the independent verification that round 15's F-1 is genuinely closed and round 11's lock intact.

- **Build note:** one `forge build` in this round failed with `std::bad_alloc` and succeeded immediately on a cache
  clear — the third of the three flaky cold-build symptoms already documented. Not a source defect; the twice-over
  cold build in a fresh checkout remains the standing rule.

- **Suite: 497 total / 492 excluding the 5 fork tests.**

**Audit round 17 — dead-code removal. Bytecode-affecting: this MUST land before any init-code hash is published.**

Everything in this round is a DELETION. Each item changes the runtime bytecode of a deployed linked library, which
changes that library's address, which changes every dependent's linked bytecode and therefore every mined salt.
Nothing here changes a single ABI selector, storage slot, or on-chain behaviour of a surviving contract.

- **Deleted `src/RealmAnyPairsDividendTrackerEthBasket.sol` and `src/RealmAnyPairsDividendTrackerMultiBasket.sol`.**
  Neither was ever constructed by production code: `new RealmAnyPairsDividendTracker*` in `src/` yields only `Quote`,
  `Basket` and `AutoBasket` (in `RealmAnyPairsV4PairTrackerDeployer`) and the native `DividendTracker` (in
  `RealmAnyPairsV4TokenDeployer`). Round 9 had already removed `deployEthBasketTracker` for the same reason and left
  both files in the tree; round 17 finishes the job. **The tracker variant count is now four:**
  `RealmAnyPairsDividendTracker` (native), `…Quote`, `…Basket`, `…AutoBasket`.
  - **Struct relocation.** `RealmAnyPairsV4UnifiedLauncher` imported both files ONLY to use their `Leg` struct as a
    calldata type (`RewardsBasketLaunchParams.basket`, `MultiLaunchParams.rewardBaskets`). Those types now name
    `RealmAnyPairsDividendTrackerAutoBasket.Leg` — the identical `{address asset; uint16 bps;}`, declared by the
    contract every basket launch actually deploys and whose `Leg` the launcher was already converting into. **Verified
    ABI-safe:** `forge inspect RealmAnyPairsV4UnifiedLauncher methodIdentifiers` is byte-identical before and after
    (no selector moved); the `abi` output holds the same **116 entries — 20 events and 48 errors — in the same order,
    with the same `type` (the canonical encoding) everywhere**, and differs ONLY in four `internalType` strings, which
    is solc's documentation field and is not part of the encoding. The storage layout is unchanged in slot, offset,
    label and type (only AST node ids shift, as they do on any source edit). The four are:
    `…MultiBasket.Leg[][]` → `…AutoBasket.Leg[][]` (x2) and `…EthBasket.Leg[]` → `…AutoBasket.Leg[]` (x2). **An
    indexer or front end that decodes by selector, topic or tuple shape sees no change at all.**
- **Deleted `RealmAnyPairsV4PairTrackerDeployer.deployBasketTracker`.** Its only caller in the whole tree was
  `RealmAnyPairsV4PairLauncherImmutable` (also deleted this round). It embedded `…TrackerBasket`'s entire creation
  bytecode in the size-critical, salt-linked library for no production path: **the library's runtime size fell from
  75,929 to 55,747 bytes, −20,182.**
- **Deleted `src/RealmAnyPairsV4PairLauncherImmutable.sol`** (round 16 item 2). It was never deployed and had drifted
  out of the parity its own header claimed. **No test imported it** — the single reference anywhere in `test/` was one
  doc comment in `R17LockerRefundMeasured.t.sol`, so no coverage moved and nothing needed re-pointing.
- **`RealmAnyPairsDividendTrackerBasket` was left with no production deployer either**, since `deployBasketTracker`
  was its only one — exactly the pattern EthBasket and MultiBasket were deleted for. Flagged here rather than
  decided; **the user then approved it and pass 2 below deletes it.** The tracker set is now THREE.
- **Consistency matrix updated, no rule weakened.** `test/consistency/` went from six registered variants to four
  (`EXPECTED_VARIANTS = 4`; `EthBasketAdapter` and `MultiBasketAdapter` removed). Every RULE still runs against every
  surviving variant, and both native-paying and ERC20-paying variants are still represented. `test_MATRIX_registryIsComplete`
  enumerates `src/` for real (the `./src` `fs_permissions` grant is present), so it would have failed had the registry
  not been updated — which is the point of it.
- **COVERAGE RESTORED: `test/audit/R17FeedDuringClaim.t.sol` (3 tests).** Of the 17 tests removed below, fifteen had a
  surviving sibling row on Basket/AutoBasket/Quote/native. **Two did not**, and the class they pinned is LIVE on two
  surviving trackers, so it was rewritten against them rather than lost:
  `R5RegTracker::test_R5Reg_feedDuringClaim_bookedAtFeeTimeBalances` and
  `R2RegRoutes::test_reg_feedDuringNativeV4LegIsBookedExactlyOnce` both asserted the ROUND 5 rule that income
  arriving through `feed()` while a claim is IN FLIGHT is booked **exactly once, at fee-time balances**, and never
  re-books the claim's own in-flight value. Both were written against the deleted `…EthBasket`. The hazard survives it:
  `RealmAnyPairsDividendTracker.feed()` is **deliberately not `nonReentrant`** (a revert there would send the hook's
  rewards slice to the creator) while `claim` forwards **uncapped** gas, and `…AutoBasket` has the same open `feed()`
  plus a `claimAs(to, address(0), …)` that hands the recipient control with a raw `call{value:}`.
  - **Mutation-verified, not merely green.** Moving the native tracker's `_spend(amount)` from before the payout to
    after it makes both native tests fail `2.0 != 2.5 ether` — the claim's own ETH re-booked as income. Deleting
    `_spend(d, amt)` from the auto-basket's `claimSwapSelf` fails the auto-basket test the same way.
  - **One asymmetry recorded rather than papered over.** The auto-basket is structurally immune to the ORDERING half
    of this hazard: its `feed()` only WRAPS to WETH and books nothing (the hook forwards a fixed 200k, less than a
    full multi-leg sync), so booking always lands at a later `sync` when the claim is done and `reserve`/balance have
    moved together. Moving its `_spend` after the payout therefore changes nothing and the test correctly does not
    fail on it. What is live there — exactly-once, fee-time balances, never absorbing the in-flight value — is what
    the second mutation breaks.
- **Two internal helpers renamed** in `RealmAnyPairsV4UnifiedLauncher`, because a helper named for a contract that no
  longer exists is a false signpost — precisely the kind that sent this round chasing a stale claim in a comment.
  `_deployEthBasketTracker` → **`_deployNativeBasketTracker`** (it has deployed an `…AutoBasket` since round 108) and
  `_oneMultiBasket` → **`_oneInputBasket`** (it fills one `…AutoBasket.InputBasket`). A third, `_deployBasketTracker`
  → **`_deployPairBasketTracker`**, because it collided by name with the linked-library `deployBasketTracker` deleted
  in this round while being a different thing entirely (the PAIR launch path, deploying an `…AutoBasket`). The launcher
  now reads `_deployPairBasketTracker` / `_deployNativeBasketTracker` / `_oneInputBasket` → `_deployAutoTracker`. All
  three are `internal`, so **no selector, event topic or error signature moves**; re-verified below.
- **Tests removed: 17, all of them coverage OF the deleted contracts, none of production behaviour.** These audit
  suites test a rule once per tracker variant; only the EthBasket/MultiBasket rows were dropped and every sibling row
  for a surviving variant is untouched. `R1RegEthBasketFeed.t.sol` (whole file, 1 test); `R2RegRoutes` 1;
  `R16ZeroDelivery` 1 (the Basket, Basket-processHolders, Quote-control and Basket-claimPath rows all stay);
  `R4RegPartialFillBasket` 1 (Basket row stays); `R5RegTracker` 5; `R9Reg` 2 (native, quote, basket and autoBasket
  `cappedAt1Percent` rows all stay); `DRRegClaimFloor` 2 (Basket and AutoBasket floor suites stay); `Round106` 2;
  `Round107` 2.
- **Sizes after (runtime bytes; limit 98,304 = 4x EIP-170, measured on Robinhood Chain 2026-09-16; see docs/DEPLOY_UNIFIED.md).** Only the tracker-deployer library moved:
  `RealmAnyPairsV4PairTrackerDeployer` **55,747** (was 75,660 at round 12, 75,929 immediately before this round) ·
  `RealmAnyPairsTaxHookPairImmutable` 55,673 · `RealmAnyPairsV4UnifiedLauncher` 40,477 (byte-for-byte unchanged by the
  struct relocation) · `RealmAnyPairsDividendTrackerAutoBasket` 37,616 · `RealmAnyPairsV4TokenDeployer` 28,774 ·
  `RealmAnyPairsDividendTrackerBasket` 17,887 · `RealmAnyPairsPlatformFeeConverter` 17,498 ·
  `RealmAnyPairsV4PairLpLockerImmutable` 13,361 · `RealmAnyPairsDividendTrackerQuote` 10,086 ·
  `RealmAnyPairsDividendTracker` 8,394.
- **`foundry.toml` and `dependencies.lock` unchanged, deliberately.** No remapping and no pinned dependency became
  unused: the deleted files imported only OpenZeppelin `SafeCast`/`SafeERC20` and v4-core `Pool`/`StateLibrary`/
  `FullMath`/`TickMath`, every one of which survives in several other `src/` files. The `./src` `fs_permissions` grant
  is still required by `test_MATRIX_registryIsComplete`.
- **Build note:** `std::bad_alloc` recurred repeatedly on the full `src` + `test` compile and cleared on retry — the
  same flaky cold-build symptom recorded in round 16, not a source defect. Build with `--threads 1` and retry.

- **[DONE — ROUND 17, PASS 3] `RealmAnyPairsRouteLib`'s native-ETH probing was unreachable from production.** `best(..., probeNative, ...)`
  and `supplied(..., allowNativeIn, ...)` exist so a tracker can route through a V4 pool paired with NATIVE ETH
  (`currency0 == address(0)`) instead of its own input token. **`…EthBasket` was the only caller that ever passed
  `true`.** After its deletion all six surviving call sites — three in `…AutoBasket`, three in `…Basket` — pass
  `false` as a literal, so neither branch can be reached by any deployed path. Production native-basket launches wrap
  to WETH and convert from there (`_deployNativeBasketTracker`), which is why nothing needs it.
  - **Removed in pass 3 on the user's approval.** See the pass-3 entry below for the measured bytecode effect.
  - The two Round 106/107 tests that exercised these branches (`test_convertsEthThroughANativeV4Pool`,
    `test_suppliedNativeHookedRoute`) went with `…EthBasket`. That is coverage of a path no deployed contract can
    now take — recorded here so it is a known consequence and not a surprise in round 18.

- **Suite after passes 1–2: 538 total / 533 excluding the 5 fork tests.** (Was 552 / 547: −17 tests of deleted contracts, +3 restoring
  the feed-during-claim class onto the survivors.)

### Round 17, pass 2 — `RealmAnyPairsDividendTrackerBasket` removed. **THREE tracker variants remain.**

Removing `deployBasketTracker` in pass 1 left `…TrackerBasket` constructible from nowhere — the same state
`…EthBasket` and `…MultiBasket` were deleted for. It is now deleted too. **The production set is
`RealmAnyPairsDividendTracker` (native), `…Quote` and `…AutoBasket`.** Every basket launch deploys `…AutoBasket`.

- **Struct relocation, same treatment and same proof.** `RewardsPairLaunchParams.basket` was the last use of
  `…TrackerBasket.Leg` and now names `…AutoBasket.Leg`. `forge inspect RealmAnyPairsV4UnifiedLauncher`:
  `methodIdentifiers` **byte-identical**; the ABI holds the same **116 entries — 20 events, 48 errors — in the same
  order with the same `type` everywhere**; the only delta is **two `internalType` strings**
  (`…TrackerBasket.Leg[]` → `…AutoBasket.Leg[]`). No selector, topic or tuple shape moved.
- **THE TWO-STEP TRAP, AND HOW IT WAS AVOIDED.** Pass 1 justified deleting 15 of its 17 tests by naming a surviving
  **Basket** row for each. Deleting Basket now would have silently evaporated exactly those justifications — a loss
  that looks like nothing at either step. So every one of the **32** Basket-dependent tests was resolved by name:
  **23 deleted with a named survivor, 5 RE-POINTED onto `…AutoBasket`, 2 fork tests re-pointed, 0 dropped.**

| deleted Basket test(s) | named survivor |
|---|---|
| `R9Reg basketTracker_cappedAt1Percent` | `R9Reg autoBasketTracker_cappedAt1Percent` (+ native, quote rows) |
| `R5RegTracker basket_v3Overspend1wei_legPasses` / `_claimPasses_residualShortfallDocumented` / `basket_v3Underspend_stillReverts` | `R5RegTracker autoBasket_v3Overspend1wei_convertSelfPasses` / `_convertCommits_shortfallHealsOnIncome` / `autoBasket_v3Underspend_stillReverts` |
| `R4RegPartialFillBasket basket_v3PartialFill_legReverts_nothingRebooked` (whole file) | `R2RegRoutes::R2RegAutoBasketPartialFillTest` ×2 |
| `DRRegClaimFloor::DRRegBasketFloorTest` ×4 | `DRRegAutoBasketClaimAsTest` ×4, name-for-name mirrors |
| `Round106BasketTest test_convertsThroughADiscoveredV4Pool`, `test_noRoute_claimAtAnyPricePaysTheQuote`, `test_launchNoLongerRevertsWithoutARoute` | `DRReg test_claimAs_nonZeroFloor_emptyRoute_converts`, `DRReg test_claimAs_emptyRouteZeroFloor_paysTheDenominationItself`, `R11 test_R11_routelessLeg_paysTheInput_thenConvertsOnceRouted`, `R12 test_R12_emptyRoutesArray` |
| `Round106BasketTest test_floorAboveTheFillReverts`, `test_poolManagerIsNotAValidRecipient`, `test_unlockCallbackRefusesStrangers` | `Round108 test_claimAsHonoursTheHoldersMinimum`, `test_claimRefusesStrandingRecipients`, `test_selfOnlyEntryPointsRefuseStrangers` |
| `Round107BasketTest test_rejectsARouteToTheWrongAsset`, `test_rejectsAnUninitializedPool`, `test_rejectsARouteThroughTheFeederHook`, `test_rejectsGarbageAndAV3PathWithoutAFactory`, `test_routesLengthMustMatchLegs`, `test_emptyRouteMeansDiscover`, `test_oldEntryPointsStillDiscover` | `R12 test_R12_wrongPairRouteFailsTheLaunch`, `R11 test_R11_launchRoute_mustBeARealPool`, `R11 test_R11_launchRoute_throughTheFeederIsRefused`, `R12 test_R12_malformedRouteFailsTheLaunch` + `test_R12_v3RouteWithoutARouterIsRefusedAtLaunch`, `R12 test_R12_shortRoutesArray_isRefused` + `test_R12_overLongRoutesArray_isRefused`, `DRReg test_claimAs_nonZeroFloor_emptyRoute_converts` |
| `TrackerAdapters::BasketAdapter` | not a test — matrix row removed, `EXPECTED_VARIANTS = 3` |

- **RE-POINTED, because these had NO survivor — checked by grep, not assumed.** Each is mutation-verified.

| re-pointed onto `…AutoBasket` | why it had no survivor |
|---|---|
| `R16ZeroDelivery test_R16_autoBasket_processHolders_preservesAccrual` | `processHolders` appeared in **no other test in the suite**. It is live on `…AutoBasket`; the deleted Basket row was its only zero-delivery coverage anywhere. |
| `R16ZeroDelivery test_R16_autoBasket_process_preservesAccrual`, `…_claimPath_hasTheGuard` | kept as the push/pull pair around it so all three delivery paths stay asserted together |
| `DRRegClaimFloor test_R17_claimAs_discoveryPicksTheDeepestPool` | depth-ranked discovery was pinned **only** by `Round106 test_picksTheDeepestPool` |
| `DRRegClaimFloor test_R17_claimAs_aPoolCreatedAfterLaunchIsUsed` | discovery-at-claim-time was pinned only by `Round106 test_aPoolCreatedAfterLaunchIsUsed` |
| `DRRegClaimFloor test_R17_claimAs_noDiscoverableRouteWithAFloorReverts` | only by `Round106 test_noRoute_withAFloorReverts` |
| `DRRegClaimFloor test_R17_claimAs_hookedPoolIsNotDiscoverable_butASuppliedRouteReachesIt` | "a hooked pool is undiscoverable" was pinned only by `Round107 test_hookedPoolIsNotDiscoverable_butASuppliedRouteReachesIt` and the round-107 fork test; also absorbs `test_suppliedRouteBeatsDiscovery` |
| `test/fork/Round107RobinhoodFork.t.sol` (both tests) | the only FORK proof of a **holder**-supplied hooked route; round 108's fork suite proves the **admin**-stored route converting automatically, a different path |

  - **Mutation-verified.** Removing `…AutoBasket`'s `pushReward` `ZeroDelivery` guard fails **only** the `process`
    row; removing the `_transferDirect` guard fails **only** the `processHolders` and `claimPath` rows — each row
    bites exactly the guard it exists for. Making `RouteLib._bestV4` take the first pool instead of the deepest
    fails **only** the two discovery rows. Both source files restored `cmp`-identical afterwards.
  - **`DRRegLauncherHeavy` was a pure type swap** (`BK.Leg` was only the launcher param type): 0 tests lost.
  - **The two fork tests compile but were NOT executed** — the public Robinhood RPC blocks Foundry (Cloudflare 403),
    which is the same standing limitation recorded at round 107. Run them behind a private RPC before trusting them.
- **Consistency matrix: `EXPECTED_VARIANTS = 3`**, no rule weakened; a native-paying and an ERC20-paying variant are
  both still represented, and `test_MATRIX_registryIsComplete` still enumerates `src/` for real.
- **Suite: 515 total / 510 excluding the 5 fork tests.** (−23 Basket-dependent tests, every one with a named
  survivor; the re-pointed rows replace rows in place, so they do not move the count.)
- **Sizes: unchanged.** `…TrackerBasket` was deployed by nothing, so nothing linked against it shrank.

### Round 17, pass 3 — `RealmAnyPairsRouteLib`'s unreachable native-ETH branches removed.

`best(…, probeNative, …)` and `supplied(…, allowNativeIn, …)`. Only the deleted `…EthBasket` ever passed `true`;
every remaining call site passed the literal `false`. **Both parameters were removed outright, not just their
branches** — a `bool` nobody can set to `true` is a trap for the next reader. `Route.tokenIn` can therefore no
longer be `address(0)`, and its docstring now says so.

- **Pure deletion. No behavioural change at any call site.** The four `…AutoBasket` call sites each lost one literal
  `false`; nothing else moved. `R12 test_R12_nativeInputRouteIsRefusedAtLaunch` — which pins that a native-ETH V4
  pool cannot be smuggled in as a launch route — **still passes**: the refusal is now unconditional rather than
  conditional, which is strictly stronger.
- **ABIs: byte-identical** (not merely `internalType`-stripped) for `RealmAnyPairsTaxHookPairImmutable`,
  `RealmAnyPairsPlatformFeeConverter`, `…TrackerAutoBasket`, `…TrackerQuote`, `RealmAnyPairsDividendTracker` and
  `RealmAnyPairsV4UnifiedLauncher`.
- **Sizes, measured:** `RealmAnyPairsDividendTrackerAutoBasket` 37,616 → **37,557 (−59)** and
  `RealmAnyPairsV4PairTrackerDeployer` 55,747 → **55,628 (−119)**, the latter because it embeds the former creation
  code. **Every other contract is byte-for-byte the same size** — including the hook and the fee converter, which
  the pass-1 report predicted would move. They use `poolKey`/`swapExactIn`/`settleAndTake` and never `best`/
  `supplied`, so they inline none of the removed code. Prediction corrected by measurement.
- **Suite: 515 total / 510 excluding the 5 fork tests** — unchanged by this pass, as a pure deletion should be.
- **NOTED, NOT REMOVED:** `settleAndTake`'s `tokenIn == address(0)` branch is likewise unreachable from every
  surviving caller (both pass real denominations, and the auto-basket constructor refuses a zero input or leg
  asset). Left alone deliberately: unlike the two flags it is not a dead `bool` but a value branch on a
  general-purpose V4 settle helper, where native ETH is a legitimate currency. Removing it would be a behavioural
  change to a shared primitive rather than the deletion of a trap.

### Round 17 — final state

- **`src/` holds 21 top-level contracts.** Deleted across the round: `…TrackerEthBasket`, `…TrackerMultiBasket`,
  `…TrackerBasket`, `RealmAnyPairsV4PairLauncherImmutable`, plus
  `RealmAnyPairsV4PairTrackerDeployer.deployBasketTracker` and `RouteLib`'s two native flags.
- **Tracker variants: three.** `RealmAnyPairsDividendTracker` (native), `…Quote`, `…AutoBasket`.
- **`RealmAnyPairsV4PairTrackerDeployer` 75,929 → 55,628 runtime bytes (−20,301)** — the only size that moved
  materially. `RealmAnyPairsV4UnifiedLauncher` is unchanged at 40,477 throughout the whole round.
- **Suite: 515 total / 510 excluding the 5 fork tests** (from 552 / 547 at the start of the round).
- **`foundry.toml` and `dependencies.lock` still unchanged**, re-verified after every pass.
