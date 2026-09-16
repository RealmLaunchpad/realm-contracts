// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title RealmAnyPairsV3TwapOracle
/// @notice Minimal Uniswap V3 TWAP helpers, ported from v3-periphery `OracleLibrary` (`consult` / `getQuoteAtTick`,
/// GPL-2.0-or-later) with only Solidity 0.8 changes and v4-core's `TickMath`.
/// @dev The pool `observe` call stays in the caller, so a pool without history can be skipped via try/catch.
library RealmAnyPairsV3TwapOracle {
    /// @notice Arithmetic mean tick over `secondsAgo` from two tick cumulatives ([secondsAgo, 0] order).
    /// Rounds toward negative infinity, exactly as OracleLibrary.consult does.
    function meanTick(int56 cumulativeThen, int56 cumulativeNow, uint32 secondsAgo) internal pure returns (int24 tick) {
        int56 delta = cumulativeNow - cumulativeThen;
        int56 s = int56(uint56(secondsAgo));
        tick = int24(delta / s);
        if (delta < 0 && (delta % s != 0)) tick--;
    }

    /// @notice `baseAmount` of `baseToken` expressed in `quoteToken` at `tick` (price of token1 in token0 = 1.0001^tick).
    function quoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtPriceAtTick(tick);
        // Calculate quoteAmount with better precision if it doesn't overflow when multiplied by itself.
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}
