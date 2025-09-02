// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";

// This is a test file to test the bonding curve ConstantProductBondingCurve
contract ConstantProductBondingCurveTest is Test {
    ConstantProductBondingCurve public curve;

    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;

    // Graduation parameters
    // These ones are set in the LivoLaunchpad contract, and the curves need to be compliant with them
    uint256 constant GRADUATION_THRESHOLD = 7956000000000052224; // ~7.956 ETH
    uint256 constant GRADUATION_ETH_FEE = 0.5 ether;
    uint256 constant GRADUATION_TOKEN_CREATOR_REWARD = 10_000_000e18;

    function setUp() public {
        curve = new ConstantProductBondingCurve();
    }

    /////////////////////// TESTING BASIC FUNCTION SHAPE ////////////////////////////////
    function test_tokenReservesAtZeroEthSupply() public {
        uint256 tokenReserves = curve.getTokenReserves(0);
        assertEq(tokenReserves, TOTAL_SUPPLY, "Token reserves should be 1B at start");
    }

    function test_tokenReservesAtGraduation() public {
        uint256 tokenReserves = curve.getTokenReserves(GRADUATION_THRESHOLD);
        // here we accept a 0.1%  error as 200,000,000 is pretty much arbitraryf
        // note that 1M are for the token creator, included in this tokenReserves
        assertApproxEqRel(
            tokenReserves, 201_000_000e18, 0.001e18, "Token reserves should be 201M at graduation (1M for creator)"
        );
    }

    function test_buyTokensWithExactEth_initialState() public {
        uint256 tokenReserves = TOTAL_SUPPLY;
        uint256 ethReserves = 0;
        uint256 ethAmount = 1;

        uint256 tokens = curve.buyTokensWithExactEth(tokenReserves, ethReserves, ethAmount);
        assertTrue(tokens > 0, "Should mint non-zero amount of tokens");
    }

    function _uniswapV2EstimatedPrice(uint256 tokenReserves, uint256 ethReserves) internal pure returns (uint256) {
        if (tokenReserves == 0 || ethReserves == 0) return 0;
        return (ethReserves * 1e18) / tokenReserves;
    }

    function test_tokenPriceAtGraduationPoint_matchesUniswap() public {
        // reserves pre-graduation
        uint256 tokenReserves = curve.getTokenReserves(GRADUATION_THRESHOLD);
        uint256 ethReserves = GRADUATION_THRESHOLD;
        uint256 curvePrice = curve.buyExactTokens(tokenReserves, ethReserves, 1e18);

        // then we take the graduation fee and tokens for creators, and calculate the Uniswap price
        uint256 tokenReservesForUniswap = tokenReserves - GRADUATION_TOKEN_CREATOR_REWARD;
        uint256 ethReservesForUniswap = ethReserves - GRADUATION_ETH_FEE;
        uint256 uniswapPrice = _uniswapV2EstimatedPrice(tokenReservesForUniswap, ethReservesForUniswap);

        // accept an price change of %0.001 between uniswap and bonding curve at the moment of graduation
        assertApproxEqRel(curvePrice, uniswapPrice, 0.00001e18, "Token prices should match at graduation point");
    }

    // todo sell tokens tests
}
