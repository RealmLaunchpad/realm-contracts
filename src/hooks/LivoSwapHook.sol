// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseHook} from "lib/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

interface IGraduatorTaxCollector {
    function depositAccruedTaxes(address token, address taxRecipient) external payable;
}

/// @title LivoSwapHook
/// @notice Uniswap V4 hook that collects time-limited sell taxes on token swaps
/// @dev Singleton hook serving all taxable tokens graduated via LivoGraduatorUniswapV4
/// @dev Hook queries each token for tax configuration and applies taxes only during the configured period
contract LivoSwapHook is BaseHook {
    /// @notice Custom error for preventing swaps before graduation
    error NoSwapsBeforeGraduation();

    /// @notice Basis points denominator (10000 = 100%)
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice Initializes the hook with the pool manager address
    /// @param _poolManager The Uniswap V4 pool manager contract
    /// @dev Constructor validates that the deployed address matches the required hook permissions
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @notice Allows contract to receive ETH from poolManager.take()
    /// question for auditor: ETH could get stuck here as there is no way to rescue eth. But I don't want to make this contract Ownable, and I don't want to add a permisionless rescueEth() function to avoid introducing security risks.
    receive() external payable {}

    /// @notice Returns the hook permissions indicating which callbacks are implemented
    /// @dev Hook address must have these permission flags encoded in its address (via CREATE2)
    /// @return Permissions struct with afterSwap and afterSwapReturnDelta set to true
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // to prevent swaps without liquidity
            afterSwap: true, // to charge the taxes
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true, // to calculate how much tax should be collected
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Hook callback executed after each swap to collect taxes
    /// @param key The pool key identifying the pool
    /// @param params The swap parameters including direction
    /// @param delta The balance changes from the swap
    /// @return bytes4 The function selector to indicate successful execution
    /// @return int128 The tax amount taken from the pool (positive = hook took from pool)
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // Get token address and tax config
        address tokenAddress = Currency.unwrap(key.currency1);
        (bool shouldTax, uint16 taxBps, address taxRecipient) = _getTaxParams(tokenAddress, params.zeroForOne);

        // if tax=0 or, out of tax period, or no tax config, then we exit here without taxation
        if (!shouldTax) {
            return (IHooks.afterSwap.selector, 0);
        }

        // BUY: No tax collected on buys
        if (params.zeroForOne) {
            return (IHooks.afterSwap.selector, 0);
        }

        // SELL: Tax is taken from ETH output (seller receives less ETH)
        return _collectSellTax(key.currency0, tokenAddress, taxRecipient, delta.amount0(), taxBps);
    }

    /// @notice Prevents swaps if the token has not been graduated
    /// @param key The pool key identifying the pool
    /// @return bytes4 The function selector to indicate successful execution
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        /*params*/
        bytes calldata
    )
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Get token address (currency1 is always the token, currency0 is ETH)
        address tokenAddress = Currency.unwrap(key.currency1);

        // Check if token has graduated. Swaps not allowed before graduation
        if (!ILivoToken(tokenAddress).graduated()) {
            revert NoSwapsBeforeGraduation();
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Get tax parameters for a token
    /// @return shouldTax Whether tax should be collected
    /// @return taxBps The tax rate in basis points
    /// @return taxRecipient The token owner to whom taxes are attributed
    function _getTaxParams(address tokenAddress, bool isBuy)
        internal
        view
        returns (bool shouldTax, uint16 taxBps, address taxRecipient)
    {
        ILivoToken.TaxConfig memory config = ILivoToken(tokenAddress).getTaxConfig();

        // Check if token has graduated
        if (config.graduationTimestamp == 0) {
            return (false, 0, address(0));
        }

        // Check if tax period has expired
        if (block.timestamp > config.graduationTimestamp + config.taxDurationSeconds) {
            return (false, 0, address(0));
        }

        // buy tax will always be zero in the current tax-token implementation
        taxBps = isBuy ? config.buyTaxBps : config.sellTaxBps;
        if (taxBps == 0) {
            return (false, 0, address(0));
        }
        // In this system, `taxRecipient` is always the token owner.
        return (true, taxBps, config.taxRecipient);
    }

    /// @notice Collect sell tax in ETH and attribute it in the graduator
    function _collectSellTax(
        Currency currency,
        address tokenAddress,
        address taxRecipient,
        int128 ethDelta,
        uint16 taxBps
    ) internal returns (bytes4 selector, int128 taxCollected) {
        uint256 absEthAmount = uint256(uint128(ethDelta));
        uint256 taxAmount = (absEthAmount * taxBps) / BASIS_POINTS;

        // Take ETH to this contract first so we can forward it to the graduator
        poolManager.take(currency, address(this), taxAmount);

        address graduator = ILivoToken(tokenAddress).graduator();
        IGraduatorTaxCollector(graduator).depositAccruedTaxes{value: taxAmount}(tokenAddress, taxRecipient);

        return (IHooks.afterSwap.selector, int128(uint128(taxAmount)));
    }
}
