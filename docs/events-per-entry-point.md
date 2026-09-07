# Events per Entry Point

Reference for indexers, subgraphs, monitoring and auditing: which Livo events are emitted by each core user-facing entry point, in the order they occur on-chain.

## Scope and current fee-handler model

This document describes the active source tree after the legacy implementations were removed:

- `src/feeHandlers/LivoFeeHandler.sol` — removed from active source.
- `src/feeSplitters/LivoFeeSplitter.sol` — removed from active source.
- `ILivoFeeHandler` / `ILivoFeeSplitter` interfaces may remain for legacy deployed-contract interaction, but no active factory/token path deploys or imports those implementations.

All new tokens use the singleton `LivoMasterFeeHandler`.

Pre-graduation trading fees are no longer global launchpad state. Each token carries its own LP
(trading) fee — split treasury/creator by `treasuryShareBps` — plus, on taxable variants, a creator
tax (100% to the creator), read per-trade by the launchpad via `ILivoToken.getLaunchpadFees` and
reported through `LivoLaunchpad.LpFeesAccrued` / `LivoLaunchpad.CreatorTaxesAccrued` (mirroring the
post-graduation `LivoSwapHook` for accounting parity). The launchpad's global `setTradingFees` /
`TradingFeesUpdated` are removed; the per-token LP-fee config surfaces as
`LivoToken.LaunchpadFeesInitialized` (at creation). The LP fee is immutable after launch (no setter).
The creator tax is configured on taxable variants and surfaces via `LivoTaxableTokenInitialized` /
`TaxBpsUpdated`; its window is creation-anchored (`[launchTimestamp, launchTimestamp + taxDurationSeconds]`)
and applies identically pre- and post-graduation.

Unified factories register fee config automatically during token creation:

`factory.createToken(...) -> _finalizeCreation(...) -> LivoToken.registerFees(...) -> LivoMasterFeeHandler.registerToken(...)`

`LivoMasterFeeHandler.registerToken` emits any initial direct-receiver events first, then `SharesUpdated`.

## Active event emitters covered here

- `LivoFactoryUniV2Unified` / `LivoFactoryUniV4Unified`
- `LivoLaunchpad`
- `LivoToken` / `LivoTaxableTokenUniV4` / `LivoTaxableTokenUniV2` / sniper-protected variants
- `LivoGraduatorUniswapV2` / `LivoGraduatorUniswapV4` — the ARC variant `LivoGraduatorUniswapV2Arc` shares `LivoGraduatorUniswapV2Base` and emits the identical events in the identical order; every `LivoGraduatorUniswapV2` mention below applies to it unchanged.
- `LivoMasterFeeHandler`
- `LivoSwapHook`
- `LivoDividendSwapRegistry` — one shared upgradeable proxy per chain, not a per-token contract

External ERC20 / Uniswap / WETH / Permit2 events still occur in traces, but this file focuses on Livo-owned events and notes the main external-operation points.

## Table of contents

1. [`createToken` — unified factory paths](#1-createtoken--unified-factory-paths)
2. [`buyTokensWithExactEth` — pre-graduation](#2-buytokenswithexacteth--pre-graduation)
3. [`buyTokensWithExactEth` that triggers V2 graduation](#3-buytokenswithexacteth-that-triggers-v2-graduation)
4. [`buyTokensWithExactEth` that triggers V4 graduation](#4-buytokenswithexacteth-that-triggers-v4-graduation)
5. [`sellExactTokens` — pre-graduation](#5-sellexacttokens--pre-graduation)
6. [V4 post-graduation swaps](#6-v4-post-graduation-swaps)
7. [`LivoMasterFeeHandler.claim`](#7-livomasterfeehandlerclaimaddress-tokens)
8. [`LivoMasterFeeHandler.setShares`](#8-livomasterfeehandlersetsharesaddress-token-feeshare-feeshares)
9. [Direct-fee behavior](#9-direct-fee-behavior)
10. [`LivoTaxableToken.setTaxBps`](#10-livotaxabletokensettaxbpsuint16-newbuytaxbps-uint16-newselltaxbps)

---

## 1. `createToken` — unified factory paths

Each unified factory exposes five `createToken` overloads with different selectors:
- **Legacy positional** (deprecated): `(name, symbol, salt, feeReceivers, supplyShares, taxCfg, antiSniperCfg)` on V2 and the same plus `renounceOwnership_` on V4. Never creates creator vaults. Takes the legacy `TaxConfigInit` (static tax only) and always uses `LiquidityTier.DEFAULT`.
- **Struct-based, tiered** (backwards-compat): `(TokenSetupTiered, TaxConfigs, [UniV4Configs,] SupplyShare[], AntiSniperConfigs, CreatorVault[])` — struct-grouped inputs (to keep the ABI extensible without hitting stack-too-deep) plus a trailing `CreatorVault[]` (empty for none) that locks supply in vesting vaults. `TokenSetupTiered` carries the `liquidityTier` field selecting the post-graduation pool depth. Takes the full `TaxConfigs` (static tax + the three launch-tax-decay fields).
- **Struct-based, tiered + referral** (current/recommended): the same shape plus a trailing `address referral` for relayers that forward the creation and are entitled to a cut of the fees. When `referral != address(0)` it additionally emits `LivoFactory.TokenReferral` (see §1.1 step 7). No token storage or on-chain payout is wired to the referral yet — it is purely an off-chain signal for now.
- **Struct-based, tiered + referral + earnings allocation**: the referral overload's shape but with `TaxConfigsWithAllocation` in place of `TaxConfigs` — the flat `TaxConfigs` fields plus a nested `earningsAllocation` = `{burnBps, dividendsBps, liquidityBps, dividendToken}` (post-graduation earnings routed to buy-back-and-burn / holder dividends / liquidity; the fund wallets take the remainder). The split is stored on the token at creation via a factory-guarded `initializeEarningsAllocation` call, emitting `EarningsAllocationInitialized` and — when `dividendsBps != 0` — `DividendsInitialized` (see §1.1 step 6b). A non-zero split requires a token with a LONG-TERM STATIC tax (`taxConfigs.taxDurationSeconds != 0`); otherwise the overload reverts `EarningsAllocationRequiresTax`. Being a taxable-impl clone is NOT enough: a decay-only token (zero static tax, non-zero `taxDecayDuration`) is deployed on the taxable impl and is still rejected, because its ≤20-minute decay window is not a post-graduation tax stream worth splitting. A token pays dividends in exactly ONE asset: `address(0)` (native), `DividendDistribution.DIVIDEND_SELF_TOKEN` (paid in the token itself), or ANY ERC20. There is no asset whitelist, no per-asset approval and no review: the creator names the pools their token will convert through and the registry checks only that those pools are real. An ERC20 qualifies if `LivoDividendSwapRegistry.registerRoute(asset, route)` accepts it at creation, which is either a Uniswap **V2** pair for `quote`/`asset` whose quote-side reserve clears the registry's threshold (the empty route), or a Uniswap **V4** / **V3** route whose every pool is initialized and holds liquidity — which is how assets with no V2 pair at all, such as Robinhood Chain's ~190 xStocks, qualify. Otherwise the registry reverts `RouteRejected(rejection)` at creation, where `rejection` is `NoPair` | `InsufficientLiquidity` | `Blacklisted` | `QuoteNotAllowed` | `MalformedRoute` | `DeadPool` | `IntermediateNotAllowed`, because a clone cannot be patched afterwards. What is NOT checked, by anyone, is whether the named pool's price tracks the asset's real market. The registry is never consulted for the native and self-token payouts, which buy nothing. An all-zero `earningsAllocation` behaves exactly like the referral overload (no extra call, no event).

- **Struct-based, tiered + referral + MULTI-ASSET earnings allocation**: the allocation overload's shape but with `TaxConfigsWithMultiAllocation` in place of `TaxConfigsWithAllocation` — its nested `earningsAllocation` is `{burnBps, dividendsBps, liquidityBps, dividendTokens[], dividendWeightsBps[], dividendRoutes[]}`. Identical in every respect except that the dividends slice may name UP TO THREE payout assets (`DividendDistribution.MAX_DIVIDEND_ASSETS`) and how it is divided between them: `dividendWeightsBps[i]` is asset `i`'s share OF THE DIVIDENDS SLICE, in bps. The set is validated once, at creation, and is permanent: 1..3 entries with both arrays the same length, every weight non-zero, the weights summing to exactly 10 000, the assets DISTINCT, and `DIVIDEND_SELF_TOKEN` legal only as the sole entry — otherwise `InvalidDividendAssetSet` / `SelfTokenDividendMustBeSole`. Every non-native, non-self entry is registered with `LivoDividendSwapRegistry` individually, on the same terms as the single-asset overload, carrying `dividendRoutes[i]` as its route — an array shorter than `dividendTokens` means the empty route (the permissionless V2 pair) for the remainder, which is what the single-asset overload always uses. A one-entry set weighted 10 000 produces a token identical to the single-asset overload's. Emits `EarningsAllocationInitialized`, then one `DividendRouteRegistered` (from the registry) and one `DividendAssetInitialized` per asset, then `DividendsInitialized` (see §1.1 step 6c).

The legacy positional overload internally lifts its `TaxConfigInit` into a `TaxConfigs` (decay fields zeroed) before dispatch, so all three share the same internal flow and emit the events listed below in the same order; only the two struct-based overloads can emit the creator-vault events in §1 step 4b.

### 1.1 Common sequence

For both unified factories, the common Livo event order is:

1. **`LivoFactory.TokenCreated`** (`token, name, symbol, tokenOwner, launchpad, graduator, feeHandler=LivoMasterFeeHandler`) — emitted before token initialization so indexers see the token entity before initializer-side events. `LivoFactoryUniV2Unified` always emits `tokenOwner = address(0)`; `LivoFactoryUniV4Unified` emits `address(0)` only when ownership is renounced.
2. **Graduator initialization events**:
   - V2: **`LivoGraduator.PairInitialized`** (`token, pair`) — pair address is predicted; pair deployment can happen later at graduation.
   - V4: **`LivoGraduator.PairInitialized`** (`token, pair=PoolManager`) then **`LivoGraduatorUniswapV4.PoolIdRegistered`** (`token, poolId, swapHookAddress`).
3. Implementation initializer events (emitted during the token's `initialize`, after the initial mint(s)):
   - Always: **`LivoToken.LaunchpadFeesInitialized`** (`lpFeeBps, treasuryShareBps`) — the per-token pre-graduation LP-fee config the launchpad reads each trade. A single LP fee applies to both buys and sells (mirroring the post-graduation hook). The creator tax (if any) is reported separately by `LivoTaxableTokenInitialized` below. Emitted before the tax/sniper events below.
   - Tax token: **`LivoTaxableTokenInitialized`** (`buyTaxBps, sellTaxBps, taxDurationSeconds, startTaxFromLaunch, buyTaxDecayStartBps, sellTaxDecayStartBps, taxDecayDuration`). `startTaxFromLaunch` tells the indexer the tax-window anchor: `true` → window runs `[launchTimestamp, launchTimestamp + taxDurationSeconds]` (creation-anchored, spans graduation); `false` → `[graduationTimestamp, +taxDurationSeconds]` (no tax pre-graduation). The three `*Decay*` fields configure the optional linear launch-tax decay, anchored at the SAME point as the static window: each direction's rate decays linearly from `*TaxDecayStartBps` (`buyTaxDecayStartBps + sellTaxDecayStartBps` ≤ 2000 = 20% combined) at the anchor to 0 over `taxDecayDuration` (≤1200 s = 20 min). The effective tax a trade pays is `max(decay, static)` per direction, so a token may emit non-zero decay fields with zero static fields (a "decay-only" token — a non-taxable token that opted into the launch decay; it is still deployed as a taxable-impl clone). A token may also configure both, or neither (all six fields 0).
   - Sniper-protected token: **`SniperProtectionInitialized`** (`maxBuyPerTxBps, maxWalletBps, protectionWindowSeconds, whitelist`).
4. **`LivoLaunchpad.TokenLaunched`** (`token, graduationThreshold, maxExcessOverThreshold`). For a creator-vault token the registered bonding curve is the allocation-specific one, but the graduation threshold/excess are identical to the base curve.
4a. **`LivoFactory.BondingCurveAssigned`** (`token, bondingCurve`) — records which bonding curve the token was launched on (the allocation-specific curve for creator-vault tokens, the base curve otherwise). Emitted immediately after `TokenLaunched`; both fields are indexed. This is the only event carrying the curve address — combine it with the curve's own `LivoBondingCurveDeployed` (emitted at curve-deploy time, see note below) to reconstruct reserves off-chain.
4b. Creator vaults only (non-empty `CreatorVault[]`): the factory deploys and funds the vaults. Per vault, in order: **`LivoCreatorVaultFactory.CreatorVaultDeployed`** (`vault, token, owner, amount, cliffSeconds, vestingSeconds`) followed by an ERC20 `Transfer` (factory → vault). After all vaults: **`LivoFactory.CreatorVaultsCreated`** (`token, totalVaultAllocation, vaults, amounts`).
5. Initial fee config is registered through the token into `LivoMasterFeeHandler`:
   - Zero or more **`LivoMasterFeeHandler.DirectReceiverRegistered`** (`token, receiver`) — one per initial direct receiver.
   - **`LivoMasterFeeHandler.SharesUpdated`** (`token, recipients, sharesBps`).
6. V4 only: **`LivoFactory.LpFeeBpsSet`** (`token, lpFeeBps`) — emitted by `LivoFactoryUniV4Unified` for every created token, unconditionally (presence of the event is itself the V4-origin signal). `LivoFactoryUniV2Unified` never emits it. With `msg.value > 0`, this fires *after* the deployer-buy events listed in 1.2.
6b. Earnings-allocation overload only, and only when `earningsAllocation` is non-zero: **`EarningsAllocation.EarningsAllocationInitialized`** (`burnBps, dividendsBps, liquidityBps`) — the creation-time earnings split. Emitted by the token itself from the factory-guarded `initializeEarningsAllocation` call, which the factory makes *after* the shared creation body — so it fires after the fee registration (step 5), any deployer-buy events (§1.2) and `LpFeeBpsSet` (step 6, V4), and before `TokenReferral` (step 7). Both factories emit it (via the token); an all-zero allocation, or any other overload, emits nothing here.

6c. Same call, immediately after 6b, and only when `dividendsBps != 0`: one **`DividendDistribution.DividendAssetInitialized`** (`index` indexed, `asset`, `weightBps`) per configured payout asset, in index order, followed by exactly one **`DividendDistribution.DividendsInitialized`** (`dividendToken`) carrying asset 0. `DividendAssetInitialized` is the complete description of the payout configuration — how many assets, which, and each one's share of the dividends slice; `DividendsInitialized` is kept, and kept last, so indexers written against the single-asset shape keep working (a single-asset token emits one of each, with the same address). The self-token sentinel is already resolved to the token's own address in both. The set is fixed for the token's life — there is no add, no remove and no re-weight, on any path. Nothing else fires here: the accumulators start at graduation, not at creation (see §graduation).
7. Referral overload only, and only when `referral != address(0)`: **`LivoFactory.TokenReferral`** (`token, referral`, both indexed) — records the relayer/referrer that forwarded the creation. Emitted last of all factory events (after `LpFeeBpsSet` on V4, and after `EarningsAllocationInitialized` on the allocation overload). Both factories emit it; the common no-referral deploy emits nothing here.

Notes:

- The bonding curve contracts (`ConstantProductBondingCurve`, `ConstantProductBondingCurveConfigurable`) emit **`LivoBondingCurveDeployed`** (`k, t0, e0, ethGraduationThreshold, maxExcessOverThreshold`) once from their constructor — in the curve's own deploy tx, NOT during `createToken`. The `Livo` prefix gives the event a unique topic so it can be wildcard-indexed (from any curve address). Indexers join it to `BondingCurveAssigned` (step 4a) by curve address to reconstruct token reserves at any eth reserves `e`: `t = k / (e + e0) - t0`.
- Single-recipient and multi-recipient fee configs use the same master-handler registration path.
- There is no `FeeSplitterCreated` event and no splitter initialization event in the active source path.
- ERC20 mint and OpenZeppelin `Initialized` events also appear during token clone initialization. For creator-vault tokens the initial mint is split: `TOTAL_SUPPLY - vaultAllocation` is minted to the launchpad and `vaultAllocation` is minted to the factory (which then funds the vaults in step 4b). For non-vault tokens the full supply is minted to the launchpad, unchanged.

### 1.2 With deployer buy (`msg.value > 0`)

After the common sequence above, the factory performs the buy and distribution:

1. **`LivoLaunchpad.LivoTokenBuy`** (`token, buyer=factory, ethAmount=msg.value, tokenAmount=tokensBought, ethFee`).
2. **`LivoFactory.BuyOnDeploy`** (`token, buyer=msg.sender, ethSpent, tokensBought, recipients, amounts`).

ERC20 `Transfer` events occur from launchpad to factory and then from factory to each supply-share recipient.

---

## 2. `buyTokensWithExactEth` — pre-graduation

The pre-graduation fee policy is read per-trade from the token (`ILivoToken.getLaunchpadFees`) and
capped by the launchpad. The LP (trading) fee is split treasury/creator by `treasuryShareBps`; the
optional tax goes 100% to the creator. The treasury share is pushed; the creator total (LP creator
share + tax) is routed through `LivoToken.accrueFees` into `LivoMasterFeeHandler`. The event
vocabulary mirrors the post-graduation `LivoSwapHook` for accounting parity.

When the buy does not graduate the token:

1. ERC20 transfer from `LivoLaunchpad` to buyer.
2. **`LivoLaunchpad.LpFeesAccrued`** (`token, creatorShare, treasuryShare`) — emitted whenever a fee is taken.
3. **`LivoLaunchpad.CreatorTaxesAccrued`** (`token, taxAmount`) — only when the tax is non-zero.
4. Creator total (LP creator share + tax), when non-zero, routed through `LivoToken.accrueFees` → `LivoMasterFeeHandler.depositFees(token)`:
   - **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount`).
   - Optional **`LivoMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) on a successful direct forward.
5. Treasury share sent via a native ETH call (no Livo event for the ETH transfer).
6. **`LivoLaunchpad.LivoTokenBuy`** (`token, buyer, ethAmount=msg.value, tokenAmount, ethFee`) — `ethFee` is the total (LP fee + tax).

A token with `treasuryShareBps = 100%` and no tax (the launchpad's legacy-equivalent default) has
`creatorShare == 0` and no tax, so steps 3–4 are skipped; its only addition vs. the legacy flow is
the `LpFeesAccrued` in step 2.

If the buy crosses the graduation threshold, append the relevant graduation sequence from §3 or §4.

---

## 3. `buyTokensWithExactEth` that triggers V2 graduation

The initial buy emits the pre-graduation buy sequence from §2, then graduation begins in `LivoLaunchpad._graduateToken`.

Livo event order:

1. The triggering buy first emits its full §2 sequence — ERC20 transfer to buyer, the fee events (**`LivoLaunchpad.LpFeesAccrued`**, optional **`CreatorTaxesAccrued`**, and the creator-share `CreatorFeesDeposited` when applicable), and **`LivoLaunchpad.LivoTokenBuy`** (`token, buyer, ethAmount, tokenAmount, ethFee`).
2. ERC20 transfer of the remaining launchpad token balance from `LivoLaunchpad` to `LivoGraduatorUniswapV2`.
3. **`LivoGraduator.CreatorGraduationFeeCollected`** (`token, amount=creatorCompensation`).
4. Creator compensation is routed through `LivoToken.accrueFees()` into `LivoMasterFeeHandler.depositFees(token)`:
   - **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount=creatorCompensation`).
   - Optional **`LivoMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) if the configured receiver is direct and the forward succeeds.
5. **`LivoGraduator.TreasuryGraduationFeeCollected`** (`token, amount=treasuryShare`).
6. **`LivoToken.Graduated`**.
7. External Uniswap V2 pair creation / liquidity / LP-token events may occur.
8. **`LivoGraduator.TokenGraduated`** (`token, tokenAmount, ethAmount, liquidity`).
9. Optional **`LivoGraduatorUniswapV2.SweepedRemainingEth`** (`token, amount`) if triggerer compensation failed or residual ETH remains.
10. **`LivoLaunchpad.TokenGraduated`** (`token, ethCollected, tokensForGraduation`).

---

## 4. `buyTokensWithExactEth` that triggers V4 graduation

The initial buy emits the pre-graduation buy sequence from §2, then graduation begins in `LivoLaunchpad._graduateToken`.

Livo event order:

1. The triggering buy first emits its full §2 sequence — ERC20 transfer to buyer, the fee events (**`LivoLaunchpad.LpFeesAccrued`**, optional **`CreatorTaxesAccrued`**, and the creator-share `CreatorFeesDeposited` when applicable), and **`LivoLaunchpad.LivoTokenBuy`** (`token, buyer, ethAmount, tokenAmount, ethFee`).
2. ERC20 transfer of the remaining launchpad token balance from `LivoLaunchpad` to `LivoGraduatorUniswapV4`.
3. **`LivoGraduator.CreatorGraduationFeeCollected`** (`token, amount=creatorCompensation`).
4. Creator compensation is routed through `LivoToken.accrueFees()` into `LivoMasterFeeHandler.depositFees(token)`:
   - **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount=creatorCompensation`).
   - Optional **`LivoMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) if the configured receiver is direct and the forward succeeds.
5. **`LivoGraduator.TreasuryGraduationFeeCollected`** (`token, amount=treasuryShare`).
6. **`LivoToken.Graduated`**.
   - Tax tokens emit this same event from the override and also record `graduationTimestamp`.
7. External Uniswap V4 PoolManager / PositionManager / Permit2 events occur while liquidity positions are minted.
7a. ERC20 `Transfer` (graduator -> `0x…dEaD`) of the token dust the positions could not take. Always present in practice — the position math never consumes the deposit exactly — and burned rather than held so the graduator never becomes a continuous holder accruing unclaimable dividends.
8. **`LivoGraduator.TokenGraduated`** (`token, tokenAmount, ethAmount, liquidity`). `tokenAmount` is what the positions ACTUALLY took, so it already excludes the dust burned in 7a.
9. **`LivoLaunchpad.TokenGraduated`** (`token, ethCollected, tokensForGraduation`).

---

## 5. `sellExactTokens` — pre-graduation

When a token is not graduated yet, sells happen against launchpad reserves. As with buys, the fee
policy is read per-trade from the token: the LP fee is split treasury/creator, the tax goes 100% to
the creator. The treasury share is pushed and the creator total is routed through `accrueFees`.

The event order matches buys (§2) and the post-graduation `LivoSwapHook` (§6): the fee events come
first and the trade event closes the sequence.

Livo event order:

1. ERC20 transfer from seller to launchpad.
2. **`LivoLaunchpad.LpFeesAccrued`** (`token, creatorShare, treasuryShare`) — emitted whenever a fee is taken.
3. **`LivoLaunchpad.CreatorTaxesAccrued`** (`token, taxAmount`) — only when the tax is non-zero.
4. Creator total, when non-zero, via `LivoToken.accrueFees` → `LivoMasterFeeHandler.depositFees(token)`:
   - **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount`).
   - Optional **`LivoMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) on a successful direct forward.
5. **`LivoLaunchpad.LivoTokenSell`** (`token, seller, tokenAmount, ethAmount, ethFee`) — `ethFee` is the total (LP fee + tax).
6. Treasury share sent via native ETH call (no Livo event for the ETH transfer).
7. Seller receives ETH via native ETH call (no Livo event for the ETH transfer).

---

## 6. V4 post-graduation swaps

V4 swaps are mediated by `LivoSwapHook`. Swaps before graduation revert with `NoSwapsBeforeGraduation` and emit no Livo swap/fee events.

The hook reads the per-token fees via `LivoToken.getSwapFees(isBuy)` (LP fee + currently-effective tax for
that direction). The LP fee is forwarded whole to `LivoLpFeeRouter`, which splits it between treasury and
creator by a marketcap tier; the tax (if any) is forwarded to the token's master fee handler. The LP fee and
the tax are accrued in **separate** `accrueFees` calls, so the creator can see up to two
`CreatorFeesDeposited`.

### 6.1 Buy (`ETH -> token`)

The fee is withheld from the ETH leg (`beforeSwap` for exact-input, `afterSwap` for exact-output); the
routing and all events below are emitted in `afterSwap`.

Livo event order (LP fee `> 0`, buy tax active, router healthy):

1. **`LivoSwapHook.LpFeesForwarded`** (`token, amount`) — the whole LP fee handed to the router.
2. **`LivoLpFeeRouter.LpFeesRouted`** (`token, creatorShare, treasuryShare, liquidityShare=0`) — the tier split.
3. Treasury LP share is sent to the router's treasury via native ETH call (no event).
4. Creator LP share is routed through `LivoToken.accrueFees()` into `LivoMasterFeeHandler.depositFees(token)`:
   - **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount=creatorShare`).
   - Optional **`LivoMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) per successful direct forward.
5. Optional **`LivoSwapHook.CreatorTaxesAccrued`** (`token, taxAmount`) if buy tax is active and non-zero, then the
   tax is routed through `LivoToken.accrueFees()` (a second **`CreatorFeesDeposited`** / optional `CreatorClaimed`).
6. **`LivoSwapHook.LivoSwapBuy`** (`token, txOrigin, ethIn, tokensOut, ethFees`).

Router-failure fallback: if `LivoLpFeeRouter.depositLpFees` reverts, step 2 (`LpFeesRouted`) and step 4 are
absent — the hook instead pushes the **entire** LP fee to the protocol treasury via a native ETH call (no
event). Indexers detect the fallback by the presence of `LpFeesForwarded` without a matching `LpFeesRouted`.

### 6.2 Sell (`token -> ETH`)

The fee is taken from the ETH leg (`afterSwap` for exact-input, withheld in `beforeSwap` for exact-output);
the routing and all events below are emitted in `afterSwap`.

Livo event order (LP fee `> 0`, sell tax active, router healthy):

1. **`LivoSwapHook.LpFeesForwarded`** (`token, amount`) — the whole LP fee handed to the router.
2. **`LivoLpFeeRouter.LpFeesRouted`** (`token, creatorShare, treasuryShare, liquidityShare=0`) — the tier split.
3. Treasury LP share is sent to the router's treasury via native ETH call (no event).
4. Creator LP share is routed through `LivoToken.accrueFees()` into `LivoMasterFeeHandler.depositFees(token)`:
   - **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount=creatorShare`).
   - Optional **`LivoMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, amount`) per successful direct forward.
5. Optional **`LivoSwapHook.CreatorTaxesAccrued`** (`token, taxAmount`) if sell tax is active and non-zero, then the
   tax is routed through `LivoToken.accrueFees()` (a second **`CreatorFeesDeposited`** / optional `CreatorClaimed`).
6. **`LivoSwapHook.LivoSwapSell`** (`token, txOrigin, tokensIn, ethOut, ethFees`).

Router-failure fallback: same as §6.1 — `LpFeesRouted` + step 4 absent, full LP fee pushed to treasury.

### 6.3 V2 post-graduation swaps on tax variants

Tax tokens deployed on V2 (`LivoTaxableTokenUniV2`, `LivoTaxableTokenUniV2SniperProtected`) take taxes intrinsically inside `_update`. There is no V2 hook; the token contract diverts a portion of every pair-touching transfer into its own balance, then auto-swaps the accumulated tokens to ETH on a sell once the contract balance crosses `SWAP_THRESHOLD = TOTAL_SUPPLY / 2000` (= 500_000e18).

Indexer-relevant points:

- **Buy (ETH → token)** within the tax window emits an extra `Transfer(pair, address(token), buyTaxAmount)` for the tax slice in addition to `Transfer(pair, buyer, netAmount)`. No Livo event is emitted at this point — the tax accrual is reported later, at swap-back time.
- **Sell (token → ETH)** within the tax window emits an extra `Transfer(seller, address(token), sellTaxAmount)` for the tax slice in addition to `Transfer(seller, pair, netAmount)`. The auto-swap-back, if triggered, fires *before* the tax slice transfers, while `inSwap` is true. No Livo event is emitted at this point either; the accrual is reported by `CreatorTaxSwapback` from the auto-swap-back below.
- **Auto- or manual-triggered swap-back** burns the burn-allocation share as tokens in-place first, sets the liquidity-allocation share aside as tokens (kept on the contract, tracked by `liquidityPendingTokens` — no event), then runs `IUniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens` on the remainder, then routes the ETH through the earnings-allocation split. Livo event order:
  1. Burn allocation only (`burnBps > 0`): ERC20 `Transfer(address(token), address(0), burnAmount)` then **`LivoTaxableToken.CreatorTaxBurn`** (`ethSpent = 0, tokensBurned = burnAmount`) — the burn share removed from total supply *before* the swap. The shared two-field signature; `ethSpent` is 0 here because V2 burns in token-space with no ETH→token round trip.
  2. ERC20 transfer from `address(token)` to `pair` for the swap input (the remainder after the burn and liquidity shares).
  3. External Uniswap V2 `Sync` / `Swap` events on the pair, plus `Withdrawal` on WETH.
  4. **`LivoTaxableTokenUniV2.CreatorTaxSwapback`** (`tokenAmountIn, ethAmount, ethToFund`) — `tokenAmountIn` is the amount actually swapped (net of the burn and liquidity shares); `ethAmount` is this swap's ETH proceeds (a balance delta, matching the pair's `Swap`); `ethToFund` is the slice of THAT ETH which reaches the fee handler as creator fees. The swap-back routes its own proceeds and nothing else — stray or refunded ETH sitting in the same balance is left for `sweepStrayEth()`, which splits it with the burn/liquidity shares it is owed rather than renormalizing it into the dividend pot — so `ethToFund <= ethAmount` always, and the two are equal for a token with no earnings allocation.
  5. Fund deposit of `ethToFund`: **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount = ethToFund`), plus optional **`CreatorClaimed`** per direct forward — always AFTER `CreatorTaxSwapback` (historical order preserved). The dividends bucket is accrue-only and emits nothing on this path — its slice is buffered as native (or, for a V2 self-token payout, set aside as TOKENS alongside the liquidity buffer) and converted out-of-band by `processDividends`. So a token still emits exactly one `CreatorFeesDeposited` (the liquidity slice, and any self-token dividend slice, were already set aside as tokens above, not carved from this ETH).
- The token's `swapBack(uint256 swapAmount, uint256 amountOutMinWei)` external function is owner/launchpad-owner gated and reverts `NotGraduated` before graduation; it produces the same event sequence as the auto-trigger. Factory-deployed V2 tokens are ownerless, so the launchpad owner is the only reachable manual caller.
- The token's **`processLiquidity(uint256 amountOutMinWei)`** external function (permissionless; reverts `NotGraduated` / `NothingToAdd` / `ProcessCooldown` when already run this block; processes at most `2 * SWAP_THRESHOLD` tokens per call, remainder stays buffered) turns the set-aside liquidity tokens into a locked LP position: under `inSwap` it sells half through `UniswapV2Venue.swapTaxToNative()`, then adds the retained half plus the proceeds through `UniswapV2Venue.supplyLiquidity()` and sends the LP to `0xdEaD`. The venue lib is import-swapped per chain, so ETH-family builds take the WETH `swapExactTokensForETHSupportingFeeOnTransferTokens` / `addLiquidityETH` path while ARC builds pair `<token, USDC-ERC20>` via `swapExactTokensForTokensSupportingFeeOnTransferTokens` / two-ERC20 `addLiquidity` — the emitted event sequence is the same either way. Emits the external V2 `Sync` / `Swap` / pair `Mint` / `Transfer` events, then **`LivoTaxableToken.LiquidityAdded`** (`ethIn, tokensAdded, liquidity`) — the shared event; here `liquidity` is the V2 LP tokens minted, and `ethIn` / `tokensAdded` are the router's ACTUAL deposited amounts (they match the pair's `Mint`), not the requested ones: V2 adds at whatever ratio the pool is at and the router refunds the excess side back to the token.
- Past the tax window (`block.timestamp > graduationTimestamp + taxDurationSeconds`), no tax transfer is taken and the swap-back path is not entered.

### 6.4 V4 earnings-allocation burn and liquidity buckets and their entry points

For a V4 token with a burn or liquidity allocation, the swap-time `CreatorTaxesAccrued` → `token.accrueFees` splits the tax on the ETH side: the burn slice is buffered in `burnPendingEth` and the liquidity slice in `liquidityPendingEth` (no event beyond the fund-wallet `CreatorFeesDeposited`), the rest routes to the fund wallets. Permissionless entry points then process each buffer:

- **`processBurn(uint256 minTokensOut)`** — buys back tokens with `burnPendingEth` via the universal router and burns them. Emits, in order: **`LivoTaxableTokenUniV4.BuyBackInitiated`** (`ethIn`) — a precursor marker emitted BEFORE the swap so indexers can classify the following hook `LivoSwapBuy` (which carries the keeper's `tx.origin`) as a protocol buy-back rather than a trade — then the external V4 buy-back swap events (`Swap`, plus the hook's own LP-fee/tax events since the buy-back is an ordinary swap), an ERC20 `Transfer(address(token), address(0), tokensBought)`, then **`LivoTaxableToken.CreatorTaxBurn`** (`ethSpent, tokensBurned`) — the same shared event V2 emits, with a non-zero `ethSpent` here since V4 does buy the tokens back before burning. Reverts `NotAKeeper` unless `msg.sender` is on the `LivoKeepersRegistry` allowlist, `NothingToBurn` when the buffer is empty and `ProcessCooldown` when already run this block; spends at most `MAX_EARNINGS_PER_PROCESS` per call (remainder stays buffered).
- **`processLiquidity()`** — deposits `liquidityPendingEth` as a single-sided ETH position just below the current price (a bid wall). Takes one of TWO paths, which differ only in their EXTERNAL events; the token's own event is identical either way. Both run through the shared `LivoUniV4LiquidityAdder.addOrTopUpSingleSidedEth`, which is also handed an ERC721 `ApprovalForAll(token, adder, true)` from the token on every call (a no-op after the first). (a) TOP-UP — the token remembers the two walls it most recently used (`getLiquidityWalls()` exposes their NFT ids and lower ticks), and when one of them still sits entirely below the current price and within ~2000 ticks of it, the adder thickens that position: emits `ModifyLiquidity` and settlement `Transfer`s, but NO ERC721 `Transfer` — no new NFT exists. (b) MINT — otherwise a fresh position is minted at the live tick, emitting the external V4 position-mint events (`ModifyLiquidity`, an ERC721 `Transfer(0x0, token, tokenId)`, settlement `Transfer`s). Either path then emits **`LivoTaxableToken.LiquidityAdded`** (`ethIn, tokensAdded, liquidity`) — the shared event; `tokensAdded` is always 0 (ETH-only wall) and `liquidity` is the V4 liquidity units the position GAINED on this call. Indexers that counted one new position per `LiquidityAdded` must key off the ERC721 `Transfer` instead. Reverts `NotAKeeper` unless `msg.sender` is on the `LivoKeepersRegistry` allowlist, `NothingToAdd` when the buffer is empty and `ProcessCooldown` when already run this block; spends at most `MAX_EARNINGS_PER_PROCESS` per call (remainder stays buffered). Every position the token mints is held by it forever (permanent depth), whether or not it is still one of the two remembered.
- **`sweepStrayEth()`** — routes the token's native balance beyond everything it owes (`burnPendingEth`, `liquidityPendingEth`, the dividend buffers and undelivered pots) back through the earnings-allocation split (same events as an `accrueFees` split), so stray native becomes token earnings instead of being stuck. Permissionless. Present on BOTH venues — it lives on `LivoTaxableToken` — and it is the only exit for stray native on V2, where `rescueTokens` no longer accepts `address(0)` and the swap-back only routes its own swap proceeds. Pre-graduation it deposits the whole balance to the fund wallets, which is what `rescueTokens(address(0))` used to do.

---

## 7. `LivoMasterFeeHandler.claim(address[] tokens)`

Entry point for claimable fee recipients to withdraw accumulated ETH across any registered tokens.

For each token in `tokens` where `msg.sender` has a non-zero claimable balance:

1. **`LivoMasterFeeHandler.CreatorClaimed`** (`token, account=msg.sender, amount`).

After iterating all tokens, a single native ETH transfer pays the sum to `msg.sender`. If the sum is zero, no events are emitted and no ETH transfer is attempted.

Duplicate token entries do not double-pay because the first matching entry clears the caller's claimable balance for that token.

---

## 8. `LivoMasterFeeHandler.setShares(address token, FeeShare[] feeShares)`

Callable only by the master handler owner or the token's current non-zero owner. The token must already be registered.

Event order on a successful update:

1. Zero or more **`LivoMasterFeeHandler.DirectReceiverRemoved`** (`token, receiver`) — for addresses that were direct before the update and are no longer direct after it.
2. Zero or more **`LivoMasterFeeHandler.DirectReceiverRegistered`** (`token, receiver`) — for addresses that were not direct before the update and are direct after it.
3. **`LivoMasterFeeHandler.SharesUpdated`** (`token, recipients, sharesBps`).

A BPS-only rebalance with an unchanged direct set emits only `SharesUpdated`.

---

## 9. Direct-fee behavior

Direct fees are configured per token through `FeeShare.directFeesEnabled` at token creation or through `LivoMasterFeeHandler.setShares`.

For every successful non-zero `depositFees(token)` against a registered config:

1. **`LivoMasterFeeHandler.CreatorFeesDeposited`** (`token, amount`).
2. For each direct receiver with a non-zero slice:
   - If the ETH forward succeeds, **`LivoMasterFeeHandler.CreatorClaimed`** (`token, directReceiver, sliceAmount`) is emitted immediately.
   - If the ETH forward fails, no `CreatorClaimed` event is emitted for that slice; the slice is stored as pending and can later be recovered through `claim()`.
3. Claimable recipients do not emit per-deposit claim events; they accrue through the master handler accumulator and emit `CreatorClaimed` only when they call `claim()`.

Zero-value `depositFees(token)` calls are no-ops and emit no fee events, including for unregistered tokens.

---

## 10. `LivoTaxableToken.setTaxBps(uint16 newBuyTaxBps, uint16 newSellTaxBps)`

Owner-only entry point on both `LivoTaxableTokenUniV2` (and its sniper-protected variant) and `LivoTaxableTokenUniV4` (and its sniper-protected variant). Callable by the token owner OR `launchpad.owner()` — on factory-deployed tokens (`owner == address(0)`) only the launchpad-owner branch is reachable.

The function is decrease-only: `newBuyTaxBps` and `newSellTaxBps` must both be `<= ` their current values, otherwise the call reverts with `TaxBpsCanOnlyDecrease`. Equal values are accepted (no-op for that side). `taxDurationSeconds` and `graduationTimestamp` are untouched.

On success:

1. **`LivoTaxableToken.TaxBpsUpdated`** (`newBuyTaxBps, newSellTaxBps`) — emitted before the storage write. Old values can be reconstructed from the preceding `LivoTaxableTokenInitialized` event at creation time and the chain of any prior `TaxBpsUpdated` events.

---

## Holder dividends (out-of-band)

None of these fire on a trade. The dividend module accrues on the earnings path and does everything
else in separate, permissionless transactions, so an indexer sees them on their own.

`processDividends` and `claimDividends` are `delegatecall` stubs on the token into a per-venue
extension (`LivoDividendLogicUniV2` / `LivoDividendLogicUniV4`), because their bodies do not fit in the
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
buffer, its own `DIVIDEND_THRESHOLD` to cross, its own conversion, its own stream and slope, its own
accumulator, its own per-block funding cooldown and its own staleness clock. So the events below
interleave freely ACROSS assets, and nothing may be inferred about asset `j` from an event carrying
asset `i` — a 20/80 split converts the 20% leg roughly four times less often, and one leg can go stale
and be swept while the other is streaming normally.

Dividends are STREAMED, not dropped. Each distribution funds a linear stream over
`DIVIDEND_DRIP_DURATION` (15 minutes) and every holder accrues against a `balance x time` accumulator.
There are no rounds, no phases and no snapshots, so there is no round id on any event and nothing for
an indexer to reconstruct a denominator from: a holder's entitlement is `previewDividend(holder)`, read
from the chain.

**At graduation**, immediately after `Graduated` and from `markGraduated()` itself:
**`DividendsActivated`** (no args) — the accumulator starts here rather than at creation, so a holder
earns from the moment the token is live. It is also the anchor for `STALE_DIVIDEND_WINDOW`. There is
ONE exception to the timing: a deploy buy large enough to graduate the token inside `createToken` runs
`markGraduated()` before the allocation is configured, so that token emits `DividendsActivated` on its
first earnings instead.

**`processDividends(uint8 assetIndex, uint256 minOut, address[] holders)`** — KEEPER-GATED, and the ONLY
keeper entry point. It services ONE payout asset per call: each asset crosses its threshold on its own
schedule, prices its floor against its own pool and holds its own cooldown, so a keeper calls it once
per asset and the assets never contend. `assetIndex` past `dividendAssetCount()` reverts
`DividendAssetOutOfRange`. The pre-existing two-argument form
**`processDividends(uint256 minOut, address[] holders)`** is still there and services asset 0, so a
keeper written for a single-asset token needs no change. Reverts `NotAKeeper` unless `msg.sender` is on
the `LivoKeepersRegistry` allowlist, with one exception: once THAT ASSET is stale
(`dividendsStale(assetIndex)`, i.e. `STALE_DIVIDEND_WINDOW` with no distribution of it) anyone may call
it for that asset, so a keeper set that goes away cannot strand holders' money. For an asset whose
funding SWAPS (any third ERC20, and the V4 self-token buy-back) staleness alone is NOT enough — its
buffer must ALSO hold at least `DIVIDEND_THRESHOLD`. A quiet token reaches a month without a
distribution in its ordinary steady state, simply by never buffering enough to be worth converting, and
opening a caller-supplied-floor swap there every month is a sandwich, not a rescue; a buffer that HAS
been convertible all along and still was not converted is the reading that actually evidences an absent
keeper. Assets whose funding does not swap (native, and the Uniswap-V2 self-token leg) keep the wide
bypass — there is nothing there for a caller to extract, so stranding is their only failure mode. A
sub-threshold residual on a swapping asset stays keeper-only. Holders
are never gated — `claimDividends()` stays open to everyone. Nothing about the gate changes the EVENT
sequence; it only adds a revert path. It converts the buffer, folds the proceeds into the running stream, and pushes payouts, doing
whichever of the three there is anything to do. A keeper whose holder list does not fit in one block
just calls it again; there is no phase to sequence and no state that a second call could disturb.

The FUNDING leg — steps 1 and 1b — runs at most once per block PER ASSET; servicing all three assets in
one block is normal and expected. A second call in the same block that
actually moved the buffer skips straight to the payouts, and reverts `DividendProcessCooldown` if it
was given no holders either. Pushing payouts is never rate-limited, so splitting a large holder set
across several transactions in one block works exactly as before.

1. Only if the buffer cleared `DIVIDEND_THRESHOLD`: **`DividendsFunded`**
   (`asset, nativeIn, assetOut, rate, periodFinish`). `rate` and `periodFinish` describe the stream
   AFTER the fold-in — a distribution landing mid-stream adds the undelivered remainder to the new
   money and re-spreads the sum over a fresh full window, so the SLOPE changes and `periodFinish`
   always moves to `block.timestamp + DIVIDEND_DRIP_DURATION`. The threshold stops applying in exactly
   one case, so a residual that can no longer grow is never stranded: the token has gone
   `STALE_DIVIDEND_WINDOW` (30 days) without a distribution.
1b. Instead of `DividendsFunded`, when a zero-floor conversion came back empty AND the token has gone
   `STALE_DIVIDEND_WINDOW` without a distribution: **`DividendBufferSweptToTreasury`**
   (`asset, nativeAmount`). The pool cannot produce a single wei at any price and has been unable to for
   a month — staleness is what makes that a persistent reading rather than a snapshot anyone could
   manufacture inside one transaction, since every successful distribution pushes the staleness anchor
   forward. That slice of the native buffer went to `DIVIDEND_TREASURY` rather than sitting owed to
   holders forever, and the call returned successfully instead of reverting. It is bounded by
   `MAX_DIVIDEND_PER_CONVERSION` per call, so a dead pool's whole buffer takes several calls to clear.
   Nothing else changes: the payout asset, the stream, the accumulator and every unclaimed accrual are
   untouched, so an indexer needs only to stop expecting that native to become a distribution. A caller
   whose own `minOut` was simply unreachable gets `DividendConversionFailed` and no sweep.
2. V4 self-token only, immediately BEFORE its buy-back swap: **`DividendBuyBackInitiated`**
   (`ethIn`), followed by the pool's own `LivoSwapHook.LivoSwapBuy`. Same contract as
   `BuyBackInitiated`: the precursor must be classified as it arrives, so the keeper's PnL is not
   credited with a bag it never bought.
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
both shapes, so a holder skipped by a batch can always be paid by claiming. It never funds a stream.


### `LivoCreatorVault` (one clone per creator vault)

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

### `LivoKeepersRegistry` (one per chain)

The allowlist of addresses permitted to call `processDividends`, `processBurn` and `processLiquidity`.
It emits nothing inside a token's transaction — it is only ever read — so these events appear on their
own, rarely, and are not attributable to any token.

- **`AdminSet`** (`account`, `allowed`) — owner-only; manages who may emit the one below.
- **`KeeperSet`** (`account`, `allowed`) — admin-level; a keeper key being rotated in or out. Revocation
  takes effect in the next transaction.

### `LivoDividendSwapRegistry` (one per chain)

The eligibility gate and swap venue behind every third-asset dividend. It is a SHARED contract, so its
events are not attributable to a token by their emitter — index them on their own and join on `asset`.

**Per conversion**, inside the funding leg of `processDividends` (step 1 above), immediately before the
token's own `DividendsFunded`:

- **`DividendAssetPurchased`** (`asset`, `recipient`, `nativeIn`, `assetOut`) — `recipient` IS the token
  whose stream is being funded, which is the only link back to it. Absent when the payout asset is native or
  the token itself (no conversion happens), and absent when the conversion failed (the whole call
  reverted and the token reports `DividendConversionFailed`).
- **`KeeperFunded`** (`keeper`, `amount`) — immediately after the one above, when a keeper wallet is
  configured: the slice of the conversion's native paid to it as gas money instead of being swapped.
  `amount` is the flat per-chain `KEEPER_FEE`, except on a conversion small enough for the
  `MAX_KEEPER_CUT_BPS` clip to bite, so read it rather than deriving it. Note
  `DividendAssetPurchased.nativeIn` is the FULL amount the token sent, this included, so the amount
  actually converted is `nativeIn - amount`.

**Per token creation**, one per non-native, non-self payout asset, inside the creation transaction:

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
  their next conversion on. Livo does not review payout assets and has no whitelist, so this is what
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
