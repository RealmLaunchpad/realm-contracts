// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";
import {ConstantProductBondingCurveConfigurable} from "src/bondingCurves/ConstantProductBondingCurveConfigurable.sol";
import {IRealmBondingCurve} from "src/interfaces/IRealmBondingCurve.sol";
import {CreatorVaultCurveConstants as C} from "src/config/CreatorVaultCurveConstants.sol";

/// @notice Invariant tests for the six creator-vault bonding curves. The whole point of the feature
///         is that locking supply in vaults must NOT change any graduation property — only the
///         starting market cap is allowed to move. These tests pin every graduation invariant to be
///         identical to the base `ConstantProductBondingCurve`.
contract CreatorVaultCurvesTest is Test {
    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;

    uint256 constant GRADUATION_THRESHOLD = 3.75 ether;
    uint256 constant GRADUATION_MAX_EXCESS = 0.05 ether;
    uint256 constant GRADUATION_ETH_FEE = 0.25 ether;

    // Tokens left in reserves at graduation == tokens deposited into liquidity. Must be identical
    // for every curve (base + all 6 vault curves), to 0 wei.
    uint256 constant T_GRAD = 285714285714285714285714285;

    uint256[6] BPS = [uint256(500), 1000, 1500, 2000, 2500, 3000];

    function _deploy(uint256 bps) internal returns (ConstantProductBondingCurveConfigurable) {
        (uint256 k, uint256 t0, uint256 e0) = C.paramsForBps(bps);
        return new ConstantProductBondingCurveConfigurable(k, t0, e0, GRADUATION_THRESHOLD, GRADUATION_MAX_EXCESS);
    }

    function _uniswapPrice(uint256 tokenReserves, uint256 ethReserves) internal pure returns (uint256) {
        return (ethReserves * 1e18) / tokenReserves;
    }

    /// @dev Sanity: the base (deployed) curve produces exactly T_GRAD at graduation, so the vault
    ///      curves matching T_GRAD really do preserve "tokens into liquidity".
    function test_baseCurve_tokensAtGraduation_equalsTGRAD() public {
        ConstantProductBondingCurve base = new ConstantProductBondingCurve();
        assertEq(base.getTokenReserves(0), TOTAL_SUPPLY, "base t(0) == 1B");
        assertEq(base.getTokenReserves(GRADUATION_THRESHOLD), T_GRAD, "base t(grad) == T_GRAD");
    }

    function test_eachCurve_tokenReservesAtZero_equalsSupplyInCurve() public {
        for (uint256 i; i < 6; ++i) {
            uint256 bps = BPS[i];
            uint256 s = TOTAL_SUPPLY * (10_000 - bps) / 10_000;
            ConstantProductBondingCurveConfigurable curve = _deploy(bps);
            assertEq(curve.getTokenReserves(0), s, "t(0) must equal supply in curve (1B - vault)");
        }
    }

    function test_eachCurve_tokensIntoLiquidity_identical() public {
        for (uint256 i; i < 6; ++i) {
            ConstantProductBondingCurveConfigurable curve = _deploy(BPS[i]);
            assertEq(
                curve.getTokenReserves(GRADUATION_THRESHOLD),
                T_GRAD,
                "tokens into liquidity must be identical across all curves"
            );
        }
    }

    function test_eachCurve_graduationThresholdAndExcess_identical() public {
        for (uint256 i; i < 6; ++i) {
            ConstantProductBondingCurveConfigurable curve = _deploy(BPS[i]);
            assertEq(curve.ethGraduationThreshold(), GRADUATION_THRESHOLD, "grad threshold identical");
            assertEq(curve.maxExcessOverThreshold(), GRADUATION_MAX_EXCESS, "max excess identical");
            assertEq(curve.maxEthReserves(), GRADUATION_THRESHOLD + GRADUATION_MAX_EXCESS, "max reserves identical");
        }
    }

    /// @dev The marginal price at the graduation point must match the Uniswap price that the
    ///      graduator will create (eth-into-liquidity / tokens-into-liquidity), within 1% — same
    ///      bar as the base curve test. Since T_GRAD and eth-into-liquidity are identical for every
    ///      curve, the target Uniswap price is identical too.
    function test_eachCurve_graduationPrice_matchesUniswap() public {
        uint256 ethForUniswap = GRADUATION_THRESHOLD - GRADUATION_ETH_FEE; // 3.5 ETH, identical for all
        uint256 uniswapPrice = _uniswapPrice(T_GRAD, ethForUniswap);

        for (uint256 i; i < 6; ++i) {
            ConstantProductBondingCurveConfigurable curve = _deploy(BPS[i]);
            uint256 buyValue = 0.000001e18;
            (uint256 tokensReceived,) = curve.buyTokensWithExactEth(GRADUATION_THRESHOLD, buyValue);
            uint256 curvePrice = (1e18 * buyValue) / tokensReceived;
            assertApproxEqRel(curvePrice, uniswapPrice, 0.01e18, "curve grad price must match uniswap (1%)");
        }
    }

    /// @dev Graduation marketcap (price * full 1B supply) must be 12.25 ETH for every curve.
    function test_eachCurve_graduationMarketcap_is12p25Eth() public {
        uint256 ethForUniswap = GRADUATION_THRESHOLD - GRADUATION_ETH_FEE;
        uint256 priceWeiPerWei = (ethForUniswap * 1e18) / T_GRAD; // wei eth per token (scaled 1e18)
        uint256 mcap = priceWeiPerWei * TOTAL_SUPPLY / 1e18;
        assertApproxEqRel(mcap, 12.25 ether, 0.0001e18, "graduation mcap should be 12.25 ETH");
    }

    /// @dev Starting market cap must rise monotonically with the locked allocation (relaxation),
    ///      while staying strictly below the graduation marketcap.
    function test_startingMarketcap_risesWithAllocation_belowGraduation() public {
        uint256 prevMcap;
        for (uint256 i; i < 6; ++i) {
            ConstantProductBondingCurveConfigurable curve = _deploy(BPS[i]);
            // marginal start price via a tiny buy
            (uint256 tokensReceived,) = curve.buyTokensWithExactEth(0, 0.00000000001e18);
            uint256 startPrice = (1e18 * 0.00000000001e18) / tokensReceived;
            uint256 startMcap = startPrice * TOTAL_SUPPLY / 1e18;
            assertGt(startMcap, prevMcap, "starting mcap must rise with allocation");
            assertLt(startMcap, 12.25 ether, "starting mcap must stay below graduation mcap");
            prevMcap = startMcap;
        }
        // 30% curve start mcap ~6.69 ETH, well above the base ~2.25 ETH
        assertGt(prevMcap, 6 ether, "30% start mcap should be ~6.69 ETH");
    }

    function test_fuzz_eachCurve_buyDoesNotRevertInRange(uint256 idx, uint256 ethReserves, uint256 ethAmount) public {
        idx = bound(idx, 0, 5);
        ConstantProductBondingCurveConfigurable curve = _deploy(BPS[idx]);
        uint256 maxEth = curve.maxEthReserves();
        ethReserves = bound(ethReserves, 0, maxEth);
        uint256 limit = maxEth - ethReserves;
        if (limit == 0) return;
        ethAmount = bound(ethAmount, 0, limit);
        // within [0, maxEthReserves] the curve must never overflow/revert
        curve.buyTokensWithExactEth(ethReserves, ethAmount);
    }

    function test_fuzz_eachCurve_buyThenSell_roundTrips(uint256 idx, uint256 ethReserves, uint256 ethAmount) public {
        idx = bound(idx, 0, 5);
        ConstantProductBondingCurveConfigurable curve = _deploy(BPS[idx]);
        uint256 maxEth = curve.maxEthReserves();
        ethReserves = bound(ethReserves, 0, maxEth);
        uint256 maxAmount = maxEth - ethReserves;
        if (maxAmount < 0.000001e18) return;
        ethAmount = bound(ethAmount, 0.000001e18, maxAmount);

        (uint256 tokensReceived,) = curve.buyTokensWithExactEth(ethReserves, ethAmount);
        uint256 ethReceived = curve.sellExactTokens(ethReserves + ethAmount, tokensReceived);
        // round-trip loss bounded (rounding only)
        assertLe(ethReceived, ethAmount, "cannot extract more than put in");
        assertApproxEqRel(ethReceived, ethAmount, 0.0000001e18, "buy+sell should round-trip within 0.00001%");
    }

    function test_constructor_rejectsZeroE0() public {
        vm.expectRevert(ConstantProductBondingCurveConfigurable.InvalidCurveConstants.selector);
        new ConstantProductBondingCurveConfigurable(C.K_5, C.T0_5, 0, GRADUATION_THRESHOLD, GRADUATION_MAX_EXCESS);
    }
}
