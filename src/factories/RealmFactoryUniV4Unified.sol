// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {
    TaxConfigInit,
    TaxConfigs,
    TaxConfigsWithAllocation,
    TaxConfigsWithMultiAllocation,
    EarningsAllocationConfig,
    EarningsAllocationMultiConfig,
    IRealmTaxableToken
} from "src/interfaces/IRealmTaxableToken.sol";
import {RealmFactoryAbstract} from "src/factories/RealmFactoryAbstract.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";

/// @notice Unified factory for the Uniswap V4 token family. Dispatches between two token
///         implementations (`base`, `tax`) based on whether tax is configured; anti-sniper
///         protection is a gated feature of both, not a separate impl.
///
///         Replaces `RealmFactoryUniV4`, `RealmFactoryTaxToken`, `RealmFactoryUniV4SniperProtected`,
///         and `RealmFactoryTaxTokenSniperProtected`.
contract RealmFactoryUniV4Unified is RealmFactoryAbstract {
    /// @notice V4-specific config bundle for the struct-based `createToken` overload.
    /// @dev `lpFeeBps` is the per-swap LP fee `LivoSwapHook` charges post-graduation. It is stored on
    ///      the token (via `InitializeParams.swapLpFeeBps`) and read back by the hook through
    ///      `getSwapFees`. Only `100` (1%) and `50` (0.5%) are accepted; `_validateUniv4Configs`
    ///      enforces the allowlist so misconfiguration is loud. A single graduator/hook pair serves both
    ///      fees — the hook reads the rate from the token instead of hardcoding it per variant, so the
    ///      graduator is selected by liquidity tier alone (`_resolveGraduator(tier)`), not by fee.
    struct UniV4Configs {
        bool renounceOwnership;
        uint16 lpFeeBps;
    }

    /// @notice Constructor-only bundle of the THIN/THICK tier V4 graduators. One graduator per tier: the
    ///         hook is fee-agnostic (reads the rate from the token), so a tier needs a single graduator
    ///         regardless of `lpFeeBps`. The DEFAULT-tier graduator is `GRADUATOR` in the abstract base.
    struct TierGraduators {
        address thin;
        address thick;
    }

    /// @notice Constructor-only bundle of all the V4 tier additions (curves + graduators), grouped into
    ///         one struct to keep the constructor's parameter count within the ABI-decode stack limit.
    struct V4TierConfig {
        LiquidityTierConfig curves;
        TierGraduators graduators;
    }

    /// @notice THIN/THICK tier graduators, one per tier. Each initializes its pool at the tier-specific
    ///         graduation price and pairs with the single fee-agnostic `LivoSwapHook`. Selected by
    ///         `_resolveGraduator(tier)`.
    address public immutable GRADUATOR_THIN;
    address public immutable GRADUATOR_THICK;

    /// @notice Pre-graduation launchpad LP fee for V4 tokens (bps), charged on every bonding-curve trade
    ///         and split treasury/creator by `V4_LAUNCHPAD_TREASURY_SHARE_BPS`. Fixed at 1% for every V4
    ///         token regardless of the post-graduation hook fee it selects (`UniV4Configs.lpFeeBps`, 50 or
    ///         100): the pre-graduation rate is a constant launchpad policy, decoupled from the LP fee the
    ///         hook charges after graduation.
    uint16 internal constant V4_LAUNCHPAD_LP_FEE_BPS = 100;

    /// @notice Treasury share of the V4 pre-graduation LP fee (bps): 60 treasury / 40 creator.
    uint16 internal constant V4_LAUNCHPAD_TREASURY_SHARE_BPS = 6_000;

    error InvalidLpFeeBps();

    constructor(
        address launchpad,
        TokenImpls memory impls,
        address bondingCurve,
        address graduator,
        address masterFeeHandler,
        address creatorVaultFactory,
        address[6] memory vaultBondingCurves,
        V4TierConfig memory v4Tier
    )
        RealmFactoryAbstract(
            launchpad,
            impls,
            bondingCurve,
            graduator,
            masterFeeHandler,
            creatorVaultFactory,
            vaultBondingCurves,
            v4Tier.curves
        )
    {
        GRADUATOR_THIN = v4Tier.graduators.thin;
        GRADUATOR_THICK = v4Tier.graduators.thick;
    }

    /////////////////////// EXTERNAL FUNCTIONS /////////////////////////

    // V4-only event-emission rule: any event whose presence is meant to signal "this is a V4 token"
    // (today: `LpFeeBpsSet`) MUST be emitted here in the V4 factory overloads, never inside the
    // shared `_createToken` umbrella in `RealmFactoryAbstract`. The umbrella runs for V2 deploys
    // too, so emitting V4-only events from there would leak them onto V2 tokens and break indexers
    // that use the event as a V4 marker. When adding a new V4-only event, follow this same pattern
    // (emit after `_createToken(...)` returns, in both overloads below).

    /// @notice Deploys a V4-family Realm token and registers it in the launchpad.
    ///         Dispatches between four implementations based on `taxCfg` and `antiSniperCfg`.
    ///         The per-token fee config is registered with the master fee handler at deploy time.
    ///         If `msg.value > 0`, buys supply and distributes it across `supplyShares`.
    /// @dev DEPRECATED: legacy positional overload, kept for backwards compatibility (unchanged
    ///      signature). New integrations should use the struct-based overload that takes `creatorVaults`
    ///      and the full `TaxConfigs`. Always deploys with the DEFAULT-tier graduator and a 100-bps swap
    ///      fee, no creator vaults and no launch-tax decay — the `TaxConfigInit` is lifted into a
    ///      `TaxConfigs` with the decay fields zeroed.
    function createToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        FeeShare[] calldata feeReceivers,
        SupplyShare[] calldata supplyShares,
        bool renounceOwnership_,
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) external payable returns (address token) {
        // Positional overload always uses the 100-bps swap fee — only the struct-based overloads below
        // expose the 50-bps variant. See the "V4-only event-emission rule" comment above for why the
        // emit lives here.
        // Build `tokenSetup` first (consuming the deep `name`/`symbol`/`salt`/`feeReceivers` calldata
        // params) before introducing the `taxConfigs` memory local, to keep the stack shallow enough
        // to compile without `via_ir`.
        // Legacy overload always uses the DEFAULT liquidity tier + the 100-bps swap fee.
        TokenSetupTiered memory tokenSetup = TokenSetupTiered({
            name: name, symbol: symbol, salt: salt, feeShares: feeReceivers, liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigs memory taxConfigs = _toTaxConfigs(taxCfg);
        _validateTotalFee(100, taxConfigs);
        token = _createToken(
            tokenSetup,
            renounceOwnership_ ? address(0) : msg.sender,
            address(GRADUATOR),
            100, // default swap fee for the legacy overload
            supplyShares,
            taxConfigs,
            antiSniperCfg,
            new CreatorVault[](0)
        );
        emit LpFeeBpsSet(token, 100);
    }

    /// @notice Struct-based overload taking the full `TaxConfigs` (static tax + optional linear launch-tax
    ///         decay), a `creatorVaults` array (pass empty for none) and a `TokenSetupTiered` selecting the
    ///         liquidity tier. `univ4Configs.lpFeeBps` is the post-graduation swap fee stored on the token
    ///         (100 or 50). Kept for backwards compatibility; new integrations should use the `referral`
    ///         overload below (the current recommended overload).
    function createToken(
        TokenSetupTiered calldata tokenSetup,
        TaxConfigs calldata taxConfigs,
        UniV4Configs calldata univ4Configs,
        SupplyShare[] calldata buyOnDeployShares,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults
    ) external payable returns (address token) {
        token = _createV4(tokenSetup, univ4Configs, buyOnDeployShares, taxConfigs, antiSniperConfigs, creatorVaults);
    }

    /// @notice Recommended overload: same as the `TokenSetupTiered` overload plus a `referral` address for
    ///         relayers that forward the creation and are entitled to a cut of the fees. When `referral` is
    ///         non-zero a `TokenReferral(token, referral)` event is emitted; no token storage or on-chain
    ///         payout is wired to it yet — it is purely an off-chain signal for now.
    function createToken(
        TokenSetupTiered calldata tokenSetup,
        TaxConfigs calldata taxConfigs,
        UniV4Configs calldata univ4Configs,
        SupplyShare[] calldata buyOnDeployShares,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults,
        address referral
    ) external payable returns (address token) {
        token = _createV4(tokenSetup, univ4Configs, buyOnDeployShares, taxConfigs, antiSniperConfigs, creatorVaults);
        if (referral != address(0)) emit TokenReferral(token, referral);
    }

    /// @notice Allocation-aware overload: the recommended `referral` overload plus a
    ///         `TaxConfigsWithAllocation` that also carries the earnings-allocation split (burn /
    ///         dividends / liquidity bps; the fund wallets take the remainder). The split is stored on
    ///         the token at creation via `initializeEarningsAllocation`. A non-zero split requires a
    ///         token with a LONG-TERM static tax (`taxDurationSeconds != 0`); a decay-only token is
    ///         rejected — its tax window lasts minutes, so there is no earnings stream worth splitting.
    ///         A non-zero `dividendsBps` must name a payout asset in `dividendToken`; the token asks
    ///         `RealmDividendSwapRegistry` whether it can be bought and reverts at creation otherwise. The
    ///         registry answers yes either because the asset has a Uniswap V2 pair that is deep enough
    ///         right now — the permissionless rule, no whitelist and no per-asset approval — or because
    ///         an admin has given it a curated Uniswap V4 route, which is how V4-only assets qualify.
    function createToken(
        TokenSetupTiered calldata tokenSetup,
        TaxConfigsWithAllocation calldata taxAllocationConfigs,
        UniV4Configs calldata univ4Configs,
        SupplyShare[] calldata buyOnDeployShares,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults,
        address referral
    ) external payable returns (address token) {
        EarningsAllocationConfig calldata alloc = taxAllocationConfigs.earningsAllocation;
        bool hasAllocation = alloc.burnBps != 0 || alloc.dividendsBps != 0 || alloc.liquidityBps != 0;
        // Naming a payout asset with a zero share would leave dividends silently OFF, forever: clones
        // are not upgradeable and `initializeEarningsAllocation` only ever runs here, at creation.
        require(alloc.dividendToken == address(0) || alloc.dividendsBps != 0, DividendAssetWithoutShare());

        TaxConfigs memory taxConfigs = _toTaxConfigs(taxAllocationConfigs);
        if (hasAllocation) require(_hasStaticTax(taxConfigs), EarningsAllocationRequiresTax());

        token = _createV4(tokenSetup, univ4Configs, buyOnDeployShares, taxConfigs, antiSniperConfigs, creatorVaults);
        if (hasAllocation) {
            IRealmTaxableToken(payable(token))
                .initializeEarningsAllocation(
                    alloc.burnBps, alloc.dividendsBps, alloc.liquidityBps, alloc.dividendToken
                );
        }
        if (referral != address(0)) emit TokenReferral(token, referral);
    }

    /// @notice Multi-asset dividends overload: identical to the `TaxConfigsWithAllocation` one above,
    ///         except the dividends slice may name UP TO THREE payout assets and the bps split between
    ///         them. Every rule the single-asset path enforces still applies to each member of the set,
    ///         and a few more that only a set can break — distinct assets, non-zero weights summing to
    ///         10,000, and `DIVIDEND_SELF_TOKEN` only on its own. See `EarningsAllocationMultiConfig`.
    /// @dev A one-entry set weighted 10,000 is exactly the single-asset overload; the two produce
    ///      identical tokens, so there is nothing an integrator loses by moving to this one.
    function createToken(
        TokenSetupTiered calldata tokenSetup,
        TaxConfigsWithMultiAllocation calldata taxAllocationConfigs,
        UniV4Configs calldata univ4Configs,
        SupplyShare[] calldata buyOnDeployShares,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults,
        address referral
    ) external payable returns (address token) {
        EarningsAllocationMultiConfig calldata alloc = taxAllocationConfigs.earningsAllocation;
        bool hasAllocation = alloc.burnBps != 0 || alloc.dividendsBps != 0 || alloc.liquidityBps != 0;
        // Naming payout assets with a zero share would leave dividends silently OFF, forever: clones
        // are not upgradeable and `initializeEarningsAllocation` only ever runs here, at creation.
        require(alloc.dividendTokens.length == 0 || alloc.dividendsBps != 0, DividendAssetWithoutShare());

        TaxConfigs memory taxConfigs = _toTaxConfigs(taxAllocationConfigs);
        if (hasAllocation) require(_hasStaticTax(taxConfigs), EarningsAllocationRequiresTax());

        token = _createV4(tokenSetup, univ4Configs, buyOnDeployShares, taxConfigs, antiSniperConfigs, creatorVaults);
        if (hasAllocation) {
            IRealmTaxableToken(payable(token))
                .initializeEarningsAllocation(
                    alloc.burnBps,
                    alloc.dividendsBps,
                    alloc.liquidityBps,
                    alloc.dividendTokens,
                    alloc.dividendWeightsBps,
                    alloc.dividendRoutes
                );
        }
        if (referral != address(0)) emit TokenReferral(token, referral);
    }

    ///////////////////////// INTERNAL FUNCTIONS /////////////////////////

    /// @dev Shared tail of the two struct-based `createToken` overloads: validates the V4 config, resolves
    ///      the tier's graduator, deploys via the shared umbrella storing `univ4Configs.lpFeeBps` on the
    ///      token, and emits the V4-only `LpFeeBpsSet` marker. Factored out to keep each overload's stack
    ///      shallow enough to compile without `via_ir`. `tokenOwner`/`graduator` are inlined for the same
    ///      reason. Private to this V4 factory, so the "V4-only event-emission rule" above still holds —
    ///      the emit never runs for a V2 deploy.
    function _createV4(
        TokenSetupTiered calldata tokenSetup,
        UniV4Configs calldata univ4Configs,
        SupplyShare[] calldata buyOnDeployShares,
        TaxConfigs memory taxConfigs,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults
    ) private returns (address token) {
        _validateUniv4Configs(univ4Configs);
        _validateTotalFee(univ4Configs.lpFeeBps, taxConfigs);
        token = _createToken(
            tokenSetup,
            univ4Configs.renounceOwnership ? address(0) : msg.sender,
            _resolveGraduator(tokenSetup.liquidityTier),
            univ4Configs.lpFeeBps,
            buyOnDeployShares,
            taxConfigs,
            antiSniperConfigs,
            creatorVaults
        );
        emit LpFeeBpsSet(token, univ4Configs.lpFeeBps);
    }

    /// @dev V4-specific config validation. `lpFeeBps` is the per-swap LP fee stored on the token and
    ///      read by the hook via `getSwapFees` — only the two supported tiers (100 = 1%, 50 = 0.5%)
    ///      are accepted, so a typo reverts instead of silently storing an unsupported fee. Add further
    ///      V4-only invariants here as the struct grows.
    function _validateUniv4Configs(UniV4Configs calldata configs) internal pure {
        require(configs.lpFeeBps == 100 || configs.lpFeeBps == 50, InvalidLpFeeBps());
    }

    /// @dev Maps a liquidity `tier` to its graduator, which graduates at the tier's price and pairs with
    ///      the single fee-agnostic `LivoSwapHook`. The swap fee is not a selection axis: it is stored on
    ///      the token (`swapLpFeeBps`) and read by the hook, so one graduator serves both 100 and 50 bps.
    function _resolveGraduator(LiquidityTier tier) internal view returns (address) {
        if (tier == LiquidityTier.DEFAULT) return address(GRADUATOR);
        if (tier == LiquidityTier.THIN) return GRADUATOR_THIN;
        return GRADUATOR_THICK; // THICK
    }

    /// @dev Pre-graduation launchpad LP fee, fixed at `V4_LAUNCHPAD_LP_FEE_BPS` (1%) for every V4 token
    ///      regardless of the post-graduation hook fee it selected. The pre-graduation rate is a constant
    ///      launchpad policy, decoupled from the post-graduation LP fee, so `graduator` is ignored.
    function _launchpadLpFeeBps(
        address /* graduator */
    )
        internal
        pure
        override
        returns (uint16)
    {
        return V4_LAUNCHPAD_LP_FEE_BPS;
    }

    /// @inheritdoc RealmFactoryAbstract
    function _launchpadTreasuryShareBps() internal pure override returns (uint16) {
        return V4_LAUNCHPAD_TREASURY_SHARE_BPS;
    }

    /// @notice Returns which token implementation `createToken(...)` would clone for the given inputs.
    /// @dev Mirrors the dispatch-relevant `createToken` inputs minus the identity fields (`name`,
    ///      `symbol`, `salt`) and ownership flag so the ABI stays stable when future features change
    ///      which inputs participate in dispatch. Today `taxCfg.taxDurationSeconds`,
    ///      `taxCfg.taxDecayDuration` (a decay-only token still clones the taxable impl) and
    ///      `antiSniperCfg.protectionWindowSeconds` matter for dispatch; disabled configs must
    ///      have all other tax/anti-sniper fields
    ///      empty/zero. Used by frontends to compute the initcode hash before mining a salt.
    function previewTokenImplementation(
        FeeShare[] calldata, /* feeReceivers */
        SupplyShare[] calldata, /* supplyShares */
        TaxConfigs calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) external view returns (address) {
        _validateAntiSniperConfig(antiSniperCfg);
        _validateTaxConfig(taxCfg);
        return _previewTokenImplementation(taxCfg, antiSniperCfg);
    }

    /// @notice Quotes the ETH (msg.value) needed to receive ~`tokenAmount` tokens via the deployer buy.
    ///         Pass the same `taxCfg` and `univ4Configs` you'll pass to `createToken`; the buy fee is
    ///         derived from them (the fixed pre-graduation launchpad LP fee plus the buy tax) so the
    ///         frontend doesn't recompute it.
    /// @param tokenAmount Amount of tokens to receive
    /// @param totalLockedInVaultsBps Sum of `supplyBps` across the creator vaults (0 for none); selects
    ///        the same curve `createToken` uses. See `_quoteBuyOnDeploy`.
    /// @param taxCfg The tax config the token will be created with; only `buyTaxBps` affects the buy,
    ///        and only when the window is creation-anchored (`startTaxFromLaunch`) — a graduation-anchored
    ///        tax is not charged on the deploy buy (see `_deployBuyTaxBps`).
    /// @param univ4Configs The V4 config the token will be created with; `lpFeeBps` selects the
    ///        post-graduation hook fee. Validated here so the fee is one of the supported hook variants.
    ///        The deploy buy is a pre-graduation trade, so it is quoted at the fixed
    ///        `V4_LAUNCHPAD_LP_FEE_BPS`, not `lpFeeBps`.
    /// @return totalEthNeeded The msg.value to pass to createToken
    function quoteBuyOnDeploy(
        LiquidityTier liquidityTier,
        uint256 tokenAmount,
        uint256 totalLockedInVaultsBps,
        TaxConfigs calldata taxCfg,
        UniV4Configs calldata univ4Configs
    ) external view returns (uint256 totalEthNeeded) {
        _validateUniv4Configs(univ4Configs);
        return _quoteBuyOnDeploy(
            liquidityTier,
            tokenAmount,
            totalLockedInVaultsBps,
            uint256(V4_LAUNCHPAD_LP_FEE_BPS) + _deployBuyTaxBps(taxCfg)
        );
    }
}
