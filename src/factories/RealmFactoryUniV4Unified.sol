// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {
    TaxConfigs,
    TaxConfigsWithMultiAllocation,
    EarningsAllocationMultiConfig,
    IRealmTaxableToken
} from "src/interfaces/IRealmTaxableToken.sol";
import {RealmFactoryCurveAbstract} from "src/factories/RealmFactoryCurveAbstract.sol";
import {RealmFactoryAbstract} from "src/factories/RealmFactoryAbstract.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";

/// @notice Unified factory for the Uniswap V4 token family. Dispatches between two token
///         implementations (`base`, `tax`) based on whether tax is configured; anti-sniper
///         protection is a gated feature of both, not a separate impl.
///
///         Replaces `RealmFactoryUniV4`, `RealmFactoryTaxToken`, `RealmFactoryUniV4SniperProtected`,
///         and `RealmFactoryTaxTokenSniperProtected`.
contract RealmFactoryUniV4Unified is RealmFactoryCurveAbstract {
    /// @notice V4-specific config bundle for `createToken`.
    /// @dev `lpFeeBps` is the per-swap LP fee `RealmSwapHook` charges post-graduation. It is stored on
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
    ///         graduation price and pairs with the single fee-agnostic `RealmSwapHook`. Selected by
    ///         `_resolveGraduator(tier)`.
    address public immutable GRADUATOR_THIN;
    address public immutable GRADUATOR_THICK;

    /// @notice Pre-graduation launchpad LP fee for V4 tokens (bps), charged on every bonding-curve trade
    ///         and split treasury/creator by `V4_LAUNCHPAD_TREASURY_SHARE_BPS`. Fixed at 1% for every V4
    ///         token regardless of the post-graduation hook fee it selects (`UniV4Configs.lpFeeBps`, 50 or
    ///         100): the pre-graduation rate is a constant launchpad policy, decoupled from the LP fee the
    ///         hook charges after graduation.
    uint16 internal constant V4_LAUNCHPAD_LP_FEE_BPS = 100;

    /// @notice Treasury share of the V4 pre-graduation LP fee (bps): 30 treasury / 70 creator.
    uint16 internal constant V4_LAUNCHPAD_TREASURY_SHARE_BPS = 3_000;

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
        RealmFactoryCurveAbstract(
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
    // (emit after `_createToken(...)` returns, in `_createV4` below).

    /// @notice Deploys a V4-family Realm token and registers it in the launchpad. The ONE entry point:
    ///         `taxAllocationConfigs` carries the static tax, the optional linear launch-tax decay and the
    ///         earnings-allocation split (burn / dividends / liquidity bps; the fund wallets take the
    ///         remainder), paid out in up to three dividend assets. An all-zero allocation deploys a
    ///         token with no split, and one with no tax and no allocation is cloned from the base
    ///         implementation. `univ4Configs.lpFeeBps` is the post-graduation swap fee (100 or 50),
    ///         `creatorVaults` may be empty, and `referral` (or `address(0)`) is only emitted as an
    ///         off-chain signal. If `msg.value > 0`, buys supply and splits it across
    ///         `buyOnDeployShares`.
    /// @dev Any tax config is accepted with an allocation, a zero one included: the creator's share of
    ///      the LP fee is a permanent earnings stream on this venue, so a no-tax token with an allocation
    ///      is a revenue-share token cloned from the taxable implementation (see
    ///      `previewTokenImplementation`). A non-zero `dividendsBps` must name its payout assets; each is
    ///      checked with `RealmDividendSwapRegistry` at creation. Every rule of
    ///      `EarningsAllocationMultiConfig` applies: distinct assets, non-zero weights summing to 10,000,
    ///      and `DIVIDEND_SELF_TOKEN` only on its own.
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
        bool hasAllocation = _hasAllocation(alloc.burnBps, alloc.dividendsBps, alloc.liquidityBps);
        // Naming payout assets with a zero share would leave dividends silently OFF, forever: clones
        // are not upgradeable and `initializeEarningsAllocation` only ever runs here, at creation.
        require(alloc.dividendTokens.length == 0 || alloc.dividendsBps != 0, DividendAssetWithoutShare());

        TaxConfigs memory taxConfigs = _toTaxConfigs(taxAllocationConfigs);
        _allocationPending = hasAllocation;
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

    /// @dev The deploy half of `createToken`: validates the V4 config, resolves the tier's graduator,
    ///      deploys via the shared umbrella storing `univ4Configs.lpFeeBps` on the token, and emits the
    ///      V4-only `LpFeeBpsSet` marker. Factored out to keep `createToken`'s stack shallow enough to
    ///      compile without `via_ir`. `tokenOwner`/`graduator` are inlined for the same
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
    ///      the single fee-agnostic `RealmSwapHook`. The swap fee is not a selection axis: it is stored on
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

    /// @notice Returns which token implementation `createToken` would clone for the same arguments, so a
    ///         frontend can compute the initcode hash before mining a `0xeeaa` salt. Takes EXACTLY
    ///         `createToken`'s arguments, so the ABI stays stable whichever inputs dispatch reads later;
    ///         today only the tax config and whether any allocation bucket is set matter.
    function previewTokenImplementation(
        TokenSetupTiered calldata, /* tokenSetup */
        TaxConfigsWithMultiAllocation calldata taxAllocationConfigs,
        UniV4Configs calldata, /* univ4Configs */
        SupplyShare[] calldata, /* buyOnDeployShares */
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata, /* creatorVaults */
        address /* referral */
    ) external view returns (address) {
        _validateAntiSniperConfig(antiSniperConfigs);
        TaxConfigs memory cfg = _toTaxConfigs(taxAllocationConfigs);
        _validateTaxConfig(cfg);
        EarningsAllocationMultiConfig calldata alloc = taxAllocationConfigs.earningsAllocation;
        return _previewTokenImplementation(cfg, _hasAllocation(alloc.burnBps, alloc.dividendsBps, alloc.liquidityBps));
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
