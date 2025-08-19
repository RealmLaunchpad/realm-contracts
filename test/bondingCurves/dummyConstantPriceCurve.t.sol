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

    function test_ethToTokens_onBuy_basic() public {
        uint256 ethAmount = 1e10;
        uint256 circulatingSupply = 0;
        uint256 ethReserves = 0;

        uint256 tokens = curve.ethToTokens_onBuy(circulatingSupply, ethReserves, ethAmount);
        assertEq(tokens, 1 ether);
    }

    function test_ethToTokens_onBuy_withCirculatingSupply() public {
        uint256 ethAmount = 1e10;
        uint256 circulatingSupply = 1000e18;
        uint256 ethReserves = 0;

        uint256 tokens = curve.ethToTokens_onBuy(circulatingSupply, ethReserves, ethAmount);
        assertEq(tokens, 1 ether);
    }

    function test_ethToTokens_onBuy_zeroEth() public {
        uint256 ethAmount = 0;
        uint256 circulatingSupply = 0;
        uint256 ethReserves = 0;

        uint256 tokens = curve.ethToTokens_onBuy(circulatingSupply, ethReserves, ethAmount);
        assertEq(tokens, 0);
    }

    function test_tokensToEth_onBuy_basic() public {
        uint256 tokenAmount = 1e18;
        uint256 circulatingSupply = 0;
        uint256 ethReserves = 0;

        uint256 ethRequired = curve.tokensToEth_onBuy(circulatingSupply, ethReserves, tokenAmount);
        assertEq(ethRequired, 1e10);
    }

    function test_tokensToEth_onBuy_withCirculatingSupply() public {
        uint256 tokenAmount = 1e18;
        uint256 circulatingSupply = 500e18;
        uint256 ethReserves = 0;

        uint256 ethRequired = curve.tokensToEth_onBuy(circulatingSupply, ethReserves, tokenAmount);
        assertEq(ethRequired, 1e10);
    }

    function test_tokensToEth_onBuy_zeroTokens() public {
        uint256 tokenAmount = 0;
        uint256 circulatingSupply = 0;
        uint256 ethReserves = 0;

        uint256 ethRequired = curve.tokensToEth_onBuy(circulatingSupply, ethReserves, tokenAmount);
        assertEq(ethRequired, 0);
    }

    function test_reciprocal_relationship() public view {
        uint256 ethAmount = 1 ether;
        uint256 circulatingSupply = 100e18;
        uint256 ethReserves = 0;

        uint256 tokens = curve.ethToTokens_onBuy(circulatingSupply, ethReserves, ethAmount);
        uint256 ethBack = curve.tokensToEth_onBuy(circulatingSupply, ethReserves, tokens);

        assertEq(ethBack, ethAmount);
    }

    function test_constant_price_independence() public view {
        uint256 ethAmount = 1 ether;
        uint256 ethReserves = 0;

        uint256 tokens1 = curve.ethToTokens_onBuy(0, ethReserves, ethAmount);
        uint256 tokens2 = curve.ethToTokens_onBuy(1000e18, ethReserves, ethAmount);
        uint256 tokens3 = curve.ethToTokens_onBuy(1e24, ethReserves, ethAmount);

        assertEq(tokens1, tokens2);
        assertEq(tokens2, tokens3);
    }
}
