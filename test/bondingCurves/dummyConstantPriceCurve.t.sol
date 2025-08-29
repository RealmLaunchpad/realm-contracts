// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {DummyConstantPriceCurve} from "src/bondingCurves/DummyConstantPriceCurve.sol";

contract DummyConstantPriceCurveTest is Test {
    DummyConstantPriceCurve public curve;

    // 1e18 means 1 token == 1 eth
    uint256 constant TOKEN_PRICE = 1e10;
    uint256 constant PRECISION = 1e18;

    function setUp() public {
        curve = new DummyConstantPriceCurve();

        curve.setPrice(TOKEN_PRICE);
    }

    function test_buyTokensForExactEth_basic() public {
        uint256 ethAmount = 1e10;
        uint256 tokenReserves = 0;
        uint256 ethReserves = 0;

        uint256 tokens = curve.buyTokensForExactEth(tokenReserves, ethReserves, ethAmount);
        assertEq(tokens, 1 ether);
    }

    function test_buyTokensForExactEth_withTokenReserves() public {
        uint256 ethAmount = 1e10;
        uint256 tokenReserves = 1000e18;
        uint256 ethReserves = 0;

        uint256 tokens = curve.buyTokensForExactEth(tokenReserves, ethReserves, ethAmount);
        assertEq(tokens, 1 ether);
    }

    function test_buyTokensForExactEth_zeroEth() public {
        uint256 ethAmount = 0;
        uint256 tokenReserves = 0;
        uint256 ethReserves = 0;

        uint256 tokens = curve.buyTokensForExactEth(tokenReserves, ethReserves, ethAmount);
        assertEq(tokens, 0);
    }

    function test_buyExactTokens_basic() public {
        uint256 tokenAmount = 1e18;
        uint256 tokenReserves = 0;
        uint256 ethReserves = 0;

        uint256 ethRequired = curve.buyExactTokens(tokenReserves, ethReserves, tokenAmount);
        assertEq(ethRequired, 1e10);
    }

    function test_buyExactTokens_withTokenReserves() public {
        uint256 tokenAmount = 1e18;
        uint256 tokenReserves = 500e18;
        uint256 ethReserves = 0;

        uint256 ethRequired = curve.buyExactTokens(tokenReserves, ethReserves, tokenAmount);
        assertEq(ethRequired, 1e10);
    }

    function test_buyExactTokens_zeroTokens() public {
        uint256 tokenAmount = 0;
        uint256 tokenReserves = 0;
        uint256 ethReserves = 0;

        uint256 ethRequired = curve.buyExactTokens(tokenReserves, ethReserves, tokenAmount);
        assertEq(ethRequired, 0);
    }

    function test_reciprocal_relationship() public view {
        uint256 ethAmount = 1 ether;
        uint256 tokenReserves = 100e18;
        uint256 ethReserves = 0;

        uint256 tokens = curve.buyTokensForExactEth(tokenReserves, ethReserves, ethAmount);
        uint256 ethBack = curve.buyExactTokens(tokenReserves, ethReserves, tokens);

        assertEq(ethBack, ethAmount);
    }

    function test_constant_price_independence() public view {
        uint256 ethAmount = 1 ether;
        uint256 ethReserves = 0;

        uint256 tokens1 = curve.buyTokensForExactEth(0, ethReserves, ethAmount);
        uint256 tokens2 = curve.buyTokensForExactEth(1000e18, ethReserves, ethAmount);
        uint256 tokens3 = curve.buyTokensForExactEth(1e24, ethReserves, ethAmount);

        assertEq(tokens1, tokens2);
        assertEq(tokens2, tokens3);
    }
}
