// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmBondingCurve} from "src/interfaces/IRealmBondingCurve.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {RealmFactoryAbstract} from "src/factories/RealmFactoryAbstract.sol";

/// @notice The BONDING-CURVE venue layer: everything about a factory that only makes sense when supply
///         reaches the market through a launchpad curve rather than straight into a pool. The curve
///         immutables and their `(tier, vault allocation)` resolution, the `LAUNCHPAD.launchToken()`
///         registration, the deploy buy that runs against the curve, and the quotes a frontend needs to
///         size that buy.
/// @dev Split out of `RealmFactoryAbstract` so `RealmFactoryUniV4Direct` — which has no curve and no
///      launchpad at all — can inherit the shared half without carrying 21 dead curve immutables and a
///      `launchToken` call it must never make. The two unified factories (V2, V4) extend THIS.
/// @dev Adds NO storage: every member below is an immutable or a function, so inserting this layer
///      leaves the UUPS proxy's slot layout — and `RealmFactoryAbstract.__gap` — exactly where it was.
abstract contract RealmFactoryCurveAbstract is RealmFactoryAbstract {
    using SafeERC20 for IERC20;

    /// @notice Bonding curve used for token pricing before graduation
    IRealmBondingCurve public immutable BONDING_CURVE;

    /// @notice DEFAULT-tier bonding curves used when creator vaults lock 5%/10%/15%/20%/25%/30% of supply.
    ///         Each keeps every graduation invariant identical to `BONDING_CURVE`; only the starting
    ///         market cap is relaxed. Selected by `(tier, totalBps)` in `_resolveBondingCurve`.
    IRealmBondingCurve public immutable VAULT_CURVE_5;
    IRealmBondingCurve public immutable VAULT_CURVE_10;
    IRealmBondingCurve public immutable VAULT_CURVE_15;
    IRealmBondingCurve public immutable VAULT_CURVE_20;
    IRealmBondingCurve public immutable VAULT_CURVE_25;
    IRealmBondingCurve public immutable VAULT_CURVE_30;

    /// @notice THIN-tier curves (1.75 ETH liquidity, 6.125 ETH graduation mcap): the no-vault curve
    ///         plus the six vault curves. Same graduation invariants as the rest of the tier; only the
    ///         starting market cap is relaxed as supply is locked.
    IRealmBondingCurve public immutable THIN_CURVE_BASE;
    IRealmBondingCurve public immutable THIN_VAULT_CURVE_5;
    IRealmBondingCurve public immutable THIN_VAULT_CURVE_10;
    IRealmBondingCurve public immutable THIN_VAULT_CURVE_15;
    IRealmBondingCurve public immutable THIN_VAULT_CURVE_20;
    IRealmBondingCurve public immutable THIN_VAULT_CURVE_25;
    IRealmBondingCurve public immutable THIN_VAULT_CURVE_30;

    /// @notice THICK-tier curves (7.0 ETH liquidity, 24.5 ETH graduation mcap): the no-vault curve
    ///         plus the six vault curves.
    IRealmBondingCurve public immutable THICK_CURVE_BASE;
    IRealmBondingCurve public immutable THICK_VAULT_CURVE_5;
    IRealmBondingCurve public immutable THICK_VAULT_CURVE_10;
    IRealmBondingCurve public immutable THICK_VAULT_CURVE_15;
    IRealmBondingCurve public immutable THICK_VAULT_CURVE_20;
    IRealmBondingCurve public immutable THICK_VAULT_CURVE_25;
    IRealmBondingCurve public immutable THICK_VAULT_CURVE_30;

    /// @notice Sets up the curve immutables on top of the shared factory ones. Same external shape the
    ///         concrete factories have always had, so no deploy script changes.
    /// @param vaultBondingCurves The six DEFAULT-tier allocation-specific bonding curves, ordered
    ///        [5%, 10%, 15%, 20%, 25%, 30%]
    /// @param tierConfig The THIN + THICK tier curve sets (`thin`/`thick`, each `base` + `vaults`).
    constructor(
        address launchpad,
        TokenImpls memory impls,
        address bondingCurve,
        address graduator,
        address masterFeeHandler,
        address creatorVaultFactory,
        address[6] memory vaultBondingCurves,
        LiquidityTierConfig memory tierConfig
    ) RealmFactoryAbstract(launchpad, impls, graduator, masterFeeHandler, creatorVaultFactory) {
        BONDING_CURVE = IRealmBondingCurve(bondingCurve);
        VAULT_CURVE_5 = IRealmBondingCurve(vaultBondingCurves[0]);
        VAULT_CURVE_10 = IRealmBondingCurve(vaultBondingCurves[1]);
        VAULT_CURVE_15 = IRealmBondingCurve(vaultBondingCurves[2]);
        VAULT_CURVE_20 = IRealmBondingCurve(vaultBondingCurves[3]);
        VAULT_CURVE_25 = IRealmBondingCurve(vaultBondingCurves[4]);
        VAULT_CURVE_30 = IRealmBondingCurve(vaultBondingCurves[5]);

        THIN_CURVE_BASE = IRealmBondingCurve(tierConfig.thin.base);
        THIN_VAULT_CURVE_5 = IRealmBondingCurve(tierConfig.thin.vaults[0]);
        THIN_VAULT_CURVE_10 = IRealmBondingCurve(tierConfig.thin.vaults[1]);
        THIN_VAULT_CURVE_15 = IRealmBondingCurve(tierConfig.thin.vaults[2]);
        THIN_VAULT_CURVE_20 = IRealmBondingCurve(tierConfig.thin.vaults[3]);
        THIN_VAULT_CURVE_25 = IRealmBondingCurve(tierConfig.thin.vaults[4]);
        THIN_VAULT_CURVE_30 = IRealmBondingCurve(tierConfig.thin.vaults[5]);

        THICK_CURVE_BASE = IRealmBondingCurve(tierConfig.thick.base);
        THICK_VAULT_CURVE_5 = IRealmBondingCurve(tierConfig.thick.vaults[0]);
        THICK_VAULT_CURVE_10 = IRealmBondingCurve(tierConfig.thick.vaults[1]);
        THICK_VAULT_CURVE_15 = IRealmBondingCurve(tierConfig.thick.vaults[2]);
        THICK_VAULT_CURVE_20 = IRealmBondingCurve(tierConfig.thick.vaults[3]);
        THICK_VAULT_CURVE_25 = IRealmBondingCurve(tierConfig.thick.vaults[4]);
        THICK_VAULT_CURVE_30 = IRealmBondingCurve(tierConfig.thick.vaults[5]);
    }

    /// @notice Max tokens a deploy buy can purchase for a given liquidity tier and total creator-vault
    ///         allocation. Buying this amount pushes the curve to exactly its graduation threshold, so the
    ///         token graduates in the same `createToken` tx while staying clear of `maxExcessOverThreshold`
    ///         — a deploy buy sized at or below it never reverts `MaxEthReservesExceeded`. There is no other
    ///         cap on the deploy buy; graduation is the limit. Frontends read this to bound the deploy-buy
    ///         token amount, then price it with `quoteBuyOnDeploy`.
    /// @param totalLockedInVaultsBps Sum of `supplyBps` across the creator vaults (0 for none); selects the
    ///        same curve `createToken` uses. Reverts `InvalidCreatorVault` if not a valid multiple in range.
    function maxBuyOnDeploy(LiquidityTier tier, uint256 totalLockedInVaultsBps)
        external
        view
        returns (uint256 maxTokens)
    {
        IRealmBondingCurve curve = _resolveBondingCurve(tier, totalLockedInVaultsBps);
        (maxTokens,) = curve.buyTokensWithExactEth(0, curve.ethGraduationThreshold());
    }

    ///////////////////////// INTERNAL FUNCTIONS /////////////////////////

    /// @dev Shared body for the concrete factories' `quoteBuyOnDeploy`: total ETH (including the
    ///      inverse buy fee) needed to buy `tokenAmount` from the curve `totalLockedInVaultsBps`
    ///      selects. `buyFeeBps` is the pre-graduation buy fee the launchpad will charge (LP fee + buy
    ///      tax); each factory's public `quoteBuyOnDeploy` derives it from the venue config + tax the
    ///      deployer will pass to `createToken` — the token doesn't exist at quote time, so the fee is
    ///      computed from those inputs rather than read from the token. Pass the SUM of `supplyBps`
    ///      across the vaults (0 for a non-vault token); only the aggregate matters (it keys the curve),
    ///      so vault owners/vesting need not be finalized to quote. The only bound on `tokenAmount` is
    ///      graduation: keep it at or below `maxBuyOnDeploy(tier, totalLockedInVaultsBps)`, else the
    ///      resulting buy reverts `MaxEthReservesExceeded`. Reverts (`InvalidCreatorVault`) on a
    ///      `totalLockedInVaultsBps` no vault array could sum to; a `buyFeeBps >= BASIS_POINTS` reverts
    ///      on the subtraction below (nonsensical input).
    function _quoteBuyOnDeploy(
        LiquidityTier tier,
        uint256 tokenAmount,
        uint256 totalLockedInVaultsBps,
        uint256 buyFeeBps
    ) internal view returns (uint256 totalEthNeeded) {
        require(
            totalLockedInVaultsBps <= MAX_CREATOR_VAULT_TOTAL_BPS
                && totalLockedInVaultsBps % CREATOR_VAULT_BPS_STEP == 0,
            InvalidCreatorVault()
        );
        (uint256 ethForReserves,) = _resolveBondingCurve(tier, totalLockedInVaultsBps).buyExactTokens(0, tokenAmount);
        uint256 denom = BASIS_POINTS - buyFeeBps;
        totalEthNeeded = (ethForReserves * BASIS_POINTS + denom - 1) / denom;
    }

    /// @dev Buys supply with `msg.value` off the curve and distributes it to `supplyShares`. There is
    ///      no per-deploy buy cap: the buy is bounded only by graduation — the launchpad/curve accept ETH
    ///      up to `graduationThreshold + maxExcessOverThreshold` and revert `MaxEthReservesExceeded`
    ///      beyond it (a buy that reaches the threshold graduates the token in this same tx). Use
    ///      `maxBuyOnDeploy` to size a buy up to the instant-graduation point without risking that revert.
    function _buyAndDistribute(address token, SupplyShare[] calldata supplyShares) internal {
        _distributeDeployBuy(
            token, supplyShares, LAUNCHPAD.buyTokensWithExactEth{value: msg.value}(token, 0, block.timestamp)
        );
    }

    /// @dev Shared postamble: asks the token to self-register its fee config with the master
    ///      handler, then performs the deployer buy (if any). Event order: `SharesUpdated` fires
    ///      strictly after `TokenLaunched`, and the deployer buy events fire last.
    function _finalizeCreation(address token, FeeShare[] memory feeReceivers, SupplyShare[] calldata supplyShares)
        internal
    {
        IRealmToken(token).registerFees(feeReceivers);
        if (msg.value > 0) _buyAndDistribute(token, supplyShares);
    }

    /// @dev The shared `createToken` body of both curve factories. Centralises validation → dispatch →
    ///      launch → finalize so both venues emit the exact same events in the same order.
    ///      Takes structs (not flat args) so future fields can be added to `TokenSetupTiered`/configs
    ///      without growing this function's stack frame. Callers derive `tokenOwner` per their
    ///      venue policy (V2: always `address(0)`; V4: `msg.sender` unless renounced).
    ///
    ///      `graduator` is passed in by the caller (instead of read from the `GRADUATOR` immutable)
    ///      so V4 can pick the graduator matching the token's liquidity tier. V2 has a single graduator
    ///      and always passes `address(GRADUATOR)`. `swapLpFeeBps` is the per-swap LP fee the
    ///      post-graduation `RealmSwapHook` charges, stored on the token and surfaced via `getSwapFees`:
    ///      0 for V2 (no hook LP fee), 50 or 100 for V4. A single hook reads it from the token, so one
    ///      V4 graduator per tier serves both fee tiers.
    /// @dev `tokenSetup` is `memory`, a leftover of the removed positional overload that built one in
    ///      memory; the string/`FeeShare[]` fields cascade into `_validateInputs`/`_validateNameSymbol`/
    ///      `_validateFeeShares`/`_dispatchAndInitialize`/`_cloneAndCreateToken`/`_finalizeCreation`.
    ///      Switching it (and the cascaded fields) to `calldata` would skip a one-time copy
    ///      (~100–250 gas/deploy).
    function _createToken(
        TokenSetupTiered memory tokenSetup,
        address tokenOwner,
        address graduator,
        uint16 swapLpFeeBps,
        SupplyShare[] calldata buyOnDeployShares,
        TaxConfigs memory taxConfigs,
        AntiSniperConfigs calldata antiSniperConfigs,
        CreatorVault[] memory creatorVaults
    ) internal returns (address token) {
        _validateInputs(tokenSetup.name, tokenSetup.symbol, tokenSetup.feeShares, buyOnDeployShares);
        _validateAntiSniperConfig(antiSniperConfigs);
        _validateTaxConfig(taxConfigs);

        // Creator vaults: validate and pick the allocation-specific bonding curve. `vaultAllocation`
        // is minted to this factory by the token initializer; everything else (`TOTAL_SUPPLY -
        // vaultAllocation`) is minted to the launchpad and sold on the resolved curve.
        (uint256 totalLockedInVaultsBps, uint256 vaultAllocation) = _validateCreatorVaults(creatorVaults);
        IRealmBondingCurve bondingCurve = _resolveBondingCurve(tokenSetup.liquidityTier, totalLockedInVaultsBps);

        token = _dispatchAndInitialize(
            tokenSetup.name,
            tokenSetup.symbol,
            tokenSetup.salt,
            tokenOwner,
            graduator,
            swapLpFeeBps,
            vaultAllocation,
            taxConfigs,
            antiSniperConfigs
        );

        LAUNCHPAD.launchToken(token, bondingCurve);
        emit BondingCurveAssigned(token, address(bondingCurve));

        // Deploy + fund the vaults BEFORE the deployer buy so the factory ends the tx holding no
        // tokens. The factory→vault transfers are exempt from sniper caps (`from == tokenFactory`).
        if (vaultAllocation > 0) _deployAndFundVaults(token, creatorVaults, vaultAllocation);

        // buy-on-deploy executes after the vaults are deployed and funded
        _finalizeCreation(token, tokenSetup.feeShares, buyOnDeployShares);
    }

    /// @dev Maps a `(liquidity tier, total locked allocation)` pair to the matching bonding curve.
    ///      `totalBps == 0` uses the tier's no-vault curve (the deployed base curve for DEFAULT);
    ///      otherwise it is guaranteed by `_validateCreatorVaults` to be a multiple of 500 in
    ///      [500, 3000]. The explicit final branches + `else` revert make this a total function, so any
    ///      unexpected value fails loudly instead of silently defaulting to a curve.
    function _resolveBondingCurve(LiquidityTier tier, uint256 totalBps) internal view returns (IRealmBondingCurve) {
        if (tier == LiquidityTier.DEFAULT) {
            if (totalBps == 0) return BONDING_CURVE;
            if (totalBps == 500) return VAULT_CURVE_5;
            if (totalBps == 1000) return VAULT_CURVE_10;
            if (totalBps == 1500) return VAULT_CURVE_15;
            if (totalBps == 2000) return VAULT_CURVE_20;
            if (totalBps == 2500) return VAULT_CURVE_25;
            if (totalBps == 3000) return VAULT_CURVE_30;
        } else if (tier == LiquidityTier.THIN) {
            if (totalBps == 0) return THIN_CURVE_BASE;
            if (totalBps == 500) return THIN_VAULT_CURVE_5;
            if (totalBps == 1000) return THIN_VAULT_CURVE_10;
            if (totalBps == 1500) return THIN_VAULT_CURVE_15;
            if (totalBps == 2000) return THIN_VAULT_CURVE_20;
            if (totalBps == 2500) return THIN_VAULT_CURVE_25;
            if (totalBps == 3000) return THIN_VAULT_CURVE_30;
        } else if (tier == LiquidityTier.THICK) {
            if (totalBps == 0) return THICK_CURVE_BASE;
            if (totalBps == 500) return THICK_VAULT_CURVE_5;
            if (totalBps == 1000) return THICK_VAULT_CURVE_10;
            if (totalBps == 1500) return THICK_VAULT_CURVE_15;
            if (totalBps == 2000) return THICK_VAULT_CURVE_20;
            if (totalBps == 2500) return THICK_VAULT_CURVE_25;
            if (totalBps == 3000) return THICK_VAULT_CURVE_30;
        }
        revert InvalidCreatorVault();
    }
}
