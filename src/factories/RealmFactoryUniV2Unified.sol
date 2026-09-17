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

/// @notice Unified factory for the Uniswap V2 token family. Dispatches between two token
///         implementations (`base`, `tax`) based on whether tax is configured; anti-sniper
///         protection is a gated feature of both, not a separate impl.
///
///         Replaces `RealmFactoryUniV2` and `RealmFactoryUniV2SniperProtected`, and now also
///         covers the tax variant `RealmTaxableTokenUniV2`.
///
///         Ownership rule: all V2-family tokens are deployed with `tokenOwner = address(0)`.
///         Tax cap: V2 has no post-graduation LP fee, so the per-direction tax can reach the full
///         `MAX_TOTAL_FEE_BPS` (5%). Pre-graduation the launchpad additionally charges
///         `V2_LAUNCHPAD_LP_FEE_BPS`, so a trader transiently pays up to 6% on the bonding curve —
///         bounded by the launchpad's own (looser) per-trade cap, not by `_validateTotalFee`.
contract RealmFactoryUniV2Unified is RealmFactoryCurveAbstract {
    /// @notice Pre-graduation launchpad LP fee for V2 tokens (bps), charged on every bonding-curve
    ///         trade and split treasury/creator by `V2_LAUNCHPAD_TREASURY_SHARE_BPS`. It exists only
    ///         pre-graduation (V2 has no post-graduation LP fee) and does NOT count against the tax cap
    ///         (see `V2_POST_GRADUATION_LP_FEE_BPS`); the launchpad's own looser per-trade cap absorbs
    ///         it on top of the tax.
    uint16 internal constant V2_LAUNCHPAD_LP_FEE_BPS = 100;

    /// @notice Post-graduation LP fee for V2 tokens (bps): none. V2 graduates to Uniswap V2, which
    ///         carries no Realm LP fee, so the post-graduation fee a trader pays is the tax alone. This
    ///         is the LP fee `_validateTotalFee` caps against, letting the V2 tax reach the full
    ///         `MAX_TOTAL_FEE_BPS` (5%) regardless of the pre-graduation launchpad fee.
    uint16 internal constant V2_POST_GRADUATION_LP_FEE_BPS = 0;

    /// @notice Treasury share of the V2 pre-graduation LP fee (bps): 30 treasury / 70 creator.
    uint16 internal constant V2_LAUNCHPAD_TREASURY_SHARE_BPS = 3_000;

    constructor(
        address launchpad,
        TokenImpls memory impls,
        address bondingCurve,
        address graduator,
        address masterFeeHandler,
        address creatorVaultFactory,
        address[6] memory vaultBondingCurves,
        LiquidityTierConfig memory tierConfig
    )
        RealmFactoryCurveAbstract(
            launchpad,
            impls,
            bondingCurve,
            graduator,
            masterFeeHandler,
            creatorVaultFactory,
            vaultBondingCurves,
            tierConfig
        )
    {}

    /////////////////////// EXTERNAL FUNCTIONS /////////////////////////

    /// @notice Deploys a V2-family Realm token and registers it in the launchpad. The ONE entry point:
    ///         `taxAllocationConfigs` carries the static tax, the optional linear launch-tax decay and the
    ///         earnings-allocation split (burn / dividends / liquidity bps; the fund wallets take the
    ///         remainder), paid out in up to three dividend assets. An all-zero allocation deploys a
    ///         token with no split. `creatorVaults` may be empty and `referral` (or `address(0)`) is only
    ///         emitted as an off-chain signal. If `msg.value > 0`, buys supply and splits it across
    ///         `buyOnDeployShares`. V2-family tokens are always deployed ownerless.
    /// @dev A non-zero split requires a token with a LONG-TERM static tax (`taxDurationSeconds != 0`): V2
    ///      LP fees never reach the token, so the tax is its only earnings stream, and a decay-only token's
    ///      window lasts minutes. A non-zero `dividendsBps` must name its payout assets; each is checked
    ///      with `RealmDividendSwapRegistry` at creation. Every rule of `EarningsAllocationMultiConfig`
    ///      applies: distinct assets, non-zero weights summing to 10,000, and `DIVIDEND_SELF_TOKEN` only
    ///      on its own.
    function createToken(
        TokenSetupTiered calldata tokenSetup,
        TaxConfigsWithMultiAllocation calldata taxAllocationConfigs,
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

        // V2-family tokens are always deployed ownerless; V2 never emits `LpFeeBpsSet`.
        _validateTotalFee(V2_POST_GRADUATION_LP_FEE_BPS, taxConfigs);
        token = _createToken(
            tokenSetup,
            address(0),
            address(GRADUATOR),
            V2_POST_GRADUATION_LP_FEE_BPS,
            buyOnDeployShares,
            taxConfigs,
            antiSniperConfigs,
            creatorVaults
        );
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

    /// @notice Returns which token implementation `createToken` would clone for the same arguments, so a
    ///         frontend can compute the initcode hash before mining a `0xeeaa` salt. Takes EXACTLY
    ///         `createToken`'s arguments, so the ABI stays stable whichever inputs dispatch reads later;
    ///         today only the tax config and whether any allocation bucket is set matter.
    function previewTokenImplementation(
        TokenSetupTiered calldata, /* tokenSetup */
        TaxConfigsWithMultiAllocation calldata taxAllocationConfigs,
        SupplyShare[] calldata, /* buyOnDeployShares */
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata, /* creatorVaults */
        address /* referral */
    ) external view returns (address) {
        _validateAntiSniperConfig(antiSniperConfigs);
        TaxConfigs memory cfg = _toTaxConfigs(taxAllocationConfigs);
        _validateTaxConfig(cfg);
        _validateTotalFee(V2_POST_GRADUATION_LP_FEE_BPS, cfg);
        EarningsAllocationMultiConfig calldata alloc = taxAllocationConfigs.earningsAllocation;
        return _previewTokenImplementation(cfg, _hasAllocation(alloc.burnBps, alloc.dividendsBps, alloc.liquidityBps));
    }

    /// @notice Quotes the ETH (msg.value) needed to receive ~`tokenAmount` tokens via the deployer buy.
    ///         Pass the same `taxCfg` you'll pass to `createToken`; the buy fee is derived from it (the
    ///         fixed V2 pre-graduation LP fee plus the buy tax) so the frontend doesn't recompute it.
    /// @param tokenAmount Amount of tokens to receive
    /// @param totalLockedInVaultsBps Sum of `supplyBps` across the creator vaults (0 for none); selects
    ///        the same curve `createToken` uses. See `_quoteBuyOnDeploy`.
    /// @param taxCfg The tax config the token will be created with; only `buyTaxBps` affects the buy,
    ///        and only when the window is creation-anchored (`startTaxFromLaunch`) — a graduation-anchored
    ///        tax is not charged on the deploy buy (see `_deployBuyTaxBps`).
    /// @return totalEthNeeded The msg.value to pass to createToken
    function quoteBuyOnDeploy(
        LiquidityTier liquidityTier,
        uint256 tokenAmount,
        uint256 totalLockedInVaultsBps,
        TaxConfigs calldata taxCfg
    ) external view returns (uint256 totalEthNeeded) {
        return _quoteBuyOnDeploy(
            liquidityTier, tokenAmount, totalLockedInVaultsBps, _deployBuyTaxBps(taxCfg) + V2_LAUNCHPAD_LP_FEE_BPS
        );
    }

    ///////////////////////// INTERNAL FUNCTIONS /////////////////////////

    /// @dev V2 has a single graduator and a fixed pre-graduation launchpad LP fee (no post-graduation
    ///      LP fee to mirror), so `graduator` is ignored.
    function _launchpadLpFeeBps(
        address /* graduator */
    )
        internal
        pure
        override
        returns (uint16)
    {
        return V2_LAUNCHPAD_LP_FEE_BPS;
    }

    /// @inheritdoc RealmFactoryAbstract
    function _launchpadTreasuryShareBps() internal pure override returns (uint16) {
        return V2_LAUNCHPAD_TREASURY_SHARE_BPS;
    }
}
