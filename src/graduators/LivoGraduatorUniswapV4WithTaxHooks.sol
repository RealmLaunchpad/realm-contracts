// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoGraduatorUniswapV4} from "./LivoGraduatorUniswapV4.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";

/// @title LivoGraduatorUniswapV4WithTaxHooks
/// @notice Extension of LivoGraduatorUniswapV4 that adds tax hook support
/// @dev Inherits all functionality from the base contract and only overrides pool configuration
contract LivoGraduatorUniswapV4WithTaxHooks is LivoGraduatorUniswapV4 {
    /// @notice Tax hook contract for collecting buy/sell taxes
    address public immutable TAX_HOOK;

    /// @notice Initializes the Uniswap V4 graduator with tax hooks support
    /// @param _launchpad Address of the LivoLaunchpad contract
    /// @param _liquidityLock Address of the liquidity lock contract
    /// @param _poolManager Address of the Uniswap V4 pool manager
    /// @param _positionManager Address of the Uniswap V4 position manager
    /// @param _permit2 Address of the Permit2 contract
    /// @param _taxHook Address of the tax hook contract
    constructor(
        address _launchpad,
        address _liquidityLock,
        address _poolManager,
        address _positionManager,
        address _permit2,
        address _taxHook
    )
        LivoGraduatorUniswapV4(_launchpad, _liquidityLock, _poolManager, _positionManager, _permit2)
    {
        TAX_HOOK = _taxHook;
    }

    /// @notice Overrides the pool key to include the tax hook
    /// @param tokenAddress Address of the token
    /// @return PoolKey with tax hook configured
    function _getPoolKey(address tokenAddress) internal view override returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(tokenAddress)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(TAX_HOOK) // tax hook for buy/sell taxes
        });
    }
}
