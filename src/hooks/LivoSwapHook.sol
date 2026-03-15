// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseHook} from "lib/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";

/// @title LivoSwapHook
/// @notice Uniswap V4 hook that collects LP fees and time-limited sell taxes on token swaps
/// @dev Singleton hook serving all taxable tokens graduated via LivoGraduatorUniswapV4
/// @dev Hook charges 1% LP fee (split 50/50 creator/treasury) on all swaps, plus sell tax during tax period
contract LivoSwapHook is BaseHook {
    error NoSwapsBeforeGraduation();
    error EthTransferFailed();

    /// @notice Emitted when creator taxes are accrued from a taxed swap
    event CreatorTaxesAccrued(address indexed token, uint256 amount);
    /// @notice Emitted when LP fees are accrued
    event LpFeesAccrued(address indexed token, uint256 creatorShare, uint256 treasuryShare);

    /// @notice Basis points denominator (10000 = 100%)
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice LP fee rate in basis points (1%)
    uint256 private constant LP_FEE_BPS = 100;

    /// @notice Launchpad contract for resolving treasury address
    address public immutable LAUNCHPAD;

    /// @notice Initializes the hook with the pool manager and launchpad addresses
    /// @param _poolManager The Uniswap V4 pool manager contract
    /// @param _launchpad The Livo launchpad contract
    constructor(IPoolManager _poolManager, address _launchpad) BaseHook(_poolManager) {
        LAUNCHPAD = _launchpad;
    }

    /// @notice Allows contract to receive ETH from `poolManager.take()`
    /// @dev ETH should never remain in this contract between transactions. If it does, it is accepted as stuck.
    ///      Adding a rescue mechanism would require `Ownable`, which is avoided to keep this singleton hook minimal and ownerless.
    receive() external payable {}

    /// @notice Returns the hook permissions indicating which callbacks are implemented
    /// @dev Hook address must have these permission flags encoded in its address (via CREATE2)
    /// @return Permissions struct with beforeSwap, afterSwap, beforeSwapReturnDelta, and afterSwapReturnDelta set to true
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Hook callback executed before each swap to check graduation and charge LP fees on buys
    /// @param key The pool key identifying the pool
    /// @param params The swap parameters including direction
    /// @return bytes4 The function selector
    /// @return BeforeSwapDelta The delta representing ETH taken as LP fee (buys only)
    /// @return uint24 Always 0 (no dynamic fee override)
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address tokenAddress = Currency.unwrap(key.currency1);

        // Check if token has graduated. Swaps not allowed before graduation
        if (!ILivoToken(tokenAddress).graduated()) {
            revert NoSwapsBeforeGraduation();
        }

        // Only charge LP fee on buys (swapping ETH→tokens, zeroForOne=true)
        // Sells are handled in afterSwap where we know the ETH output amount
        if (!params.zeroForOne) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // BUY: charge 1% LP fee on ETH input before the swap
        // amountSpecified is negative for exact-input swaps
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 absAmount = uint256(-params.amountSpecified);
        uint256 feeAmount = (absAmount * LP_FEE_BPS) / BASIS_POINTS;

        // Calculate buy tax if applicable
        (bool shouldTax, uint16 taxBps) = _getTaxParams(tokenAddress, true);
        uint256 taxAmount = shouldTax ? (absAmount * taxBps) / BASIS_POINTS : 0;

        uint256 totalFee = feeAmount + taxAmount;

        // Take ETH from the pool to this contract
        poolManager.take(key.currency0, address(this), totalFee);

        // Split and deposit LP fee + buy tax
        _accrue(tokenAddress, feeAmount, taxAmount);

        // Return delta: positive deltaSpecified means hook is taking from the specified (input) currency
        // forge-lint: disable-next-line(unsafe-typecast)
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(totalFee)), 0), 0);
    }

    /// @notice Hook callback executed after each swap to collect sell taxes and LP fees on sells
    /// @param key The pool key identifying the pool
    /// @param params The swap parameters including direction
    /// @param delta The balance changes from the swap
    /// @return bytes4 The function selector to indicate successful execution
    /// @return int128 The total fee amount taken from the pool (positive = hook took from pool)
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // Only charge fees on sells (tokens→ETH, zeroForOne=false)
        // Buy LP fees are handled in beforeSwap
        if (params.zeroForOne) {
            return (IHooks.afterSwap.selector, 0);
        }

        address tokenAddress = Currency.unwrap(key.currency1);

        // ETH output from the swap (amount0 is positive for sells = ETH going out)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 absEthAmount = uint256(uint128(delta.amount0()));

        // Calculate LP fee on gross ETH output
        uint256 lpFee = (absEthAmount * LP_FEE_BPS) / BASIS_POINTS;

        // Calculate sell tax if applicable
        (bool shouldTax, uint16 taxBps) = _getTaxParams(tokenAddress, false);
        uint256 taxAmount = shouldTax ? (absEthAmount * taxBps) / BASIS_POINTS : 0;

        // stack fees and taxes on top of each other
        uint256 totalFee = lpFee + taxAmount;

        // Take total fee from pool
        poolManager.take(key.currency0, address(this), totalFee);

        // Deposit LP fee (50/50 creator/treasury) + sell tax (100% creator) in a single accrueFees call
        _accrue(tokenAddress, lpFee, taxAmount);

        // forge-lint: disable-next-line(unsafe-typecast)
        return (IHooks.afterSwap.selector, int128(uint128(totalFee)));
    }

    /// @notice Get tax parameters for a token
    /// @return shouldTax Whether tax should be collected
    /// @return taxBps The tax rate in basis points
    function _getTaxParams(address tokenAddress, bool isBuy) internal view returns (bool shouldTax, uint16 taxBps) {
        ILivoToken.TaxConfig memory config = ILivoToken(tokenAddress).getTaxConfig();

        // Check if token has graduated
        if (config.graduationTimestamp == 0) {
            return (false, 0);
        }

        // Check if tax period has expired
        if (block.timestamp > config.graduationTimestamp + config.taxDurationSeconds) {
            return (false, 0);
        }

        taxBps = isBuy ? config.buyTaxBps : config.sellTaxBps;
        if (taxBps == 0) {
            return (false, 0);
        }

        return (true, taxBps);
    }

    /// @notice Deposit LP fee (50/50 creator/treasury) and optional sell tax (100% creator) in a single accrueFees call
    /// @param tokenAddress The token whose creator receives fees
    /// @param lpFeeAmount The total LP fee to split 50/50
    /// @param taxAmount The sell tax amount (100% to creator), 0 on buys
    function _accrue(address tokenAddress, uint256 lpFeeAmount, uint256 taxAmount) internal {
        uint256 treasuryShare = lpFeeAmount / 2;
        uint256 creatorLpShare = lpFeeAmount - treasuryShare;

        // Single accrueFees call: creator LP share + sell tax
        uint256 creatorTotal = creatorLpShare + taxAmount;

        // emit events for accounting purposes
        emit LpFeesAccrued(tokenAddress, creatorLpShare, treasuryShare);
        if (taxAmount > 0) {
            emit CreatorTaxesAccrued(tokenAddress, taxAmount);
        }

        ILivoToken(tokenAddress).accrueFees{value: creatorTotal}();

        // Treasury share via direct transfer
        address treasury = ILivoLaunchpad(LAUNCHPAD).treasury();
        (bool success,) = treasury.call{value: treasuryShare}("");
        require(success, EthTransferFailed());
    }
}
