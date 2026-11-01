// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {RealmEtfJitMath} from "src/etf/RealmEtfJitMath.sol";

/// @notice Checks `RealmEtfJitMath` against the properties proven in `docs/etf-jit-math.md`, running the core's
///         own swap step on every plan.
contract RealmEtfJitMathTest is Test {
    function testFuzz_plan(bool zeroForOne, bool exactIn, uint256 x, uint256 y) public pure {
        x = bound(x, 1, 1 << 100);
        y = bound(y, 1, 1 << 100);
        _check(zeroForOne, exactIn, x, y);
    }

    /// @dev Realistic sizes: USDG (6 decimals) against shares (18 decimals) near 1 USDG per share.
    function testFuzz_plan_usdgShares(bool zeroForOne, bool exactIn, uint256 usdg, uint256 navBps) public pure {
        usdg = bound(usdg, 1_000, 1e15); // 0.001 to 1B USDG
        uint256 shares = usdg * 1e12 * 10_000 / bound(navBps, 1, 1e8); // NAV 0.0001 to 10,000 USDG
        // USDG is the input of a buy: token0 on a zeroForOne buy, token1 otherwise.
        _check(zeroForOne, exactIn, usdg, shares);
        _check(zeroForOne, exactIn, shares, usdg);
    }

    function _check(bool zeroForOne, bool exactIn, uint256 x, uint256 y) internal pure {
        RealmEtfJitMath.Plan memory p = RealmEtfJitMath.plan(zeroForOne, exactIn, x, y);
        if (p.liquidity == 0) return;

        uint160 sa = TickMath.getSqrtPriceAtTick(p.tickLower);
        uint160 sb = TickMath.getSqrtPriceAtTick(p.tickLower + 1);
        (uint160 start, uint160 far) = zeroForOne ? (sb, sa) : (sa, sb);
        assertEq(p.startSqrtPriceX96, start, "start edge");

        // P1: the position costs at most the ETF's output.
        uint256 cost = zeroForOne
            ? SqrtPriceMath.getAmount1Delta(sa, sb, p.liquidity, true)
            : SqrtPriceMath.getAmount0Delta(sa, sb, p.liquidity, true);
        assertEq(cost, p.cost, "cost");
        assertLe(cost, y, "P1 funded");

        // P2: the core's step fills exactly the predicted amounts, all within this one step. The price may end ON
        // the far edge (rounding, with nothing left to fill), never needing liquidity past it.
        (uint160 next, uint256 amountIn, uint256 amountOut,) =
            SwapMath.computeSwapStep(start, far, p.liquidity, exactIn ? -int256(p.inC) : int256(p.outC), 0);
        assertEq(amountIn, p.inC, "curve input");
        assertEq(amountOut, p.outC, "curve output");
        assertTrue(zeroForOne ? next >= sa : next <= sb, "P2 contained");

        // The removal the hook predicts is what the core pays at the final price, and never more than the
        // curve put in or the position kept.
        assertEq(
            p.removedOut,
            zeroForOne
                ? SqrtPriceMath.getAmount1Delta(sa, next, p.liquidity, false)
                : SqrtPriceMath.getAmount0Delta(next, sb, p.liquidity, false),
            "removed out"
        );
        assertLe(p.removedIn, p.inC, "removed in");
        assertLe(p.removedOut + p.outC, cost, "removed out <= kept");

        // The hook's own deltas are never negative: it takes input and gives output.
        assertLe(p.inC, x, "hook input >= 0");
        assertLe(p.outC, y, "hook output >= 0");

        _checkExhaustion(p, exactIn, x, y, sa, sb);
    }

    function _checkExhaustion(RealmEtfJitMath.Plan memory p, bool exactIn, uint256 x, uint256 y, uint160 sa, uint160 sb)
        internal
        pure
    {
        // P3: the position keeps at most ~3 raw units of output plus the output worth ~1 raw unit of input, each
        // scaled by 1 + L/2^96 for huge positions (one raw unit of either token per raw sqrt-price step).
        uint256 left = p.cost - p.outC;
        uint256 lq = uint256(p.liquidity) >> 95;
        assertLe(left * x, (3 + lq) * x + (2 + lq) * y, "P3 near exhaustion");

        // The hook's own part of the trade: the price gap of at most 1.5 ticks plus rounding.
        // Rounding: the floors in L, each worth one unit of L (or of its intermediate) in either token.
        // (+1 for each of the two divisions below, which round down)
        uint256 rounding = 5 + (y >> 96) + ((sb - sa) >> 96) + FullMath.mulDiv(1 << 96, sb - sa, sa) / sb
            + FullMath.mulDiv(y, 1 << 96, sa) / sb;
        if (exactIn) assertLe((x - p.inC) * 10_000, 2 * x + 10_000 * rounding, "hook input share");
        else assertLe(y - p.outC, rounding, "hook output share");
    }
}
