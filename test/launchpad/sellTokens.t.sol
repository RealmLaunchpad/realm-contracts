// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    LaunchpadBaseTests,
    LaunchpadBaseTestsWithUniv2Graduator,
    LaunchpadBaseTestsWithUniv4Graduator,
    LaunchpadBaseTestsWithUniv4GraduatorTaxableToken
} from "./base.t.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TokenState} from "src/types/tokenData.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {IERC20Errors} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

abstract contract SellTokensTest is LaunchpadBaseTests {
    uint256 constant ONE_ETH_BUY = 1 ether;
    uint256 constant TWO_ETH_BUY = 2 ether;

    modifier afterOneBuy() {
        vm.prank(alice);
        launchpad.buyTokensWithExactEth{value: ONE_ETH_BUY}(testToken, 0, DEADLINE);
        _;
    }

    modifier afterMultipleBuys() {
        vm.prank(alice);
        launchpad.buyTokensWithExactEth{value: ONE_ETH_BUY}(testToken, 0, DEADLINE);

        vm.prank(bob);
        launchpad.buyTokensWithExactEth{value: TWO_ETH_BUY}(testToken, 0, DEADLINE);
        _;
    }

    modifier afterBuyAndPartialSell() {
        vm.prank(alice);
        launchpad.buyTokensWithExactEth{value: TWO_ETH_BUY}(testToken, 0, DEADLINE);

        uint256 tokensToSell = IERC20(testToken).balanceOf(alice) / 2;
        vm.prank(alice);
        IERC20(testToken).approve(address(launchpad), tokensToSell);
        vm.prank(alice);
        launchpad.sellExactTokens(testToken, tokensToSell, 0, DEADLINE);
        _;
    }

    function testSellExactTokens_happyPath() public createTestToken afterOneBuy {
        uint256 tokensToSell = IERC20(testToken).balanceOf(alice);
        uint256 aliceEthBalanceBefore = alice.balance;
        uint256 aliceTokenBalanceBefore = IERC20(testToken).balanceOf(alice);
        uint256 launchpadEthBalanceBefore = address(launchpad).balance;

        (, uint256 expectedEthFee, uint256 expectedEthForSeller) =
            launchpad.quoteSellExactTokens(testToken, tokensToSell);

        vm.prank(alice);
        IERC20(testToken).approve(address(launchpad), tokensToSell);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit LivoLaunchpad.LivoTokenSell(testToken, alice, tokensToSell, expectedEthForSeller, expectedEthFee);
        launchpad.sellExactTokens(testToken, tokensToSell, 0, DEADLINE);

        assertEq(alice.balance, aliceEthBalanceBefore + expectedEthForSeller);
        assertEq(IERC20(testToken).balanceOf(alice), aliceTokenBalanceBefore - tokensToSell);
        assertEq(address(launchpad).balance, launchpadEthBalanceBefore - expectedEthForSeller);
        assertEq(
            IERC20(testToken).balanceOf(address(launchpad)),
            TOTAL_SUPPLY,
            "all the supply was sold back to the launchpad"
        );

        TokenState memory state = launchpad.getTokenState(testToken);
        assertEq(state.releasedSupply, 0);
        assertEq(launchpad.treasuryEthFeesCollected(), 0.01 ether + expectedEthFee); // Buy fee + sell fee
    }

    function testSellExactTokens_partialSell() public createTestToken afterOneBuy {
        uint256 totalTokens = IERC20(testToken).balanceOf(alice);
        uint256 tokensToSell = totalTokens / 2;
        uint256 tokensToKeep = totalTokens - tokensToSell;
        uint256 launchpadBalanceBefore = address(launchpad).balance;

        TokenState memory stateBefore = launchpad.getTokenState(testToken);

        vm.prank(alice);
        IERC20(testToken).approve(address(launchpad), tokensToSell);
        vm.prank(alice);
        launchpad.sellExactTokens(testToken, tokensToSell, 0, DEADLINE);

        assertEq(IERC20(testToken).balanceOf(alice), tokensToKeep);

        TokenState memory stateAfter = launchpad.getTokenState(testToken);
        assertEq(stateAfter.releasedSupply, stateBefore.releasedSupply - tokensToSell);
        assertLt(stateAfter.ethCollected, stateBefore.ethCollected);
        // Verify that launchpad balance decreased due to selling tokens
        assertGt(launchpadBalanceBefore, address(launchpad).balance);
    }

    function testSellExactTokens_multipleSells() public createTestToken afterOneBuy {
        uint256 totalTokens = IERC20(testToken).balanceOf(alice);
        uint256 firstSell = totalTokens / 3;
        uint256 secondSell = totalTokens / 3;

        // First sell
        vm.prank(alice);
        IERC20(testToken).approve(address(launchpad), firstSell);
        vm.prank(alice);
        launchpad.sellExactTokens(testToken, firstSell, 0, DEADLINE);

        TokenState memory stateAfterFirst = launchpad.getTokenState(testToken);
        uint256 ethAfterFirst = alice.balance;

        // Second sell
        vm.prank(alice);
        IERC20(testToken).approve(address(launchpad), secondSell);
        vm.prank(alice);
        launchpad.sellExactTokens(testToken, secondSell, 0, DEADLINE);

        TokenState memory stateAfterSecond = launchpad.getTokenState(testToken);
        uint256 ethAfterSecond = alice.balance;

        assertLt(stateAfterSecond.ethCollected, stateAfterFirst.ethCollected);
        assertLt(stateAfterSecond.releasedSupply, stateAfterFirst.releasedSupply);
        assertGt(ethAfterSecond, ethAfterFirst);
        assertEq(stateAfterSecond.releasedSupply, stateAfterFirst.releasedSupply - secondSell);
    }

    function testSellExactTokens_differentSellers() public createTestToken afterMultipleBuys {
        uint256 aliceTokens = IERC20(testToken).balanceOf(alice);
        uint256 bobTokens = IERC20(testToken).balanceOf(bob);

        uint256 aliceTokensToSell = aliceTokens / 2;
        uint256 bobTokensToSell = bobTokens / 2;

        // Buyer sells
        vm.prank(alice);
        IERC20(testToken).approve(address(launchpad), aliceTokensToSell);
        vm.prank(alice);
        launchpad.sellExactTokens(testToken, aliceTokensToSell, 0, DEADLINE);

        uint256 aliceEthAfterSell = alice.balance;

        // Seller sells
        vm.prank(bob);
        IERC20(testToken).approve(address(launchpad), bobTokensToSell);
        vm.prank(bob);
        launchpad.sellExactTokens(testToken, bobTokensToSell, 0, DEADLINE);

        uint256 bobEthAfterSell = bob.balance;

        assertEq(IERC20(testToken).balanceOf(alice), aliceTokens - aliceTokensToSell);
        assertEq(IERC20(testToken).balanceOf(bob), bobTokens - bobTokensToSell);
        assertGt(aliceEthAfterSell, INITIAL_ETH_BALANCE - ONE_ETH_BUY);
        assertGt(bobEthAfterSell, INITIAL_ETH_BALANCE - TWO_ETH_BUY);
    }

    function testSellExactTokens_sellAfterBuyGetsLessEth() public createTestToken afterOneBuy {
        uint256 tokensOwned = IERC20(testToken).balanceOf(alice);
        uint256 ethSpentOnBuy = ONE_ETH_BUY;

        vm.prank(alice);
        IERC20(testToken).approve(address(launchpad), tokensOwned);
        vm.prank(alice);
        launchpad.sellExactTokens(testToken, tokensOwned, 0, DEADLINE);

        uint256 ethReceivedFromSell = alice.balance - (INITIAL_ETH_BALANCE - ethSpentOnBuy);

        // Should get less ETH than spent due to fees and bonding curve slippage
        assertLt(ethReceivedFromSell, ethSpentOnBuy);
    }

    function testSellExactTokens_sameSellAmountGetsLessEthWhenPriceIsLower() public createTestToken {
        // First: buy some tokens and sell half
        vm.prank(alice);
        launchpad.buyTokensWithExactEth{value: TWO_ETH_BUY}(testToken, 0, DEADLINE);

        uint256 tokensToSell = IERC20(testToken).balanceOf(alice) / 2;

        vm.prank(alice);
        IERC20(testToken).approve(address(launchpad), tokensToSell);
        vm.prank(alice);
        launchpad.sellExactTokens(testToken, tokensToSell, 0, DEADLINE);

        uint256 ethFromFirstSell = alice.balance - (INITIAL_ETH_BALANCE - TWO_ETH_BUY);

        // Now sell the remaining tokens (same amount)
        uint256 remainingTokens = IERC20(testToken).balanceOf(alice);
        assertEq(remainingTokens, tokensToSell); // Should be the same amount

        vm.prank(alice);
        IERC20(testToken).approve(address(launchpad), remainingTokens);
        vm.prank(alice);
        launchpad.sellExactTokens(testToken, remainingTokens, 0, DEADLINE);

        uint256 ethFromSecondSell = alice.balance - (INITIAL_ETH_BALANCE - TWO_ETH_BUY) - ethFromFirstSell;

        // Second sell should give less ETH as price is lower
        assertLt(ethFromSecondSell, ethFromFirstSell);
    }

    function testSellExactTokens_withMinEthAmount() public createTestToken afterOneBuy {
        uint256 tokensToSell = IERC20(testToken).balanceOf(alice);

        (,, uint256 expectedEthForSeller) = launchpad.quoteSellExactTokens(testToken, tokensToSell);

        vm.prank(alice);
        IERC20(testToken).approve(address(launchpad), tokensToSell);
        vm.prank(alice);
        launchpad.sellExactTokens(testToken, tokensToSell, expectedEthForSeller, DEADLINE);

        assertEq(IERC20(testToken).balanceOf(alice), 0);
    }

    function testSellExactTokens_revertZeroTokenAmount() public createTestToken afterOneBuy {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.InvalidAmount.selector));
        launchpad.sellExactTokens(testToken, 0, 0, DEADLINE);
    }

    function testSellExactTokens_revertInvalidToken() public {
        LivoToken invalidToken = new LivoToken();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.InvalidToken.selector));
        launchpad.sellExactTokens(address(invalidToken), 100, 0, DEADLINE);
    }

    function testSellExactTokens_revertDeadlineExceeded() public createTestToken afterOneBuy {
        uint256 tokensToSell = IERC20(testToken).balanceOf(alice);
        uint256 deadline = block.timestamp + 1 minutes;

        skip(2 minutes);

        vm.prank(alice);
        IERC20(testToken).approve(address(launchpad), tokensToSell);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.DeadlineExceeded.selector));
        launchpad.sellExactTokens(testToken, tokensToSell, 0, deadline);
    }

    function testSellExactTokens_revertSlippageExceeded() public createTestToken afterOneBuy {
        uint256 tokensToSell = IERC20(testToken).balanceOf(alice);

        (,, uint256 expectedEthForSeller) = launchpad.quoteSellExactTokens(testToken, tokensToSell);
        uint256 minEthAmount = expectedEthForSeller + 1; // Set min higher than expected

        vm.prank(alice);
        IERC20(testToken).approve(address(launchpad), tokensToSell);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.SlippageExceeded.selector));
        launchpad.sellExactTokens(testToken, tokensToSell, minEthAmount, DEADLINE);
    }

    function testSellExactTokens_feeCalculation() public createTestToken afterOneBuy {
        uint256 tokensToSell = IERC20(testToken).balanceOf(alice);

        (uint256 expectedEthFromSale, uint256 expectedEthFee, uint256 expectedEthForSeller) =
            launchpad.quoteSellExactTokens(testToken, tokensToSell);

        assertEq(expectedEthForSeller, expectedEthFromSale - expectedEthFee);
        assertEq(expectedEthFee, (expectedEthFromSale * BASE_SELL_FEE_BPS) / 10000);

        uint256 treasuryFeesBefore = launchpad.treasuryEthFeesCollected();

        vm.prank(alice);
        IERC20(testToken).approve(address(launchpad), tokensToSell);
        vm.prank(alice);
        launchpad.sellExactTokens(testToken, tokensToSell, 0, DEADLINE);

        uint256 treasuryFeesAfter = launchpad.treasuryEthFeesCollected();
        assertEq(treasuryFeesAfter - treasuryFeesBefore, expectedEthFee);
    }

    function testSellExactTokens_quotingAccuracy() public createTestToken afterOneBuy {
        uint256 tokensToSell = IERC20(testToken).balanceOf(alice);

        (uint256 quotedEthFromSale, uint256 quotedEthFee, uint256 quotedEthForSeller) =
            launchpad.quoteSellExactTokens(testToken, tokensToSell);

        uint256 treasuryFeesBefore = launchpad.treasuryEthFeesCollected();
        TokenState memory stateBefore = launchpad.getTokenState(testToken);
        uint256 ethBalanceBefore = alice.balance;

        vm.prank(alice);
        IERC20(testToken).approve(address(launchpad), tokensToSell);
        vm.prank(alice);
        launchpad.sellExactTokens(testToken, tokensToSell, 0, DEADLINE);

        uint256 treasuryFeesAfter = launchpad.treasuryEthFeesCollected();
        TokenState memory stateAfter = launchpad.getTokenState(testToken);
        uint256 ethBalanceAfter = alice.balance;

        // Verify quote accuracy
        assertEq(treasuryFeesAfter - treasuryFeesBefore, quotedEthFee);
        assertEq(stateBefore.ethCollected - stateAfter.ethCollected, quotedEthFromSale);
        assertEq(ethBalanceAfter - ethBalanceBefore, quotedEthForSeller);
    }

    function testSellExactTokens_stateUpdatesCorrectly() public createTestToken afterMultipleBuys {
        uint256 aliceTokensToSell = IERC20(testToken).balanceOf(alice) / 2;

        TokenState memory stateBefore = launchpad.getTokenState(testToken);
        uint256 circulatingBefore = stateBefore.releasedSupply;
        uint256 ethCollectedBefore = stateBefore.ethCollected;

        (uint256 expectedEthFromSale,,) = launchpad.quoteSellExactTokens(testToken, aliceTokensToSell);

        vm.prank(alice);
        IERC20(testToken).approve(address(launchpad), aliceTokensToSell);
        vm.prank(alice);
        launchpad.sellExactTokens(testToken, aliceTokensToSell, 0, DEADLINE);

        TokenState memory stateAfter = launchpad.getTokenState(testToken);

        assertEq(stateAfter.releasedSupply, circulatingBefore - aliceTokensToSell);
        assertEq(stateAfter.ethCollected, ethCollectedBefore - expectedEthFromSale);
        assertFalse(stateAfter.graduated);
    }

    function testSellExactTokens_sellAllreleasedSupply() public createTestToken afterOneBuy {
        uint256 allTokens = IERC20(testToken).balanceOf(alice);
        TokenState memory stateBefore = launchpad.getTokenState(testToken);

        assertEq(stateBefore.releasedSupply, allTokens);

        vm.prank(alice);
        IERC20(testToken).approve(address(launchpad), allTokens);
        vm.prank(alice);
        launchpad.sellExactTokens(testToken, allTokens, 0, DEADLINE);

        TokenState memory stateAfter = launchpad.getTokenState(testToken);
        assertEq(stateAfter.releasedSupply, 0);
        assertEq(IERC20(testToken).balanceOf(alice), 0);
        assertEq(IERC20(testToken).balanceOf(address(launchpad)), TOTAL_SUPPLY);
    }

    function testSellExactTokens_afterMultipleBuysAndSells() public createTestToken afterBuyAndPartialSell {
        // We're in a state where alice has already bought and sold some tokens
        uint256 remainingTokens = IERC20(testToken).balanceOf(alice);
        assertTrue(remainingTokens > 0);

        TokenState memory stateBefore = launchpad.getTokenState(testToken);
        assertTrue(stateBefore.releasedSupply > 0);
        assertTrue(stateBefore.ethCollected > 0);

        // Now sell the remaining tokens
        vm.prank(alice);
        IERC20(testToken).approve(address(launchpad), remainingTokens);
        vm.prank(alice);
        launchpad.sellExactTokens(testToken, remainingTokens, 0, DEADLINE);

        TokenState memory stateAfter = launchpad.getTokenState(testToken);
        assertEq(stateAfter.releasedSupply, stateBefore.releasedSupply - remainingTokens);
        assertLt(stateAfter.ethCollected, stateBefore.ethCollected);
        assertEq(IERC20(testToken).balanceOf(alice), 0);
    }

    function testSellExactTokens_multipleSellsEqualsBigSell() public createTestToken {
        uint256 initialBuyAmount = 0.4 ether;
        uint256 numberOfSells = 4;

        address bob1 = makeAddr("bob1");
        address bob2 = makeAddr("bob2");

        vm.deal(bob1, 2 * initialBuyAmount);
        vm.deal(bob2, 2 * initialBuyAmount);

        // First, we need tokens to sell - buy some for both scenarios
        vm.prank(alice);
        launchpad.buyTokensWithExactEth{value: initialBuyAmount}(testToken, 0, DEADLINE);

        // Scenario 1: Multiple small sells
        vm.startPrank(bob1);
        launchpad.buyTokensWithExactEth{value: initialBuyAmount}(testToken, 0, DEADLINE);

        uint256 bob1InitialTokens = IERC20(testToken).balanceOf(bob1);
        uint256 bob1InitialEth = bob1.balance;
        uint256 singleSellAmount = bob1InitialTokens / 4;

        IERC20(testToken).approve(address(launchpad), type(uint256).max);
        for (uint256 i = 0; i < numberOfSells; i++) {
            launchpad.sellExactTokens(testToken, singleSellAmount, 0, DEADLINE);
        }
        vm.stopPrank();

        uint256 ethFromMultipleSells = bob1.balance - bob1InitialEth;
        uint256 tokensAfterMultipleSells = IERC20(testToken).balanceOf(bob1);
        TokenState memory stateAfterMultiple = launchpad.getTokenState(testToken);
        assertApproxEqAbs(tokensAfterMultipleSells, 0, 4, "bob1 should have sold all tokens. 4 wei allowed error");

        // Reset state by creating a new token and setting up the same initial conditions
        vm.prank(creator);
        address testToken2 = launchpad.createToken(
            "Test Token 2",
            "TT2",
            address(implementation),
            address(bondingCurve),
            address(graduator),
            creator,
            "0x12",
            ""
        );

        // Buy the same amount for both scenarios to establish identical starting conditions
        vm.prank(alice);
        launchpad.buyTokensWithExactEth{value: initialBuyAmount}(testToken2, 0, DEADLINE);

        // Scenario 2: One big sell
        vm.startPrank(bob2);
        launchpad.buyTokensWithExactEth{value: initialBuyAmount}(testToken2, 0, DEADLINE);

        uint256 bob2InitialTokens = IERC20(testToken2).balanceOf(bob2);
        uint256 bob2InitialEth = bob2.balance;
        uint256 totalSellAmount = singleSellAmount * numberOfSells;

        IERC20(testToken2).approve(address(launchpad), type(uint256).max);
        launchpad.sellExactTokens(testToken2, totalSellAmount, 0, DEADLINE);

        uint256 ethFromBigSell = bob2.balance - bob2InitialEth;
        uint256 tokensAfterBigSell = IERC20(testToken2).balanceOf(bob2);
        TokenState memory stateAfterBig = launchpad.getTokenState(testToken2);
        vm.stopPrank();

        // The final state should be the same
        // accept small errors
        assertApproxEqAbs(ethFromMultipleSells, ethFromBigSell, 4, "Multiple small sells should equal one big sell");
        assertEq(
            bob1InitialTokens - tokensAfterMultipleSells,
            bob2InitialTokens - tokensAfterBigSell,
            "Tokens sold should be the same"
        );
        assertEq(
            stateAfterMultiple.releasedSupply, stateAfterBig.releasedSupply, "Circulating supply should be the same"
        );
    }

    /// @notice Verifies that when multiple buyers sell all their tokens, the entire circulating supply returns to the launchpad
    function testSellExactTokens_allCirculatingSupplyReturnsToLaunchpad() public createTestToken {
        // Setup: Multiple buyers purchase tokens
        address buyer1 = makeAddr("buyer1");
        address buyer2 = makeAddr("buyer2");
        address buyer3 = makeAddr("buyer3");

        vm.deal(buyer1, 2 ether);
        vm.deal(buyer2, 3 ether);
        vm.deal(buyer3, 1.5 ether);

        // Buyers purchase tokens
        vm.prank(buyer1);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        vm.prank(buyer2);
        launchpad.buyTokensWithExactEth{value: 2 ether}(testToken, 0, DEADLINE);

        vm.prank(buyer3);
        launchpad.buyTokensWithExactEth{value: 0.5 ether}(testToken, 0, DEADLINE);

        TokenState memory stateAfterBuys = launchpad.getTokenState(testToken);
        uint256 totalCirculatingSupply = stateAfterBuys.releasedSupply;

        // Verify tokens are distributed to buyers
        uint256 buyer1Tokens = IERC20(testToken).balanceOf(buyer1);
        uint256 buyer2Tokens = IERC20(testToken).balanceOf(buyer2);
        uint256 buyer3Tokens = IERC20(testToken).balanceOf(buyer3);

        assertEq(buyer1Tokens + buyer2Tokens + buyer3Tokens, totalCirculatingSupply);
        assertTrue(totalCirculatingSupply > 0);

        // All buyers sell all their tokens
        vm.startPrank(buyer1);
        IERC20(testToken).approve(address(launchpad), buyer1Tokens);
        launchpad.sellExactTokens(testToken, buyer1Tokens, 0, DEADLINE);
        vm.stopPrank();

        vm.startPrank(buyer2);
        IERC20(testToken).approve(address(launchpad), buyer2Tokens);
        launchpad.sellExactTokens(testToken, buyer2Tokens, 0, DEADLINE);
        vm.stopPrank();

        vm.startPrank(buyer3);
        IERC20(testToken).approve(address(launchpad), buyer3Tokens);
        launchpad.sellExactTokens(testToken, buyer3Tokens, 0, DEADLINE);
        vm.stopPrank();

        // Verify all circulating supply returned to launchpad
        TokenState memory stateAfterSells = launchpad.getTokenState(testToken);
        assertEq(stateAfterSells.releasedSupply, 0, "All circulating supply should be returned");
        assertEq(IERC20(testToken).balanceOf(buyer1), 0);
        assertEq(IERC20(testToken).balanceOf(buyer2), 0);
        assertEq(IERC20(testToken).balanceOf(buyer3), 0);
        assertEq(
            IERC20(testToken).balanceOf(address(launchpad)),
            TOTAL_SUPPLY,
            "Launchpad should hold entire supply after all sells"
        );
    }

    /// @notice Verifies that buying with 1 wei always results in receiving a non-zero amount of tokens
    function testBuyTokens_oneWeiAlwaysGivesNonZeroTokens() public createTestToken {
        // Test at initial state (lowest price point)
        vm.prank(alice);
        launchpad.buyTokensWithExactEth{value: 1}(testToken, 0, DEADLINE);

        uint256 tokensReceived = IERC20(testToken).balanceOf(alice);
        assertGt(tokensReceived, 0, "Should receive non-zero tokens for 1 wei at initial price");

        // Buy more tokens to increase price significantly
        vm.prank(bob);
        launchpad.buyTokensWithExactEth{value: 5 ether}(testToken, 0, DEADLINE);

        // Test at much higher price point
        address charlie = makeAddr("charlie");
        vm.deal(charlie, 1 ether);

        vm.prank(charlie);
        launchpad.buyTokensWithExactEth{value: 1}(testToken, 0, DEADLINE);

        uint256 charlieTokens = IERC20(testToken).balanceOf(charlie);
        assertGt(charlieTokens, 0, "Should receive non-zero tokens for 1 wei at high price");
    }

    /// @notice Verifies that selling tokens with reasonable amounts always returns non-zero ETH
    function testSellExactTokens_alwaysGivesNonZeroEthOrReverts() public createTestToken afterOneBuy {
        uint256 tokensOwned = IERC20(testToken).balanceOf(alice);

        // Test selling all tokens - should give non-zero ETH
        uint256 ethBalanceBefore = alice.balance;

        vm.prank(alice);
        IERC20(testToken).approve(address(launchpad), tokensOwned);
        vm.prank(alice);
        launchpad.sellExactTokens(testToken, tokensOwned, 0, DEADLINE);

        uint256 ethReceived = alice.balance - ethBalanceBefore;
        assertGt(ethReceived, 0, "Should receive non-zero ETH when selling tokens");

        // Test selling a reasonable small amount (0.01% of a buy)
        vm.prank(bob);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        uint256 bobTokens = IERC20(testToken).balanceOf(bob);
        uint256 tokensToSell = bobTokens / 10000; // Sell 0.01% of tokens
        require(tokensToSell > 0, "Need non-zero tokens to test");

        uint256 bobEthBefore = bob.balance;

        vm.prank(bob);
        IERC20(testToken).approve(address(launchpad), tokensToSell);
        vm.prank(bob);
        launchpad.sellExactTokens(testToken, tokensToSell, 0, DEADLINE);

        uint256 bobEthReceived = bob.balance - bobEthBefore;
        assertGt(bobEthReceived, 0, "Should receive non-zero ETH when selling reasonable amount");
    }

    function test_launchpadCanTransferFromWithoutApproval() public createTestToken {
        // alice buys some tokens
        vm.prank(alice);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        uint256 tokensOwned = IERC20(testToken).balanceOf(alice);
        assertGt(tokensOwned, 0, "Alice should own tokens");

        vm.prank(address(launchpad));
        IERC20(testToken).transferFrom(alice, bob, tokensOwned);

        assertEq(IERC20(testToken).balanceOf(bob), tokensOwned, "Bob should receive tokens");
    }

    function test_attackerCannotTransferFromWithoutApproval() public createTestToken {
        // alice buys some tokens
        vm.prank(alice);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        uint256 tokensOwned = IERC20(testToken).balanceOf(alice);
        assertGt(tokensOwned, 0, "Alice should own tokens");

        vm.prank(address(bob));
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        IERC20(testToken).transferFrom(alice, bob, tokensOwned);

        assertEq(IERC20(testToken).balanceOf(bob), 0, "Bob should not have tokens");
    }

    function test_buyerCanSellWithoutPreApprovingLaunchpad() public createTestToken {
        address peter = makeAddr("peter");
        deal(peter, 10 ether);

        vm.prank(peter);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        uint256 tokensOwned = IERC20(testToken).balanceOf(peter);
        assertGt(tokensOwned, 0, "Peter should own tokens");

        // Peter sells tokens without pre-approving the launchpad
        vm.prank(peter);
        launchpad.sellExactTokens(testToken, tokensOwned, 0, DEADLINE);

        assertEq(IERC20(testToken).balanceOf(peter), 0, "Peter should not own any tokens after selling");
    }
}

/// @dev run all the tests in ProtocolAgnosticGraduationTests, with Uniswap V2 graduator
contract SellTokenTests_Univ2 is SellTokensTest, LaunchpadBaseTestsWithUniv2Graduator {
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator) {
        super.setUp();
    }
}

/// @dev run all the tests in ProtocolAgnosticGraduationTests, with Uniswap V4 graduator
contract SellTokenTests_Univ4 is SellTokensTest, LaunchpadBaseTestsWithUniv4Graduator {
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv4Graduator) {
        super.setUp();
    }
}
