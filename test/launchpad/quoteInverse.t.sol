// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    LaunchpadBaseTests,
    LaunchpadBaseTestsWithUniv2Graduator,
    LaunchpadBaseTestsWithUniv4Graduator
} from "./base.t.sol";
import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";

abstract contract QuoteInverseTests is LaunchpadBaseTests {
    // Buy round-trip tolerance: fee floor/ceil can cause ±1 wei in ETH terms
    uint256 constant BUY_ABS_TOLERANCE = 2;
    // Sell round-trip tolerance: 1 wei of ETH rounding gets amplified by the curve slope
    // into ~1e8 token-wei. Using 1e9 for margin.
    uint256 constant SELL_ABS_TOLERANCE = 1e9;

    // ─── Buy round-trip: exactEth → tokens → exactTokens → eth' ───

    function testBuyRoundTrip_fixedAmount() public createTestToken {
        uint256 ethIn = 1 ether;
        (,, uint256 tokensOut) = launchpad.quoteBuyWithExactEth(testToken, ethIn);
        (uint256 ethBack,,,) = launchpad.quoteBuyExactTokens(testToken, tokensOut);
        assertApproxEqAbs(ethBack, ethIn, BUY_ABS_TOLERANCE, "buy round-trip ETH mismatch");
    }

    function testBuyRoundTrip_smallAmount() public createTestToken {
        uint256 ethIn = 0.001 ether;
        (,, uint256 tokensOut) = launchpad.quoteBuyWithExactEth(testToken, ethIn);
        (uint256 ethBack,,,) = launchpad.quoteBuyExactTokens(testToken, tokensOut);
        assertApproxEqAbs(ethBack, ethIn, BUY_ABS_TOLERANCE, "buy round-trip ETH mismatch");
    }

    function testBuyRoundTrip_largeAmount() public createTestToken {
        uint256 ethIn = 3 ether;
        (,, uint256 tokensOut) = launchpad.quoteBuyWithExactEth(testToken, ethIn);
        (uint256 ethBack,,,) = launchpad.quoteBuyExactTokens(testToken, tokensOut);
        assertApproxEqAbs(ethBack, ethIn, BUY_ABS_TOLERANCE, "buy round-trip ETH mismatch");
    }

    // ─── Sell round-trip: exactTokens → eth → exactEth → tokens' ───

    function testSellRoundTrip_fixedAmount() public createTestToken {
        _launchpadBuy(testToken, 2 ether);
        uint256 tokensIn = 100_000_000e18;
        (,, uint256 ethOut) = launchpad.quoteSellExactTokens(testToken, tokensIn);
        (uint256 tokensBack,,) = launchpad.quoteSellTokensForExactEth(testToken, ethOut);
        assertApproxEqAbs(tokensBack, tokensIn, SELL_ABS_TOLERANCE, "sell round-trip token mismatch");
    }

    function testSellRoundTrip_smallAmount() public createTestToken {
        _launchpadBuy(testToken, 1 ether);
        uint256 tokensIn = 1_000e18;
        (,, uint256 ethOut) = launchpad.quoteSellExactTokens(testToken, tokensIn);
        (uint256 tokensBack,,) = launchpad.quoteSellTokensForExactEth(testToken, ethOut);
        assertApproxEqAbs(tokensBack, tokensIn, SELL_ABS_TOLERANCE, "sell round-trip token mismatch");
    }

    // ─── Fuzz: buy round-trip ───

    function testFuzz_buyRoundTrip(uint256 ethIn) public createTestToken {
        uint256 maxEth = launchpad.getMaxEthToSpend(testToken);
        ethIn = bound(ethIn, 100, maxEth - 1);

        (,, uint256 tokensOut) = launchpad.quoteBuyWithExactEth(testToken, ethIn);
        if (tokensOut == 0) return;

        (uint256 ethBack,,,) = launchpad.quoteBuyExactTokens(testToken, tokensOut);
        assertApproxEqAbs(ethBack, ethIn, BUY_ABS_TOLERANCE, "fuzz buy round-trip ETH mismatch");
    }

    // ─── Fuzz: sell round-trip ───

    function testFuzz_sellRoundTrip(uint256 ethSeed, uint256 tokensIn) public createTestToken {
        uint256 maxEth = launchpad.getMaxEthToSpend(testToken);
        ethSeed = bound(ethSeed, 0.5 ether, maxEth - 1);
        _launchpadBuy(testToken, ethSeed);

        uint256 ethCollected = launchpad.getTokenState(testToken).ethCollected;
        uint256 maxTokensToSell = bondingCurve.getTokenReserves(0) - bondingCurve.getTokenReserves(ethCollected);
        // Leave 1% margin to avoid InsufficientEthReserves from ceil rounding at the boundary
        maxTokensToSell = maxTokensToSell * 99 / 100;
        if (maxTokensToSell < 1e18) return;
        tokensIn = bound(tokensIn, 1e18, maxTokensToSell);

        (,, uint256 ethOut) = launchpad.quoteSellExactTokens(testToken, tokensIn);
        if (ethOut == 0) return;

        // ethOut must not exceed the available reserves
        if (ethOut > ethCollected) return;

        (uint256 tokensBack,,) = launchpad.quoteSellTokensForExactEth(testToken, ethOut);
        assertApproxEqAbs(tokensBack, tokensIn, SELL_ABS_TOLERANCE, "fuzz sell round-trip token mismatch");
    }

    // ─── Edge cases & reverts ───

    function testBuyExactTokens_revertsOnTooManyTokens() public createTestToken {
        uint256 totalSupply = 1_000_000_000e18;
        vm.expectRevert();
        launchpad.quoteBuyExactTokens(testToken, totalSupply + 1);
    }

    function testSellTokensForExactEth_revertsOnTooMuchEth() public createTestToken {
        _launchpadBuy(testToken, 1 ether);
        uint256 ethCollected = launchpad.getTokenState(testToken).ethCollected;
        vm.expectRevert();
        launchpad.quoteSellTokensForExactEth(testToken, ethCollected + 1 ether);
    }

    function testBuyExactTokens_canGraduateFlag() public createTestToken {
        uint256 graduationEth = 3.75 ether;
        (,, uint256 tokensAtGraduation) = launchpad.quoteBuyWithExactEth(testToken, _increaseWithFees(graduationEth));
        (,,, bool canGraduate) = launchpad.quoteBuyExactTokens(testToken, tokensAtGraduation);
        assertTrue(canGraduate, "should signal graduation");
    }

    function testBuyExactTokens_invalidToken() public {
        vm.expectRevert();
        launchpad.quoteBuyExactTokens(address(0xdead), 1000);
    }

    function testSellTokensForExactEth_invalidToken() public {
        vm.expectRevert();
        launchpad.quoteSellTokensForExactEth(address(0xdead), 1000);
    }
}

contract QuoteInverseTests_Univ2 is QuoteInverseTests, LaunchpadBaseTestsWithUniv2Graduator {
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator) {
        super.setUp();
    }

    modifier createTestToken() override(LaunchpadBaseTests) {
        vm.prank(creator);
        testToken = factoryV2.createToken("TestToken", "TEST", creator, "0x003");
        _;
    }
}

contract QuoteInverseTests_Univ4 is QuoteInverseTests, LaunchpadBaseTestsWithUniv4Graduator {
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv4Graduator) {
        super.setUp();
    }

    modifier createTestToken() override(LaunchpadBaseTests) {
        vm.prank(creator);
        testToken = factoryV4.createToken("TestToken", "TEST", creator, "0x003");
        _;
    }
}
