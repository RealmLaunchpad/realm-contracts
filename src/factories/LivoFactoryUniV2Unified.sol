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
    ILivoTaxableToken
} from "src/interfaces/ILivoTaxableToken.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";

/// @notice Unified factory for the Uniswap V2 token family. Dispatches between two token
///         implementations (`base`, `tax`) based on whether tax is configured; anti-sniper
///         protection is a gated feature of both, not a separate impl.
///
///         Replaces `LivoFactoryUniV2` and `LivoFactoryUniV2SniperProtected`, and now also
///         covers the tax variant `LivoTaxableTokenUniV2`.
///
///         Ownership rule: all V2-family tokens are deployed with `tokenOwner = address(0)`.
///         Tax cap: V2 has no post-graduation LP fee, so the per-direction tax can reach the full
///         `MAX_TOTAL_FEE_BPS` (5%). Pre-graduation the launchpad additionally charges
///         `V2_LAUNCHPAD_LP_FEE_BPS`, so a trader transiently pays up to 6% on the bonding curve —
///         bounded by the launchpad's own (looser) per-trade cap, not by `_validateTotalFee`.
contract LivoFactoryUniV2Unified is LivoFactoryAbstract {
    /// @notice Pre-graduation launchpad LP fee for V2 tokens (bps), charged on every bonding-curve
    ///         trade and split treasury/creator by `V2_LAUNCHPAD_TREASURY_SHARE_BPS`. It exists only
    ///         pre-graduation (V2 has no post-graduation LP fee) and does NOT count against the tax cap
    ///         (see `V2_POST_GRADUATION_LP_FEE_BPS`); the launchpad's own looser per-trade cap absorbs
    ///         it on top of the tax.
    uint16 internal constant V2_LAUNCHPAD_LP_FEE_BPS = 100;

    /// @notice Post-graduation LP fee for V2 tokens (bps): none. V2 graduates to Uniswap V2, which
    ///         carries no Livo LP fee, so the post-graduation fee a trader pays is the tax alone. This
    ///         is the LP fee `_validateTotalFee` caps against, letting the V2 tax reach the full
    ///         `MAX_TOTAL_FEE_BPS` (5%) regardless of the pre-graduation launchpad fee.
    uint16 internal constant V2_POST_GRADUATION_LP_FEE_BPS = 0;

    /// @notice Treasury share of the V2 pre-graduation LP fee (bps): 50/50 treasury/creator.
    uint16 internal constant V2_LAUNCHPAD_TREASURY_SHARE_BPS = 5_000;

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
        LivoFactoryAbstract(
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

    /// @notice Deploys a V2-family Livo token and registers it in the launchpad.
    ///         Dispatches between four implementations based on `taxCfg` and `antiSniperCfg`.
    ///         The per-token fee config is registered with the master fee handler at deploy time.
    ///         If `msg.value > 0`, buys supply and distributes it across `supplyShares`.
    /// @dev DEPRECATED: legacy positional overload, kept for backwards compatibility (unchanged
    ///      signature). New integrations should use the struct-based overload that takes `creatorVaults`
    ///      and the full `TaxConfigs`. Always deploys with no creator vaults and no launch-tax decay —
    ///      the `TaxConfigInit` is lifted into a `TaxConfigs` with the decay fields zeroed.
    function createToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        FeeShare[] calldata feeReceivers,
        SupplyShare[] calldata supplyShares,
        TaxConfigInit calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) external payable returns (address token) {
        // V2-family tokens are always deployed ownerless. Routes through the shared `_createToken`
        // umbrella so this overload and the struct-based overloads below share the same internal flow.
        // `LpFeeBpsSet` is emitted only by the V4 factory — V2 has no LP-fee concept.
        // Build `tokenSetup` first (consuming the deep `name`/`symbol`/`salt`/`feeReceivers` calldata
        // params) before introducing the `taxConfigs` memory local, to keep the stack shallow enough
        // to compile without `via_ir`.
        // Legacy overload always uses the DEFAULT liquidity tier.
        TokenSetupTiered memory tokenSetup = TokenSetupTiered({
            name: name, symbol: symbol, salt: salt, feeShares: feeReceivers, liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigs memory taxConfigs = _toTaxConfigs(taxCfg);
        _validateTotalFee(V2_POST_GRADUATION_LP_FEE_BPS, taxConfigs);
        token = _createToken(
            tokenSetup,
            address(0),
            address(GRADUATOR),
            V2_POST_GRADUATION_LP_FEE_BPS,
            supplyShares,
            taxConfigs,
            antiSniperCfg,
            new CreatorVault[](0)
        );
    }

    /// @notice Struct-based overload taking the full `TaxConfigs` (static tax + optional linear launch-tax
    ///         decay), a `creatorVaults` array (pass empty for none) and a `TokenSetupTiered` selecting the
    ///         liquidity tier. Kept for backwards compatibility; new integrations should use the `referral`
    ///         overload below (the current recommended overload).
    function createToken(
        TokenSetupTiered calldata tokenSetup,
        TaxConfigs calldata taxConfigs,
        SupplyShare[] calldata buyOnDeployShares,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults
    ) external payable returns (address token) {
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
    }

    /// @notice Recommended overload: same as the `TokenSetupTiered` overload plus a `referral` address for
    ///         relayers that forward the creation and are entitled to a cut of the fees. When `referral` is
    ///         non-zero a `TokenReferral(token, referral)` event is emitted; no token storage or on-chain
    ///         payout is wired to it yet — it is purely an off-chain signal for now.
    function createToken(
        TokenSetupTiered calldata tokenSetup,
        TaxConfigs calldata taxConfigs,
        SupplyShare[] calldata buyOnDeployShares,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] calldata creatorVaults,
        address referral
    ) external payable returns (address token) {
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
        if (referral != address(0)) emit TokenReferral(token, referral);
    }

    /// @notice Allocation-aware overload: the recommended `referral` overload plus a
    ///         `TaxConfigsWithAllocation` that also carries the earnings-allocation split (burn /
    ///         dividends / liquidity bps; the fund wallets take the remainder). The split is stored on
    ///         the token at creation via `initializeEarningsAllocation`. A non-zero split requires a
    ///         token with a LONG-TERM static tax (`taxDurationSeconds != 0`); a decay-only token is
    ///         rejected — its tax window lasts minutes, so there is no earnings stream worth splitting.
    ///         A non-zero `dividendsBps` must name a payout asset in `dividendToken`; the token asks
    ///         `LivoDividendSwapRegistry` whether it can be bought and reverts at creation otherwise. The
    ///         registry answers yes either because the asset has a Uniswap V2 pair that is deep enough
    ///         right now — the permissionless rule, no whitelist and no per-asset approval — or because
    ///         an admin has given it a curated Uniswap V4 route, which is how V4-only assets qualify.
    function createToken(
        TokenSetupTiered calldata tokenSetup,
        TaxConfigsWithAllocation calldata taxAllocationConfigs,
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
            ILivoTaxableToken(payable(token))
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
            ILivoTaxableToken(payable(token))
                .initializeEarningsAllocation(
                    alloc.burnBps,
                    alloc.dividendsBps,
                    alloc.liquidityBps,
                    alloc.dividendTokens,
                    alloc.dividendWeightsBps
                );
        }
        if (referral != address(0)) emit TokenReferral(token, referral);
    }

    /// @notice Returns which token implementation `createToken(...)` would clone for the given inputs.
    /// @dev Mirrors the full `createToken` input set minus the identity fields (`name`, `symbol`,
    ///      `salt`) so the ABI stays stable when future features change which inputs participate in
    ///      dispatch. Today `taxCfg.taxDurationSeconds`, `taxCfg.taxDecayDuration` (a decay-only token
    ///      still clones the taxable impl) and `antiSniperCfg.protectionWindowSeconds` matter for
    ///      dispatch; disabled configs must have all other tax/anti-sniper fields empty/zero. Used by
    ///      frontends to compute the initcode hash before mining a salt.
    function previewTokenImplementation(
        FeeShare[] calldata, /* feeReceivers */
        SupplyShare[] calldata, /* supplyShares */
        TaxConfigs calldata taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) external view returns (address) {
        _validateAntiSniperConfig(antiSniperCfg);
        _validateTaxConfig(taxCfg);
        _validateTotalFee(V2_POST_GRADUATION_LP_FEE_BPS, taxCfg);
        return _previewTokenImplementation(taxCfg, antiSniperCfg);
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

    /// @inheritdoc LivoFactoryAbstract
    function _launchpadTreasuryShareBps() internal pure override returns (uint16) {
        return V2_LAUNCHPAD_TREASURY_SHARE_BPS;
    }
}
