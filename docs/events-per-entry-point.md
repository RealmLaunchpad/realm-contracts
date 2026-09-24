# Events per Entry Point

Reference for indexers, subgraphs, monitoring and auditing: which Realm events are emitted by each core user-facing entry point, in the order they occur on-chain.

## Scope and current fee-handler model

This document describes the active source tree after the legacy implementations were removed:

- `src/feeHandlers/RealmFeeHandler.sol` — removed from active source.
- `src/feeSplitters/RealmFeeSplitter.sol` — removed from active source.
- `IRealmFeeHandler` / `IRealmFeeSplitter` interfaces may remain for legacy deployed-contract interaction, but no active factory/token path deploys or imports those implementations.

All new tokens use the singleton `RealmMasterFeeHandler`.

Pre-graduation trading fees are no longer global launchpad state. Each token carries its own LP
(trading) fee — split treasury/creator by `treasuryShareBps` — plus, on taxable variants, a creator
tax (100% to the creator), read per-trade by the launchpad via `IRealmToken.getLaunchpadFees` and
reported through `RealmLaunchpad.LpFeesAccrued` / `RealmLaunchpad.CreatorTaxesAccrued` (mirroring the
post-graduation `RealmSwapHook` for accounting parity). The launchpad's global `setTradingFees` /
`TradingFeesUpdated` are removed; the per-token LP-fee config surfaces as
`RealmToken.LaunchpadFeesInitialized` (at creation). The LP fee is immutable after launch (no setter).
The creator tax is configured on taxable variants and surfaces via `RealmTaxableTokenInitialized` /
`TaxBpsUpdated`; its window is anchored at creation when `startTaxFromLaunch` is true
(`[launchTimestamp, launchTimestamp + taxDurationSeconds]`, applying identically pre- and post-graduation)
and at graduation otherwise (no tax pre-graduation) — see §1.1 step 3.

Unified factories register fee config automatically during token creation:

`factory.createToken(...) -> _finalizeCreation(...) -> RealmToken.registerFees(...) -> RealmMasterFeeHandler.registerToken(...)`

`RealmMasterFeeHandler.registerToken` emits any initial direct-receiver events first, then `SharesUpdated`.

## Active event emitters covered here

- `RealmFactoryUniV2Unified` — the bonding-curve venue (graduates to Uniswap V2)
- `RealmFactoryUniV4Direct` — the DIRECT-launch venue (no curve, no launchpad; see §1.3)
- `RealmLaunchpad`
- `RealmToken` / `RealmTaxableTokenUniV4` / `RealmTaxableTokenUniV2` (sniper protection is a gated feature of both implementations, not a separate variant)
- `RealmDirectGraduatorUniV4` — the direct venue's graduator (§1.3)
- `RealmHookAnyPair` — the hook every ERC20-QUOTED pool is bound to (§6.1). `RealmHook` keeps every native pool.
- `RealmGraduatorUniswapV2`
- `RealmMasterFeeHandler`
- `RealmSwapHook`
- `RealmDividendSwapRegistry` — one shared upgradeable proxy per chain, not a per-token contract
- `RealmAssetsWhitelist` — one upgradeable proxy per chain, the ERC20 quotes the direct venue accepts
- `RealmTreasuryRouter` / `RealmVoting` — one upgradeable proxy each per chain; the router IS the treasury address every push below lands on (§11)

External ERC20 / Uniswap / WETH / Permit2 events still occur in traces, but this file focuses on Realm-owned events and notes the main external-operation points.

## Table of contents

1. [`createToken` — unified factory paths](#1-createtoken--unified-factory-paths)
1b. [`createToken` — direct-launch factory](#13-direct-launch-realmfactoryuniv4direct)
2. [`buyTokensWithExactEth` — pre-graduation](#2-buytokenswithexacteth--pre-graduation)
3. [`buyTokensWithExactEth` that triggers V2 graduation](#3-buytokenswithexacteth-that-triggers-v2-graduation)
5. [`sellExactTokens` — pre-graduation](#5-sellexacttokens--pre-graduation)
6. [V4 post-graduation swaps](#6-v4-post-graduation-swaps)
6b. [ERC20-quoted V4 swaps](#61-erc20-quoted-v4-swaps-realmhookanypair)
7. [`RealmMasterFeeHandler.claim`](#7-realmmasterfeehandlerclaimaddress-tokens)
8. [`RealmMasterFeeHandler.setShares`](#8-realmmasterfeehandlersetsharesaddress-token-feeshare-feeshares)
9. [Direct-fee behavior](#9-direct-fee-behavior)
10. [`RealmTaxableToken.setTaxBps`](#10-realmtaxabletokensettaxbpsuint16-newbuytaxbps-uint16-newselltaxbps)
11. [Treasury pushes — `RealmTreasuryRouter` / `RealmVoting`](#11-treasury-pushes--realmtreasuryrouter--realmvoting)
12. [`RealmVoting` entry points](#12-realmvoting-entry-points)
13. [`RealmToken.burn` / `burnFrom`](#13-realmtokenburn--burnfrom)

---

## 1. `createToken` — unified factory paths

The unified factory (`RealmFactoryUniV2Unified`) exposes ONE `createToken`, and a `previewTokenImplementation` view taking exactly the same arguments: `createToken(TokenSetupTiered, TaxConfigsWithMultiAllocation, SupplyShare[] buyOnDeployShares, AntiSniperConfigs, CreatorVault[], address referral)`.

`TokenSetupTiered` carries the `liquidityTier` selecting the post-graduation pool depth. `CreatorVault[]` (empty for none) locks supply in vesting vaults (§1.1 step 4b). `referral` is an off-chain signal for relayers: when non-zero, `RealmFactory.TokenReferral` is emitted (§1.1 step 7); no token storage or on-chain payout is wired to it.

`TaxConfigsWithMultiAllocation` is the full `TaxConfigs` (static tax + the three launch-tax-decay fields, flattened) plus a nested `earningsAllocation` = `{burnBps, dividendsBps, liquidityBps, dividendTokens[], dividendWeightsBps[], dividendRoutes[]}`: post-graduation earnings routed to buy-back-and-burn / holder dividends / liquidity, the fund wallets taking the remainder. An all-zero split configures nothing (no extra call, no event). A non-zero split is stored on the token at creation via a factory-guarded `initializeEarningsAllocation` call, emitting `EarningsAllocationInitialized` and — when `dividendsBps != 0` — the dividend events of §1.1 step 6c.
- **Tax requirement.** A non-zero split requires a LONG-TERM STATIC tax (`taxDurationSeconds != 0`), otherwise `EarningsAllocationRequiresTax`: V2 LP fees never reach the token, and a decay-only token's ≤20-minute window is not an earnings stream worth splitting. The direct V4 venue (§1.3) accepts any tax config.
- **Payout set.** The dividends slice is paid in UP TO THREE assets (`DividendDistribution.MAX_DIVIDEND_ASSETS`): `address(0)` (native), `DividendDistribution.DIVIDEND_SELF_TOKEN` (the token itself), or ANY ERC20. `dividendWeightsBps[i]` is asset `i`'s share OF THE DIVIDENDS SLICE. Validated once, at creation, and permanent: 1..3 entries with both arrays the same length, every weight non-zero, the weights summing to exactly 10 000, the assets DISTINCT, and `DIVIDEND_SELF_TOKEN` legal only as the sole entry — otherwise `InvalidDividendAssetSet` / `SelfTokenDividendMustBeSole`. Naming assets with a zero `dividendsBps` reverts `DividendAssetWithoutShare`.
- **Routes.** Every non-native, non-self asset is registered with `RealmDividendSwapRegistry.registerRoute(asset, dividendRoutes[i])`; an array shorter than `dividendTokens` means the empty route (the permissionless V2 pair) for the rest. There is no asset whitelist and no review: the registry accepts either a Uniswap **V2** pair whose quote-side reserve clears its threshold (the empty route), or a Uniswap **V4** / **V3** route whose every pool is initialized and holds liquidity — how assets with no V2 pair, such as Robinhood Chain's xStocks, qualify. Otherwise it reverts `RouteRejected(rejection)` (`NoPair` | `InsufficientLiquidity` | `Blacklisted` | `QuoteNotAllowed` | `MalformedRoute` | `DeadPool` | `IntermediateNotAllowed`) at creation, because a clone cannot be patched afterwards. What is NOT checked, by anyone, is whether the named pool's price tracks the asset's real market.

### 1.1 Common sequence

For the unified factory, the common Realm event order is:

1. **`RealmFactory.TokenCreated`** (`token, name, symbol, tokenOwner, launchpad, graduator, feeHandler=RealmMasterFeeHandler`) — emitted before token initialization so indexers see the token entity before initializer-side events. `RealmFactoryUniV2Unified` always emits `tokenOwner = address(0)`.
2. **Graduator initialization**: **`RealmGraduator.PairInitialized`** (`token, pair`) — pair address is predicted; pair deployment can happen later at graduation.
3. Implementation initializer events (emitted during the token's `initialize`, after the initial mint(s)):
   - Always: **`RealmToken.LaunchpadFeesInitialized`** (`lpFeeBps, treasuryShareBps`) — the per-token pre-graduation LP-fee config the launchpad reads each trade. A single LP fee applies to both buys and sells (mirroring the post-graduation hook). The creator tax (if any) is reported separately by `RealmTaxableTokenInitialized` below. Emitted before the tax/sniper events below.
   - Tax token: **`RealmTaxableTokenInitialized`** (`buyTaxBps, sellTaxBps, taxDurationSeconds, startTaxFromLaunch, buyTaxDecayStartBps, sellTaxDecayStartBps, taxDecayDuration`). `startTaxFromLaunch` tells the indexer the tax-window anchor: `true` → window runs `[launchTimestamp, launchTimestamp + taxDurationSeconds]` (creation-anchored, spans graduation); `false` → `[graduationTimestamp, +taxDurationSeconds]` (no tax pre-graduation). The three `*Decay*` fields configure the optional linear launch-tax decay, anchored at the SAME point as the static window: each direction's rate decays linearly from `*TaxDecayStartBps` (`buyTaxDecayStartBps + sellTaxDecayStartBps` ≤ 2000 = 20% combined) at the anchor to 0 over `taxDecayDuration` (≤1200 s = 20 min). The effective tax a trade pays is `max(decay, static)` per direction, so a token may emit non-zero decay fields with zero static fields (a "decay-only" token — a non-taxable token that opted into the launch decay; it is still deployed as a taxable-impl clone). A token may also configure both, or neither (all six fields 0).
   - Sniper-protected token: **`SniperProtectionInitialized`** (`maxBuyPerTxBps, maxWalletBps, protectionWindowSeconds, whitelist`).
4. **`RealmLaunchpad.TokenLaunched`** (`token, graduationThreshold, maxExcessOverThreshold`). For a creator-vault token the registered bonding curve is the allocation-specific one, but the graduation threshold/excess are identical to the base curve.
4a. **`RealmFactory.BondingCurveAssigned`** (`token, bondingCurve`) — records which bonding curve the token was launched on (the allocation-specific curve for creator-vault tokens, the base curve otherwise). Emitted immediately after `TokenLaunched`; both fields are indexed. This is the only event carrying the curve address — combine it with the curve's own `RealmBondingCurveDeployed` (emitted at curve-deploy time, see note below) to reconstruct reserves off-chain.
4b. Creator vaults only (non-empty `CreatorVault[]`): the factory deploys and funds the vaults. Per vault, in order: **`RealmCreatorVaultFactory.CreatorVaultDeployed`** (`vault, token, owner, amount, cliffSeconds, vestingSeconds`) followed by an ERC20 `Transfer` (factory → vault). After all vaults: **`RealmFactory.CreatorVaultsCreated`** (`token, totalVaultAllocation, vaults, amounts`).
5. Initial fee config is registered through the token into `RealmMasterFeeHandler`:
   - Zero or more **`RealmMasterFeeHandler.DirectReceiverRegistered`** (`token, receiver`) — one per initial direct receiver.
   - **`RealmMasterFeeHandler.SharesUpdated`** (`token, recipients, sharesBps`).
6. (No `RealmFactory.LpFeeBpsSet`: only the direct V4 venue emits it, §1.3 step 11.)
6b. Only when `earningsAllocation` is non-zero: **`EarningsAllocation.EarningsAllocationInitialized`** (`burnBps, dividendsBps, liquidityBps`) — the creation-time earnings split. Emitted by the token itself from the factory-guarded `initializeEarningsAllocation` call, which the factory makes *after* the shared creation body — so it fires after the fee registration (step 5), and any deployer-buy events (§1.2), and before `TokenReferral` (step 7). The token emits it; an all-zero allocation emits nothing here.

6c. Same call, immediately after 6b, and only when `dividendsBps != 0`: one **`DividendDistribution.DividendAssetInitialized`** (`index` indexed, `asset`, `weightBps`) per configured payout asset, in index order, followed by exactly one **`DividendDistribution.DividendsInitialized`** (`dividendToken`) carrying asset 0. `DividendAssetInitialized` is the complete description of the payout configuration — how many assets, which, and each one's share of the dividends slice; `DividendsInitialized` is kept, and kept last, so indexers written against the single-asset shape keep working (a single-asset token emits one of each, with the same address). The self-token sentinel is already resolved to the token's own address in both. The set is fixed for the token's life — there is no add, no remove and no re-weight, on any path. Nothing else fires here: the accumulators start at graduation, not at creation (see §graduation).
7. Only when `referral != address(0)`: **`RealmFactory.TokenReferral`** (`token, referral`, both indexed) — records the relayer/referrer that forwarded the creation. Emitted last of all factory events (after `EarningsAllocationInitialized` when an allocation is set). the common no-referral deploy emits nothing here.

Notes:

- The bonding curve contracts (`ConstantProductBondingCurve`, `ConstantProductBondingCurveConfigurable`) emit **`RealmBondingCurveDeployed`** (`k, t0, e0, ethGraduationThreshold, maxExcessOverThreshold`) once from their constructor — in the curve's own deploy tx, NOT during `createToken`. The `Realm` prefix gives the event a unique topic so it can be wildcard-indexed (from any curve address). Indexers join it to `BondingCurveAssigned` (step 4a) by curve address to reconstruct token reserves at any eth reserves `e`: `t = k / (e + e0) - t0`.
- Single-recipient and multi-recipient fee configs use the same master-handler registration path.
- There is no `FeeSplitterCreated` event and no splitter initialization event in the active source path.
- ERC20 mint and OpenZeppelin `Initialized` events also appear during token clone initialization. For creator-vault tokens the initial mint is split: `TOTAL_SUPPLY - vaultAllocation` is minted to the launchpad and `vaultAllocation` is minted to the factory (which then funds the vaults in step 4b). For non-vault tokens the full supply is minted to the launchpad, unchanged. On the DIRECT venue the mint target is the GRADUATOR rather than the launchpad (there is none) — see §1.3.
- The anti-sniper window now runs to its configured end REGARDLESS of graduation, on every venue. There is no event for this; it changes which transfers revert, not what is emitted. Indexers that inferred "caps lifted" from `Graduated` must instead use `launchTimestamp + protectionWindowSeconds` from `SniperProtectionInitialized`. Post-graduation pool BUYS (`from == pair`) are now subject to the per-tx cap, and every incoming transfer to the per-wallet cap, until that timestamp.

### 1.2 With deployer buy (`msg.value > 0`)

After the common sequence above, the factory performs the buy and distribution:

1. **`RealmLaunchpad.RealmTokenBuy`** (`token, buyer=factory, ethAmount=msg.value, tokenAmount=tokensBought, ethFee`).
2. **`RealmFactory.BuyOnDeploy`** (`token, buyer=msg.sender, quoteSpent, tokensBought, recipients, amounts`). `quoteSpent` is always wei here. Renamed from `ethSpent` (name only; topic0 unchanged).

ERC20 `Transfer` events occur from launchpad to factory and then from factory to each supply-share recipient.

---

## 1.3 Direct launch (`RealmFactoryUniV4Direct`)

A second, independent venue. `RealmFactoryUniV4Direct.createToken(DirectTokenSetup, DirectPair[], TaxConfigsWithDirectAllocation, AntiSniperConfigs, CreatorVault[], DevBuy, address referral)` — creates the token, creates ONE TO THREE Uniswap V4 pools, each opening at a fixed `LAUNCH_MARKET_CAP_X18` (2.25 ETH) market cap, splits the circulating supply across them as single-sided token bands and settles the creator's first buy — all in one transaction. There is no bonding curve, no launchpad and no pre-graduation phase, so §2–§5 never apply to these tokens; §6 (post-graduation V4 swaps) applies from the creation block onwards.

Each `DirectPair` names a `quote` (`address(0)` for the chain's native currency, or any ERC20 with `decimals()` that is not the wrapped native), and a `weightBps` share of the supply. There is no price field: the factory derives each pair's launch tick (QUOTE PER COIN) on-chain from `LAUNCH_MARKET_CAP_X18`, converted to the quote at its LIVE `ASSETS_WHITELIST` rate (`liveUnitsPerNativeX18`, a spot read of the quote's listed price pool; native is 1:1). A native pair is bound to `SWAP_HOOK` (`RealmHook`); an ERC20 pair is bound to `SWAP_HOOK_ANY_PAIR` (`RealmHookAnyPair`, §6.1). `DevBuy` spends `msg.value` on a native pair and a pulled `quoteAmount` on an ERC20 one.

**How an indexer recognises one**: `TokenCreated.launchpad == address(0)`. No `TokenLaunched`, no `BondingCurveAssigned` and no `RealmTokenBuy` is ever emitted for a direct-launched token. Its `graduator` is a `RealmDirectGraduatorUniV4`.

Realm event order:

1. **`RealmFactory.TokenCreated`** (`token, name, symbol, tokenOwner, launchpad=address(0), graduator=RealmDirectGraduatorUniV4, feeHandler`).
2. Graduator initialization, from inside the token's `initialize`: **`RealmGraduator.PairInitialized`** (`token, pair=PoolManager`) then **`RealmDirectGraduatorUniV4.PoolIdRegistered`** (`token, poolId, swapHookAddress`) — the same `PairInitialized` as §1.1 step 2, followed by the V4 pool id. The pool is created at the first pair's derived launch tick, QUOTE PER COIN; the pool's own `slot0.tick` is its reciprocal whenever the coin sorts as `currency1`, which it always does against native.
3. Implementation initializer events, exactly as §1.1 step 3 — **`RealmToken.LaunchpadFeesInitialized`** (both fields `0`: there is no pre-graduation fee to charge or split), then **`RealmTaxableTokenInitialized`** and/or **`SniperProtectionInitialized`** when configured.
3a. Any ERC20 quotes only: **`RealmToken.QuotesRegistered`** (`quotes[]`) — the currencies beyond the native one the token will earn in. `quotes[0]` on the token is ALWAYS `address(0)`, so this event carries only the extras and is absent on a native-only launch. It is what tells an indexer which currencies to expect in that token's `CreatorAssetFeesDeposited` / `LpAssetFeesRouted`.
4. Creator vaults, when configured: the §1.1 step 4b sequence unchanged (`CreatorVaultDeployed` per vault, then **`RealmFactory.CreatorVaultsCreated`**).
5. Fee registration, exactly as §1.1 step 5: zero or more **`DirectReceiverRegistered`**, then **`RealmMasterFeeHandler.SharesUpdated`**.
5b. Only when any allocation bucket is non-zero: **`EarningsAllocationInitialized`** (`burnBps, dividendsBps, liquidityBps`), then — with a dividends share — one **`DividendAssetInitialized`** (`index, asset, weightBps`) per payout asset, each preceded by the registry's **`DividendRouteRegistered`** for a non-native, non-self asset, then **`DividendsInitialized`** (`dividendToken` = asset 0), then one more **`DividendRouteRegistered`** per ERC20 QUOTE some payout leg has to be bought out of (see the registry section). The allocation lands BEFORE the seed on purpose: the `Graduated` of step 6 is what emits `DividendsActivated`, so a direct-launched dividend token is active from its creation block, never from its first earnings.
5c. Every pool after the first: **`RealmDirectGraduatorUniV4.PoolIdRegistered`** (`token, poolId, swapHookAddress`), one per extra pool in `pairs` order, emitted by the factory-driven `initializePool`. The FIRST pool's pair of events fired in step 2.
6. **`RealmToken.Graduated`** — the token is opened for trading in its own creation transaction. On a taxable token this also sets `graduationTimestamp`, so a graduation-anchored tax window (`startTaxFromLaunch == false`) starts here, at creation.
7. **`RealmDirectGraduatorUniV4.PoolSeeded`** for the FIRST pool (`token` indexed, `quote` indexed, `poolId`, `weightBps`, `tick`, `liquidity`, `launchMarketCap`, `targetMarketCap`, `quoteDecimals`, `quoteSymbol`), then **`RealmGraduator.TokenGraduated`** (`token, tokenAmount` = the first pool's share of the supply, `ethAmount` = ALWAYS `0` on this venue, `liquidity` = the first pool's), then one more **`PoolSeeded`** per further pool, in `pairs` order. `tick` is the derived quote-per-coin value, NOT the pool's internal orientation. `weightBps` is that pool's share of the seeded supply, summing to 10000 across the set; the LAST pool also absorbs the rounding remainder, so its actual amount is marginally above its weight. `launchMarketCap` is the whole supply at `tick`, in the quote's RAW units (wei for native, no decimals applied), the same units an indexer derives from the pool's `sqrtPriceX96`; `targetMarketCap` is `launchMarketCap * GRADUATION_TARGET_MULTIPLE` (5). The token is graduated on-chain from birth; indexers show it graduated once its largest pool (highest `weightBps`, the first seeded on a tie) reaches that pool's `targetMarketCap`. `quoteDecimals` is 18 for native; `quoteSymbol` is the quote's `symbol()`, empty for native and for a quote whose `symbol()` reverts or is not an ABI string of at most 32 bytes (e.g. the legacy `bytes32` form), which never blocks the launch. Each seed is accompanied by ERC20 `Transfer` events (graduator → liquidity adder → PoolManager) plus the position manager's own `Transfer` minting the position NFT to the graduator, where it stays permanently. There is no graduation fee on this venue, so no `CreatorGraduationFeeCollected` / `TreasuryGraduationFeeCollected`.
8. Dev buy only (`msg.value > 0` or `quoteAmount > 0`): on a quote-funded ERC20 pair first the quote's `Transfer` (creator → graduator); on a native-funded ERC20 pair (zap) instead, inside the same unlock, the conversion hops' `PoolManager.Swap` (1-2, native → [reference →] quote, through the quote's whitelist V4 pools, plus whatever those pools' hooks emit) and NO quote `Transfer` — the quote never leaves the pool manager. Then the swap, inside the graduator's own pool-manager unlock, on the pool `devBuy.pairIndex` names, emitting that pool's ordinary post-graduation buy sequence with `txOrigin` = the creator: on a native pair the §6.1 sequence (**`RealmHook.RealmPoolState`**, **`LpFeesForwarded`** → the router's **`LpFeesRouted`**, **`CreatorTaxesAccrued`** on a taxable token inside its window, **`RealmSwapHook.RealmSwapBuy`**); on an ERC20 pair the ERC20-quoted sequence (**`RealmHookAnyPair.RealmPoolState`**, **`LpFeesForwarded`**, **`CreatorTaxesAccrued`**, **`RealmQuoteSwapBuy`** — the fees are only BOOKED here; `FeesSettled` and the router's `LpAssetFeesRouted` come later, with `settleFees`). Then ERC20 `Transfer`s of exactly the tokens bought: PoolManager → graduator → factory.
9. The seed remainder no band could absorb: ERC20 `Transfer` (graduator → `0x…dEaD`). Present in practice on every launch — the position math never consumes the deposit exactly — and burned AFTER the dev buy, which never touches it.
10. Dev buy only: **`RealmFactory.BuyOnDeploy`** (`token, buyer=msg.sender, quoteSpent, tokensBought, recipients, amounts`) — the same event and the same split rule the curve venue uses in §1.2, sourced from the pool instead of the curve. `quoteSpent` is what the buy spent in the dev-buy pair's own quote, raw units: `msg.value` (wei) on a native pair, `devBuy.quoteAmount` on a quote-funded ERC20 pair, and the CONVERTED quote amount (not the native sent) on a native-funded ERC20 pair.
11. **`RealmFactory.LpFeeBpsSet`** (`token, lpFeeBps`) — always, for every direct-launched token; the curve factory never emits it.
12. Only when `referral != address(0)`: **`RealmFactory.TokenReferral`** (`token, referral`).

Notes:

- The rounding remainder the bands cannot absorb is burned (step 9), never held: the graduator must not become a continuous holder, or it would accrue dividends nobody can claim.
- A launch takes 1 to `MAX_PAIRS` (3) pairs with distinct quotes and weights summing to 10000 (`InvalidPairs`); an ERC20 quote must be whitelisted in `RealmAssetsWhitelist` (`ASSETS_WHITELIST()`), have `decimals()` ≤ 36 and not be the wrapped native (`QuoteNotSupported`). Fee-on-transfer quotes are not supported. `DevBuy.route` and `DevBuy.minQuoteOut` exist in the ABI but must be empty/zero, and the dev buy's currency must match its pair (`InvalidDevBuy`).
- Every pair's derived tick must still imply an opening market cap worth between `MIN_LAUNCH_MARKET_CAP_X18` (1 ETH) and `MAX_LAUNCH_MARKET_CAP_X18` (250 ETH) (`LaunchPriceOutOfBounds`) at the quote's LIVE rate, the same one that priced the tick. The listed snapshot rate `unitsPerNativeX18` only gates whether the quote is listed; how far the live rate has drifted from it is not checked. The tick is also spacing-aligned (rounded to the nearest multiple) and must sit strictly inside the usable band (`InvalidLaunchTick`).
- An earnings allocation on this venue needs NO tax: the creator's LP-fee share is a permanent stream here, so a zero-tax token with an allocation is a revenue-share token. It is cloned from the TAXABLE implementation, which `previewTokenImplementation` (same arguments as `createToken`) reports, so a salt mined against it names the right initcode. Only the V2 curve factory requires a static tax, because V2 LP fees never reach the token.
- On an ERC20-quoted pool the dividends slice buffers IN THE QUOTE (`quoteDividendPending(quote)`), per payout asset, and is serviced by `processDividends(assetIndex, quote, minOut, holders)` — see Holder dividends.
- `previewLaunchTick(quote)` returns the tick a pair against `quote` would launch at right now, plus the opening price of one whole coin and the implied market cap in whole quote units, both scaled by 1e18. It reverts where `createToken` would (`QuoteNotSupported`, `LaunchPriceOutOfBounds`). Live: an ERC20 quote's result can move with its price pool before the creation transaction lands.

---

## 2. `buyTokensWithExactEth` — pre-graduation

The pre-graduation fee policy is read per-trade from the token (`IRealmToken.getLaunchpadFees`) and
capped by the launchpad. The LP (trading) fee is split treasury/creator by `treasuryShareBps`; the
optional tax goes 100% to the creator. The treasury share is pushed; the creator total (LP creator
share + tax) is routed through `RealmToken.accrueFees` into `RealmMasterFeeHandler`. The event
vocabulary mirrors the post-graduation `RealmSwapHook` for accounting parity.

When the buy does not graduate the token:

1. ERC20 transfer from `RealmLaunchpad` to buyer.
2. **`RealmLaunchpad.LpFeesAccrued`** (`token, creatorShare, treasuryShare`) — emitted whenever a fee is taken.
3. **`RealmLaunchpad.CreatorTaxesAccrued`** (`token, taxAmount`) — only when the tax is non-zero.
4. Creator total (LP creator share + tax), when non-zero, routed through `RealmToken.accrueFees` → `RealmMasterFeeHandler.depositFees(token)`:
   - **`RealmMasterFeeHandler.CreatorFeesDeposited`** (`token, amount`).
   - Optional **`RealmMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) on a successful direct forward.
5. Treasury share pushed to the treasury address → the §11 router/voting events.
6. **`RealmLaunchpad.RealmTokenBuy`** (`token, buyer, ethAmount=msg.value, tokenAmount, ethFee`) — `ethFee` is the total (LP fee + tax).

The curve factory creates every token with `treasuryShareBps = 3000` (30% treasury / 70% creator of
the 1% LP fee), so step 4 fires on every buy that takes a fee; only step 3 depends on an active tax.

If the buy crosses the graduation threshold, append the graduation sequence from §3.

---

## 3. `buyTokensWithExactEth` that triggers V2 graduation

The initial buy emits the pre-graduation buy sequence from §2, then graduation begins in `RealmLaunchpad._graduateToken`.

Realm event order:

1. The triggering buy first emits its full §2 sequence — ERC20 transfer to buyer, the fee events (**`RealmLaunchpad.LpFeesAccrued`**, optional **`CreatorTaxesAccrued`**, and the creator-share `CreatorFeesDeposited` when applicable), and **`RealmLaunchpad.RealmTokenBuy`** (`token, buyer, ethAmount, tokenAmount, ethFee`).
2. ERC20 transfer of the remaining launchpad token balance from `RealmLaunchpad` to `RealmGraduatorUniswapV2`.
3. **`RealmGraduator.CreatorGraduationFeeCollected`** (`token, amount=creatorCompensation`).
4. Creator compensation is routed through `RealmToken.accrueFees()` into `RealmMasterFeeHandler.depositFees(token)`:
   - **`RealmMasterFeeHandler.CreatorFeesDeposited`** (`token, amount=creatorCompensation`).
   - Optional **`RealmMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) if the configured receiver is direct and the forward succeeds.
5. **`RealmGraduator.TreasuryGraduationFeeCollected`** (`token, amount=treasuryShare`), the push itself landing on the treasury address → the §11 router/voting events.
6. **`RealmToken.Graduated`**.
7. External Uniswap V2 pair creation / liquidity / LP-token events may occur.
8. **`RealmGraduator.TokenGraduated`** (`token, tokenAmount, ethAmount, liquidity`).
9. Optional **`RealmGraduatorUniswapV2.SweepedRemainingEth`** (`token, amount`) if triggerer compensation failed or residual ETH remains.
10. **`RealmLaunchpad.TokenGraduated`** (`token, ethCollected, tokensForGraduation`).

---

## 5. `sellExactTokens` — pre-graduation

When a token is not graduated yet, sells happen against launchpad reserves. As with buys, the fee
policy is read per-trade from the token: the LP fee is split treasury/creator, the tax goes 100% to
the creator. The treasury share is pushed and the creator total is routed through `accrueFees`.

The event order matches buys (§2) and the post-graduation `RealmSwapHook` (§6): the fee events come
first and the trade event closes the sequence.

Realm event order:

1. ERC20 transfer from seller to launchpad.
2. **`RealmLaunchpad.LpFeesAccrued`** (`token, creatorShare, treasuryShare`) — emitted whenever a fee is taken.
3. **`RealmLaunchpad.CreatorTaxesAccrued`** (`token, taxAmount`) — only when the tax is non-zero.
4. Creator total, when non-zero, via `RealmToken.accrueFees` → `RealmMasterFeeHandler.depositFees(token)`:
   - **`RealmMasterFeeHandler.CreatorFeesDeposited`** (`token, amount`).
   - Optional **`RealmMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) on a successful direct forward.
5. **`RealmLaunchpad.RealmTokenSell`** (`token, seller, tokenAmount, ethAmount, ethFee`) — `ethFee` is the total (LP fee + tax).
6. Treasury share pushed to the treasury address → the §11 router/voting events.
7. Seller receives ETH via native ETH call (no Realm event for the ETH transfer).

---

## 6. V4 post-graduation swaps

V4 pools exist only for direct-launched tokens (§1.3), which graduate in their creation transaction, so every V4 swap is post-graduation. Swaps are mediated by the swap hook; a swap on an ungraduated token reverts `NoSwapsBeforeGraduation` and emits no Realm swap/fee events.

Every native-quoted pool is attached to `RealmHook`, which extends `RealmSwapHook` and additionally emits
`RealmPoolState` (§6.0) on every swap. `RealmSwapHook` is deprecated as a deployment target: it is never
deployed standalone and survives only as `RealmHook`'s base. Event names below are qualified as
`RealmSwapHook.*` because that is where they are declared; the emitter is the `RealmHook` address and the
signatures are identical (they are inherited). ERC20-quoted pools use `RealmHookAnyPair` instead (§6.1 below).

The hook reads the per-token fees via `RealmToken.getSwapFees(isBuy)` (LP fee + currently-effective tax for
that direction). The LP fee is forwarded whole to `SwapLpFeeRouter`, which splits it 30/70 between treasury and
creator; the tax (if any) is forwarded to the token's master fee handler. The LP fee and
the tax are accrued in **separate** `accrueFees` calls, so the creator can see up to two
`CreatorFeesDeposited`.

### 6.0 Pool state (`RealmHook` only)

**`RealmHook.RealmPoolState`** (`token, poolId, sqrtPriceX96, liquidity`) — the post-swap price and
active liquidity of the token's pool, emitted once per swap leg as the FIRST hook event, before any fee
event and before the buy/sell event.

`sqrtPriceX96` and `liquidity` are the only two fields any consumer reads from the singleton
`UniswapV4PoolManager.Swap` event, and they arrive at the same log position relative to the hook's own
events, so an indexer can derive virtual reserves (`eth = L * 2**96 / sqrtPriceX96`,
`token = L * sqrtPriceX96 / 2**96`) from a Realm-only log instead of subscribing to every V4 swap on the
chain. `poolId` is the `id` topic of `PoolManager.Swap` — nothing consumes it today (`univ4poolId` is
already known per token from `PoolIdRegistered`), it is carried as the universal V4 join key because the
hook is immutable and behind Uniswap's whitelist.

A standalone `RealmSwapHook` pool would not emit this, but none is deployed (see §6).

### 6.1 Buy (`ETH -> token`)

The fee is withheld from the ETH leg (`beforeSwap` for exact-input, `afterSwap` for exact-output); the
routing and all events below are emitted in `afterSwap`.

Realm event order (LP fee `> 0`, buy tax active, router healthy):

0. **`RealmHook.RealmPoolState`** (`token, poolId, sqrtPriceX96, liquidity`) — see §6.0.
1. **`RealmSwapHook.LpFeesForwarded`** (`token, amount`) — the whole LP fee handed to the router.
2. **`SwapLpFeeRouter.LpFeesRouted`** (`token, creatorShare, treasuryShare, liquidityShare=0`) — the flat 70/30 creator/treasury split.
3. Treasury LP share pushed to the router's treasury address → the §11 router/voting events.
4. Creator LP share is routed through `RealmToken.accrueFees()` into `RealmMasterFeeHandler.depositFees(token)`:
   - **`RealmMasterFeeHandler.CreatorFeesDeposited`** (`token, amount=creatorShare`).
   - Optional **`RealmMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) per successful direct forward.
5. Optional **`RealmSwapHook.CreatorTaxesAccrued`** (`token, taxAmount`) if buy tax is active and non-zero, then the
   tax is routed through `RealmToken.accrueFees()` (a second **`CreatorFeesDeposited`** / optional `CreatorClaimed`).
6. **`RealmSwapHook.RealmSwapBuy`** (`token, txOrigin, ethIn, tokensOut, ethFees`).

Router-failure fallback: if `SwapLpFeeRouter.depositLpFees` reverts, step 2 (`LpFeesRouted`) and step 4 are
absent — the hook instead pushes the **entire** LP fee to the hook's own `TREASURY` immutable via a native ETH call (the multisig directly on today's deployments, so NO §11 events; no
event). Indexers detect the fallback by the presence of `LpFeesForwarded` without a matching `LpFeesRouted`.

### 6.2 Sell (`token -> ETH`)

The fee is taken from the ETH leg (`afterSwap` for exact-input, withheld in `beforeSwap` for exact-output);
the routing and all events below are emitted in `afterSwap`.

Realm event order (LP fee `> 0`, sell tax active, router healthy):

0. **`RealmHook.RealmPoolState`** (`token, poolId, sqrtPriceX96, liquidity`) — see §6.0.
1. **`RealmSwapHook.LpFeesForwarded`** (`token, amount`) — the whole LP fee handed to the router.
2. **`SwapLpFeeRouter.LpFeesRouted`** (`token, creatorShare, treasuryShare, liquidityShare=0`) — the flat 70/30 creator/treasury split.
3. Treasury LP share pushed to the router's treasury address → the §11 router/voting events.
4. Creator LP share is routed through `RealmToken.accrueFees()` into `RealmMasterFeeHandler.depositFees(token)`:
   - **`RealmMasterFeeHandler.CreatorFeesDeposited`** (`token, amount=creatorShare`).
   - Optional **`RealmMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) per successful direct forward.
5. Optional **`RealmSwapHook.CreatorTaxesAccrued`** (`token, taxAmount`) if sell tax is active and non-zero, then the
   tax is routed through `RealmToken.accrueFees()` (a second **`CreatorFeesDeposited`** / optional `CreatorClaimed`).
6. **`RealmSwapHook.RealmSwapSell`** (`token, txOrigin, tokensIn, ethOut, ethFees`).

Router-failure fallback: same as §6.1 — `LpFeesRouted` + step 4 absent, full LP fee pushed to treasury.

### 6.3 V2 post-graduation swaps on tax variants

Tax tokens deployed on V2 (`RealmTaxableTokenUniV2`) take taxes intrinsically inside `_update`. There is no V2 hook; the token contract diverts a portion of every pair-touching transfer into its own balance, then auto-swaps the accumulated tokens to ETH on a sell once the contract balance crosses `SWAP_THRESHOLD = TOTAL_SUPPLY / 2000` (= 500_000e18).

Indexer-relevant points:

- **Buy (ETH → token)** within the tax window emits an extra `Transfer(pair, address(token), buyTaxAmount)` for the tax slice in addition to `Transfer(pair, buyer, netAmount)`. No Realm event is emitted at this point — the tax accrual is reported later, at swap-back time.
- **Sell (token → ETH)** within the tax window emits an extra `Transfer(seller, address(token), sellTaxAmount)` for the tax slice in addition to `Transfer(seller, pair, netAmount)`. The auto-swap-back, if triggered, fires *before* the tax slice transfers, while `inSwap` is true. No Realm event is emitted at this point either; the accrual is reported by `CreatorTaxSwapback` from the auto-swap-back below.
- **Auto- or manual-triggered swap-back** burns the burn-allocation share as tokens in-place first, sets the liquidity-allocation share aside as tokens (kept on the contract, tracked by `liquidityPendingTokens` — no event), then runs `IUniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens` on the remainder, then routes the ETH through the earnings-allocation split. Realm event order:
  1. Burn allocation only (`burnBps > 0`): ERC20 `Transfer(address(token), address(0), burnAmount)` then **`RealmTaxableToken.CreatorTaxBurn`** (`quote = address(0), amountSpent = 0, tokensBurned = burnAmount`) — the burn share removed from total supply *before* the swap. The shared signature; `amountSpent` is 0 here because V2 burns in token-space with no ETH→token round trip.
  2. ERC20 transfer from `address(token)` to `pair` for the swap input (the remainder after the burn and liquidity shares).
  3. External Uniswap V2 `Sync` / `Swap` events on the pair, plus `Withdrawal` on WETH.
  4. **`RealmTaxableTokenUniV2.CreatorTaxSwapback`** (`tokenAmountIn, ethAmount, ethToFund`) — `tokenAmountIn` is the amount actually swapped (net of the burn and liquidity shares); `ethAmount` is this swap's ETH proceeds (a balance delta, matching the pair's `Swap`); `ethToFund` is the slice of THAT ETH which reaches the fee handler as creator fees. The swap-back routes its own proceeds and nothing else — stray or refunded ETH sitting in the same balance is left for `sweepStrayEth()`, which splits it with the burn/liquidity shares it is owed rather than renormalizing it into the dividend pot — so `ethToFund <= ethAmount` always, and the two are equal for a token with no earnings allocation.
  5. Fund deposit of `ethToFund`: **`RealmMasterFeeHandler.CreatorFeesDeposited`** (`token, amount = ethToFund`), plus optional **`CreatorClaimed`** per direct forward — always AFTER `CreatorTaxSwapback` (historical order preserved). The dividends bucket is accrue-only and emits nothing on this path — its slice is buffered as native (or, for a V2 self-token payout, set aside as TOKENS alongside the liquidity buffer) and converted out-of-band by `processDividends`. So a token still emits exactly one `CreatorFeesDeposited` (the liquidity slice, and any self-token dividend slice, were already set aside as tokens above, not carved from this ETH).
- The token's `swapBack(uint256 swapAmount, uint256 amountOutMinWei)` external function is owner/launchpad-owner gated and reverts `NotGraduated` before graduation; it produces the same event sequence as the auto-trigger. Factory-deployed V2 tokens are ownerless, so the launchpad owner is the only reachable manual caller.
- The token's **`processLiquidity(uint256 amountOutMinWei)`** external function (keeper-gated; reverts `NotGraduated` / `NotAKeeper` unless `msg.sender` is on the `RealmKeepersRegistry` allowlist / `NothingToAdd` / `ProcessCooldown` when already run this block; processes at most `2 * SWAP_THRESHOLD` tokens per call, remainder stays buffered) turns the set-aside liquidity tokens into a locked LP position: under `inSwap` it sells half through `UniswapV2Venue.swapTaxToNative()`, then adds the retained half plus the proceeds through `UniswapV2Venue.supplyLiquidity()` and sends the LP to `0xdEaD`. The venue takes the WETH `swapExactTokensForETHSupportingFeeOnTransferTokens` / `addLiquidityETH` path. Emits the external V2 `Sync` / `Swap` / pair `Mint` / `Transfer` events, then **`RealmTaxableToken.LiquidityAdded`** (`quote = address(0), amountIn, tokensAdded, liquidity`) — the shared event; here `liquidity` is the V2 LP tokens minted, and `amountIn` (the ETH side) / `tokensAdded` are the router's ACTUAL deposited amounts (they match the pair's `Mint`), not the requested ones: V2 adds at whatever ratio the pool is at and the router refunds the excess side back to the token.
- Past the tax window (anchored at launch or at graduation, see §1.1 step 3), no tax transfer is taken and the swap-back path is not entered.

### 6.4 V4 earnings-allocation burn and liquidity buckets and their entry points

For a V4 token with a burn or liquidity allocation, every post-graduation `token.accrueFees` — the tax (`CreatorTaxesAccrued`) and the creator's LP-fee share alike — is split in the currency it arrived in: the burn and liquidity slices are buffered per quote (`quoteBufferOf(quote)`; the native buffers are also readable as `burnPendingEth` / `liquidityPendingEth`), with no event beyond the fund-wallet `CreatorFeesDeposited` / `CreatorAssetFeesDeposited`, and the rest routes to the fund wallets. Keeper-gated entry points then process each buffer:

- **`processBurn(uint256 minTokensOut)`** — buys back tokens with `burnPendingEth` via the universal router and burns them. Emits, in order: **`RealmTaxableTokenUniV4.BuyBackInitiated`** (`quote, amountIn`) — a precursor marker emitted BEFORE the swap so indexers can classify the following hook `RealmSwapBuy` (which carries the keeper's `tx.origin`) as a protocol buy-back rather than a trade — then the external V4 buy-back swap events (`Swap`, plus the hook's own LP-fee/tax events since the buy-back is an ordinary swap), an ERC20 `Transfer(address(token), address(0), tokensBought)`, then **`RealmTaxableToken.CreatorTaxBurn`** (`quote, amountSpent, tokensBurned`) — the same shared event V2 emits, with a non-zero `amountSpent` here since V4 does buy the tokens back before burning. On `processBurn(address quote, uint256 minTokensOut)` both events carry that quote and `amountIn` / `amountSpent` are in its units, and the buy event is the ERC20 pool's `RealmHookAnyPair.RealmQuoteSwapBuy`; the no-quote overload is `quote = address(0)`. Reverts `NotAKeeper` unless `msg.sender` is on the `RealmKeepersRegistry` allowlist, `NothingToBurn` when the buffer is empty and `ProcessCooldown` when already run this block; spends at most `MAX_EARNINGS_PER_PROCESS` per call from the native buffer, or `MAX_QUOTE_SPEND_BPS` (25%) of an ERC20 quote's buffer (remainder stays buffered).
- **`processLiquidity()`** — deposits `liquidityPendingEth` as a single-sided ETH position just below the current price (a bid wall). Takes one of TWO paths, which differ only in their EXTERNAL events; the token's own event is identical either way. Both run through the shared `RealmUniV4LiquidityAdder.addOrTopUpSingleSidedEth`, which is also handed an ERC721 `ApprovalForAll(token, adder, true)` from the token on every call (a no-op after the first). (a) TOP-UP — the token remembers the two walls it most recently used (`getLiquidityWalls()` exposes their NFT ids and lower ticks), and when one of them still sits entirely below the current price and within ~2000 ticks of it, the adder thickens that position: emits `ModifyLiquidity` and settlement `Transfer`s, but NO ERC721 `Transfer` — no new NFT exists. (b) MINT — otherwise a fresh position is minted at the live tick, emitting the external V4 position-mint events (`ModifyLiquidity`, an ERC721 `Transfer(0x0, token, tokenId)`, settlement `Transfer`s). Either path then emits **`RealmTaxableToken.LiquidityAdded`** (`quote, amountIn, tokensAdded, liquidity`) — the shared event; `quote` is `address(0)` here and the ERC20 on `processLiquidity(address quote)`, which walls that quote's own pool with `amountIn` in its units; `tokensAdded` is always 0 (quote-only wall) and `liquidity` is the V4 liquidity units the position GAINED on this call. Indexers that counted one new position per `LiquidityAdded` must key off the ERC721 `Transfer` instead. Reverts `NotAKeeper` unless `msg.sender` is on the `RealmKeepersRegistry` allowlist, `NothingToAdd` when the buffer is empty and `ProcessCooldown` when already run this block; spends at most `MAX_EARNINGS_PER_PROCESS` per call from the native buffer, or `MAX_QUOTE_SPEND_BPS` (25%) of an ERC20 quote's buffer (remainder stays buffered). Every position the token mints is held by it forever (permanent depth), whether or not it is still one of the two remembered.
- **`sweepStrayEth()`** — routes the token's native balance beyond everything it owes (`burnPendingEth`, `liquidityPendingEth`, the dividend buffers and undelivered pots) back through the earnings-allocation split (same events as an `accrueFees` split), so stray native becomes token earnings instead of being stuck. Permissionless. Present on BOTH venues — it lives on `RealmTaxableToken` — and it is the only exit for stray native on V2, where `rescueTokens` no longer accepts `address(0)` and the swap-back only routes its own swap proceeds. Pre-graduation it deposits the whole balance to the fund wallets, which is what `rescueTokens(address(0))` used to do.

---

## 6.1 ERC20-quoted V4 swaps (`RealmHookAnyPair`)

A pool quoted in an ERC20 rather than the chain's native currency is mediated by `RealmHookAnyPair`, not `RealmHook`. Same fee formula, same destinations, same per-leg matrix; what differs is the currency and, crucially, WHEN it moves.

**The hook resolves the pair itself.** On a pool's first swap it asks each side which one is the Realm token — the side whose `pair()` is this pool manager AND which lists the other side among its own `quotes`. The answer is cached in `poolInfo(poolId)` and never recomputed. A pool whose pair holds no such token reverts `NotARealmPool`; a native-quoted pool reverts `NativeQuoteNotSupported` (those belong to `RealmHook`).

**The fee is CLAIMED during the swap and redeemed later.** A swapper settles their input AFTER the swap callbacks run, so on the first buy of a freshly seeded ERC20-quoted pool the pool manager is holding none of the quote and a `take` would revert — the launch would be untradeable. The hook therefore books an ERC-6909 claim (`PoolManager.mint`, which is pure accounting) and `settleFees(token, quote)` turns those claims into the currency and forwards them. That call is PERMISSIONLESS: the destinations are fixed, so a caller can only ever move protocol money where the protocol already decided it goes.

Per swap leg, in order:

1. **`RealmHookAnyPair.RealmPoolState`** (`token, poolId, sqrtPriceX96, liquidity`) — same fields and same ordering rationale as `RealmHook`'s.
2. **`RealmHookAnyPair.LpFeesForwarded`** (`token, quote, amount`) — the LP fee this leg produced, booked against the token. The name is kept from the native hook even though nothing is forwarded yet; the forward happens in step 5.
3. **`RealmHookAnyPair.CreatorTaxesAccrued`** (`token, quote, amount`) — only when the tax is non-zero.
4. **`RealmHookAnyPair.RealmQuoteSwapBuy`** (`token, quote, txOrigin, quoteIn, tokensOut, quoteFees`) or **`RealmQuoteSwapSell`** (`token, quote, txOrigin, tokensIn, quoteOut, quoteFees`). Separate events from the native hook's `RealmSwapBuy` / `RealmSwapSell` so an indexer cannot read a 6-decimal stablecoin amount as wei.

Then, on any later `settleFees(token, quote)` call:

5. `PoolManager` `Transfer` (the 6909 burn) and the ERC20 `Transfer` out of the manager, then **`SwapLpFeeRouter.LpAssetFeesRouted`** (`token, asset, creatorShare, treasuryShare, liquidityShare`) — or, on the router-failure fallback, no such event and the whole LP fee transferred to the treasury. The creator share reaches the token through `accrueFees(asset, amount)`, which routes it through the earnings split and then **`RealmMasterFeeHandler.CreatorAssetFeesDeposited`** (`token, asset, amount`), with an optional **`CreatorAssetClaimed`** on a successful direct forward.
6. The tax: the token's `accrueFees(quote, tax)`, with the same earnings split and **`CreatorAssetFeesDeposited`** / optional **`CreatorAssetClaimed`** — or, if that call reverts, no such events and the tax transferred to the treasury.
7. **`RealmHookAnyPair.TreasuryFallback`** (`token, quote, lpFee, tax`) — only when step 5 and/or step 6 fell back; each field is the amount of that leg that went to the treasury, 0 for a leg delivered normally.
8. **`RealmHookAnyPair.FeesSettled`** (`token, quote, lpFee, tax`) — records the (batched) moment the currency moved. The fees themselves were already reported, at the trades that produced them, in steps 2–3.

`settleFees` reverts `InsufficientGas` (no events) when the caller did not supply enough gas for the router and token calls to receive their full capped budgets, so a fallback is always a genuine destination failure, never a starved call.

**A batched overload settles many tokens in one call.** `settleFees(address[] tokens, address quote)` empties every listed token's ledger in that one quote under a SINGLE pool-manager unlock and a single `take`, then runs steps 5-8 once per token, in list order. The events are exactly the per-token ones — nothing is aggregated — just interleaved within one transaction; every one of them carries its own `token` and `quote`, so an indexer reads them as it always did. An entry whose ledger is empty emits nothing, which includes a token listed twice (it settles on its first appearance) and an all-empty batch, which is a silent no-op with no `PoolManager` `Transfer` at all. `InsufficientGas` is still checked per delivery but reverts the WHOLE batch, so a batch either settles all of its non-empty entries or none of them.

The treasury slice of an ERC20 LP fee ACCUMULATES on `RealmTreasuryRouter` — an ERC20 has no `receive()` to route it on arrival — until an owner calls `sweep(asset)`, which forwards the whole balance to the multisig and emits **`RealmTreasuryRouter.TreasuryAssetSwept`** (`asset, amount`), or a keeper converts it to native with `convert` (§11). Voting stays native-only, so an ERC20 is never split into it; only the native a conversion produces is.

---

## 7. `RealmMasterFeeHandler.claim(address[] tokens)`

Entry point for claimable fee recipients to withdraw accumulated ETH across any registered tokens.

For each token in `tokens` where `msg.sender` has a non-zero claimable balance:

1. **`RealmMasterFeeHandler.CreatorClaimed`** (`token, account=msg.sender, amount`).

After iterating all tokens, a single native ETH transfer pays the sum to `msg.sender`. If the sum is zero, no events are emitted and no ETH transfer is attempted.

Duplicate token entries do not double-pay because the first matching entry clears the caller's claimable balance for that token.

---

## 8. `RealmMasterFeeHandler.setShares(address token, FeeShare[] feeShares)`

Callable only by the master handler owner or the token's current non-zero owner. The token must already be registered.

Event order on a successful update:

1. Zero or more **`RealmMasterFeeHandler.DirectReceiverRemoved`** (`token, receiver`) — for addresses that were direct before the update and are no longer direct after it.
2. Zero or more **`RealmMasterFeeHandler.DirectReceiverRegistered`** (`token, receiver`) — for addresses that were not direct before the update and are direct after it.
3. **`RealmMasterFeeHandler.SharesUpdated`** (`token, recipients, sharesBps`).

A BPS-only rebalance with an unchanged direct set emits only `SharesUpdated`.

---

## 9. Direct-fee behavior

Direct fees are configured per token through `FeeShare.directFeesEnabled` at token creation or through `RealmMasterFeeHandler.setShares`.

For every successful non-zero `depositFees(token)` against a registered config:

1. **`RealmMasterFeeHandler.CreatorFeesDeposited`** (`token, amount`).
2. For each direct receiver with a non-zero slice:
   - If the ETH forward succeeds, **`RealmMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, sliceAmount`) is emitted immediately.
   - If the ETH forward fails, no `CreatorClaimed` event is emitted for that slice; the slice is stored as pending and can later be recovered through `claim()`.
3. Claimable recipients do not emit per-deposit claim events; they accrue through the master handler accumulator and emit `CreatorClaimed` only when they call `claim()`.

Zero-value `depositFees(token)` calls are no-ops and emit no fee events, including for unregistered tokens.

---

## 10. `RealmTaxableToken.setTaxBps(uint16 newBuyTaxBps, uint16 newSellTaxBps)`

Owner-only entry point on both `RealmTaxableTokenUniV2` and `RealmTaxableTokenUniV4`. Callable by the token owner OR `launchpad.owner()`. V2 tokens are always ownerless (`owner == address(0)`), so only the launchpad-owner branch is reachable there; V4 tokens are all direct-launched: owned by their creator unless ownership was renounced at creation, and with no launchpad, so only their owner can call it, and nobody once ownership is renounced.

The function is decrease-only: `newBuyTaxBps` and `newSellTaxBps` must both be `<= ` their current values, otherwise the call reverts with `TaxBpsCanOnlyDecrease`. Equal values are accepted (no-op for that side). `taxDurationSeconds` and `graduationTimestamp` are untouched.

On success:

1. **`RealmTaxableToken.TaxBpsUpdated`** (`newBuyTaxBps, newSellTaxBps`) — emitted before the storage write. Old values can be reconstructed from the preceding `RealmTaxableTokenInitialized` event at creation time and the chain of any prior `TaxBpsUpdated` events.

---

## 11. Treasury pushes — `RealmTreasuryRouter` / `RealmVoting`

Every "treasury share pushed" step above is a plain native call to the treasury address the payer holds:
`RealmLaunchpad.treasury()` (launchpad trades, both graduators via the launchpad) and the `TREASURY`
immutable of `SwapLpFeeRouter`. Once those point at the `RealmTreasuryRouter` proxy, each such push
nests the following inside the paying entry point, at the point of the push:

1. `RealmVoting`, inside the router's forward of 1/3:
   - **`RealmVoting.RoundStarted`** (`roundId, startTime, endTime`) — zero or more, only when the live round is
     ahead of storage: one per round skipped since the last touch (empty rounds, announced late with their
     true times), then one for the live round. See §12 for the round model.
   - **`RealmVoting.EthAllocated`** (`roundId, from=router, amount`) — the 1/3 slice, earmarked for the live round.
2. **`RealmTreasuryRouter.TreasuryEthRouted`** (`from, votingShare, treasuryShare`) — `from` is the payer
   (launchpad / graduator / LP fee router). `votingShare == 0` and no step-1 events when the voting call
   reverted: the whole amount then went to the multisig (fail-safe so a voting bug cannot brick trading),
   or when `msg.value < 3`.

**`convert(address asset, uint256 amountIn, uint256 minOut)`** — keeper-gated (`RealmKeepersRegistry`). Sells an ERC20 the router holds for native along the owner-set route, then routes the proceeds:

1. Universal-router swap events.
2. **`RealmTreasuryRouter.TreasuryAssetConverted`** (`asset, amountIn, nativeOut`) — both measured as balance deltas.
3. The §11 sequence above for `nativeOut`, with `TreasuryEthRouted.from` = the router itself.

**`setConversionRoute(address asset, PathKey[] path)`** — owner. **`RealmTreasuryRouter.ConversionRouteSet`** (`asset, route`), `route` = `abi.encode(path)`.

The multisig transfer emits nothing. `DividendBufferSweptToTreasury` (dividends section) pushes to the
token impl's compile-time `DIVIDEND_TREASURY`, which follows `DeploymentAddresses.REALM_TREASURY` at
the impl's deploy; whether it produces §11 events depends on what that constant was set to.

---

## 12. `RealmVoting` entry points

Rounds are derived from the clock, not a counter: contiguous, `roundDuration` long, anchored at
(`anchorId`, `anchorTime`). The live round id is `currentRound()`; storage (`lastSyncedRound`,
`rounds(id)`) only catches up on the first `vote` / native / `nextRound()` after a boundary, so an
indexer must treat a `RoundStarted` for id `n` as also closing every round `< n`, and a round with no
`RoundStarted` at all as empty. Round `1` starts at `initialize`. Winner = most votes; strictly greater
replaces, so the leader is replayable from `Voted` alone (first to reach the max wins a tie).

### `vote(address token, uint256 amount)` — permissionless

1. Optional **`RealmVoting.RoundStarted`** ×N (§11 step 1).
2. ERC20 `Transfer(voter, 0x0, amount)` on REALM — the burn (`burnFrom`, needs allowance).
3. **`RealmVoting.Voted`** (`roundId, token, voter, amount`) — `amount` burned = votes added. `token` is
   any address the voter chose: there is deliberately no launchpad check.

### `receive()` — native from the treasury router (or anyone)

§11 step 1: optional `RoundStarted` ×N, then **`EthAllocated`** (`roundId, from, amount`).

### `nextRound()` — permissionless, keeper convenience

**`RoundStarted`** ×N (§11 step 1). Reverts `RoundNotEnded` when storage is already at the live round.

### `processWinner(uint256 roundId, uint256 amount)` — admin

Only for `roundId < currentRound()`. **`WinnerProcessed`** (`roundId, winner, amount, to=admin`) then the
native transfer to the admin. Callable repeatedly until `ethCollected` is drained; `winner` is `0x0` for a
round without votes. Purchases of the winner are NOT reported on-chain: the admin wallet in `to` is the
one that buys, so attribute its buys of `winner` after this event.

### Admin

- **`RoundDurationSet`** (`duration, fromRoundId`) — at `initialize` (`fromRoundId = 1`) and on
  `setRoundDuration`, which applies from the round AFTER the live one: the live round keeps the end it
  was announced with, and the schedule re-anchors at that end. Emits `RoundStarted` ×N first if storage
  was behind.
- **`AdminSet`** (`account, allowed`).

---

## 13. `RealmToken.burn` / `burnFrom`

`RealmToken` (and so every clone, taxable variants included) is `ERC20Burnable`: `burn(amount)` and
`burnFrom(account, amount)` (allowance-gated) emit only the ERC20 `Transfer(account, 0x0, amount)`.
Burns are exempt from the anti-sniper wallet cap and are never taxed. Added for the REALM vote (§12).

---

## Holder dividends (out-of-band)

None of these fire on a trade. The dividend module accrues on the earnings path and does everything
else in separate transactions — `processDividends` keeper-gated, `claimDividends` open to every holder —
so an indexer sees them on their own.

`processDividends` and `claimDividends` are `delegatecall` stubs on the token into a per-venue
extension (`RealmDividendLogicUniV2` / `RealmDividendLogicUniV4`), because their bodies do not fit in the
clone's implementation under EIP-170. This changes nothing observable: the selectors, the argument
shapes, the event signatures and the emitting ADDRESS are all still the token's. The extension address
is never an event source and never needs indexing.

A token pays dividends in ONE TO THREE assets (`MAX_DIVIDEND_ASSETS`), fixed at creation: native, the
token itself (only when it is the sole asset), or any ERC20 whose configured pool held liquidity at
creation. The SET is written once and never rewritten, by anyone — there is no path that adds an asset,
removes one, or re-weights the split, so an indexer reads the whole configuration off the
`DividendAssetInitialized` events at creation and never has to watch for a change. `asset` on every
event below identifies WHICH member of that set the event is about, and is always one of them.

The assets are independent machines sharing only the token's eligible supply. Each has its own native
buffer, its own conversion, its own accumulator, its own per-block funding cooldown and its own
staleness clock. So the events below interleave freely ACROSS assets, and nothing may be inferred about
asset `j` from an event carrying asset `i` — a 20/80 split fills the 20% leg roughly four times more
slowly and is serviced that much less often, and one leg can go stale and be swept while the other is
distributing normally.

Each distribution is credited INSTANTLY, pro rata to the balances held when it lands, against a global
`rewardPerToken` accumulator that moves only then. (It used to drip over a 15-minute stream; that is
gone. What keeps a distribution out of a caller's own transaction is the keeper gate below, and the
keeper firing at unpredictable times.) There are no rounds, no phases and no snapshots, so there is no
round id on any event and nothing for an indexer to reconstruct a denominator from: a holder's
entitlement is `previewDividend(holder)`, read from the chain.

**At graduation**, immediately after `Graduated` and from `markGraduated()` itself:
**`DividendsActivated`** (no args) — the accumulator starts here rather than at creation, so a holder
earns from the moment the token is live. It is also the anchor for `STALE_DIVIDEND_WINDOW`. There is
ONE exception to the timing: a deploy buy large enough to graduate the token inside `createToken` runs
`markGraduated()` before the allocation is configured, so that token emits `DividendsActivated` on its
first earnings instead.

**`processDividends(uint8 assetIndex, uint256 minOut, address[] holders)`** — KEEPER-GATED, and the
keeper entry point for the NATIVE buffer. It services ONE payout asset per call: each asset fills on its own
schedule, prices its floor against its own pool and holds its own cooldown, so a keeper calls it once
per asset and the assets never contend. There is NO minimum buffer size — any non-zero buffer converts,
and whether a conversion earns its gas is the keeper's judgement, not a contract rule. `assetIndex` past `dividendAssetCount()` reverts
`DividendAssetOutOfRange`. The pre-existing two-argument form
**`processDividends(uint256 minOut, address[] holders)`** is still there and services asset 0, so a
keeper written for a single-asset token needs no change. Reverts `NotAKeeper` unless `msg.sender` is on
the `RealmKeepersRegistry` allowlist, with one exception: once THAT ASSET is stale
(`dividendsStale(assetIndex)`, i.e. `STALE_DIVIDEND_WINDOW` with no distribution of it) anyone may call
it for that asset, so a keeper set that goes away cannot strand holders' money. For an asset whose
funding SWAPS (any third ERC20, and the V4 self-token buy-back) staleness alone is NOT enough — its
buffer must ALSO hold at least `DIVIDEND_THRESHOLD`. A quiet token reaches a month without a
distribution in its ordinary steady state, simply by never buffering enough to be worth converting, and
opening a caller-supplied-floor swap there every month is a sandwich, not a rescue; a buffer that HAS
been convertible all along and still was not converted is the reading that actually evidences an absent
keeper. Assets whose funding does not swap (native, and the Uniswap-V2 self-token leg) keep the wide
bypass — there is nothing there for a caller to extract, so stranding is their only failure mode. A
sub-threshold residual on a swapping asset stays keeper-only. This is the ONLY thing
`DIVIDEND_THRESHOLD` still governs: it no longer gates funding. Holders
are never gated — `claimDividends()` stays open to everyone.

**`processDividends(uint8 assetIndex, address quote, uint256 minOut, address[] holders)`** (V4 tokens
only) services the buffer held in one of the token's QUOTES — what that quote's pool earned. `quote ==
address(0)` is exactly the call above. For an ERC20 quote the leg is one of three shapes, and the shape
decides the gate: the payout asset IS the quote (nothing is swapped; the whole buffer credits at once;
anyone may call once the asset is stale), the payout asset is the token itself (a buy-back on that
quote's own pool, the `processBurn` primitive, capped at `MAX_QUOTE_SPEND_BPS` of the buffer per call
and keeper-only however stale), or anything else (the registry's `swapAssetToAsset`, same cap, same
gate). As on the native leg there is no minimum buffer — the keeper decides when a buffer is worth its
gas — and `DIVIDEND_THRESHOLD` does not even apply here, being native-denominated and meaningless in a
currency the creator picked, so the staleness bypass never opens a quote leg that swaps. NO treasury sweep either:
a quote pool nobody can swap on strands that quote's buffer, as it strands `processBurn`'s. The
once-per-block cooldown is the ASSET's, shared across its native leg and every quote. `quote` not one
of the token's reverts `UnknownQuote`. Nothing about the gate changes the EVENT
sequence; it only adds a revert path. Once stale, the bypass also makes a distribution an ATOMIC
flash-buy capture (buy, fund, claim, sell in one transaction) — accepted, because a token nobody has
distributed for a month is most likely dead. It converts the buffer, credits the proceeds to holders,
and pushes payouts, doing whichever of the three there is anything to do. A keeper whose holder list
does not fit in one block just calls it again; there is no phase to sequence and no state that a
second call could disturb.

The FUNDING leg — steps 1 and 1b — runs at most once per block PER ASSET; servicing all three assets in
one block is normal and expected. A second call in the same block that
actually moved the buffer skips straight to the payouts, and reverts `DividendProcessCooldown` if it
was given no holders either. Pushing payouts is never rate-limited, so splitting a large holder set
across several transactions in one block works exactly as before.

1. Only if the buffer held anything at all, on either leg — there is no size floor, so an indexer must
   expect distributions of any magnitude, including dust:
   **`DividendsFunded`** (`quote, asset, amountIn, assetOut`). `quote` is the currency the buffer was held
   in — `address(0)` for native, else the ERC20 quote — and `amountIn` how much of it was consumed, in
   THAT currency's units; `assetOut` was split across the eligible supply at this instant. Reverts `NoDividendSupply`
   instead, leaving the buffer untouched, if the eligible supply is under one whole token.
1b. Instead of `DividendsFunded`, when a zero-floor conversion came back empty AND the token has gone
   `STALE_DIVIDEND_WINDOW` without a distribution: **`DividendBufferSweptToTreasury`**
   (`asset, nativeAmount`). The pool cannot produce a single wei at any price and has been unable to for
   a month — staleness is what makes that a persistent reading rather than a snapshot anyone could
   manufacture inside one transaction, since every successful distribution resets the staleness anchor.
   That slice of the native buffer went to `DIVIDEND_TREASURY` rather than sitting owed to
   holders forever, and the call returned successfully instead of reverting. It is bounded by
   `MAX_DIVIDEND_PER_CONVERSION` per call, so a dead pool's whole buffer takes several calls to clear.
   Nothing else changes: the payout asset, the accumulator and every unclaimed accrual are
   untouched, so an indexer needs only to stop expecting that native to become a distribution. A caller
   whose own `minOut` was simply unreachable gets `DividendConversionFailed` and no sweep.
2. V4 self-token only, immediately BEFORE its buy-back swap: **`DividendBuyBackInitiated`**
   (`quote, amountIn` — `address(0)` or the ERC20 quote, and the amount in its units), followed by the pool's own buy event
   (`RealmSwapHook.RealmSwapBuy` on the native pool, `RealmHookAnyPair.RealmQuoteSwapBuy` on an ERC20
   quote's). Same contract as `BuyBackInitiated`: the precursor must be classified as it arrives, so the
   keeper's PnL is not credited with a bag it never bought.
3. One **`DividendPaid`** (`holder, asset, amount`) per holder actually paid, in the order the caller
   listed them, for everything that holder had accrued at that moment. A holder with nothing accrued,
   a duplicate later in the same list, and a failed send all emit nothing — and a holder the keeper
   simply omits loses nothing at all, so a keeper is free to push only above whatever size threshold
   it likes.

   A call that funds nothing AND was given no holders reverts rather than emitting:
   `DividendConversionFailed` when the buffer was fundable and the conversion did not happen (an
   unreachable floor, or a dead pool on a token not yet stale), `BelowDividendThreshold` when it had not
   earned enough to try, and `DividendProcessCooldown` when the funding leg already ran this block.
   A call that swept does NOT revert —
   it resolved the buffer, and reverting would undo the sweep. A call carrying holders never reverts for
   either reason — it pushes the payouts it was asked to push.

**`claimDividends()`** — the self-serve backstop, emitting one **`DividendPaid`** for `msg.sender` PER
CONFIGURED ASSET that had anything accrued, in index order. It is the holder's one call for the whole
set, so a holder never has to know how many assets there are. It differs from a batch payout in one respect: a native payout inside `processDividends`
is gas-capped, so one expensive holder cannot starve the batch — at the chain's `NATIVE_PAYOUT_GAS` for
a native payout, and at the far larger `ASSET_PAYOUT_GAS` for an ERC20 one, whose `transfer` is a
contract the registry only ever vetted for liquidity. `claimDividends` forwards all remaining gas for
both shapes, so a holder skipped by a batch can always be paid by claiming. It never distributes.


### `RealmCreatorVault` (one clone per creator vault)

A vault is an ordinary dividend holder — its locked supply is a real team allocation, merely vested —
so it receives native and ERC20 payouts like any other address. Both entry points below are
**owner-only** and out-of-band; neither ever runs inside a token's transaction. The vault's own
creation events are in §1 step 4b.

- **`claim()`** → **`Claimed`** (`owner` indexed, `amount`) plus an ERC20 `Transfer` (vault → owner).
  Reverts `NotOwner` / `NotGraduated` / `NothingToClaim`. Only ever moves the VESTED allocation;
  it never touches anything the vault was paid.
- **`rescueTokens(address[] tokens)`** — sweeps everything that is NOT the locked allocation to the
  owner: one ERC20 `Transfer` (vault → owner) per listed token holding a balance, then the vault's
  whole native balance. `address(0)` entries in the array are skipped (native is always swept, it is
  not requested). For the vested token itself only the EXCESS above `totalAllocation - claimed` is
  sweepable, so a self-token dividend paid to a vault is recoverable without ever touching the
  vesting. Emits nothing of its own on the happy path — the ERC20 `Transfer`s are the record.
- **`NativeRescueFailed`** (`amount`) — emitted by `rescueTokens` when the native send to the owner
  reverts (an owner contract with no payable fallback). Best-effort by design and NOT a revert: the
  native leg runs after the ERC20 loop, so failing hard would make the ERC20s unrecoverable too. The
  native stays in the vault for a later attempt, so this event is a retry signal, not a loss.
- **`receive()`** — the vault accepts native so a `processDividends` payout to it lands rather than
  being skipped. No event; the payout is attributed by the paying token's own dividend events.

### Factories (`RealmFactoryUniV2Unified`, `RealmFactoryUniV4Direct` — one UUPS proxy each per chain)

- **`GraduatorSet`** (`graduator`) — the factory's `GRADUATOR`, emitted at most once per graduator per
  proxy, always before any token can use it: from `initialize()` (after `OwnershipTransferred` and
  `Initialized`), and from `announceGraduator()` passed as `upgradeToAndCall` data (after `Upgraded`),
  which is a no-op when the new implementation keeps the same graduator. Permissionless and idempotent.
  The indexer registers the graduator from this event, not from `TokenCreated`.

### `RealmKeepersRegistry` (one per chain)

The allowlist of addresses permitted to call `processDividends`, `processBurn` and `processLiquidity`.
It emits nothing inside a token's transaction — it is only ever read — so these events appear on their
own, rarely, and are not attributable to any token.

- **`AdminSet`** (`account`, `allowed`) — owner-only; manages who may emit the one below.
- **`KeeperSet`** (`account`, `allowed`) — admin-level; a keeper key being rotated in or out. Revocation
  takes effect in the next transaction.

### `RealmAssetsWhitelist` (one upgradeable proxy per chain)

The ERC20 quotes `RealmFactoryUniV4Direct` accepts, each with the Uniswap V2, V3 or V4 pool that prices it
and its rate in native. Only ever read by the factory, so its events appear on their own and are not
attributable to any token. Delisting refuses new launches only; live pools are untouched. A UUPS proxy:
deployment emits the proxy's `Upgraded`, `OwnershipTransferred` and `Initialized`, and every owner-only
upgrade another `Upgraded`.

- **`ApproverSet`** (`account` indexed, `allowed`) — owner-only; manages who may emit the one below. The
  owner cannot whitelist itself.
- **`WhitelistUpdated`** (`asset` indexed, `unitsPerNativeX18`, `source`) — approver-only, from
  `setWhitelisted(asset, source)`. `source` is `(venue, pool, key)`: venue `V2`/`V3` with the pair/pool
  address in `pool`, or `V4` with the full `PoolKey` in `key`, against native (WETH counts as native) or
  against an asset itself listed against native. `asset` is listed or repriced with the rate snapshotted
  from that pool's spot price, or delisted by venue `NONE`, emitting `unitsPerNativeX18 == 0`.

### `RealmDividendSwapRegistry` (one per chain)

The eligibility gate and swap venue behind every third-asset dividend. It is a SHARED contract, so its
events are not attributable to a token by their emitter — index them on their own and join on `asset`.

**Per conversion**, inside the funding leg of `processDividends` (step 1 above), immediately before the
token's own `DividendsFunded`:

- **`DividendAssetPurchased`** (`asset`, `recipient`, `nativeIn`, `assetOut`) — `recipient` IS the token
  whose holders are being credited, which is the only link back to it. Absent when the payout asset is native or
  the token itself (no conversion happens), and absent when the conversion failed (the whole call
  reverted and the token reports `DividendConversionFailed`).
- **`DividendAssetSwapped`** (`source`, `asset`, `recipient`, `amountIn`, `nativeVia`, `assetOut`) — the
  quote-leg counterpart (`swapAssetToAsset`): `amountIn` of the ERC20 `source` (the token's quote) was
  walked backwards along `source`'s route to `nativeVia` native, the keeper's cut came out of that, and
  the rest went forward along `asset`'s route (or, for `asset == address(0)`, was delivered as native —
  then `assetOut` is what was delivered). Absent when the payout asset is the quote itself or the
  token (no registry involved).
- **`KeeperFunded`** (`keeper`, `amount`) — immediately after either of the above, when a keeper wallet
  is configured: the slice of the conversion's native paid to it as gas money instead of being swapped.
  A quote leg pays it out of the native in the MIDDLE of the conversion, so the keeper is funded in
  native whatever currency the buffer was in.
  `amount` is the flat per-chain `KEEPER_FEE`, except on a conversion small enough for the
  `MAX_KEEPER_CUT_BPS` clip to bite, so read it rather than deriving it. Note
  `DividendAssetPurchased.nativeIn` is the FULL amount the token sent, this included, so the amount
  actually converted is `nativeIn - amount`.

**Per token creation**, one per non-native, non-self payout asset — plus, on the direct venue, one per
ERC20 quote some payout leg has to be bought OUT of (a quote that is itself a payout asset registers
once; its one route is walked either way) — inside the creation transaction:

- **`DividendRouteRegistered`** (`token`, `asset`, `route`) — the pools `token` will convert `asset`
  through, for the rest of its life. `route` is the `DividendRouteLib` wire format: EMPTY means the
  asset's permissionless Uniswap V2 pair (a real choice, not a missing one), a leading `0x04` is an
  abi-encoded `Hop[]` of `{currency, fee, tickSpacing, hooks}` running from the native coin, and a
  leading `0x03` is Uniswap V3's own packed `token | fee | token` path running from the quote token.
  Chosen by the creator, validated once, and NEVER rewritten — there is no second event for a
  `(token, asset)` pair and no admin override. Replaying these is the only way to learn which pools a
  token's dividends cross; nothing else records it, and the route is not derivable from the asset.

**Configuration** (admin, rare, never inside a token's transaction):

- **`AdminSet`** (`account`, `allowed`) — owner-only; manages who may emit the four below.
- **`BlacklistSet`** (`asset`, `blacklisted`) — THE ONLY VETO, and the only admin lever that touches
  eligibility at all. Retroactive: it stops tokens that already registered a route for the asset, from
  their next conversion on. Realm does not review payout assets and has no whitelist, so this is what
  answers an asset that turns out to be hostile after tokens have committed to it.
- **`DefaultThresholdSet`** (`threshold`) / **`QuoteTokenThresholdSet`** (`quote`, `threshold`) — the
  quote-side depth an asset's V2 pair must hold. Applies to the EMPTY route only; a route names its
  pools, which are checked for existence and liquidity instead. A change applies to tokens that ALREADY
  exist, for every conversion they have not made yet.
- **`QuoteTokenAllowed`** (`quote`, `allowed`) — the `from` side of a conversion, and the set of
  currencies a two-hop V3 path may route THROUGH. Emitted once at deployment for the chain's canonical
  quote token.
- **`KeeperFundingSet`** (`keeper`) — the wallet the fee above is paid to; `address(0)` turns the fee
  off, which is the state a freshly deployed registry is in. The fee AMOUNT is not here and never
  changes without an upgrade: it is the compile-time `KEEPER_FEE`. Applies to tokens that ALREADY exist,
  from the next conversion on.

Eligibility is not fully replayable from logs: for a token whose route is empty it is a live liquidity
read against Uniswap V2, and for a routed one it is a live pool read against the V4 singleton, so an
indexer must call `checkSwapSupported(token, asset)` for a current answer.

Resolution is not an order any more — a token has exactly ONE route per asset and it names its venue.
`checkSwapSupported` and the swap itself share that order.
