// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";

/// @title RealmEtfJitMath
/// @notice Sizes the one-tick position `RealmEtfHook` places for a swap, so the pool's own curve fills all but
///         a few raw units of the trade and provably never needs more than the range holds. Derivation and proofs:
///         `docs/etf-jit-math.md` (Case U: price moves up, Case D: price moves down).
/// @dev Every quantity is computed with the core's own functions and arguments, so `inC`/`outC` are exactly
///      what the core's swap step will produce. The pool must have fee 0 (LP and protocol) and tick spacing 1.
library RealmEtfJitMath {
    /// @notice A position of `liquidity` on `[tickLower, tickLower + 1]`, the price to start the swap at, the
    ///         curve's exact input and output, what adding the position costs (output token) and what removing
    ///         it after the swap returns (both tokens, rounded down by the core). Zero `liquidity`: no JIT.
    struct Plan {
        int24 tickLower;
        uint128 liquidity;
        uint160 startSqrtPriceX96;
        uint256 inC;
        uint256 outC;
        uint256 cost;
        uint256 removedIn;
        uint256 removedOut;
    }

    uint256 private constant Q192 = 1 << 192;

    /// @param zeroForOne the swap's direction (input token0)
    /// @param exactIn whether the input (`x`) is the specified amount, else the output (`y`)
    /// @param x everything the swapper pays, in the input token
    /// @param y everything the swapper receives, in the output token (what the position holds)
    function plan(bool zeroForOne, bool exactIn, uint256 x, uint256 y) internal pure returns (Plan memory p) {
        if (x == 0 || y == 0) return p;
        return zeroForOne ? _planDown(exactIn, x, y) : _planUp(exactIn, x, y);
    }

    /// @dev Case U: input token1, position token0, range BELOW x/y, swap runs from its lower edge up.
    function _planUp(bool exactIn, uint256 x, uint256 y) private pure returns (Plan memory p) {
        if (x / y >= 1 << 64) return p; // x * 2^192 / y would overflow
        uint256 sigma = Math.sqrt(FullMath.mulDiv(x, Q192, y));
        if (sigma < TickMath.MIN_SQRT_PRICE || sigma >= TickMath.MAX_SQRT_PRICE) return p;
        int24 tickLower = TickMath.getTickAtSqrtPrice(uint160(sigma)) - 1;
        if (tickLower < TickMath.MIN_TICK) return p;
        uint160 sa = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sb = TickMath.getSqrtPriceAtTick(tickLower + 1);

        // getLiquidityForAmount0, without its uint128 revert
        uint256 l = FullMath.mulDiv(y, FullMath.mulDiv(sa, sb, 1 << 96), sb - sa);
        if (l == 0 || l > Pool.tickSpacingToMaxLiquidityPerTick(1)) return p;
        uint128 liquidity = uint128(l);

        uint160 sNext;
        if (exactIn) {
            uint256 b = SqrtPriceMath.getAmount1Delta(sa, sb, liquidity, true);
            if (b <= 1) return p;
            p.inC = b - 1;
            sNext = SqrtPriceMath.getNextSqrtPriceFromInput(sa, liquidity, p.inC, false);
            p.outC = SqrtPriceMath.getAmount0Delta(sa, sNext, liquidity, false);
        } else {
            uint256 bo = SqrtPriceMath.getAmount0Delta(sa, sb, liquidity, false);
            if (bo <= 1) return p;
            p.outC = bo - 1;
            sNext = SqrtPriceMath.getNextSqrtPriceFromOutput(sa, liquidity, p.outC, false);
            p.inC = SqrtPriceMath.getAmount1Delta(sa, sNext, liquidity, true);
        }
        p.cost = SqrtPriceMath.getAmount0Delta(sa, sb, liquidity, true);
        // The core prices a removal at the final price, in or at the edge of the range alike.
        p.removedOut = SqrtPriceMath.getAmount0Delta(sNext, sb, liquidity, false);
        p.removedIn = SqrtPriceMath.getAmount1Delta(sa, sNext, liquidity, false);
        (p.tickLower, p.liquidity, p.startSqrtPriceX96) = (tickLower, liquidity, sa);
    }

    /// @dev Case D: input token0, position token1, range ABOVE y/x, swap runs from its upper edge down.
    function _planDown(bool exactIn, uint256 x, uint256 y) private pure returns (Plan memory p) {
        if (y / x >= 1 << 64) return p; // y * 2^192 / x would overflow
        uint256 v = FullMath.mulDivRoundingUp(y, Q192, x);
        uint256 sigma = Math.sqrt(v);
        if (sigma * sigma < v) ++sigma;
        if (sigma < TickMath.MIN_SQRT_PRICE || sigma >= TickMath.MAX_SQRT_PRICE) return p;
        int24 tickLower = TickMath.getTickAtSqrtPrice(uint160(sigma));
        if (TickMath.getSqrtPriceAtTick(tickLower) < sigma) ++tickLower;
        if (tickLower >= TickMath.MAX_TICK) return p;
        uint160 sa = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sb = TickMath.getSqrtPriceAtTick(tickLower + 1);

        // getLiquidityForAmount1, without its uint128 revert
        uint256 l = FullMath.mulDiv(y, 1 << 96, sb - sa);
        if (l == 0 || l > Pool.tickSpacingToMaxLiquidityPerTick(1)) return p;
        uint128 liquidity = uint128(l);

        uint160 sNext;
        if (exactIn) {
            uint256 b = SqrtPriceMath.getAmount0Delta(sa, sb, liquidity, true);
            if (b <= 1) return p;
            p.inC = b - 1;
            sNext = SqrtPriceMath.getNextSqrtPriceFromInput(sb, liquidity, p.inC, true);
            p.outC = SqrtPriceMath.getAmount1Delta(sNext, sb, liquidity, false);
        } else {
            uint256 bo = SqrtPriceMath.getAmount1Delta(sa, sb, liquidity, false);
            if (bo <= 1) return p;
            p.outC = bo - 1;
            sNext = SqrtPriceMath.getNextSqrtPriceFromOutput(sb, liquidity, p.outC, true);
            p.inC = SqrtPriceMath.getAmount0Delta(sNext, sb, liquidity, true);
        }
        p.cost = SqrtPriceMath.getAmount1Delta(sa, sb, liquidity, true);
        p.removedOut = SqrtPriceMath.getAmount1Delta(sa, sNext, liquidity, false);
        p.removedIn = SqrtPriceMath.getAmount0Delta(sNext, sb, liquidity, false);
        (p.tickLower, p.liquidity, p.startSqrtPriceX96) = (tickLower, liquidity, sb);
    }
}
