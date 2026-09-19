// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RealmTaxableTokenUniV4Base} from "src/tokens/RealmTaxableTokenUniV4Base.sol";
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
/// @dev EVERY out-of-band keeper entry point is a thin `delegatecall` stub: `processDividends` and
///      `claimDividends` into `DIVIDEND_LOGIC`, `processBurn` and `processLiquidity` into
///      `EARNINGS_LOGIC`. Only their bodies live elsewhere, and nothing on the swap hot path does. See
///      `RealmDividendLogicUniV4` and `RealmEarningsLogicUniV4`.
contract RealmTaxableTokenUniV4 is RealmTaxableTokenUniV4Base {
    /// @notice The `RealmDividendLogicUniV4` extension the dividend entry points `delegatecall` into.
    /// @dev Immutable, so clones read it straight from the implementation.
    address public immutable DIVIDEND_LOGIC;

    /// @notice The `RealmEarningsLogicUniV4` extension `processBurn` / `processLiquidity` delegate into.
    address public immutable EARNINGS_LOGIC;

    /// @notice Thrown when either extension address is zero. The token would be deployable but every
    ///         out-of-band entry point on it would `delegatecall` into nothing and silently succeed.
    error InvalidExtension();

    //////////////////////////////////////////////////////

    /// @notice Creates a new RealmTaxableTokenUniV4 instance which will be used as implementation for clones
    /// @dev Token configuration is set during initialization, not in constructor.
    /// @dev The two extensions are PASSED IN rather than deployed here. They used to be deployed by this
    ///      constructor — the pair is storage-layout-coupled, so making it atomic removed one thing that
    ///      could be wired wrong — but their creation code counts toward this contract's own initcode,
    ///      and with both of them it no longer fits under EIP-3860. Deploy them first, in the same
    ///      script, and `just check-dividend-layout` still pins both layouts against this token's.
    /// @param dividendLogic_ A freshly deployed `RealmDividendLogicUniV4`.
    /// @param earningsLogic_ A freshly deployed `RealmEarningsLogicUniV4`.
    constructor(address dividendLogic_, address earningsLogic_) RealmToken() {
        require(block.chainid == DeploymentAddresses.BLOCKCHAIN_ID, "configuration for wrong chainId");
        require(dividendLogic_ != address(0) && earningsLogic_ != address(0), InvalidExtension());
        DIVIDEND_LOGIC = dividendLogic_;
        EARNINGS_LOGIC = earningsLogic_;
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
        _delegateTo(EARNINGS_LOGIC);
    }

    /// @notice Same, on ONE of the token's pools. `quote` picks which — `address(0)` is the native one,
    ///         which the no-argument overload above targets.
    function processBurn(address quote, uint256 minTokensOut) external {
        quote;
        minTokensOut;
        _delegateTo(EARNINGS_LOGIC);
    }

    /// @notice Deposits the accrued liquidity ETH as a single-sided ETH position just below the current
    ///         price — a protective bid wall. Keeper-gated, once per block, spending at most
    ///         `MAX_EARNINGS_PER_PROCESS`.
    function processLiquidity() external {
        _delegateTo(EARNINGS_LOGIC);
    }

    /// @notice Same, on ONE of the token's pools. See `processBurn(address,uint256)`.
    function processLiquidity(address quote) external {
        quote;
        _delegateTo(EARNINGS_LOGIC);
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

    /// @notice Same, for a buffer held in one of this token's QUOTES: `quote == address(0)` is the
    ///         native machine above; an ERC20 quote services what that quote's pool earned, converting
    ///         it into asset `assetIndex` on the quote's own pool or through the registry. See
    ///         `RealmDividendLogicUniV4.processDividends(uint8,address,uint256,address[])`.
    function processDividends(uint8 assetIndex, address quote, uint256 minOut, address[] calldata holders) external {
        assetIndex;
        quote;
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

    /// @dev The burn slice accrues in whatever currency the pool that produced it is quoted in; the
    ///      buy-back-and-burn happens out-of-band in `processBurn`, on that same pool. Stays cheap (one
    ///      SSTORE into a slot the sibling slice shares) and consumes the slice fully — returns 0, so
    ///      nothing folds back to the fund wallets. Overrides the base fallback in `EarningsAllocation`.
    function _handleBurn(address asset, uint256 amount) internal override returns (uint256) {
        QuoteBuffers storage buf = quoteBuffers[_quoteIndex(asset)];
        uint256 updated = buf.burnPending + amount;
        require(updated <= type(uint128).max, DividendBufferOverflow());
        // forge-lint: disable-next-line(unsafe-typecast)
        buf.burnPending = uint128(updated);
        return 0;
    }

    /// @dev The liquidity slice, same shape: buffered per quote and deposited out-of-band by
    ///      `processLiquidity` as a single-sided wall on that quote's own pool.
    function _handleLiquidity(address asset, uint256 amount) internal override returns (uint256) {
        QuoteBuffers storage buf = quoteBuffers[_quoteIndex(asset)];
        uint256 updated = buf.liquidityPending + amount;
        require(updated <= type(uint128).max, DividendBufferOverflow());
        // forge-lint: disable-next-line(unsafe-typecast)
        buf.liquidityPending = uint128(updated);
        return 0;
    }

    /// @dev The dividends slice of ERC20-quoted earnings, buffered per quote AND per payout asset —
    ///      split by `dividendWeightsBps` here exactly as the native slice is split across
    ///      `pendingNative` — and converted out-of-band by `processDividends(i, quote, …)`. Two SSTOREs
    ///      at most (the three buffers pack into two slots), inside the router's gas budget.
    function _accrueQuoteDividends(address asset, uint256 amount) internal override returns (uint256) {
        uint256 n = dividendAssetCount;
        if (n == 0) return amount;
        uint128[MAX_DIVIDEND_ASSETS] storage pending = quoteBuffers[_quoteIndex(asset)].dividendPending;
        uint256 remaining = amount;
        for (uint256 i; i < n; ++i) {
            uint256 share = i + 1 == n ? remaining : amount * dividendWeightsBps[i] / DIVIDEND_BPS_TOTAL;
            remaining -= share;
            if (share == 0) continue;
            uint256 updated = uint256(pending[i]) + share;
            require(updated <= type(uint128).max, DividendBufferOverflow());
            // forge-lint: disable-next-line(unsafe-typecast)
            pending[i] = uint128(updated);
        }
        return 0;
    }

    /// @inheritdoc RealmTaxableToken
    function dividendLogic() public view override returns (address) {
        return DIVIDEND_LOGIC;
    }

    /// @inheritdoc RealmTaxableTokenUniV4Base
    function earningsLogic() public view override returns (address) {
        return EARNINGS_LOGIC;
    }

    /// @dev The payout-set configuration lives in the earnings extension on this venue: it runs once per
    ///      token, and the dividend extension has no room left for it under EIP-170.
    function _allocationLogic() internal view override returns (address) {
        return EARNINGS_LOGIC;
    }
}
