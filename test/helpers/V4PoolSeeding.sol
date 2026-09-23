// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "lib/v4-core/src/test/PoolModifyLiquidityTest.sol";

/// @notice Adds full-range liquidity to a hookless V4 pool on a fork, opening it at 1:1 first when it is
///         not initialized. Robinhood's real V4 pools are too thin (or missing) for some route shapes the
///         fork suites exercise, so those suites build the depth they need instead of hunting for it.
abstract contract V4PoolSeeding is Test {
    using StateLibrary for IPoolManager;

    function _seedV4Pool(IPoolManager manager, address a, address b, uint24 fee, int24 spacing, uint256 liquidity)
        internal
    {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        PoolKey memory key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, IHooks(address(0)));
        (uint160 sqrtPrice,,,) = manager.getSlot0(key.toId());
        if (sqrtPrice == 0) manager.initialize(key, uint160(1 << 96));

        // A fresh EOA-like seeder: the liquidity helper refunds unused native to its caller.
        address seeder = makeAddr("v4PoolSeeder");
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        vm.deal(seeder, 1e30);
        vm.startPrank(seeder);
        for (uint256 i; i < 2; ++i) {
            address c = i == 0 ? c0 : c1;
            if (c == address(0)) continue;
            deal(c, seeder, 1e27);
            // xStocks' `approve` returns nothing.
            SafeERC20.forceApprove(IERC20(c), address(lp), type(uint256).max);
        }
        lp.modifyLiquidity{value: c0 == address(0) ? 1e30 : 0}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(spacing),
                tickUpper: TickMath.maxUsableTick(spacing),
                liquidityDelta: int256(liquidity),
                salt: 0
            }),
            ""
        );
        vm.stopPrank();
    }
}
