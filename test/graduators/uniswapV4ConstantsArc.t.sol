// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {UniswapV4PoolConstantsArc as C} from "src/libraries/UniswapV4PoolConstantsArc.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "lib/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @notice Validates the ARC (USDC-native) Uniswap V4 pool constants. ARC reprices every native-
///         denominated economic value x2000 (native ~$1 vs ETH ~$2000) but keeps 18-dec native + 18-dec
///         token, so the pool geometry is the ETH geometry translated to a x1/2000 price (sqrtPrice
///         x1/sqrt(2000); ticks shifted -76000, re-derived per set-point via uniswapV4Settings.py). These tests
///         replicate `RealmGraduatorUniswapV4`'s constructor derivations against the ARC constants and
///         fuzz the liquidity-sizing math at ARC scale to prove the constructor invariants hold and the
///         `getLiquidityForAmounts`/`getLiquidityForAmount0` (uint128) paths never overflow.
contract UniswapV4ConstantsArcTest is Test {
    uint256 constant Q96 = 2 ** 96;

    // Tokens into liquidity at graduation (scale-invariant; identical to the ETH curves).
    uint256 constant T_GRAD = 285714285714285714285714285;

    // Per-tier: graduation sqrtPriceX96, its primary-range upper tick, and the tick the solver rounded
    // the graduation price to. THIN uses TICK_UPPER_THIN; DEFAULT/THICK use TICK_UPPER.
    struct Tier {
        uint160 sqrtGrad;
        int24 tickUpper;
        int24 expectedGradTick;
        uint256 expectedWeiPerToken; // native wei per token at graduation = ETH wei/token x 2000
    }

    function _tiers() internal pure returns (Tier[3] memory t) {
        t[0] = Tier(C.SQRT_PRICEX96_GRADUATION_DEFAULT, C.TICK_UPPER, 106200, 24500000000000);
        t[1] = Tier(C.SQRT_PRICEX96_GRADUATION_THIN, C.TICK_UPPER_THIN, 113200, 12250000000000);
        t[2] = Tier(C.SQRT_PRICEX96_GRADUATION_THICK, C.TICK_UPPER, 99200, 49000000000000);
    }

    /// @dev Each graduation sqrtPrice, rounded to nearest spacing (as the solver does), must equal the
    ///      tick the solver produced — i.e. the stored constant is exactly the solver's price cell.
    function test_graduationSqrtPrices_roundToSolverTicks() public pure {
        Tier[3] memory tiers = _tiers();
        int24 spacing = C.TICK_SPACING;
        for (uint256 i; i < tiers.length; ++i) {
            // getTickAtSqrtPrice floors; the solver rounds to nearest spacing. All ARC grad ticks are
            // positive, so round-half-up via +spacing/2 before truncating division.
            int24 gradTick = TickMath.getTickAtSqrtPrice(tiers[i].sqrtGrad);
            int24 rounded = (gradTick + spacing / 2) / spacing * spacing;
            assertEq(rounded, tiers[i].expectedGradTick, "sqrtPrice rounds to solver tick");
        }
    }

    /// @dev The exact invariants `RealmGraduatorUniswapV4`'s constructor enforces must hold for every tier
    ///      with the ARC range bounds, and the graduation price must sit strictly inside the range.
    function test_constructorInvariants_holdForEachTier() public pure {
        Tier[3] memory tiers = _tiers();
        int24 spacing = C.TICK_SPACING;
        for (uint256 i; i < tiers.length; ++i) {
            int24 tickUpper = tiers[i].tickUpper;
            int24 gradTick = TickMath.getTickAtSqrtPrice(tiers[i].sqrtGrad);
            int24 tickLower2 = (gradTick / spacing + 1) * spacing;
            int24 tickUpper2 = tickUpper - C.TICK_UPPER_2_OFFSET;

            // the graduator's on-chain require()
            assertEq(tickUpper % spacing, 0, "upper spacing-aligned");
            assertGt(gradTick, C.TICK_LOWER, "grad above range lower");
            assertLt(tickLower2, tickUpper2, "secondary range ordered");
            // price strictly inside the primary range (both sides have liquidity)
            assertLt(gradTick, tickUpper, "grad below range upper");
        }
    }

    /// @dev Repricing check: the native wei-per-token at graduation must be the ETH value x2000 (same
    ///      token USD value, native mcap x2000), within rounding.
    function test_graduationPrice_isEthScaledBy2000() public pure {
        Tier[3] memory tiers = _tiers();
        for (uint256 i; i < tiers.length; ++i) {
            // wei/token = 1e18 / (tokens per native) = 1e18 * Q96^2 / sqrt^2
            uint256 s = uint256(tiers[i].sqrtGrad);
            uint256 weiPerToken = (1e18 * Q96 * Q96) / (s * s);
            assertApproxEqRel(weiPerToken, tiers[i].expectedWeiPerToken, 0.0001e18, "wei/token == eth x2000");
        }
    }

    /// @dev Primary position: sizing liquidity from ARC-scale native + token amounts must never overflow
    ///      the uint128 return across the full plausible graduation range (native up to ~20k ether).
    function test_fuzz_primaryLiquidity_noOverflow(uint256 tIdx, uint256 nativeForLiquidity, uint256 tokenAmount)
        public
        pure
    {
        tIdx = bound(tIdx, 0, 2);
        Tier memory tier = _tiers()[tIdx];
        // THIN 3500 / DEFAULT 7000 / THICK 14000 ether into liquidity, + up to 100 excess; 20000 covers all.
        nativeForLiquidity = bound(nativeForLiquidity, 0.1 ether, 20000 ether);
        tokenAmount = bound(tokenAmount, 1e18, T_GRAD);

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(C.TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tier.tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            tier.sqrtGrad, sqrtLower, sqrtUpper, nativeForLiquidity, tokenAmount
        );
        assertGt(liquidity, 0, "primary liquidity > 0");
    }

    /// @dev Secondary single-sided native position (the other liquidity path): its `getLiquidityForAmount0`
    ///      sizing must also never overflow at ARC scale.
    function test_fuzz_secondaryLiquidity_noOverflow(uint256 tIdx, uint256 remainingNative) public pure {
        tIdx = bound(tIdx, 0, 2);
        Tier memory tier = _tiers()[tIdx];
        remainingNative = bound(remainingNative, 0.1 ether, 20000 ether);

        int24 gradTick = TickMath.getTickAtSqrtPrice(tier.sqrtGrad);
        int24 tickLower2 = (gradTick / C.TICK_SPACING + 1) * C.TICK_SPACING;
        int24 tickUpper2 = tier.tickUpper - C.TICK_UPPER_2_OFFSET;
        uint160 sqrtLower2 = TickMath.getSqrtPriceAtTick(tickLower2);
        uint160 sqrtUpper2 = TickMath.getSqrtPriceAtTick(tickUpper2);

        // must not revert (overflow); may be 0 if the range rounds to a dust position
        LiquidityAmounts.getLiquidityForAmount0(sqrtLower2, sqrtUpper2, remainingNative);
    }
}
