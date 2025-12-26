// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    LaunchpadBaseTests,
    LaunchpadBaseTestsWithUniv2Graduator,
    LaunchpadBaseTestsWithUniv4Graduator
} from "./base.t.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TokenState} from "src/types/tokenData.sol";
import {LivoToken} from "src/LivoToken.sol";
import {console} from "forge-std/console.sol";

abstract contract BuyTokensTest is LaunchpadBaseTests {
    function testBuyTokensWithExactEth_happyPath() public createTestToken {
        uint256 ethAmount = 1 ether;
        uint256 minTokenAmount = 0;

        uint256 buyerEthBalanceBefore = buyer.balance;
        uint256 buyerTokenBalanceBefore = IERC20(testToken).balanceOf(buyer);
        uint256 launchpadEthBalanceBefore = address(launchpad).balance;

        (uint256 expectedEthForPurchase, uint256 expectedEthFee, uint256 expectedTokensToReceive) =
            launchpad.quoteBuyWithExactEth(testToken, ethAmount);

        vm.prank(buyer);
        vm.expectEmit(true, true, false, true);
        emit LivoLaunchpad.LivoTokenBuy(testToken, buyer, ethAmount, expectedTokensToReceive, expectedEthFee);
        launchpad.buyTokensWithExactEth{value: ethAmount}(testToken, minTokenAmount, DEADLINE);

        assertEq(buyer.balance, buyerEthBalanceBefore - ethAmount);
        assertEq(IERC20(testToken).balanceOf(buyer), buyerTokenBalanceBefore + expectedTokensToReceive);
        assertEq(address(launchpad).balance, launchpadEthBalanceBefore + ethAmount);
        assertEq(IERC20(testToken).balanceOf(address(launchpad)), TOTAL_SUPPLY - expectedTokensToReceive);

        TokenState memory state = launchpad.getTokenState(testToken);
        assertEq(state.ethCollected, expectedEthForPurchase);
        assertEq(state.releasedSupply, expectedTokensToReceive);
        assertEq(launchpad.treasuryEthFeesCollected(), expectedEthFee);
    }

    function testBuyTokensWithExactEth_multipleBuys() public createTestToken {
        uint256 firstBuyAmount = 0.5 ether;
        uint256 secondBuyAmount = 1.5 ether;

        // First buy
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: firstBuyAmount}(testToken, 0, DEADLINE);

        TokenState memory stateAfterFirst = launchpad.getTokenState(testToken);
        uint256 firstTokensReceived = IERC20(testToken).balanceOf(buyer);
        uint256 firstFeesCollected = launchpad.treasuryEthFeesCollected();

        // Second buy
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: secondBuyAmount}(testToken, 0, DEADLINE);

        TokenState memory stateAfterSecond = launchpad.getTokenState(testToken);
        uint256 totalTokensReceived = IERC20(testToken).balanceOf(buyer);
        uint256 totalFeesCollected = launchpad.treasuryEthFeesCollected();

        assertTrue(stateAfterSecond.ethCollected > stateAfterFirst.ethCollected);
        assertTrue(stateAfterSecond.releasedSupply > stateAfterFirst.releasedSupply);
        assertTrue(totalTokensReceived > firstTokensReceived);
        assertTrue(totalFeesCollected > firstFeesCollected);
        assertEq(stateAfterSecond.releasedSupply, totalTokensReceived);
    }

    function testBuyTwoTimesSameAmount_secondGetsLessTokens() public createTestToken {
        uint256 ethAmount = 1 ether;

        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmount}(testToken, 0, DEADLINE);

        uint256 firstTokensReceived = IERC20(testToken).balanceOf(buyer);
        uint256 firstFeesCollected = launchpad.treasuryEthFeesCollected();

        // Second buy
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmount}(testToken, 0, DEADLINE);

        uint256 secondTokensReceived = IERC20(testToken).balanceOf(buyer) - firstTokensReceived;
        uint256 totalFeesCollected = launchpad.treasuryEthFeesCollected();

        assertEq(totalFeesCollected, 2 * firstFeesCollected);
        assertLt(
            secondTokensReceived,
            firstTokensReceived,
            "The second purchase should get less tokens as the price is higher"
        );
    }

    function test_quoteInitialPrice() public createTestToken {
        // how many tokens do you get with the first wei?
        (,, uint256 expectedTokens) = launchpad.quoteBuyWithExactEth(testToken, 1);
        assertApproxEqAbs(expectedTokens, 393333333, 1);
    }

    function testBuyTokensWithExactEth_withMinTokenAmount() public createTestToken {
        uint256 ethAmount = 1 ether;

        (,, uint256 expectedTokens) = launchpad.quoteBuyWithExactEth(testToken, ethAmount);

        // Should succeed with exact min amount
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmount}(testToken, expectedTokens, DEADLINE);

        assertEq(IERC20(testToken).balanceOf(buyer), expectedTokens);
    }

    function testBuyTokensWithExactEth_slippageProtection() public createTestToken {
        uint256 ethAmount = 1 ether;

        (,, uint256 expectedTokens) = launchpad.quoteBuyWithExactEth(testToken, ethAmount);
        // Set min higher than expected to trigger slippage protection
        uint256 minTokenAmount = expectedTokens + 1;

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.SlippageExceeded.selector));
        launchpad.buyTokensWithExactEth{value: ethAmount}(testToken, minTokenAmount, DEADLINE);
    }

    function testBuyTokensWithExactEth_revertZeroEth() public createTestToken {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.InvalidAmount.selector));
        launchpad.buyTokensWithExactEth{value: 0}(testToken, 0, DEADLINE);
    }

    function testBuyTokensWithExactEth_revertInvalidToken() public {
        LivoToken invalidToken = new LivoToken();

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.InvalidToken.selector));
        launchpad.buyTokensWithExactEth{value: 1 ether}(address(invalidToken), 0, DEADLINE);
    }

    function testBuyTokensWithExactEth_revertDeadlineExceeded() public createTestToken {
        uint256 deadline = block.timestamp + 1 minutes;

        skip(2 minutes);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.DeadlineExceeded.selector));
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, deadline);
    }

    function testBuyTokensWithExactEth_nearGraduationThreshold() public createTestToken {
        // Test buying close to graduation threshold without actually graduating
        uint256 graduationThreshold = GRADUATION_THRESHOLD;

        // Buy up to just before the threshold (accounting for fees)
        // Calculate amount that gets us close but not over threshold
        uint256 targetEthReserves = graduationThreshold - 1 ether; // Stay well below threshold
        uint256 ethAmountToBuy = _increaseWithFees(targetEthReserves);

        vm.deal(buyer, ethAmountToBuy + 1 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmountToBuy}(testToken, 0, DEADLINE);

        TokenState memory state = launchpad.getTokenState(testToken);
        assertTrue(state.ethCollected > 0);
        assertTrue(state.ethCollected < graduationThreshold);
        assertFalse(state.graduated);
    }

    function testBuyTokensWithExactEth_revertExceedsPostGraduationLimit() public createTestToken {
        uint256 graduationThreshold = GRADUATION_THRESHOLD;
        uint256 maxExcess = 0.5 ether; // MAX_THRESHOLD_EXCESS

        // Try to buy way beyond the excess limit
        uint256 excessiveAmount = graduationThreshold + maxExcess + 0.1 ether;

        vm.deal(buyer, excessiveAmount);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.PurchaseExceedsLimitPostGraduation.selector));
        launchpad.buyTokensWithExactEth{value: excessiveAmount}(testToken, 0, DEADLINE);
    }

    function testBuyTokensWithExactEth_someBuysTakesItNearGraduation_thenExceedPostGraduationLimit()
        public
        createTestToken
    {
        uint256 graduationThreshold = GRADUATION_THRESHOLD;
        uint256 maxExcess = 0.5 ether; // MAX_THRESHOLD_EXCESS

        // Buy up to just before the threshold (accounting for fees)
        uint256 targetEthReserves = graduationThreshold - 1 ether; // Stay well below threshold
        uint256 ethAmountToBuy = _increaseWithFees(targetEthReserves);

        vm.deal(buyer, ethAmountToBuy + 1 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmountToBuy}(testToken, 0, DEADLINE);

        TokenState memory state = launchpad.getTokenState(testToken);
        assertTrue(state.ethCollected > 0);
        assertFalse(state.graduated);

        // Now try to exceed the post-graduation limit
        uint256 excessiveAmount = graduationThreshold + maxExcess + 0.1 ether;

        vm.deal(buyer, excessiveAmount);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.PurchaseExceedsLimitPostGraduation.selector));
        launchpad.buyTokensWithExactEth{value: excessiveAmount}(testToken, 0, DEADLINE);
    }

    function testBuyTokensWithExactEth_feeCalculation() public createTestToken {
        uint256 ethAmount = 1 ether;
        uint256 expectedFee = 0.01 ether;
        uint256 expectedEthForPurchase = ethAmount - expectedFee;

        (uint256 actualEthForPurchase, uint256 actualFee,) = launchpad.quoteBuyWithExactEth(testToken, ethAmount);

        assertEq(actualFee, expectedFee);
        assertEq(actualEthForPurchase, expectedEthForPurchase);

        uint256 feesBefore = launchpad.treasuryEthFeesCollected();

        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmount}(testToken, 0, DEADLINE);

        uint256 feesAfter = launchpad.treasuryEthFeesCollected();
        assertEq(feesAfter - feesBefore, expectedFee);

        TokenState memory state = launchpad.getTokenState(testToken);
        assertEq(state.ethCollected, expectedEthForPurchase);
    }

    function testBuyTokensWithExactEth_quotingAccuracy() public createTestToken {
        uint256 ethAmount = 5 ether;

        (uint256 quotedEthForPurchase, uint256 quotedEthFee, uint256 quotedTokens) =
            launchpad.quoteBuyWithExactEth(testToken, ethAmount);

        uint256 treasuryFeesBefore = launchpad.treasuryEthFeesCollected();
        TokenState memory stateBefore = launchpad.getTokenState(testToken);

        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmount}(testToken, 0, DEADLINE);

        uint256 treasuryFeesAfter = launchpad.treasuryEthFeesCollected();
        TokenState memory stateAfter = launchpad.getTokenState(testToken);
        uint256 tokensReceived = IERC20(testToken).balanceOf(buyer);

        // Verify quote accuracy
        assertEq(treasuryFeesAfter - treasuryFeesBefore, quotedEthFee);
        assertEq(stateAfter.ethCollected - stateBefore.ethCollected, quotedEthForPurchase);
        assertEq(tokensReceived, quotedTokens);
    }

    function testBuyTokensWithExactEth_differentBuyers() public createTestToken {
        address secondBuyer = makeAddr("secondBuyer");
        vm.deal(secondBuyer, INITIAL_ETH_BALANCE);

        uint256 firstBuyAmount = 1 ether;
        uint256 secondBuyAmount = 2 ether;

        // First buyer
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: firstBuyAmount}(testToken, 0, DEADLINE);

        uint256 firstBuyerTokens = IERC20(testToken).balanceOf(buyer);

        // Second buyer
        vm.prank(secondBuyer);
        launchpad.buyTokensWithExactEth{value: secondBuyAmount}(testToken, 0, DEADLINE);

        uint256 secondBuyerTokens = IERC20(testToken).balanceOf(secondBuyer);

        assertTrue(firstBuyerTokens > 0);
        assertTrue(secondBuyerTokens > 0);
        assertEq(IERC20(testToken).balanceOf(buyer), firstBuyerTokens); // First buyer balance unchanged

        TokenState memory finalState = launchpad.getTokenState(testToken);
        assertEq(finalState.releasedSupply, firstBuyerTokens + secondBuyerTokens);
    }

    function testBuyTokensWithExactEth_multipleBuysEqualsBigBuy() public createTestToken {
        uint256 singleBuyAmount = 0.5 ether;
        uint256 numberOfBuys = 4;
        uint256 totalBuyAmount = singleBuyAmount * numberOfBuys;

        // Scenario 1: Multiple small buys
        address buyer1 = makeAddr("buyer1");
        vm.deal(buyer1, totalBuyAmount);

        for (uint256 i = 0; i < numberOfBuys; i++) {
            vm.prank(buyer1);
            launchpad.buyTokensWithExactEth{value: singleBuyAmount}(testToken, 0, DEADLINE);
        }

        uint256 tokensFromMultipleBuys = IERC20(testToken).balanceOf(buyer1);
        TokenState memory stateAfterMultiple = launchpad.getTokenState(testToken);

        // Reset state by creating a new token for the second scenario
        vm.prank(creator);
        address testToken2 = launchpad.createToken(
            "Test Token 2", "TT2", address(implementation), address(bondingCurve), address(graduator), creator, "0x12"
        );

        // Scenario 2: One big buy
        address buyer2 = makeAddr("buyer2");
        vm.deal(buyer2, totalBuyAmount);

        vm.prank(buyer2);
        launchpad.buyTokensWithExactEth{value: totalBuyAmount}(testToken2, 0, DEADLINE);

        uint256 tokensFromBigBuy = IERC20(testToken2).balanceOf(buyer2);
        TokenState memory stateAfterBig = launchpad.getTokenState(testToken2);

        // The final state should be the same (allow a 10wei error)
        assertApproxEqAbs(tokensFromMultipleBuys, tokensFromBigBuy, 10, "Multiple small buys should equal one big buy");
        assertEq(stateAfterMultiple.ethCollected, stateAfterBig.ethCollected, "ETH collected should be the same");
        assertApproxEqAbs(
            stateAfterMultiple.releasedSupply, stateAfterBig.releasedSupply, 10, "Circulating supply should be the same"
        );
    }

    /// @notice Test funds collected match reserves and fees
    function test_balanceChangesMatchesReservesAndFees() public createTestToken {
        vm.deal(buyer, 100 ether);
        uint256 initialLaunchpadBalance = address(launchpad).balance;

        // buy but not graduate
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: GRADUATION_THRESHOLD - 1 ether}(testToken, 0, DEADLINE);

        assertEq(
            address(launchpad).balance - initialLaunchpadBalance,
            launchpad.getTokenState(testToken).ethCollected + launchpad.treasuryEthFeesCollected(),
            "eth balance should match reserves + fees"
        );
    }

    /// @notice Given a fuzzed starting point in the curve, two consecutive buys of the same amount should yield a higher price the second time
    function test_fuzz_twoConsecutiveBuysSecondPriceIsHigher(uint256 ethForPreBuy, uint256 ethForComparison)
        public
        createTestToken
    {
        uint256 maxTotalEth = GRADUATION_THRESHOLD + MAX_THRESHOLD_EXCESS;
        // if the token graduates from the first one, the next one is pointless
        ethForPreBuy = bound(ethForPreBuy, 1, GRADUATION_THRESHOLD - 2);
        ethForComparison = bound(ethForComparison, 1, (maxTotalEth - ethForPreBuy) / 2);

        vm.deal(buyer, 10 ether);
        vm.deal(seller, 10 ether);

        // this is bascially to get a random starting point in the curve
        launchpad.buyTokensWithExactEth{value: ethForPreBuy}(testToken, 0, DEADLINE);

        // first buy
        uint256 initialTokenBalance = IERC20(testToken).balanceOf(buyer);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: ethForComparison}(testToken, 0, DEADLINE);
        uint256 tokensReceived1 = IERC20(testToken).balanceOf(buyer) - initialTokenBalance;
        uint256 firstPrice = (ethForComparison * 1e18) / tokensReceived1;

        // if graduated here, the next part is pointless. Return
        if (launchpad.getTokenState(testToken).graduated) {
            return;
        }

        // second buy
        initialTokenBalance = IERC20(testToken).balanceOf(seller);
        vm.prank(seller);
        launchpad.buyTokensWithExactEth{value: ethForComparison}(testToken, 0, DEADLINE);
        uint256 tokensReceived2 = IERC20(testToken).balanceOf(seller) - initialTokenBalance;
        uint256 secondPrice = (ethForComparison * 1e18) / tokensReceived2;

        assertGe(secondPrice, firstPrice, "The second purchase should get a higher price");
    }

    function test_quoteBuyTokens_invalidToken() public {
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.InvalidToken.selector));
        launchpad.quoteBuyWithExactEth(address(0), 1 ether);
    }

    function test_quoteSellTokens_invalidToken() public {
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.InvalidToken.selector));
        launchpad.quoteSellExactTokens(address(0), 1 ether);
    }

    function test_quoteBuyTokens_rightBelowHittingExcessLimit() public createTestToken {
        uint256 maxValue = _increaseWithFees(GRADUATION_THRESHOLD + MAX_THRESHOLD_EXCESS + 1);

        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.PurchaseExceedsLimitPostGraduation.selector));
        launchpad.quoteBuyWithExactEth(testToken, maxValue);

        // however, one wei less should be fine
        uint256 maxValueJustBelow = maxValue - 1;
        (uint256 ethForPurchase, uint256 ethFee, uint256 tokensToReceive) =
            launchpad.quoteBuyWithExactEth(testToken, maxValueJustBelow);

        assertGt(tokensToReceive, 0, "No tokens received");
        assertEq(ethForPurchase + ethFee, maxValueJustBelow, "Amounts don't add up");
    }

    function test_fuzzBuyMaxEth(uint256 firstEthBuy) public createTestToken {
        uint256 limit = _increaseWithFees(GRADUATION_THRESHOLD) - 1;
        firstEthBuy = bound(firstEthBuy, 1, limit);

        vm.deal(buyer, 20 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: firstEthBuy}(testToken, 0, DEADLINE);

        uint256 secondBuyMaxEth = launchpad.getMaxEthToSpend(testToken);
        console.log("secondBuy", secondBuyMaxEth);

        uint256 ethReserves = launchpad.getTokenState(testToken).ethCollected;
        uint256 expectedMaxEth = _increaseWithFees(GRADUATION_THRESHOLD + MAX_THRESHOLD_EXCESS - ethReserves);
        assertEq(secondBuyMaxEth, expectedMaxEth, "Max ETH to spend mismatch");

        // this call should always go through because getMaxEthToSpend should not give you a value that would revert when buying
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: secondBuyMaxEth}(testToken, 0, DEADLINE);
    }
}

/// @dev run all the tests in ProtocolAgnosticGraduationTests, with Uniswap V2 graduator
contract BuyTokenTests_Univ2 is BuyTokensTest, LaunchpadBaseTestsWithUniv2Graduator {
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator) {
        super.setUp();
    }
}

/// @dev run all the tests in ProtocolAgnosticGraduationTests, with Uniswap V4 graduator
contract BuyTokenTests_Univ4 is BuyTokensTest, LaunchpadBaseTestsWithUniv4Graduator {
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv4Graduator) {
        super.setUp();
    }
}
