// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RealmTaxableTokenUniV4Base} from "src/tokens/RealmTaxableTokenUniV4Base.sol";
import {RealmDividendLogicUniV4} from "src/tokens/RealmDividendLogicUniV4.sol";
import {RealmTaxableToken} from "src/tokens/RealmTaxableToken.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// this line below is swapped per target chain at deploy time (the addresses are compile-time
/// constants baked into bytecode): DeploymentAddressesEthereumSepolia, DeploymentAddressesRobinhood*,
/// or DeploymentAddressesArc{Mainnet,Testnet} (ARC native currency is USDC, 18-dec at msg.value).
import {DeploymentAddressesRobinhoodTestnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

/// @title RealmTaxableTokenUniV4
/// @notice ERC20 token implementation with time-limited buy/sell taxes enforced via Uniswap V4 hooks.
/// @dev Extends `RealmTaxableTokenUniV4Base` (tax config + earnings split + the V4 buy-back primitive).
///      Tax accounting on swaps lives in `RealmSwapHook`; the token exposes the tax config via
///      `getTaxConfig()`. The earnings-allocation burn bucket is buffered here as ETH
///      (`burnPendingEth`) and processed out-of-band by `processBurn`.
/// @dev EVERY out-of-band keeper entry point (`processBurn`, `processLiquidity`, `processDividends`,
///      `claimDividends`) is a thin `delegatecall` stub into `DIVIDEND_LOGIC`; only their bodies live
///      elsewhere, and nothing on the swap hot path does. See `RealmDividendLogicUniV4`.
contract RealmTaxableTokenUniV4 is RealmTaxableTokenUniV4Base {
    /// @notice The `RealmDividendLogicUniV4` extension the out-of-band entry points `delegatecall` into.
    /// @dev Deployed by THIS constructor rather than passed in or read from a manifest: the two are
    ///      storage-layout-coupled, so pairing them at deploy time is one more thing that can be wired
    ///      wrong for no benefit. Deploying it here makes the pair atomic, keeps every deploy script and
    ///      test unchanged (`new RealmTaxableTokenUniV4()` still takes no arguments), and costs only
    ///      creation-code size on the implementation — which EIP-170 does not bound, and EIP-3860 bounds
    ///      far above what this needs. Immutable, so clones read it straight from the implementation.
    address public immutable DIVIDEND_LOGIC;

    //////////////////////////////////////////////////////

    /// @notice Creates a new RealmTaxableTokenUniV4 instance which will be used as implementation for clones
    /// @dev Token configuration is set during initialization, not in constructor
    constructor() RealmToken() {
        // All token initialization happens in initialize() due to minimal proxy pattern; the only thing
        // the implementation itself owns is its dividend extension.
        require(block.chainid == DeploymentAddresses.BLOCKCHAIN_ID, "configuration for wrong chainId");
        DIVIDEND_LOGIC = address(new RealmDividendLogicUniV4());
    }

    /// @notice Initializes the token clone with its tax configuration. Anti-sniper protection is
    ///         enabled iff `antiSniperCfg` opts in (`protectionWindowSeconds != 0`); pass an all-zero
    ///         config for a tax-only token.
    /// @param params Shared token initialization parameters
    /// @param taxCfg Tax configuration (buy/sell bps, window, optional launch-tax decay)
    /// @param antiSniperCfg Anti-sniper caps + window config (validated upstream in the factory)
    function initialize(
        IRealmToken.InitializeParams memory params,
        TaxConfigs memory taxCfg,
        AntiSniperConfigs memory antiSniperCfg
    ) external virtual initializer {
        _initializeRealmTaxableToken(params, taxCfg);
        _initializeAntiSniper(antiSniperCfg);
    }

    ////////////////////// KEEPER ENTRY POINTS (delegated) //////////////////////

    /// @notice Buys back tokens with the accrued burn ETH and burns them, reducing total supply.
    ///         Keeper-gated, once per block, spending at most `MAX_EARNINGS_PER_PROCESS`.
    /// @param minTokensOut Slippage floor — the minimum tokens the buy-back must yield, or the swap
    ///        reverts. Callers should set this from the current price; a value of 0 invites sandwiching.
    function processBurn(uint256 minTokensOut) external {
        minTokensOut;
        _delegateToDividendLogic();
    }

    /// @notice Deposits the accrued liquidity ETH as a single-sided ETH position just below the current
    ///         price — a protective bid wall. Keeper-gated, once per block, spending at most
    ///         `MAX_EARNINGS_PER_PROCESS`.
    function processLiquidity() external {
        _delegateToDividendLogic();
    }

    /// @notice Advances the dividend round by everything it is due for: freezes the pot once the buffer
    ///         has cleared its threshold, pushes payouts to `holders`, and rolls the round over once the
    ///         pot is drained. Permissionless, and the only entry point a keeper needs.
    /// @param minOut Slippage floor for the conversion, in the payout asset's own decimals. Ignored when
    ///        the payout asset is native or the token itself, and by any call that does not freeze.
    /// @param holders Addresses to push this round's payouts to. May be empty.
    function processDividends(uint256 minOut, address[] calldata holders) external {
        minOut;
        holders;
        _delegateToDividendLogic();
    }

    /// @notice Same, for one of the payout assets of a token that pays in several. `assetIndex` selects
    ///         which; each asset crosses its own threshold, prices its own floor and holds its own
    ///         per-block cooldown, so a keeper services them one call at a time.
    /// @param assetIndex Which configured payout asset to service, `0 .. dividendAssetCount() - 1`.
    /// @param minOut Slippage floor for that asset's conversion, in its own decimals.
    /// @param holders Addresses to push that asset's accrued payouts to. May be empty.
    function processDividends(uint8 assetIndex, uint256 minOut, address[] calldata holders) external {
        assetIndex;
        minOut;
        holders;
        _delegateToDividendLogic();
    }

    /// @notice Self-serve backstop for a holder the keeper missed. Same formula, same paid marker.
    function claimDividends() external {
        _delegateToDividendLogic();
    }

    ////////////////////// INTERNAL FUNCTIONS //////////////////////

    /// @inheritdoc RealmTaxableToken
    /// @dev Adds the V4 pool-manager pair check after shared init. The graduator is expected to
    ///      have set `pair == UNIV4_POOL_MANAGER` during `RealmToken._initializeRealmToken`; if not,
    ///      revert and roll back any earlier writes (storage updates already performed are
    ///      reverted with the rest of the tx, so ordering vs `_initializeTaxConfig` is irrelevant).
    function _initializeRealmTaxableToken(IRealmToken.InitializeParams memory params, TaxConfigs memory taxCfg)
        internal
        override
        onlyInitializing
    {
        super._initializeRealmTaxableToken(params, taxCfg);
        require(pair == UNIV4_POOL_MANAGER, "Invalid pair address");
    }

    /// @dev V4 burn accrues ETH (earnings are ETH-native); the buy-back-and-burn happens out-of-band
    ///      in `processBurn`, so this stays cheap (one SSTORE) and consumes the slice fully (returns 0,
    ///      nothing folds back to the fund wallets). Overrides the base fund-fallback in
    ///      `EarningsAllocation`.
    function _handleBurn(uint256 amount) internal override returns (uint256) {
        burnPendingEth += amount;
        return 0;
    }

    /// @dev V4 liquidity accrues ETH (earnings are ETH-native); the single-sided add happens out-of-band
    ///      in `processLiquidity`, so this stays cheap (one SSTORE) and consumes the slice fully (returns
    ///      0). Mirrors `_handleBurn`; overrides the base fund-fallback in `EarningsAllocation`.
    function _handleLiquidity(uint256 amount) internal override returns (uint256) {
        liquidityPendingEth += amount;
        return 0;
    }

    /// @inheritdoc RealmTaxableToken
    function dividendLogic() public view override returns (address) {
        return DIVIDEND_LOGIC;
    }
}
