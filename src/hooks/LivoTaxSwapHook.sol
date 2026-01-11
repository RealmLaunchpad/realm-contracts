// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseHook} from "lib/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ILivoTokenTaxable} from "src/interfaces/ILivoTokenTaxable.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @title LivoTaxSwapHook
/// @notice Uniswap V4 hook that collects time-limited buy/sell taxes on token swaps
/// @dev Singleton hook serving all taxable tokens graduated via LivoGraduatorUniswapV4WithTaxHooks
/// @dev Hook queries each token for tax configuration and applies taxes only during the configured period
contract LivoTaxSwapHook is BaseHook {
    /// @notice Basis points denominator (10000 = 100%)
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice Initializes the hook with the pool manager address
    /// @param _poolManager The Uniswap V4 pool manager contract
    /// @dev Constructor validates that the deployed address matches the required hook permissions
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

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
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Hook callback executed after each swap to collect taxes
    /// @param sender The address initiating the swap
    /// @param key The pool key identifying the pool
    /// @param params The swap parameters including direction
    /// @param delta The balance changes from the swap
    /// @param hookData Additional data passed to the hook (unused)
    /// @return bytes4 The function selector to indicate successful execution
    /// @return int128 The tax amount taken from the pool (positive = hook took from pool)
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // Query token tax configuration (try/catch for backwards compatibility with non-taxable tokens)
        ILivoTokenTaxable.TaxConfig memory config;
        try ILivoTokenTaxable(Currency.unwrap(key.currency1)).getTaxConfig() returns (
            ILivoTokenTaxable.TaxConfig memory c
        ) {
            config = c;
        } catch {
            // Token doesn't implement tax interface or call reverted - no tax applied
            // review if non-taxable tokens are actually catched in this try/catch (since signature may not exist at all)
            return (IHooks.afterSwap.selector, 0);
        }

        // Check if token has graduated (graduationTimestamp == 0 means not graduated yet)
        if (config.graduationTimestamp == 0) {
            return (IHooks.afterSwap.selector, 0);
        }

        // Check if tax period has expired
        if (block.timestamp > config.graduationTimestamp + config.taxDurationSeconds) {
            return (IHooks.afterSwap.selector, 0);
        }

        // Determine swap direction
        // Pool structure: (currency0=ETH, currency1=Token)
        // zeroForOne=true → Swapping ETH (currency0) for Token (currency1) → BUY → apply buyTaxBps
        // zeroForOne=false → Swapping Token (currency1) for ETH (currency0) → SELL → apply sellTaxBps
        bool isBuy = params.zeroForOne;
        uint16 taxBps = isBuy ? config.buyTaxBps : config.sellTaxBps;

        // If tax rate is 0%, no tax to collect
        if (taxBps == 0) {
            return (IHooks.afterSwap.selector, 0);
        }

        // review this thing with positive/negative and who loses the ETH
        // Calculate tax on ETH amount
        // delta.amount0() represents the change in ETH:
        //   - For BUY: delta.amount0() > 0 (pool gains ETH from buyer)
        //   - For SELL: delta.amount0() < 0 (pool loses ETH to seller)
        // We always tax ETH, so use absolute value of delta.amount0()
        int128 ethDelta = delta.amount0();
        uint256 absEthAmount = uint256(uint128(ethDelta > 0 ? ethDelta : -ethDelta));

        // Calculate tax: (ethAmount * taxBps) / 10000
        uint256 taxAmount = (absEthAmount * taxBps) / BASIS_POINTS;

        // Take tax from pool and send to tax recipient
        // manager.take() transfers currency from the pool to the specified recipient
        poolManager.take(
            key.currency0, // Always ETH (currency0)
            config.taxRecipient,
            taxAmount
        );

        // Return success selector and tax amount as delta
        // Positive delta means hook took funds from the pool
        return (IHooks.afterSwap.selector, int128(uint128(taxAmount)));
    }
}
