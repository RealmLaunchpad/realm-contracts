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

    function test_getTokensForEth_basic() public {
        uint256 ethAmount = 1e10;
        uint256 circulatingSupply = 0;

        uint256 tokens = curve.getTokensForEth(circulatingSupply, ethAmount);
        assertEq(tokens, 1 ether);
    }

    function test_getTokensForEth_withCirculatingSupply() public {
        uint256 ethAmount = 1e10;
        uint256 circulatingSupply = 1000e18;

        uint256 tokens = curve.getTokensForEth(circulatingSupply, ethAmount);
        assertEq(tokens, 1 ether);
    }

    function test_getTokensForEth_zeroEth() public {
        uint256 ethAmount = 0;
        uint256 circulatingSupply = 0;

        uint256 tokens = curve.getTokensForEth(circulatingSupply, ethAmount);
        assertEq(tokens, 0);
    }

    function test_getEthForTokens_basic() public {
        uint256 tokenAmount = 1e18;
        uint256 circulatingSupply = 0;

        uint256 ethRequired = curve.getEthForTokens(circulatingSupply, tokenAmount);
        assertEq(ethRequired, 1e10);
    }

    function test_getEthForTokens_withCirculatingSupply() public {
        uint256 tokenAmount = 1e18;
        uint256 circulatingSupply = 500e18;

        uint256 ethRequired = curve.getEthForTokens(circulatingSupply, tokenAmount);
        assertEq(ethRequired, 1e10);
    }

    function test_getEthForTokens_zeroTokens() public {
        uint256 tokenAmount = 0;
        uint256 circulatingSupply = 0;

        uint256 ethRequired = curve.getEthForTokens(circulatingSupply, tokenAmount);
        assertEq(ethRequired, 0);
    }

    function test_reciprocal_relationship() public view {
        uint256 ethAmount = 1 ether;
        uint256 circulatingSupply = 100e18;

        uint256 tokens = curve.getTokensForEth(circulatingSupply, ethAmount);
        uint256 ethBack = curve.getEthForTokens(circulatingSupply, tokens);

        assertEq(ethBack, ethAmount);
    }

    function test_constant_price_independence() public view {
        uint256 ethAmount = 1 ether;

        uint256 tokens1 = curve.getTokensForEth(0, ethAmount);
        uint256 tokens2 = curve.getTokensForEth(1000e18, ethAmount);
        uint256 tokens3 = curve.getTokensForEth(1e24, ethAmount);

        assertEq(tokens1, tokens2);
        assertEq(tokens2, tokens3);
    }
}
