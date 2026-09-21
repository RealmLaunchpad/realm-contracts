// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// @notice Initialization-time tax configuration for taxable tokens: the static tax plus the optional
///         linearly-decaying launch tax. Consumed by the whole internal token-init pipeline; each
///         factory's `createToken` lifts it out of its tax-and-allocation struct.
/// @dev Separate from `IRealmToken.TaxConfig` (which adds the post-init `graduationTimestamp`).
/// @dev The three `*Decay*` fields configure the optional linearly-decaying launch tax. It runs from
///      the SAME anchor `startTaxFromLaunch` selects, decaying each direction linearly from its start
///      rate to 0 over `taxDecayDuration`. The effective rate a trade pays is `max(decay, static)` per
///      direction, so a token may set ONLY the decay fields (static bps + duration all zero) to get a
///      pure decaying launch tax with no long-term tax — a "non-taxable token with tax decay". Such a
///      token is still deployed as a taxable-impl clone (the post-graduation collection machinery lives
///      there); its dispatch is triggered by `taxDecayDuration != 0` alone.
struct TaxConfigs {
    uint16 buyTaxBps;
    uint16 sellTaxBps;
    uint32 taxDurationSeconds;
    /// @dev Anchor for BOTH the static and decay windows. `true`: windows run from `launchTimestamp`
    ///      (start at token creation, span graduation). `false`: windows run from `graduationTimestamp`
    ///      (no tax before graduation).
    bool startTaxFromLaunch;
    uint16 buyTaxDecayStartBps; // buy decay rate at the anchor (decays to 0 over taxDecayDuration); 0 = no buy decay
    uint16 sellTaxDecayStartBps; // sell decay rate at the anchor (decays to 0 over taxDecayDuration); 0 = no sell decay
    uint32 taxDecayDuration; // seconds over which the decay rate falls from its start to 0; 0 = no decay
}

/// @notice The earnings-allocation split: the bps of post-graduation earnings (swap tax + LP-fee
///         creator share) routed to buy-back-and-burn, holder dividends, and liquidity additions, and the
///         UP TO THREE assets (`DividendDistribution.MAX_DIVIDEND_ASSETS`) holders are paid in. The fund
///         wallets take the remainder. All-zero bps = no allocation (100% to the fund wallets).
/// @dev `dividendTokens` is the payout set and `dividendWeightsBps` how the dividends slice is divided
///      between its members, index for index. Rules, all enforced at creation and all permanent:
///      - 1..3 entries, the two arrays the same length;
///      - every weight non-zero, and the weights summing to exactly 10,000;
///      - the assets DISTINCT (a repeat would make the token under-report what it owes holders);
///      - `DividendDistribution.DIVIDEND_SELF_TOKEN` only as the sole entry;
///      - every non-native, non-self entry reachable by `RealmDividendSwapRegistry` right now.
/// @dev Each asset is independent from there on: its own native buffer, its own conversion, its own
///      accumulator. A 20/80 split fills the 20% asset roughly four times more slowly.
struct EarningsAllocationMultiConfig {
    uint16 burnBps;
    uint16 dividendsBps;
    uint16 liquidityBps;
    address[] dividendTokens;
    uint16[] dividendWeightsBps;
    /// @dev One route per asset, positionally, in the `DividendRouteLib` wire format: the pools this
    ///      token converts that asset through, chosen by the creator and fixed for the token's life.
    ///      An entry may be empty — that is the explicit choice of the asset's permissionless Uniswap V2
    ///      pair — and the array may be SHORTER than `dividendTokens`, which means empty for the rest.
    ///      Realm does not review these: the registry checks the pools are real and holds liquidity, and
    ///      nothing on-chain can check the price they name is the asset's real one.
    bytes[] dividendRoutes;
}

/// @notice The full `TaxConfigs` fields (flattened) plus a nested `earningsAllocation` split, as the
///         curve factories' `createToken` takes it: the tax fields are lifted back into a `TaxConfigs`
///         for the shared creation pipeline and the allocation is forwarded to
///         `initializeEarningsAllocation` at creation.
/// @dev On the Uniswap-V2 factory a non-zero allocation requires a long-term static tax
///      (`taxDurationSeconds != 0`, else `EarningsAllocationRequiresTax`): V2 LP fees never reach the
///      token, so a tax is its only earnings stream. The V4 factories accept any tax config, zero
///      included — the creator's LP-fee share is a permanent stream there — and clone the taxable
///      implementation whenever an allocation is set.
struct TaxConfigsWithMultiAllocation {
    uint16 buyTaxBps;
    uint16 sellTaxBps;
    uint32 taxDurationSeconds;
    bool startTaxFromLaunch;
    uint16 buyTaxDecayStartBps;
    uint16 sellTaxDecayStartBps;
    uint32 taxDecayDuration;
    EarningsAllocationMultiConfig earningsAllocation;
}

/// @notice `TaxConfigsWithMultiAllocation` for the DIRECT venue, where a token's earnings can arrive in
///         an ERC20 quote as well as in native. Same leading fields, same allocation rules, plus the
///         swap routes the token's ERC20 quotes are converted THROUGH when a dividends leg has to move
///         out of one of them.
/// @dev `quoteRoutes` is positional to the factory's `pairs[]`: one `DividendRouteLib` route per pair,
///      from native to that pair's quote, empty for a native pair. It may be shorter than `pairs`,
///      which means empty for the rest. A route is only REQUIRED for an ERC20 quote that some payout
///      asset has to be bought out of — i.e. one that is neither that quote itself nor the token —
///      and only when the quote is not already a payout asset, whose route `dividendRoutes` carries.
///      The registry walks it BACKWARDS (quote -> native) and then forward along the payout asset's own
///      route, so every conversion pivots through native and there is nothing else to configure.
struct TaxConfigsWithDirectAllocation {
    uint16 buyTaxBps;
    uint16 sellTaxBps;
    uint32 taxDurationSeconds;
    bool startTaxFromLaunch;
    uint16 buyTaxDecayStartBps;
    uint16 sellTaxDecayStartBps;
    uint32 taxDecayDuration;
    EarningsAllocationMultiConfig earningsAllocation;
    bytes[] quoteRoutes;
}

/// @title IRealmTaxableToken
/// @notice Unified interface for Realm taxable tokens, regardless of the underlying graduation
///         venue (Uniswap V2 with intrinsic taxation, Uniswap V4 with hook-driven taxation).
/// @dev Extends `IRealmToken`. Variant-specific entry points (e.g. V2's owner-only `swapBack`)
///      and variant-specific events (e.g. V2's `CreatorTaxSwapback`) are not surfaced here —
///      callers that need them should cast to the concrete contract. On the V4 variant the
///      equivalent accrual is emitted by `RealmSwapHook` as `CreatorTaxesAccrued(token, amount)`.
interface IRealmTaxableToken is IRealmToken {
    /// @notice Returns the graduation timestamp for this token (0 before graduation).
    function graduationTimestamp() external view returns (uint40);

    /// @notice Tax-window anchor for this token: `true` if the window starts at token creation
    ///         (`launchTimestamp`), `false` if it starts at graduation (`graduationTimestamp`).
    function startTaxFromLaunch() external view returns (bool);

    /// @notice Initializes a taxable-token clone. Used by the factory to dispatch into either V2 or V4
    ///         concrete tax-token implementations through a single shared type. Takes the full
    ///         `TaxConfigs` plus the `AntiSniperConfigs`; anti-sniper protection is
    ///         enabled iff that config opts in (`protectionWindowSeconds != 0`), gated inside the token.
    function initialize(
        IRealmToken.InitializeParams memory params,
        TaxConfigs memory taxCfg,
        AntiSniperConfigs memory antiSniperCfg
    ) external;

    /// @notice Owner-only setter for `buyTaxBps` / `sellTaxBps`. Currently enforces decrease-only —
    ///         attempts to raise either rate revert.
    function setTaxBps(uint16 newBuyTaxBps, uint16 newSellTaxBps) external;

    /// @notice Factory-only, creation-time setter for the earnings-allocation split (burn / dividends /
    ///         liquidity bps; the fund wallets take the remainder). Guarded by the transient factory,
    ///         so it is only callable during the deploy tx.
    function initializeEarningsAllocation(uint16 burnBps, uint16 dividendsBps, uint16 liquidityBps) external;

    /// @notice Same again for a multi-asset payout: the set of assets, the bps split of the dividends
    ///         slice between them, and the swap route each one is bought through. See
    ///         `EarningsAllocationMultiConfig` for the rules.
    function initializeEarningsAllocation(
        uint16 burnBps,
        uint16 dividendsBps,
        uint16 liquidityBps,
        address[] calldata dividendTokens,
        uint16[] calldata dividendWeightsBps,
        bytes[] calldata dividendRoutes
    ) external;

    /// @notice The multi-asset overload plus the routes of this token's ERC20 QUOTES, for a token whose
    ///         earnings can arrive in a currency other than native. `quoteRoutes` is positional to the
    ///         token's `quotes` from index 1 (index 0 is native and needs no route). See
    ///         `TaxConfigsWithDirectAllocation` for when an entry is required.
    function initializeEarningsAllocation(
        uint16 burnBps,
        uint16 dividendsBps,
        uint16 liquidityBps,
        address[] calldata dividendTokens,
        uint16[] calldata dividendWeightsBps,
        bytes[] calldata dividendRoutes,
        bytes[] calldata quoteRoutes
    ) external;
}
