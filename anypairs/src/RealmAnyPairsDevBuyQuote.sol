// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";

/// @title RealmAnyPairsDevBuyQuote
/// @notice Reproduces, in a view, exactly what the launch transaction's dev-buy swap does to a freshly seeded pool.
/// @dev A line-for-line port of v4-core `Pool.swap`'s step loop, specialised to the one state a launch can be in:
/// a pool whose ONLY initialized ticks are the seeded position's two bounds, whose protocol fee is 0 (`Pool.initialize`
/// zeroes it; only a separate `setProtocolFee` transaction can raise it), and whose trade is exact-in. It must stay a
/// port: a closed-form single step would differ from the real swap by accumulated per-step rounding.
library RealmAnyPairsDevBuyQuote {
    struct Seed {
        bool zeroForOne;        // direction of the dev buy: quote in, coin out
        int24 tick;             // pool tick at launch (== the pool-native launch tick)
        uint160 sqrtPriceX96;   // pool price at launch
        int24 tickLower;        // the seeded position's bounds -- the only initialized ticks
        int24 tickUpper;
        uint128 liquidity;      // the seeded position's liquidity
        int24 tickSpacing;
        uint24 lpFee;           // pips; the swap fee when the protocol fee is 0
    }

    /// @return amountOut coin the swap delivers
    /// @return consumed quote the POOL consumed (excludes the hook's fee, which is taken before the pool sees it)
    function simulate(Seed memory s, uint256 amountIn) internal pure returns (uint256 amountOut, uint256 consumed) {
        if (amountIn == 0) return (0, 0);
        bool zfo = s.zeroForOne;
        uint160 limit = zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        int256 remaining = -int256(amountIn);
        uint160 sqrtP = s.sqrtPriceX96;
        int24 tick = s.tick;
        // Active liquidity is the position's only if the current tick is inside [lower, upper). A coin-is-currency1
        // launch sits exactly ON tickUpper, which is outside, so it starts at zero and crosses before trading.
        uint128 liq = (s.tickLower <= tick && tick < s.tickUpper) ? s.liquidity : 0;

        while (!(remaining == 0 || sqrtP == limit)) {
            uint160 start = sqrtP;
            (int24 tickNext, bool initialized) = _nextInitialized(tick, s.tickSpacing, zfo, s.tickLower, s.tickUpper);
            if (tickNext <= TickMath.MIN_TICK) tickNext = TickMath.MIN_TICK;
            if (tickNext >= TickMath.MAX_TICK) tickNext = TickMath.MAX_TICK;
            uint160 sqrtNext = TickMath.getSqrtPriceAtTick(tickNext);

            uint256 stepIn;
            uint256 stepOut;
            uint256 stepFee;
            (sqrtP, stepIn, stepOut, stepFee) = SwapMath.computeSwapStep(
                sqrtP, SwapMath.getSqrtPriceTarget(zfo, sqrtNext, limit), liq, remaining, s.lpFee
            );
            unchecked {
                remaining += int256(stepIn + stepFee);
            }
            amountOut += stepOut;

            if (sqrtP == sqrtNext) {
                if (initialized) {
                    // modifyLiquidity booked +L at the lower bound and -L at the upper; crossing downward negates.
                    int128 net = tickNext == s.tickLower ? int128(s.liquidity) : -int128(s.liquidity);
                    if (zfo) net = -net;
                    liq = LiquidityMath.addDelta(liq, net);
                }
                unchecked {
                    tick = zfo ? tickNext - 1 : tickNext;
                }
            } else if (sqrtP != start) {
                tick = TickMath.getTickAtSqrtPrice(sqrtP);
            }
        }
        consumed = amountIn - uint256(-remaining);
    }

    /// @dev `TickBitmap.nextInitializedTickWithinOneWord` over a bitmap whose only set bits are `a` and `b`.
    function _nextInitialized(int24 tick, int24 spacing, bool lte, int24 a, int24 b)
        private
        pure
        returns (int24 next, bool initialized)
    {
        unchecked {
            int24 compressed = _compress(tick, spacing);
            int24 ca = a / spacing; // both bounds are spacing-aligned, so this is exact
            int24 cb = b / spacing;
            if (lte) {
                (int16 word, uint8 bit) = _position(compressed);
                (bool fa, bool fb) = (_inWordAtOrBelow(ca, word, bit), _inWordAtOrBelow(cb, word, bit));
                initialized = fa || fb;
                int24 best = fa && fb ? (ca > cb ? ca : cb) : (fa ? ca : cb);
                next = initialized ? best * spacing : (compressed - int24(uint24(bit))) * spacing;
            } else {
                (int16 word, uint8 bit) = _position(++compressed);
                (bool fa, bool fb) = (_inWordAtOrAbove(ca, word, bit), _inWordAtOrAbove(cb, word, bit));
                initialized = fa || fb;
                int24 best = fa && fb ? (ca < cb ? ca : cb) : (fa ? ca : cb);
                next = initialized ? best * spacing : (compressed + int24(uint24(type(uint8).max - bit))) * spacing;
            }
        }
    }

    function _compress(int24 tick, int24 spacing) private pure returns (int24) {
        int24 c = tick / spacing;
        if (tick % spacing < 0) c -= 1;
        return c;
    }

    function _position(int24 compressed) private pure returns (int16 word, uint8 bit) {
        word = int16(compressed >> 8);
        bit = uint8(uint24(compressed) & 0xff);
    }

    function _inWordAtOrBelow(int24 c, int16 word, uint8 bit) private pure returns (bool) {
        (int16 w, uint8 b) = _position(c);
        return w == word && b <= bit;
    }

    function _inWordAtOrAbove(int24 c, int16 word, uint8 bit) private pure returns (bool) {
        (int16 w, uint8 b) = _position(c);
        return w == word && b >= bit;
    }
}
