// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";

// This is a test file to test the bonding curve ConstantProductBondingCurve
// here are some tests for buyTokensForExactEth(uint256 tokenReserves, uint256 ethReserves, uint256 ethAmount)
// tokenReserves=0, ethReserves=0, ethAmount=1 should mint a non-zero amount of tokens
// tokenReserves=0, ethReserves=0, ethAmount=8e18 should mint 800000000e18 tokens

contract ConstantProductBondingCurveTest is Test {
    ConstantProductBondingCurve public curve;

    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;

    function setUp() public {
        curve = new ConstantProductBondingCurve();
    }

    /////////////////////// TESTING BASIC FUNCTION SHAPE ////////////////////////////////
    function test_tokenReservesAtZeroEthSupply() public {
        uint256 tokenReserves = curve.getTokenReserves(0);
        assertEq(tokenReserves, TOTAL_SUPPLY, "Token reserves should be 1B at start");
    }

    function test_tokenReservesAtGraduation() public {
        uint256 ethReserves = 8e18;
        uint256 tokenReserves = curve.getTokenReserves(ethReserves);
        // here we accept a 0.000001%  error as 200,000,000 is pretty much arbitrary,
        // chosen by the team
        assertApproxEqRel(tokenReserves, 200_000_000e18, 0.00000001e18, "Token reserves should be 200M at graduation");
    }

    function test_buyTokensForExactEth_initialState() public {
        uint256 tokenReserves = TOTAL_SUPPLY;
        uint256 ethReserves = 0;
        uint256 ethAmount = 1;

        uint256 tokens = curve.buyTokensForExactEth(tokenReserves, ethReserves, ethAmount);
        assertTrue(tokens > 0, "Should mint non-zero amount of tokens");
    }

    function test_tokenPriceAtGraduationPoint() public {}

    // function test_buyTokensForExactEth_specificCase() public {
    //     uint256 tokenReserves = TOTAL_SUPPLY;
    //     uint256 ethReserves = 0;
    //     uint256 ethAmount = 8e18;

    //     uint256 tokens = curve.buyTokensForExactEth(tokenReserves, ethReserves, ethAmount);
    //     assertEq(tokens, 800000000e18, "Should mint exactly 800000000e18 tokens");
    // }

    // function test_buyTokensForExactEth_nonZeroSupply() public {
    //     uint256 tokenReserves = 1000e18;
    //     uint256 ethReserves = 1e18;
    //     uint256 ethAmount = 1e18;

    //     uint256 tokens = curve.buyTokensForExactEth(tokenReserves, ethReserves, ethAmount);
    //     assertTrue(tokens > 0, "Should mint positive tokens with existing supply");
    // }

    // function test_buyTokensForExactEth_zeroEth() public {
    //     uint256 tokenReserves = 0;
    //     uint256 ethReserves = 0;
    //     uint256 ethAmount = 0;

    //     uint256 tokens = curve.buyTokensForExactEth(tokenReserves, ethReserves, ethAmount);
    //     assertEq(tokens, 0, "Should mint zero tokens for zero ETH");
    // }

    // function test_buyExactTokens_basic() public {
    //     uint256 tokenReserves = 0;
    //     uint256 ethReserves = 0;
    //     uint256 tokenAmount = 1e18;

    //     uint256 ethRequired = curve.buyExactTokens(tokenReserves, ethReserves, tokenAmount);
    //     assertTrue(ethRequired > 0, "Should require positive ETH for tokens");
    // }

    // function test_buyExactTokens_zeroTokens() public {
    //     uint256 tokenReserves = 100e18;
    //     uint256 ethReserves = 1e18;
    //     uint256 tokenAmount = 0;

    //     uint256 ethRequired = curve.buyExactTokens(tokenReserves, ethReserves, tokenAmount);
    //     assertEq(ethRequired, 0, "Should require zero ETH for zero tokens");
    // }

    // function test_reciprocal_relationship() public {
    //     uint256 tokenReserves = 100e18;
    //     uint256 ethReserves = 1e18;
    //     uint256 ethAmount = 0.1e18;

    //     uint256 tokens = curve.buyTokensForExactEth(tokenReserves, ethReserves, ethAmount);
    //     uint256 ethBack = curve.buyExactTokens(tokenReserves, ethReserves, tokens);

    //     assertApproxEqRel(ethBack, ethAmount, 1e15, "ETH amounts should be approximately equal");
    // }

    // function test_curve_behavior_increasing_price() public {
    //     uint256 tokenReserves = 0;
    //     uint256 ethReserves = 0;
    //     uint256 ethAmount = 1e18;

    //     uint256 tokens1 = curve.buyTokensForExactEth(tokenReserves, ethReserves, ethAmount);

    //     uint256 newTokenReserves = tokenReserves + tokens1;
    //     uint256 newEthReserves = ethReserves + ethAmount;

    //     uint256 tokens2 = curve.buyTokensForExactEth(newTokenReserves, newEthReserves, ethAmount);

    //     assertTrue(tokens2 < tokens1, "Should receive fewer tokens as price increases");
    // }
}
