// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmLaunchpad} from "src/interfaces/IRealmLaunchpad.sol";
import {IRealmGraduator} from "src/interfaces/IRealmGraduator.sol";
import {IRealmBondingCurve} from "src/interfaces/IRealmBondingCurve.sol";
import {IRealmMasterFeeHandler} from "src/interfaces/IRealmMasterFeeHandler.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IRealmCreatorVaultFactory} from "src/interfaces/IRealmCreatorVaultFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {
    IRealmTaxableToken,
    TaxConfigInit,
    TaxConfigs,
    TaxConfigsWithAllocation,
    TaxConfigsWithMultiAllocation
} from "src/interfaces/IRealmTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";

/// @notice Abstract base for Realm token factories. Holds shared state and helper logic.
/// @dev    UUPS-upgradeable. The implementation contract sets its immutables in the constructor
///         (baked into bytecode) and calls `_disableInitializers()` to prevent direct init.
///         Proxies must call `initialize()` exactly once to claim ownership. Upgrade authorisation
///         lives in `_authorizeUpgrade`.
abstract contract RealmFactoryAbstract is IRealmFactory, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    uint256 internal constant BASIS_POINTS = 10_000;

    /// @notice Max configurable tax duration. Capped at 120 years purely to prevent overflow —
    ///         the upper bound is driven by `TaxConfigs.taxDurationSeconds`'s `uint32` packing.
    ///         Any deployer can use any duration up to this cap; no fee-receiver or
    ///         ownership constraints are imposed beyond the standard validation.
    uint256 public constant MAX_TAX_DURATION_SECONDS = 120 * 365 days;

    /// @notice Max COMBINED start rate (bps) for the optional linear launch-tax decay: `buy + sell`.
    ///         Fixed at 20% — higher than the static `MAX_TOTAL_FEE_BPS` (5%) because the decay only
    ///         applies transiently at launch and falls to 0 within `MAX_TAX_DECAY_DURATION_SECONDS`. The
    ///         cap is on the sum, so any split is allowed (e.g. 10%/10%, 5%/15%, 20%/0%). A trade pays
    ///         only one direction and the effective tax is `max(decay, static)`, so the worst-case rate a
    ///         single trade sees at launch is at most this cap; the launchpad's own `MAX_TRADING_FEE_BPS`
    ///         (25%) absorbs it on top of the LP fee.
    uint256 public constant MAX_TAX_DECAY_START_COMBINED_BPS = 2_000;

    /// @notice Max duration (seconds) of the linear launch-tax decay: 20 minutes. The decay rate falls
    ///         from its start value to 0 over at most this window, from the same anchor the static tax uses.
    uint256 public constant MAX_TAX_DECAY_DURATION_SECONDS = 20 minutes;

    /// @notice Launchpad where tokens are registered after creation
    IRealmLaunchpad public immutable LAUNCHPAD;
    /// @notice Graduator contract that handles token graduation to Uniswap
    IRealmGraduator public immutable GRADUATOR;
    /// @notice Bonding curve used for token pricing before graduation
    IRealmBondingCurve public immutable BONDING_CURVE;
    /// @notice Master fee handler for all token fee routing
    IRealmMasterFeeHandler public immutable MASTER_FEE_HANDLER;

    /// @notice Token implementation cloned for non-taxable tokens. Anti-sniper protection is a gated
    ///         feature of this same impl (enabled at init from `AntiSniperConfigs`), not a separate impl.
    address public immutable TOKEN_IMPL_BASE;
    /// @notice Token implementation cloned for taxable tokens (static tax and/or launch-tax decay).
    ///         Anti-sniper protection is a gated feature of this same impl, not a separate impl.
    address public immutable TOKEN_IMPL_TAX;

    /// @notice Factory that deploys the per-token creator-vault clones.
    IRealmCreatorVaultFactory public immutable CREATOR_VAULT_FACTORY;

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

    /// @notice Cap on the aggregate fee a swapper pays (LP fee + tax), in basis points. Fixed at 5%.
    ///         Enforced per call by `_validateTotalFee`. The tax headroom is venue-dependent because
    ///         the LP fee varies: V2 has no LP fee, so tax can reach the full 5%; V4 charges 50 or
    ///         100 bps in LP fees, leaving 450 or 400 bps for tax.
    uint256 public constant MAX_TOTAL_FEE_BPS = 500;

    /// @notice Total token supply minted per token. Mirrors `RealmToken.TOTAL_SUPPLY`; used to size
    ///         creator-vault allocations from their bps.
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice Max number of creator vaults a single token can have.
    uint256 public constant MAX_CREATOR_VAULTS = 5;

    /// @notice Creator-vault allocation granularity (5% in bps). Each vault must lock a multiple.
    uint256 public constant CREATOR_VAULT_BPS_STEP = 500;

    /// @notice Max total supply lockable across all creator vaults (30% in bps).
    uint256 public constant MAX_CREATOR_VAULT_TOTAL_BPS = 3_000;

    /// @notice Sets up the factory's immutables on the implementation. The implementation itself is
    ///         not meant to be used directly — `_disableInitializers()` locks its proxy storage so
    ///         only proxies pointing to this implementation can be initialized.
    /// @dev    Immutables are read from the implementation's bytecode through delegatecall, so they
    ///         work transparently behind the UUPS proxy. To change any of them, deploy a new impl
    ///         with different constructor args and call `upgradeTo` on the proxy.
    /// @param creatorVaultFactory Factory that deploys creator-vault clones
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
    ) {
        LAUNCHPAD = IRealmLaunchpad(launchpad);
        BONDING_CURVE = IRealmBondingCurve(bondingCurve);
        GRADUATOR = IRealmGraduator(graduator);
        MASTER_FEE_HANDLER = IRealmMasterFeeHandler(masterFeeHandler);
        TOKEN_IMPL_BASE = impls.base;
        TOKEN_IMPL_TAX = impls.tax;
        CREATOR_VAULT_FACTORY = IRealmCreatorVaultFactory(creatorVaultFactory);
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
        _disableInitializers();
    }

    /// @notice One-shot initializer for the proxy. Sets `msg.sender` as the initial owner.
    /// @dev    Must be called atomically with proxy deployment (via `ERC1967Proxy`'s constructor
    ///         init-data) so no one else can front-run ownership.
    function initialize() external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    /// @dev UUPS upgrade gate: only the owner can swap the implementation.
    function _authorizeUpgrade(address) internal override onlyOwner {}

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

    /// @dev Validates a FeeShare array: non-empty, no zero accounts, no duplicates, every share > 0,
    ///      sum == 10 000, and at most one entry has `directFeesEnabled = true`. The factory caps
    ///      direct receivers at 1 here as a user-surface constraint
    function _validateFeeShares(FeeShare[] memory feeReceivers) internal pure {
        uint256 len = feeReceivers.length;
        require(len > 0, InvalidFeeReceiver());

        uint256 total;
        uint256 directCount;
        for (uint256 i = 0; i < len;) {
            require(feeReceivers[i].account != address(0), InvalidFeeReceiver());
            require(feeReceivers[i].shares > 0, InvalidShares());
            for (uint256 j = i + 1; j < len;) {
                require(feeReceivers[i].account != feeReceivers[j].account, InvalidFeeReceiver());
                unchecked {
                    ++j;
                }
            }
            total += feeReceivers[i].shares;
            if (feeReceivers[i].directFeesEnabled) {
                directCount++;
            }
            unchecked {
                ++i;
            }
        }
        require(total == BASIS_POINTS, InvalidShares());
        require(directCount <= 1, MultipleDirectFeeReceivers());
    }

    /// @dev Validates a SupplyShare array: non-empty, no zero accounts, no duplicates, every share > 0, sum == 10 000.
    function _validateSupplyShares(SupplyShare[] calldata supplyShares) internal pure {
        uint256 len = supplyShares.length;
        require(len > 0, InvalidSupplyShares());

        uint256 total;
        for (uint256 i = 0; i < len;) {
            require(supplyShares[i].account != address(0), InvalidSupplyShares());
            require(supplyShares[i].shares > 0, InvalidShares());
            for (uint256 j = i + 1; j < len;) {
                require(supplyShares[i].account != supplyShares[j].account, InvalidSupplyShares());
                unchecked {
                    ++j;
                }
            }
            total += supplyShares[i].shares;
            unchecked {
                ++i;
            }
        }
        require(total == BASIS_POINTS, InvalidShares());
    }

    /// @dev Buys supply with `msg.value` and distributes it to `supplyShares` proportionally.
    ///      Rounding dust goes to the last recipient so no tokens remain in the factory. There is no
    ///      per-deploy buy cap: the buy is bounded only by graduation — the launchpad/curve accept ETH
    ///      up to `graduationThreshold + maxExcessOverThreshold` and revert `MaxEthReservesExceeded`
    ///      beyond it (a buy that reaches the threshold graduates the token in this same tx). Use
    ///      `maxBuyOnDeploy` to size a buy up to the instant-graduation point without risking that revert.
    /// @dev deployer-buy receivers bypass the sniper-protection features
    function _buyAndDistribute(address token, SupplyShare[] calldata supplyShares) internal {
        uint256 tokensBought = LAUNCHPAD.buyTokensWithExactEth{value: msg.value}(token, 0, block.timestamp);

        uint256 len = supplyShares.length;
        address[] memory recipients = new address[](len);
        uint256[] memory amounts = new uint256[](len);

        uint256 lastIdx = len - 1;
        uint256 distributed;
        for (uint256 i = 0; i < lastIdx;) {
            uint256 amount = tokensBought * supplyShares[i].shares / BASIS_POINTS;
            recipients[i] = supplyShares[i].account;
            amounts[i] = amount;
            distributed += amount;
            IERC20(token).safeTransfer(supplyShares[i].account, amount);
            unchecked {
                ++i;
            }
        }
        // last recipient absorbs rounding dust
        uint256 lastAmount = tokensBought - distributed;
        recipients[lastIdx] = supplyShares[lastIdx].account;
        amounts[lastIdx] = lastAmount;
        IERC20(token).safeTransfer(supplyShares[lastIdx].account, lastAmount);

        emit BuyOnDeploy(token, msg.sender, msg.value, tokensBought, recipients, amounts);
    }

    /// @dev Shared preamble for every factory's `createToken`: validates name/symbol and the fee
    ///      and supply share arrays. Single source of truth so both factories' `createToken`
    ///      have all input validation co-located at the top.
    function _validateInputs(
        string memory name,
        string memory symbol,
        FeeShare[] memory feeReceivers,
        SupplyShare[] calldata supplyShares
    ) internal {
        _validateNameSymbol(name, symbol);
        _validateFeeShares(feeReceivers);
        if (msg.value > 0) _validateSupplyShares(supplyShares);
        else require(supplyShares.length == 0, InvalidSupplyShares());
    }

    /// @dev Enforces anti-sniper sentinel consistency. A zero window disables anti-sniper dispatch,
    ///      so all other anti-sniper inputs must also be empty/zero.
    function _validateAntiSniperConfig(AntiSniperConfigs calldata cfg) internal pure {
        if (cfg.protectionWindowSeconds == 0) {
            require(
                cfg.maxBuyPerTxBps == 0 && cfg.maxWalletBps == 0 && cfg.whitelist.length == 0, InvalidAntiSniperConfig()
            );
        }
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

    /// @dev Single shared `createToken` body called by both `createToken` overloads on each unified
    ///      factory (legacy positional + tiered struct-based). Centralises validation → dispatch →
    ///      launch → finalize so both signatures emit the exact same events in the same order.
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
    /// @dev `tokenSetup` is `memory` so the legacy positional overload — whose ABI takes flat
    ///      calldata args — can build a `TokenSetupTiered` in memory and call this same umbrella. The
    ///      string/`FeeShare[]` propagation forces `_validateInputs`/`_validateNameSymbol`/
    ///      `_validateFeeShares`/`_dispatchAndInitialize`/`_cloneAndCreateToken`/`_finalizeCreation`
    ///      to accept `memory` for those fields too. Once the legacy overload is removed, switch
    ///      `tokenSetup` (and the cascaded fields) back to `calldata` to skip the one-time copy
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

    /// @dev Validates the creator-vault array and returns the aggregate allocation.
    ///      Rules: at most `MAX_CREATOR_VAULTS` vaults; each `owner != 0`; each `supplyBps` a
    ///      non-zero multiple of `CREATOR_VAULT_BPS_STEP` (5%); the SUM `<= MAX_CREATOR_VAULT_TOTAL_BPS`
    ///      (30%). An empty array means no vaults (returns 0, 0). Cliff/vesting durations are
    ///      unconstrained here — any value is harmless and only affects the vault's own owner.
    function _validateCreatorVaults(CreatorVault[] memory creatorVaults)
        internal
        pure
        returns (uint256 totalBps, uint256 vaultAllocation)
    {
        uint256 len = creatorVaults.length;
        // exit with no-op
        if (len == 0) return (0, 0);

        require(len <= MAX_CREATOR_VAULTS, TooManyCreatorVaults());

        for (uint256 i = 0; i < len;) {
            CreatorVault memory v = creatorVaults[i];
            require(v.owner != address(0), InvalidCreatorVault());
            require(v.supplyBps != 0 && v.supplyBps % CREATOR_VAULT_BPS_STEP == 0, InvalidCreatorVault());
            totalBps += v.supplyBps;
            unchecked {
                ++i;
            }
        }

        require(totalBps <= MAX_CREATOR_VAULT_TOTAL_BPS, CreatorVaultAllocationTooHigh());
        vaultAllocation = TOTAL_SUPPLY * totalBps / BASIS_POINTS;
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

    /// @dev Deploys one `RealmCreatorVault` per entry via the vault factory and funds each with its
    ///      token allocation from the supply minted to this factory during token init. Asserts the
    ///      factory ends with zero token balance, i.e. the per-vault amounts summed to exactly
    ///      `vaultAllocation` (they do by construction; the check guards against future drift).
    function _deployAndFundVaults(address token, CreatorVault[] memory creatorVaults, uint256 vaultAllocation)
        internal
    {
        uint256 len = creatorVaults.length;
        address[] memory vaults = new address[](len);
        uint256[] memory amounts = new uint256[](len);

        for (uint256 i = 0; i < len;) {
            CreatorVault memory v = creatorVaults[i];
            uint256 amount = TOTAL_SUPPLY * v.supplyBps / BASIS_POINTS;
            address vault = CREATOR_VAULT_FACTORY.createVault(token, v.owner, amount, v.cliffSeconds, v.vestingSeconds);
            IERC20(token).safeTransfer(vault, amount);
            vaults[i] = vault;
            amounts[i] = amount;
            unchecked {
                ++i;
            }
        }

        require(IERC20(token).balanceOf(address(this)) == 0, CreatorVaultDistributionFailed());
        emit CreatorVaultsCreated(token, vaultAllocation, vaults, amounts);
    }

    /// @dev Shared name/symbol validation. Single source of truth — called once from `_validateInputs`
    ///      for both V2 and V4 factories.
    function _validateNameSymbol(string memory name, string memory symbol) internal pure {
        require(bytes(name).length > 0 && bytes(symbol).length > 0, InvalidNameOrSymbol());
        require(bytes(symbol).length <= 96, InvalidNameOrSymbol());
    }

    /// @notice Pre-graduation LP/trading fee (bps) the launchpad charges on bonding-curve trades for a
    ///         token whose post-graduation venue is `graduator`. A fixed per-venue rate, decoupled from the
    ///         post-graduation LP fee: V4 charges 1% regardless of the token's 50/100-bps post-graduation
    ///         hook fee; V2 has no post-graduation LP fee and returns its own fixed pre-graduation rate.
    ///         Split between treasury and creator by `_launchpadTreasuryShareBps`.
    function _launchpadLpFeeBps(address graduator) internal view virtual returns (uint16);

    /// @notice Share of the pre-graduation LP fee routed to the treasury (bps); the remainder goes to
    ///         the creator. Venue-specific protocol policy fixed at the factory level, not deployer-set.
    function _launchpadTreasuryShareBps() internal pure virtual returns (uint16);

    /// @dev Clones the resolved token implementation deterministically, enforces the `0x1110` vanity
    ///      suffix, emits `TokenCreated`, and returns the freshly-deployed token plus a fully-populated
    ///      `InitializeParams` for the caller to pass to the impl-specific `initialize()` overload.
    ///      `TokenCreated` is emitted BEFORE `initialize()` because the indexer creates the TokenData
    ///      entity from that event; events emitted inside `initialize()` depend on it.
    /// @dev The CREATE2 salt is namespaced by the deployer (`msg.sender`): the address is a function of
    ///      `(factory, impl, msg.sender, salt)`, not just `(factory, impl, salt)`. This gives every
    ///      deployer a private address space so a previewed/reserved address is reachable ONLY by the
    ///      account that reserved it. Without it, the token address is public-input-only and an attacker
    ///      could lift the salt from a pending `createToken` tx and front-run the deployment of a
    ///      pre-announced address with their own fee receivers. Namespacing lets the rest of the config
    ///      (fee receivers, anti-sniper, tax, …) stay deferred to reveal time with no front-running
    ///      window. Frontends MUST apply the same `keccak256(deployer, salt)` derivation when predicting
    ///      the address and mining the `0x1110` vanity suffix.
    function _cloneAndCreateToken(
        address impl,
        string memory name,
        string memory symbol,
        bytes32 salt,
        address tokenOwner,
        address graduator,
        uint16 swapLpFeeBps,
        uint256 vaultAllocation
    ) internal returns (address token, IRealmToken.InitializeParams memory params) {
        token = Clones.cloneDeterministic(impl, keccak256(abi.encodePacked(msg.sender, salt)));
        // forge-lint: disable-next-line(unsafe-typecast)
        require(uint16(uint160(token)) == 0x1110, InvalidTokenAddress());

        emit TokenCreated(token, name, symbol, tokenOwner, address(LAUNCHPAD), graduator, address(MASTER_FEE_HANDLER));

        params = IRealmToken.InitializeParams({
            name: name,
            symbol: symbol,
            tokenOwner: tokenOwner,
            graduator: graduator,
            launchpad: address(LAUNCHPAD),
            feeHandler: address(MASTER_FEE_HANDLER),
            vaultAllocation: vaultAllocation,
            // Pre-graduation LP-fee policy carried by the token and read by the launchpad each trade. A
            // fixed per-venue rate, decoupled from the post-graduation LP fee (V4: 1% regardless of the
            // token's 50/100-bps hook fee; V2: a fixed rate, as V2 has no post-graduation LP fee). The
            // treasury/creator split is venue-specific protocol policy. The creator tax is NOT stored here —
            // taxable variants store it from `TaxConfigs` in `_initializeTaxConfig`, and it applies
            // identically pre- and post-graduation. Non-tax tokens carry none (`getLaunchpadFees` returns 0 tax).
            lpFeeBps: _launchpadLpFeeBps(graduator),
            treasuryShareBps: _launchpadTreasuryShareBps(),
            // Post-graduation LP fee the `RealmSwapHook` charges on V4 swaps (50/100); 0 for V2. Surfaced
            // by the token via `getSwapFees` so the single hook reads each token's fee tier directly.
            swapLpFeeBps: swapLpFeeBps
        });
    }

    /// @dev Lifts a legacy `TaxConfigInit` (static tax only) into the full `TaxConfigs`, leaving the three
    ///      launch-decay fields zeroed. The two backwards-compatible `createToken` overloads call this so
    ///      the whole internal pipeline (`_validateTotalFee`, `_createToken` and everything below it)
    ///      operates on a single `TaxConfigs` type; launch-tax decay is reachable only via the new overload
    ///      that takes a `TaxConfigs` directly.
    function _toTaxConfigs(TaxConfigInit calldata legacy) internal pure returns (TaxConfigs memory cfg) {
        cfg.buyTaxBps = legacy.buyTaxBps;
        cfg.sellTaxBps = legacy.sellTaxBps;
        cfg.taxDurationSeconds = legacy.taxDurationSeconds;
        cfg.startTaxFromLaunch = legacy.startTaxFromLaunch;
        // buyTaxDecayStartBps / sellTaxDecayStartBps / taxDecayDuration stay 0 — no decay on the legacy path.
    }

    /// @dev Strips the `earningsAllocation` split off a `TaxConfigsWithAllocation`, returning the plain
    ///      `TaxConfigs` the shared creation pipeline consumes. The allocation bps are read separately by
    ///      the allocation-aware overload and forwarded to `initializeEarningsAllocation`.
    function _toTaxConfigs(TaxConfigsWithAllocation calldata c) internal pure returns (TaxConfigs memory cfg) {
        cfg.buyTaxBps = c.buyTaxBps;
        cfg.sellTaxBps = c.sellTaxBps;
        cfg.taxDurationSeconds = c.taxDurationSeconds;
        cfg.startTaxFromLaunch = c.startTaxFromLaunch;
        cfg.buyTaxDecayStartBps = c.buyTaxDecayStartBps;
        cfg.sellTaxDecayStartBps = c.sellTaxDecayStartBps;
        cfg.taxDecayDuration = c.taxDecayDuration;
    }

    /// @dev Same, for the multi-asset allocation variant. The two structs share their leading fields by
    ///      construction; only the nested allocation differs, and that is read by the overload itself.
    function _toTaxConfigs(TaxConfigsWithMultiAllocation calldata c) internal pure returns (TaxConfigs memory cfg) {
        cfg.buyTaxBps = c.buyTaxBps;
        cfg.sellTaxBps = c.sellTaxBps;
        cfg.taxDurationSeconds = c.taxDurationSeconds;
        cfg.startTaxFromLaunch = c.startTaxFromLaunch;
        cfg.buyTaxDecayStartBps = c.buyTaxDecayStartBps;
        cfg.sellTaxDecayStartBps = c.sellTaxDecayStartBps;
        cfg.taxDecayDuration = c.taxDecayDuration;
    }

    /// @dev Validates a tax config. The static tax and the decay add-on are validated INDEPENDENTLY,
    ///      each with its own sentinel consistency (zero duration ⇒ zero bps, and vice-versa) so a token
    ///      may configure either, both, or neither — in particular a "decay-only" token sets just the
    ///      decay fields with no long-term static tax.
    ///      - Static: `taxDurationSeconds` capped at `MAX_TAX_DURATION_SECONDS` (120 years — an
    ///        overflow-prevention bound from `uint32` packing); the static-bps ceiling is venue-dependent
    ///        and enforced separately by `_validateTotalFee`.
    ///      - Decay: combined start bps (`buy + sell`) capped at `MAX_TAX_DECAY_START_COMBINED_BPS` (20%) and duration at
    ///        `MAX_TAX_DECAY_DURATION_SECONDS` (20 min). The decay bps are NOT part of `_validateTotalFee`
    ///        (the effective rate is `max(decay, static)`, not their sum); the launchpad's own per-trade
    ///        `MAX_TRADING_FEE_BPS` backstops the LP fee + decay total. Each configured decay start must be
    ///        strictly above its direction's static rate (`buyTaxDecayStartBps > buyTaxBps`, same for sell) —
    ///        the decay interpolates down to the static rate, so a start at or below it would never decay.
    ///        Checked per direction and only when that start is set, so single-direction and decay-only
    ///        (static 0) configs stay valid.
    ///      - Both: if a static tax AND a decay are configured, the static window must cover the decay
    ///        window (`taxDurationSeconds >= taxDecayDuration`) — the decay interpolates down to the static
    ///        rate, so a shorter static window would leave the long-term static tax effectively unused.
    ///      No fee-receiver or ownership constraints are imposed at any duration.
    function _validateTaxConfig(TaxConfigs memory t) internal pure {
        if (t.taxDurationSeconds != 0) {
            require(t.buyTaxBps > 0 || t.sellTaxBps > 0, InvalidTaxConfig());
            require(t.taxDurationSeconds <= MAX_TAX_DURATION_SECONDS, InvalidTaxDuration());
        } else {
            require(t.buyTaxBps == 0 && t.sellTaxBps == 0, InvalidTaxConfig());
        }

        if (t.taxDecayDuration != 0) {
            require(t.buyTaxDecayStartBps > 0 || t.sellTaxDecayStartBps > 0, InvalidTaxConfig());
            require(t.taxDecayDuration <= MAX_TAX_DECAY_DURATION_SECONDS, InvalidTaxDuration());
            require(
                uint256(t.buyTaxDecayStartBps) + t.sellTaxDecayStartBps <= MAX_TAX_DECAY_START_COMBINED_BPS,
                InvalidTaxBps()
            );
            // A configured decay must START strictly ABOVE its long-term static rate (per direction): the
            // decay interpolates DOWN to the static rate, so a start at or below it would never decay (the
            // effective `max(decay, static)` would just hold the static rate). Guarded per direction so a
            // single-direction decay (the other start 0) — and a decay-only token (static 0) — stay valid.
            if (t.buyTaxDecayStartBps != 0) require(t.buyTaxDecayStartBps > t.buyTaxBps, InvalidTaxBps());
            if (t.sellTaxDecayStartBps != 0) require(t.sellTaxDecayStartBps > t.sellTaxBps, InvalidTaxBps());
            // When BOTH a static tax and a decay are configured, the static window must cover the decay
            // window: the decay interpolates DOWN to the static rate, so a static window shorter than the
            // decay window would leave the long-term static tax effectively unused (it would expire before
            // the decay reaches it). A cliff at the static window's end is still expected — this only rules
            // out the degenerate config where the static duration plays no part.
            if (t.taxDurationSeconds != 0) {
                require(t.taxDurationSeconds >= t.taxDecayDuration, InvalidTaxDuration());
            }
        } else {
            require(t.buyTaxDecayStartBps == 0 && t.sellTaxDecayStartBps == 0, InvalidTaxConfig());
        }
    }

    /// @dev Caps the POST-graduation total fee a swapper pays (LP fee + tax) at `MAX_TOTAL_FEE_BPS`
    ///      (5%). Applied to buy and sell tax independently since a swap only ever pays one direction.
    ///      `lpFeeBps` is the venue's post-graduation LP fee — 0 for V2 (no LP fee, so tax can reach the
    ///      full 5%), 50 or 100 for V4 (leaving 450/400 bps for tax). Pre-graduation the launchpad
    ///      additionally charges its own LP fee on top of the tax; that transient total is bounded by
    ///      the launchpad's (looser) `MAX_TRADING_FEE_BPS`, not here. `taxCfg` bps are unbounded here, so
    ///      the sum is widened to `uint256` to avoid a spurious overflow revert before this check fires.
    function _validateTotalFee(uint256 lpFeeBps, TaxConfigs memory taxCfg) internal pure {
        require(
            lpFeeBps + taxCfg.buyTaxBps <= MAX_TOTAL_FEE_BPS && lpFeeBps + taxCfg.sellTaxBps <= MAX_TOTAL_FEE_BPS,
            InvalidTaxBps()
        );
    }

    /// @dev A token uses the taxable impl family if it configures a long-term static tax OR the launch
    ///      decay add-on. Decay-only tokens (no static tax) still need the taxable impl: post-graduation
    ///      tax collection (V2 intrinsic swap-back / V4 hook plumbing) lives only there.
    function _isTaxConfigured(TaxConfigs memory t) internal pure returns (bool) {
        return t.taxDurationSeconds != 0 || t.taxDecayDuration != 0;
    }

    /// @dev Whether the token configures a LONG-TERM static tax (a decay-only token returns false).
    ///      Gate for the earnings allocation: the decay window is capped at 20 minutes, so a decay-only
    ///      token has no meaningful post-graduation tax stream to split — its allocation would only ever
    ///      apply to the LP-fee creator share, which is not what the split is for.
    function _hasStaticTax(TaxConfigs memory t) internal pure returns (bool) {
        return t.taxDurationSeconds != 0;
    }

    /// @dev Buy tax (bps) the launchpad will charge on the deploy buy inside `createToken`. Only a
    ///      creation-anchored window (`startTaxFromLaunch`) is open at creation; a graduation-anchored
    ///      one charges no tax pre-graduation, so the deploy buy pays the LP fee alone. The deploy buy
    ///      lands at elapsed≈0, so the effective rate is `max(decay start, static)` — the same value the
    ///      token's `getLaunchpadFees` returns at launch. Used by the concrete factories'
    ///      `quoteBuyOnDeploy` so the quote matches the fee actually charged.
    /// @dev Design decision: the deployer's own deploy buy is intentionally taxed (no buyer-identity
    ///      exemption) — tax stays a pure function of (window, direction), keeping quotes caller-independent.
    //       If deployer==tax receiver, there is no extra cost, as all taxes go to the deployer anyway.
    function _deployBuyTaxBps(TaxConfigs memory taxCfg) internal pure returns (uint256) {
        if (!taxCfg.startTaxFromLaunch) return 0;
        uint256 staticBps = taxCfg.buyTaxBps;
        uint256 decayBps = taxCfg.buyTaxDecayStartBps;
        return decayBps > staticBps ? decayBps : staticBps;
    }

    /// @dev Single source of truth for which implementation `createToken` will clone for a given
    ///      `taxCfg`. Both the public `previewTokenImplementation` (used by frontends to mine a
    ///      `0x1110`-suffixed salt) and `_dispatchAndInitialize` (the path that actually clones the
    ///      impl) read from this function — so a salt that previews to a vanity-suffixed address is
    ///      guaranteed to also produce one at create time.
    /// @dev Anti-sniper is deliberately NOT a dispatch input: it is a gated feature of both impls, so
    ///      the impl (and therefore the pre-generated token address) depends only on whether the token
    ///      is taxable. `antiSniperCfg` is still accepted so the preview signature mirrors the full
    ///      `createToken` input set and stays ABI-stable if that changes.
    function _previewTokenImplementation(
        TaxConfigs memory taxCfg,
        AntiSniperConfigs calldata /* antiSniperCfg */
    )
        internal
        view
        returns (address)
    {
        return _isTaxConfigured(taxCfg) ? TOKEN_IMPL_TAX : TOKEN_IMPL_BASE;
    }

    /// @dev Resolves the implementation for `taxCfg` (tax vs non-tax — anti-sniper does NOT change the
    ///      impl), clones it, and runs the matching `initialize`. The ONLY branch is tax vs non-tax:
    ///      both impls take the `AntiSniperConfigs` and enable protection internally iff it opts in
    ///      (`protectionWindowSeconds != 0`), so the factory always forwards it and never branches on
    ///      anti-sniper. Impl resolution shares `_previewTokenImplementation` with the public preview,
    ///      so a salt that previews to a `0x1110` address also clones to one. Callers (`createToken` on
    ///      the derived factory) invoke `LAUNCHPAD.launchToken` and `_finalizeCreation` (which registers
    ///      the token's fee config with the master handler) after this returns.
    function _dispatchAndInitialize(
        string memory name,
        string memory symbol,
        bytes32 salt,
        address tokenOwner,
        address graduator,
        uint16 swapLpFeeBps,
        uint256 vaultAllocation,
        TaxConfigs memory taxCfg,
        AntiSniperConfigs calldata antiSniperCfg
    ) internal returns (address token) {
        address impl = _previewTokenImplementation(taxCfg, antiSniperCfg);

        IRealmToken.InitializeParams memory params;
        (token, params) =
            _cloneAndCreateToken(impl, name, symbol, salt, tokenOwner, graduator, swapLpFeeBps, vaultAllocation);

        if (_isTaxConfigured(taxCfg)) {
            // Taxable impl: stores the tax rate from `taxCfg` in `_initializeTaxConfig`.
            IRealmTaxableToken(payable(token)).initialize(params, taxCfg, antiSniperCfg);
        } else {
            // Non-tax impl: `taxCfg` is empty (validated); base `getLaunchpadFees` returns 0 tax.
            RealmToken(token).initialize(params, antiSniperCfg);
        }
    }

    /// @dev Reserved for future storage variables. Decrement when adding new storage to keep the
    ///      proxy's slot layout stable across upgrades. Never reorder existing storage.
    uint256[50] private __gap;
}
