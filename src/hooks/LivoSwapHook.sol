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
import {ILivoTokenTaxable} from "src/interfaces/ILivoTokenTaxable.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IWETH} from "src/interfaces/IWETH.sol";

/// @title LivoSwapHook
/// @notice Uniswap V4 hook that collects time-limited buy/sell taxes on token swaps
/// @dev Singleton hook serving all taxable tokens graduated via LivoGraduatorUniswapV4
/// @dev Hook queries each token for tax configuration and applies taxes only during the configured period
contract LivoSwapHook is BaseHook {
    /// @notice Custom error for preventing swaps before graduation
    error NoSwapsBeforeGraduation();

    /// @notice Basis points denominator (10000 = 100%)
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice WETH contract address
    IWETH private immutable WETH;

    /// @notice Initializes the hook with the pool manager and WETH addresses
    /// @param _poolManager The Uniswap V4 pool manager contract
    /// @param _weth The WETH contract address for this chain
    /// @dev Constructor validates that the deployed address matches the required hook permissions
    constructor(IPoolManager _poolManager, address _weth) BaseHook(_poolManager) {
        WETH = IWETH(_weth);
    }

    /// @notice Allows contract to receive ETH from poolManager.take()
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
            afterSwapReturnDelta: true,
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

        if (!shouldTax) {
            return (IHooks.afterSwap.selector, 0);
        }

        // BUY: Tax is taken from token output and sent to token contract for accumulation
        if (params.zeroForOne) {
            return _collectBuyTax(key.currency1, tokenAddress, delta.amount1(), taxBps);
        }

        // SELL: Tax is taken from ETH output (seller receives less ETH)
        return _collectSellTax(key.currency0, taxRecipient, delta.amount0(), taxBps);
    }

    /// @notice Prevents swaps if the token has not been graduated
    /// @param key The pool key identifying the pool
    /// @param params The swap parameters
    /// @return bytes4 The function selector to indicate successful execution
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Get token address (currency1 is always the token, currency0 is ETH)
        address tokenAddress = Currency.unwrap(key.currency1);

        // Check if token has graduated
        if (!ILivoToken(tokenAddress).graduated()) {
            revert NoSwapsBeforeGraduation();
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Get tax parameters for a token
    /// @return shouldTax Whether tax should be collected
    /// @return taxBps The tax rate in basis points
    /// @return taxRecipient The address to receive sell taxes
    function _getTaxParams(address tokenAddress, bool isBuy)
        internal
        view
        returns (bool shouldTax, uint16 taxBps, address taxRecipient)
    {
        // Query token tax configuration (try/catch for backwards compatibility with non-taxable tokens)
        try ILivoTokenTaxable(tokenAddress).getTaxConfig() returns (ILivoTokenTaxable.TaxConfig memory config) {
            // Check if token has graduated
            if (config.graduationTimestamp == 0) {
                return (false, 0, address(0));
            }

            // Check if tax period has expired
            if (block.timestamp > config.graduationTimestamp + config.taxDurationSeconds) {
                return (false, 0, address(0));
            }

            taxBps = isBuy ? config.buyTaxBps : config.sellTaxBps;
            if (taxBps == 0) {
                return (false, 0, address(0));
            }

            return (true, taxBps, config.taxRecipient);
        } catch {
            // in case tax configuration is not available, assume no taxes
            return (false, 0, address(0));
        }
    }

    /// @notice Collect buy tax (tokens sent to token contract for later swap to ETH)
    function _collectBuyTax(Currency currency, address tokenAddress, int128 tokenDelta, uint16 taxBps)
        internal
        returns (bytes4, int128)
    {
        uint256 absTokenAmount = uint256(uint128(tokenDelta > 0 ? tokenDelta : -tokenDelta));
        uint256 taxAmount = (absTokenAmount * taxBps) / BASIS_POINTS;

        // Send tokens to the token contract itself (for accumulation and later swap to ETH)
        poolManager.take(currency, tokenAddress, taxAmount);
        return (IHooks.afterSwap.selector, int128(uint128(taxAmount)));
    }

    /// @notice Collect sell tax (ETH wrapped to WETH and sent to tax recipient)
    function _collectSellTax(Currency currency, address taxRecipient, int128 ethDelta, uint16 taxBps)
        internal
        returns (bytes4, int128)
    {
        uint256 absEthAmount = uint256(uint128(ethDelta > 0 ? ethDelta : -ethDelta));
        uint256 taxAmount = (absEthAmount * taxBps) / BASIS_POINTS;

        // Take ETH to this contract instead of taxRecipient
        poolManager.take(currency, address(this), taxAmount);

        // Wrap ETH to WETH and transfer to taxRecipient
        // Silent failure - if wrap/transfer fails, ETH remains in contract
        // TODO: Consider adding rescue function for stuck ETH and event emission on failure
        WETH.deposit{value: taxAmount}();
        WETH.transfer(taxRecipient, taxAmount);

        return (IHooks.afterSwap.selector, int128(uint128(taxAmount)));
    }
}
