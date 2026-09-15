// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title RealmAnyPairsLiquidityMath
/// @notice The Uniswap `LiquidityAmounts` subset this stack needs.
/// @dev The one copy: the LP locker's compounding uses it too. All functions are `internal`, so there is nothing to
/// deploy or link.
library RealmAnyPairsLiquidityMath {
    uint256 private constant Q96 = 0x1000000000000000000000000;

    /// @dev Liquidity supportable by `amount0` across [sqrtA, sqrtB].
    /// Saturates at uint128 max: a bare cast would silently wrap, and reverting would permanently block a
    /// compounding path. Callers bound the result again.
    function liquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) internal pure returns (uint128) {
        if (sqrtA > sqrtB) {
            (sqrtA, sqrtB) = (sqrtB, sqrtA);
        }
        uint256 intermediate = FullMath.mulDiv(sqrtA, sqrtB, Q96);
        uint256 l0 = FullMath.mulDiv(amount0, intermediate, sqrtB - sqrtA);
        return l0 > type(uint128).max ? type(uint128).max : uint128(l0);
    }

    /// @dev Liquidity supportable by `amount1` across [sqrtA, sqrtB]. Same saturation rule.
    function liquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) internal pure returns (uint128) {
        if (sqrtA > sqrtB) {
            (sqrtA, sqrtB) = (sqrtB, sqrtA);
        }
        uint256 l1 = FullMath.mulDiv(amount1, Q96, sqrtB - sqrtA);
        return l1 > type(uint128).max ? type(uint128).max : uint128(l1);
    }

    /// @dev Liquidity supportable by BOTH amounts at the current price -- the binding side wins.
    function liquidityForAmounts(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtA > sqrtB) {
            (sqrtA, sqrtB) = (sqrtB, sqrtA);
        }
        if (sqrtP <= sqrtA) {
            liquidity = liquidityForAmount0(sqrtA, sqrtB, amount0);
        } else if (sqrtP < sqrtB) {
            uint128 l0 = liquidityForAmount0(sqrtP, sqrtB, amount0);
            uint128 l1 = liquidityForAmount1(sqrtA, sqrtP, amount1);
            liquidity = l0 < l1 ? l0 : l1;
        } else {
            liquidity = liquidityForAmount1(sqrtA, sqrtB, amount1);
        }
    }
}
