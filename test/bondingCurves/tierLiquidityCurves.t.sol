// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";
import {ConstantProductBondingCurveConfigurable} from "src/bondingCurves/ConstantProductBondingCurveConfigurable.sol";
import {CreatorVaultCurveConstants as C} from "src/config/CreatorVaultCurveConstants.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";

/// @dev Minimal view surface common to both `ConstantProductBondingCurve` (base) and
///      `ConstantProductBondingCurveConfigurable`. `getTokenReserves` is not on `IRealmBondingCurve`,
///      so this local interface lets the matrix treat both concrete curves uniformly.
interface ICurveView {
    function getTokenReserves(uint256 ethReserves) external view returns (uint256);
    function buyTokensWithExactEth(uint256 ethReserves, uint256 ethAmount)
        external
        view
        returns (uint256 tokensReceived, bool canGraduate);
    function sellExactTokens(uint256 ethReserves, uint256 tokenAmount) external view returns (uint256 ethReceived);
    function maxEthReserves() external view returns (uint256);
}

/// @notice Pure-curve invariants across the full (liquidity tier x creator-vault allocation) matrix —
///         the 3 tiers x {no-vault + 6 vault levels} = 21 curves. No fork needed (curves are pure math).
///         Covers two of the three feature invariants without an AMM:
///           (A) the curve's marginal price at graduation matches the pool price the graduator will
///               create (eth-into-liquidity / tokens-into-liquidity), within 1%; and
///           (C) the graduation marketcap is a function of the liquidity tier only (identical across
///               all vault levels of a tier, equal to that tier's target).
///         Plus safety: t(0)=S, T_GRAD identical everywhere, and no-overflow across each curve's range.
contract TierLiquidityCurvesTest is Test {
    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 constant FEE = 0.25 ether;

    // Tokens into liquidity at graduation — identical for EVERY tier and EVERY vault bps (the design
    // scales graduation mcap 1:2:4 with LP depth, holding the token split constant).
    uint256 constant T_GRAD = 285714285714285714285714285;

    uint256[7] BPS = [uint256(0), 500, 1000, 1500, 2000, 2500, 3000];

    function _tiers() internal pure returns (LiquidityTier[3] memory) {
        return [LiquidityTier.THIN, LiquidityTier.DEFAULT, LiquidityTier.THICK];
    }

    /// @dev Per-tier graduation marketcap target (ETH). Scales 1:2:4 with LP depth.
    function _tierMcap(LiquidityTier tier) internal pure returns (uint256) {
        if (tier == LiquidityTier.THIN) return 6.125 ether;
        if (tier == LiquidityTier.DEFAULT) return 12.25 ether;
        return 24.5 ether; // THICK
    }

    /// @dev Deploys the curve for a (tier, bps). DEFAULT+no-vault is the hardcoded base curve; every
    ///      other slot is a configurable instance built from the on-chain constants + tier threshold.
    function _deploy(LiquidityTier tier, uint256 bps) internal returns (ICurveView curve) {
        if (tier == LiquidityTier.DEFAULT && bps == 0) {
            return ICurveView(address(new ConstantProductBondingCurve()));
        }
        (uint256 k, uint256 t0, uint256 e0) = C.paramsFor(tier, bps);
        (uint256 threshold, uint256 maxExcess) = C.tierGraduation(tier);
        return ICurveView(address(new ConstantProductBondingCurveConfigurable(k, t0, e0, threshold, maxExcess)));
    }

    function _supplyInCurve(uint256 bps) internal pure returns (uint256) {
        return TOTAL_SUPPLY * (10_000 - bps) / 10_000;
    }

    /// @dev Curve marginal price at `ethReserves` (wei eth / wei token, scaled 1e18), via a tiny buy.
    function _marginalPrice(ICurveView curve, uint256 ethReserves) internal view returns (uint256) {
        uint256 buyValue = 0.000001e18;
        (uint256 tokensReceived,) = curve.buyTokensWithExactEth(ethReserves, buyValue);
        return (1e18 * buyValue) / tokensReceived;
    }

    /// @dev Invariant safety: t(0) equals the supply actually sold on the curve for every (tier, bps).
    function test_eachTierEachVault_tokenReservesAtZero_equalsSupplyInCurve() public {
        LiquidityTier[3] memory tiers = _tiers();
        for (uint256 t; t < 3; ++t) {
            for (uint256 i; i < 7; ++i) {
                ICurveView curve = _deploy(tiers[t], BPS[i]);
                assertEq(curve.getTokenReserves(0), _supplyInCurve(BPS[i]), "t(0) must equal supply in curve");
            }
        }
    }

    /// @dev Invariant C (supply side): tokens into liquidity is identical (T_GRAD) for every tier/bps.
    function test_eachTierEachVault_tokensIntoLiquidity_equalsTGRAD() public {
        LiquidityTier[3] memory tiers = _tiers();
        for (uint256 t; t < 3; ++t) {
            (uint256 threshold,) = C.tierGraduation(tiers[t]);
            for (uint256 i; i < 7; ++i) {
                ICurveView curve = _deploy(tiers[t], BPS[i]);
                assertEq(curve.getTokenReserves(threshold), T_GRAD, "tokens into liquidity must be T_GRAD everywhere");
            }
        }
    }

    /// @dev Invariant A (pure): the curve's marginal price at the tier threshold matches the Uniswap
    ///      price the graduator will set (eth-into-liquidity / T_GRAD), within 1%, for every (tier, bps).
    function test_eachTierEachVault_graduationPrice_matchesUniswap() public {
        LiquidityTier[3] memory tiers = _tiers();
        for (uint256 t; t < 3; ++t) {
            (uint256 threshold,) = C.tierGraduation(tiers[t]);
            uint256 ethForLiquidity = threshold - FEE;
            uint256 uniswapPrice = (ethForLiquidity * 1e18) / T_GRAD;
            for (uint256 i; i < 7; ++i) {
                ICurveView curve = _deploy(tiers[t], BPS[i]);
                uint256 curvePrice = _marginalPrice(curve, threshold);
                assertApproxEqRel(curvePrice, uniswapPrice, 0.01e18, "curve grad price must match uniswap (1%)");
            }
        }
    }

    /// @dev Invariant C: graduation marketcap is a function of the tier only — equal to the tier target
    ///      and IDENTICAL across all seven vault levels of that tier (proves mcap depends on tier, not vault).
    function test_eachTier_graduationMarketcap_isTierTargetAndVaultIndependent() public {
        LiquidityTier[3] memory tiers = _tiers();
        for (uint256 t; t < 3; ++t) {
            (uint256 threshold,) = C.tierGraduation(tiers[t]);
            uint256 ethForLiquidity = threshold - FEE;
            // mcap derived from the (tier-constant) pool price the graduator creates.
            uint256 mcap = (ethForLiquidity * 1e18) / T_GRAD * TOTAL_SUPPLY / 1e18;
            assertApproxEqRel(mcap, _tierMcap(tiers[t]), 0.0001e18, "graduation mcap must equal tier target");

            // And the curve's marginal-price-implied mcap is the same for every vault level.
            for (uint256 i; i < 7; ++i) {
                ICurveView curve = _deploy(tiers[t], BPS[i]);
                uint256 curveMcap = _marginalPrice(curve, threshold) * TOTAL_SUPPLY / 1e18;
                assertApproxEqRel(curveMcap, _tierMcap(tiers[t]), 0.01e18, "per-vault grad mcap must equal tier target");
            }
        }
    }

    /// @dev Safety: within [0, maxEthReserves] no (tier, bps) curve overflows/reverts on a buy. Bounds to
    ///      EACH curve's own maxEthReserves — the THICK tier legitimately reaches ~7.3 ETH reserves.
    function test_fuzz_eachTierEachVault_buyDoesNotRevertInRange(
        uint256 tierIdx,
        uint256 bpsIdx,
        uint256 ethReserves,
        uint256 ethAmount
    ) public {
        tierIdx = bound(tierIdx, 0, 2);
        bpsIdx = bound(bpsIdx, 0, 6);
        ICurveView curve = _deploy(_tiers()[tierIdx], BPS[bpsIdx]);
        uint256 maxEth = curve.maxEthReserves();
        ethReserves = bound(ethReserves, 0, maxEth);
        uint256 limit = maxEth - ethReserves;
        if (limit == 0) return;
        ethAmount = bound(ethAmount, 0, limit);
        curve.buyTokensWithExactEth(ethReserves, ethAmount);
    }

    /// @dev Safety: buy then sell round-trips within rounding for every (tier, bps).
    function test_fuzz_eachTierEachVault_buyThenSell_roundTrips(
        uint256 tierIdx,
        uint256 bpsIdx,
        uint256 ethReserves,
        uint256 ethAmount
    ) public {
        tierIdx = bound(tierIdx, 0, 2);
        bpsIdx = bound(bpsIdx, 0, 6);
        ICurveView curve = _deploy(_tiers()[tierIdx], BPS[bpsIdx]);
        uint256 maxEth = curve.maxEthReserves();
        ethReserves = bound(ethReserves, 0, maxEth);
        uint256 maxAmount = maxEth - ethReserves;
        if (maxAmount < 0.000001e18) return;
        ethAmount = bound(ethAmount, 0.000001e18, maxAmount);

        (uint256 tokensReceived,) = curve.buyTokensWithExactEth(ethReserves, ethAmount);
        uint256 ethReceived = curve.sellExactTokens(ethReserves + ethAmount, tokensReceived);
        assertLe(ethReceived, ethAmount, "cannot extract more than put in");
        assertApproxEqRel(ethReceived, ethAmount, 0.0000001e18, "buy+sell should round-trip within 0.00001%");
    }
}
