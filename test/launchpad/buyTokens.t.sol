// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTest} from "./base.t.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TokenState} from "src/types/tokenData.sol";
import {LivoToken} from "src/LivoToken.sol";

contract BuyTokensTest is LaunchpadBaseTest {
    uint256 constant DEADLINE = type(uint256).max;

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
        assertEq(state.circulatingSupply, expectedTokensToReceive);
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
        assertTrue(stateAfterSecond.circulatingSupply > stateAfterFirst.circulatingSupply);
        assertTrue(totalTokensReceived > firstTokensReceived);
        assertTrue(totalFeesCollected > firstFeesCollected);
        assertEq(stateAfterSecond.circulatingSupply, totalTokensReceived);
    }

    function testBuyTwoTimesSameAmount_secondGetsLessTokens() public createTestToken {
        uint256 ethAmount = 1 ether;

        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmount}(testToken, 0, DEADLINE);

        TokenState memory stateAfterFirst = launchpad.getTokenState(testToken);
        uint256 firstTokensReceived = IERC20(testToken).balanceOf(buyer);
        uint256 firstFeesCollected = launchpad.treasuryEthFeesCollected();

        // Second buy
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmount}(testToken, 0, DEADLINE);

        TokenState memory stateAfterSecond = launchpad.getTokenState(testToken);
        uint256 secondTokensReceived = IERC20(testToken).balanceOf(buyer) - firstTokensReceived;
        uint256 totalFeesCollected = launchpad.treasuryEthFeesCollected();

        assertEq(totalFeesCollected, 2 * firstFeesCollected);
        assertLt(
            secondTokensReceived,
            firstTokensReceived,
            "The second purchase should get less tokens as the price is higher"
        );
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
        uint256 graduationThreshold = BASE_GRADUATION_THRESHOLD;

        // Buy up to just before the threshold (accounting for fees)
        // Calculate amount that gets us close but not over threshold
        uint256 targetEthReserves = graduationThreshold - 1 ether; // Stay well below threshold
        uint256 ethAmountToBuy = (targetEthReserves * 10000) / (10000 - BASE_BUY_FEE_BPS);

        vm.deal(buyer, ethAmountToBuy + 1 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmountToBuy}(testToken, 0, DEADLINE);

        TokenState memory state = launchpad.getTokenState(testToken);
        assertTrue(state.ethCollected > 0);
        assertTrue(state.ethCollected < graduationThreshold);
        assertFalse(state.graduated);
    }

    // NOTE the purchase triggering the graduation will be tested extensively in another test contract

    function testBuyTokensWithExactEth_revertExceedsPostGraduationLimit() public createTestToken {
        uint256 graduationThreshold = BASE_GRADUATION_THRESHOLD;
        uint256 maxExcess = 0.5 ether; // MAX_THRESHOLD_EXCEESS

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
        uint256 graduationThreshold = BASE_GRADUATION_THRESHOLD;
        uint256 maxExcess = 0.5 ether; // MAX_THRESHOLD_EXCEESS

        // Buy up to just before the threshold (accounting for fees)
        uint256 targetEthReserves = graduationThreshold - 1 ether; // Stay well below threshold
        uint256 ethAmountToBuy = (targetEthReserves * 10000) / (10000 - BASE_BUY_FEE_BPS);

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
        assertEq(finalState.circulatingSupply, firstBuyerTokens + secondBuyerTokens);
    }
}
