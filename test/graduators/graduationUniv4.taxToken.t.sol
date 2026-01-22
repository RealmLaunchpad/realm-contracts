// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/graduationUniv4.taxToken.base.t.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {ILivoTaxableTokenUniV4} from "src/interfaces/ILivoTaxableTokenUniV4.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoSwapHook} from "src/hooks/LivoSwapHook.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";

interface ILivoGraduatorWithFees is ILivoGraduator {
    function collectEthFees(address[] calldata tokens, uint256[] calldata positionIndexes) external;
    function positionIds(address token, uint256 positionIndex) external view returns (uint256);
    function getClaimableFees(address[] calldata tokens, uint256 positionIndex)
        external
        view
        returns (uint256[] memory creatorFees);
    function sweep() external;
}

/// @notice Comprehensive tests for LivoTaxableTokenUniV4 and LivoTaxSwapHook functionality
contract TaxTokenUniV4Tests is TaxTokenUniV4BaseTests {
    ILivoGraduatorWithFees graduatorWithFees;

    function setUp() public override {
        super.setUp();
        graduatorWithFees = ILivoGraduatorWithFees(address(graduator));
    }

    /// @notice Helper to collect LP fees from a single token
    function _collectFees(address token) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory positionIndexes = new uint256[](1);
        positionIndexes[0] = 0;
        vm.prank(creator);
        graduatorWithFees.collectEthFees(tokens, positionIndexes);
    }

    /////////////////////////////////// CATEGORY 1: PRE-GRADUATION BEHAVIOR ///////////////////////////////////

    /// @notice Test that no taxes are charged before graduation when purchasing through launchpad
    function test_noTaxesBeforeGraduation_launchpadPurchases() public createDefaultTaxToken {
        uint256 creatorWethBalanceBefore = IERC20(WETH_ADDRESS).balanceOf(creator);

        (,, uint256 tokensToReceive) = launchpad.quoteBuyWithExactEth(testToken, 1 ether);

        uint256 buyerTokenBalanceBefore = IERC20(testToken).balanceOf(buyer);
        // Multiple users buy tokens through launchpad
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
        assertEq(
            IERC20(testToken).balanceOf(buyer),
            buyerTokenBalanceBefore + tokensToReceive,
            "Buyer should receive the correct amount of tokens, no taxes involved"
        );

        vm.deal(alice, 2 ether);
        vm.prank(alice);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        // Verify token owner (creator) received no WETH tax
        assertEq(
            IERC20(WETH_ADDRESS).balanceOf(creator),
            creatorWethBalanceBefore,
            "Creator should not receive any WETH tax before graduation"
        );

        // Verify buyers received tokens (only launchpad fees deducted, no tax)
        assertGt(IERC20(testToken).balanceOf(buyer), 0, "Buyer should have received tokens");
        assertGt(IERC20(testToken).balanceOf(alice), 0, "Alice should have received tokens");

        // Token is not graduated yet
        assertFalse(ILivoToken(testToken).graduated(), "Token should not be graduated yet");
    }

    /////////////////////////////////// CATEGORY 2: TAX COLLECTION (ACTIVE PERIOD) ///////////////////////////////////

    /// @notice Test that buy tax is collected correctly after graduation within tax period
    /// @dev buy taxes are collected as tokens in the token contract, and then swapped for WETH and sent to the creator.
    /// @dev The swap is triggered by a normal transfer ONLY when accumulated tokens >= 0.1% of totalSupply
    function test_buyTaxCollected_withinTaxPeriod() public createDefaultTaxToken {
        _graduateToken();

        assertEq(IERC20(testToken).balanceOf(address(testToken)), 0, "there should be no taxes collected yet");

        uint256 buyerTokenBalanceBefore = IERC20(testToken).balanceOf(buyer);

        // First small buy to verify tax accumulation mechanics
        uint256 smallEthIn = 1 ether;
        deal(buyer, smallEthIn);

        uint256 tokenContractBalanceBefore = IERC20(testToken).balanceOf(testToken);
        _swapBuy(buyer, smallEthIn, 0, true);

        uint256 buyerTokenBalanceAfter = IERC20(testToken).balanceOf(buyer);
        uint256 tokenContractBalanceAfter = IERC20(testToken).balanceOf(testToken);
        uint256 tokensReceivedByBuyer = buyerTokenBalanceAfter - buyerTokenBalanceBefore;
        uint256 taxAccumulatedInToken = tokenContractBalanceAfter - tokenContractBalanceBefore;

        // Buy tax is collected as tokens and sent to the token contract for accumulation
        assertGt(taxAccumulatedInToken, 0, "Token contract should accumulate buy tax");

        // Verify the tax is approximately buyTaxBps % of what buyer received
        uint256 totalTokensSwapped = tokensReceivedByBuyer + taxAccumulatedInToken;
        uint256 actualTaxPercentage = (taxAccumulatedInToken * 10000) / totalTokensSwapped;
        assertApproxEqAbs(actualTaxPercentage, DEFAULT_BUY_TAX_BPS, 1, "Tax percentage should match buyTaxBps");

        // Verify buyer received tokens
        assertGt(tokensReceivedByBuyer, 0, "Buyer should have received tokens");

        // Verify creator hasn't received WETH yet (threshold not met)
        uint256 creatorWethBalanceBefore = IERC20(WETH_ADDRESS).balanceOf(creator);
        assertEq(creatorWethBalanceBefore, 0, "Creator should not have received WETH tax yet");

        //////////////////////////// large buy to meet threshold //////////////////////////
        // Do a large buy (200 ETH) to ensure accumulated tokens exceed the 0.1% threshold

        uint256 largeEthIn = 200 ether;
        deal(buyer, largeEthIn);
        _swapBuy(buyer, largeEthIn, 0, true);

        // Verify threshold is now met
        uint256 threshold = IERC20(testToken).totalSupply() / 1000;
        uint256 accumulatedTax = IERC20(testToken).balanceOf(testToken);
        assertGe(accumulatedTax, threshold, "Accumulated tax should meet threshold after large buy");

        //////////////////////////// trigger swap and verify WETH payment //////////////////////////
        // Transfer triggers the swap of accumulated tokens to WETH for the creator

        vm.prank(buyer);
        IERC20(testToken).transfer(alice, 1e18);

        uint256 creatorWethBalanceAfter = IERC20(WETH_ADDRESS).balanceOf(creator);
        assertGt(
            creatorWethBalanceAfter, creatorWethBalanceBefore, "Creator should receive WETH tax after threshold met"
        );
        assertGt(creatorWethBalanceAfter, 0, "Creator should receive WETH tax greater than 0");
    }

    /// @notice Test that sell tax is collected correctly after graduation within tax period
    function test_sellTaxCollected_withinTaxPeriod() public createDefaultTaxToken {
        // First, buy some tokens through launchpad before graduation
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        assertGt(buyerTokenBalance, 0, "Buyer should have tokens to sell");

        _graduateToken();

        uint256 creatorWethBalanceBefore = IERC20(WETH_ADDRESS).balanceOf(creator);
        uint256 buyerEthBalanceBefore = buyer.balance;

        uint256 sellAmount = buyerTokenBalance / 2;

        // Buyer swaps tokens for ETH via UniV4
        _swapSell(buyer, sellAmount, 0, true);

        uint256 buyerEthBalanceAfter = buyer.balance;
        uint256 ethReceived = buyerEthBalanceAfter - buyerEthBalanceBefore;

        // Calculate expected tax on ETH output
        // Note: Tax is calculated on the pre-tax ETH amount. Since ethReceived is post-tax:
        // taxCharged / (ethReceived + taxCharged) = DEFAULT_SELL_TAX_BPS / 10000
        // Solving for taxCharged: taxCharged = ethReceived * taxBps / (10000 - taxBps)
        uint256 expectedTaxApprox = (ethReceived * DEFAULT_SELL_TAX_BPS) / (10000 - DEFAULT_SELL_TAX_BPS);

        // Verify tax was sent to creator as WETH (allow for some variance due to pool math)
        assertGt(
            IERC20(WETH_ADDRESS).balanceOf(creator), creatorWethBalanceBefore, "Creator should receive sell tax as WETH"
        );
        assertApproxEqRel(
            IERC20(WETH_ADDRESS).balanceOf(creator) - creatorWethBalanceBefore,
            expectedTaxApprox,
            0.00015e18, // 15% tolerance for pool math variance
            "Creator should receive approximately the expected sell tax as WETH"
        );
    }

    /// @notice test that if the tokenOwner is updated in the launchpad, the sell taxes are redirected correctly
    function test_sellTaxCollectedToNewTokenOwner_afterChangedInLaunchpad() public createDefaultTaxToken {
        _graduateToken();

        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);

        uint256 creatorWethBalanceBefore = IERC20(WETH_ADDRESS).balanceOf(creator);
        uint256 sellAmount = buyerTokenBalance / 2;
        // Buyer swaps tokens for ETH via UniV4
        _swapSell(buyer, sellAmount, 0, true);

        // Verify tax was sent to creator as WETH (allow for some variance due to pool math)
        assertGt(
            IERC20(WETH_ADDRESS).balanceOf(creator), creatorWethBalanceBefore, "Creator should receive sell tax as WETH"
        );

        /////////// now update token owner by transferring ownership

        vm.prank(creator);
        launchpad.transferTokenOwnership(testToken, alice);
        assertEq(launchpad.getTokenOwner(testToken), alice, "New token owner should be Alice");

        // Verify that sell taxes are now redirected to the new owner
        uint256 aliceWethBalanceBefore = IERC20(WETH_ADDRESS).balanceOf(alice);
        creatorWethBalanceBefore = IERC20(WETH_ADDRESS).balanceOf(creator);

        sellAmount = buyerTokenBalance / 2;
        // Buyer swaps tokens for ETH via UniV4
        _swapSell(buyer, sellAmount, 0, true);
        assertGt(IERC20(WETH_ADDRESS).balanceOf(alice), aliceWethBalanceBefore, "Alice should receive sell tax as WETH");
        assertEq(
            IERC20(WETH_ADDRESS).balanceOf(creator),
            creatorWethBalanceBefore,
            "Creator should not receive sell tax as WETH"
        );
    }

    /// @notice Test that different buy vs sell tax rates are applied correctly
    /// @dev Buy tax accumulates in token contract, sell tax goes directly to creator as ETH
    function test_buyVsSellTaxRates_appliedCorrectly() public {
        // Create token with different tax rates: 2% buy, 5% sell
        testToken = _createTaxToken(200, 500, 14 days);

        // First get some tokens through launchpad BEFORE graduating
        vm.deal(buyer, 3 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(testToken, 0, DEADLINE);

        _graduateToken();

        uint256 ethIn = 1 ether;

        // Test buy tax (2%) - now accumulates in token contract
        uint256 tokenContractBalanceBefore = IERC20(testToken).balanceOf(testToken);
        uint256 buyerTokenBalanceBefore = IERC20(testToken).balanceOf(buyer);
        deal(buyer, ethIn);
        _swapBuy(buyer, ethIn, 0, true);
        uint256 buyerTokenBalanceAfter = IERC20(testToken).balanceOf(buyer);
        uint256 tokenContractBalanceAfter = IERC20(testToken).balanceOf(testToken);

        uint256 buyTaxAccumulated = tokenContractBalanceAfter - tokenContractBalanceBefore;
        uint256 tokensReceivedByBuyer = buyerTokenBalanceAfter - buyerTokenBalanceBefore;
        uint256 totalTokens = buyTaxAccumulated + tokensReceivedByBuyer;
        uint256 actualBuyTaxPercentage = (buyTaxAccumulated * 10000) / totalTokens;
        assertApproxEqAbs(actualBuyTaxPercentage, 200, 1, "Buy tax should be ~2%");

        // Test sell tax (5%) - collected as WETH directly to creator
        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        uint256 sellAmount = buyerTokenBalance / 3;

        uint256 creatorWethBalanceBefore = IERC20(WETH_ADDRESS).balanceOf(creator);
        uint256 buyerEthBalanceBefore = buyer.balance;
        _swapSell(buyer, sellAmount, 0, true);
        uint256 buyerEthBalanceAfter = buyer.balance;
        uint256 sellTaxCollectedWeth = IERC20(WETH_ADDRESS).balanceOf(creator) - creatorWethBalanceBefore;

        uint256 ethReceived = buyerEthBalanceAfter - buyerEthBalanceBefore;

        // Calculate expected tax: taxCharged / (ethReceived + taxCharged) = 500 / 10000
        // Solving: taxCharged = ethReceived * 500 / (10000 - 500)
        uint256 expectedSellTaxApprox = (ethReceived * 500) / (10000 - 500);

        // Verify both taxes were collected
        assertGt(buyTaxAccumulated, 0, "Buy tax should accumulate in token contract");
        assertGt(sellTaxCollectedWeth, 0, "Sell tax should be collected as WETH");
        assertApproxEqRel(
            sellTaxCollectedWeth,
            expectedSellTaxApprox,
            0.00015e18, // 15% tolerance for pool math variance
            "Sell tax should be approximately 5% of ETH output"
        );
    }

    /// @notice Test that zero tax rate results in no tax collection
    function test_zeroTaxRate_noTaxCollected() public {
        // Create token with 0% buy tax, 5% sell tax
        testToken = _createTaxToken(0, 500, 14 days);

        // Buy tokens through launchpad
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        _graduateToken();

        // Test buy with 0% tax - should accumulate no tokens in token contract
        uint256 tokenContractBalanceBefore = IERC20(testToken).balanceOf(testToken);
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, true);
        assertEq(
            IERC20(testToken).balanceOf(testToken), tokenContractBalanceBefore, "No buy tax should accumulate (0% rate)"
        );

        // Test sell with 5% tax - creator receives WETH directly
        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        uint256 creatorWethBalanceBefore = IERC20(WETH_ADDRESS).balanceOf(creator);
        _swapSell(buyer, buyerTokenBalance / 2, 0, true);
        assertGt(
            IERC20(WETH_ADDRESS).balanceOf(creator),
            creatorWethBalanceBefore,
            "Creator should receive sell tax as WETH (5% rate)"
        );
    }

    /// @notice Test that buy taxes accumulate in token contract during swaps
    /// @dev Buy tax now accumulates in token contract, sell tax goes to creator as ETH
    function test_taxRecipientReceivesTaxDuringSwap_twoSwaps() public createDefaultTaxToken {
        _graduateToken();

        // Test buy tax (tokens accumulate in token contract)
        uint256 tokenContractBalance = IERC20(testToken).balanceOf(testToken);

        deal(buyer, 1 ether);
        _swapBuy(buyer, 0.5 ether, 0, true);
        uint256 taxAfterBuy1 = IERC20(testToken).balanceOf(testToken) - tokenContractBalance;
        assertGt(taxAfterBuy1, 0, "Token tax should accumulate after first buy");

        tokenContractBalance = IERC20(testToken).balanceOf(testToken);
        deal(buyer, 1 ether);
        _swapBuy(buyer, 0.5 ether, 0, true);
        uint256 taxAfterBuy2 = IERC20(testToken).balanceOf(testToken) - tokenContractBalance;
        assertGt(taxAfterBuy2, 0, "Token tax should accumulate after second buy");
    }

    /// @notice Test multiple users buying and token taxes accumulating in token contract
    /// @dev Buy tax now accumulates in token contract for later swap to ETH
    function test_multipleBuyers_taxesAccumulate() public createDefaultTaxToken {
        _graduateToken();

        uint256 tokenContractBalanceBefore = IERC20(testToken).balanceOf(testToken);

        // 5 different users buy tokens
        address[] memory buyerAddrs = new address[](5);
        buyerAddrs[0] = buyer;
        buyerAddrs[1] = alice;
        buyerAddrs[2] = bob;
        buyerAddrs[3] = makeAddr("user3");
        buyerAddrs[4] = makeAddr("user4");

        for (uint256 i = 0; i < buyerAddrs.length; i++) {
            uint256 ethIn = 0.5 ether;
            deal(buyerAddrs[i], ethIn);
            _swapBuy(buyerAddrs[i], ethIn, 0, true);
        }

        uint256 totalTokenTaxAccumulated = IERC20(testToken).balanceOf(testToken) - tokenContractBalanceBefore;

        // Verify token contract accumulated taxes from all buyers
        assertGt(totalTokenTaxAccumulated, 0, "Token contract should accumulate taxes from all buyers");
    }

    /////////////////////////////////// CATEGORY 3: POST-TAX-PERIOD BEHAVIOR ///////////////////////////////////

    /// @notice Test that no taxes are charged after the tax period expires
    /// @dev Buy tax would accumulate in token contract, sell tax would go to creator - both should be 0 after expiry
    function test_noTaxesAfterPeriodExpires() public createDefaultTaxToken {
        _graduateToken();

        // Fast-forward past tax duration (14 days + 1 second)
        vm.warp(block.timestamp + DEFAULT_TAX_DURATION + 1 seconds);

        uint256 tokenContractBalanceBeforeBuy = IERC20(testToken).balanceOf(testToken);
        uint256 creatorWethBalanceBeforeBuy = IERC20(WETH_ADDRESS).balanceOf(creator);

        // Perform buy swap - should collect no TOKEN tax
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, true);
        assertEq(
            IERC20(testToken).balanceOf(testToken),
            tokenContractBalanceBeforeBuy,
            "No buy tax (tokens) should accumulate after period expires"
        );
        assertEq(
            IERC20(WETH_ADDRESS).balanceOf(creator),
            creatorWethBalanceBeforeBuy,
            "No buy tax (WETH) should be collected after period expires"
        );

        // Perform sell swap - should collect no WETH tax
        uint256 tokenContractBalanceBeforeSell = IERC20(testToken).balanceOf(testToken);
        uint256 creatorWethBalanceBeforeSell = IERC20(WETH_ADDRESS).balanceOf(creator);

        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        _swapSell(buyer, buyerTokenBalance / 2, 0, true);

        assertEq(
            IERC20(testToken).balanceOf(testToken),
            tokenContractBalanceBeforeSell,
            "No sell tax (tokens) should accumulate after period expires"
        );
        assertEq(
            IERC20(WETH_ADDRESS).balanceOf(creator),
            creatorWethBalanceBeforeSell,
            "No sell tax (WETH) should be collected after period expires"
        );
    }

    /// @notice Test exact boundary conditions for tax period
    /// @dev Buy tax now accumulates in token contract
    /// @dev Hook uses `>` comparison: tax collected when timestamp <= graduation + duration
    function test_taxPeriodBoundaries() public createDefaultTaxToken {
        _graduateToken();

        uint40 graduationTimestamp = ILivoTaxableTokenUniV4(testToken).graduationTimestamp();
        uint256 tokenContractBalance;

        // Test at t = 0 (graduation) - token tax should accumulate
        tokenContractBalance = IERC20(testToken).balanceOf(testToken);
        deal(buyer, 0.5 ether);
        _swapBuy(buyer, 0.5 ether, 0, true);
        assertGt(
            IERC20(testToken).balanceOf(testToken),
            tokenContractBalance,
            "Token tax should accumulate at graduation (t=0)"
        );

        // Test at t = duration - 1 second (last second of period) - tax should still accumulate
        vm.warp(graduationTimestamp + DEFAULT_TAX_DURATION - 1 seconds);
        tokenContractBalance = IERC20(testToken).balanceOf(testToken);
        deal(buyer, 0.5 ether);
        _swapBuy(buyer, 0.5 ether, 0, true);
        assertGt(
            IERC20(testToken).balanceOf(testToken),
            tokenContractBalance,
            "Token tax should accumulate at last second of period"
        );

        // Test at t = duration exactly - tax IS still collected (hook uses > not >=)
        // Tax period is [graduation, graduation + duration] INCLUSIVE
        vm.warp(graduationTimestamp + DEFAULT_TAX_DURATION);
        tokenContractBalance = IERC20(testToken).balanceOf(testToken);
        deal(buyer, 0.5 ether);
        _swapBuy(buyer, 0.5 ether, 0, true);
        assertGt(
            IERC20(testToken).balanceOf(testToken),
            tokenContractBalance,
            "Token tax should accumulate at exact expiry (inclusive)"
        );

        // Test at t = duration + 1 second - NO tax should be collected
        vm.warp(graduationTimestamp + DEFAULT_TAX_DURATION + 1 seconds);
        tokenContractBalance = IERC20(testToken).balanceOf(testToken);
        deal(buyer, 0.5 ether);
        _swapBuy(buyer, 0.5 ether, 0, true);
        assertEq(
            IERC20(testToken).balanceOf(testToken), tokenContractBalance, "No token tax should accumulate after expiry"
        );
    }

    /////////////////////////////////// CATEGORY 5: EDGE CASES & SECURITY ///////////////////////////////////

    /// @notice Test maximum tax rate (5% = 500 bps)
    /// @dev Buy tax now accumulates in token contract (5% of token output)
    function test_maxTaxRate_500bps() public {
        // Create token with max tax rates
        testToken = _createTaxToken(500, 500, 14 days);
        _graduateToken();

        uint256 ethIn = 10 ether;

        uint256 tokenContractBalanceBefore = IERC20(testToken).balanceOf(testToken);
        uint256 buyerTokenBalanceBefore = IERC20(testToken).balanceOf(buyer);
        deal(buyer, ethIn);
        _swapBuy(buyer, ethIn, 0, true);

        uint256 buyerTokenBalanceAfter = IERC20(testToken).balanceOf(buyer);
        uint256 tokenContractBalanceAfter = IERC20(testToken).balanceOf(testToken);

        uint256 taxAccumulated = tokenContractBalanceAfter - tokenContractBalanceBefore;
        uint256 tokensReceivedByBuyer = buyerTokenBalanceAfter - buyerTokenBalanceBefore;
        uint256 totalTokens = taxAccumulated + tokensReceivedByBuyer;

        // Verify ~5% token tax accumulated
        uint256 actualTaxPercentage = (taxAccumulated * 10000) / totalTokens;
        assertApproxEqAbs(actualTaxPercentage, 500, 1, "Max tax rate should accumulate ~5% of token output");
    }

    /// @notice Test that token creation with invalid tax rate reverts
    function test_tokenCreation_invalidTaxRate_reverts() public {
        bytes memory tokenCalldata = taxTokenImpl.encodeTokenCalldata(
            600, // > MAX_TAX_BPS (500)
            300,
            14 days
        );

        vm.expectRevert(abi.encodeWithSelector(LivoTaxableTokenUniV4.InvalidTaxRate.selector, 600));
        vm.prank(creator);
        launchpad.createToken(
            "InvalidToken",
            "INV",
            address(taxTokenImpl),
            address(bondingCurve),
            address(graduatorV4),
            creator,
            "0x003",
            tokenCalldata
        );
    }

    /// @notice Test that swap before graduation has no liquidity to swap with
    /// @dev Pool is initialized but has no liquidity until graduation adds it
    function test_notGraduated_swapHasNoLiquidity() public createDefaultTaxToken {
        // Token is created but not graduated
        assertFalse(ILivoToken(testToken).graduated(), "Token should not be graduated");

        // Before graduation, the pool exists but has no liquidity
        // A buy swap will fail due to lack of liquidity or token transfer restrictions
        deal(buyer, 1 ether);

        // The swap should either revert or return 0 tokens due to no liquidity
        // Using expectRevert = false and checking the result instead
        uint256 buyerTokenBalanceBefore = IERC20(testToken).balanceOf(buyer);

        // this swap should revert, as there is no liquidity (expectSuccess=false)
        _swapBuy(buyer, 1 ether, 0, false);

        uint256 tokensReceived = IERC20(testToken).balanceOf(buyer) - buyerTokenBalanceBefore;
        assertEq(tokensReceived, 0, "Should receive 0 tokens before graduation (no liquidity)");
    }

    /// @notice test that a large swapBuy before graduation doesn't alter the gratuation conditions / set point
    function test_largeSwapBuyBeforeGraduation_doesntAffectGraduation() public createDefaultTaxToken {
        // Token is created but not graduated
        assertFalse(ILivoToken(testToken).graduated(), "Token should not be graduated");

        // Perform a large buy swap before graduation
        deal(buyer, 10 ether);
        uint256 tokenBalanceBefore = IERC20(testToken).balanceOf(buyer);
        // this swap should revert, since token is not graduated yet (excpectSuccess=false)
        _swapBuy(buyer, 10 ether, 0, false);
        assertEq(
            IERC20(testToken).balanceOf(buyer),
            tokenBalanceBefore,
            "Balance shouldn't change because swap should have reverted"
        );

        // Graduate the token
        // if this reverts, we have DOSed the token which cannot ever graduate
        _graduateToken();

        // Verify that graduation was successful and pool is initialized correctly
        assertTrue(ILivoToken(testToken).graduated(), "Token should be graduated successfully");

        // Further checks can be added to verify pool state if needed
    }

    /////////////////////////////////// CATEGORY 6: MULTI-USER TAX SCENARIOS ///////////////////////////////////

    /// @notice Test buy then sell from same user with both taxes applied
    /// @dev Buy tax accumulates in token contract, Sell tax goes to creator as WETH
    function test_buyThenSell_bothTaxesApplied() public createDefaultTaxToken {
        // First buy tokens through launchpad
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        _graduateToken();

        uint256 tokenContractBalanceBefore = IERC20(testToken).balanceOf(testToken);
        uint256 creatorWethBalanceBefore = IERC20(WETH_ADDRESS).balanceOf(creator);

        // Buy more tokens via UniV4 (buy tax accumulates in token contract)
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, true);
        uint256 buyTaxAccumulated = IERC20(testToken).balanceOf(testToken) - tokenContractBalanceBefore;
        assertGt(buyTaxAccumulated, 0, "Buy tax (tokens) should accumulate");

        // Sell some tokens via UniV4 (pay sell tax as WETH)
        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        _swapSell(buyer, buyerTokenBalance / 3, 0, true);
        uint256 sellTaxCollectedWeth = IERC20(WETH_ADDRESS).balanceOf(creator) - creatorWethBalanceBefore;
        assertGt(sellTaxCollectedWeth, 0, "Sell tax (WETH) should be collected");
    }

    /// @notice Test that tax hook only triggers on swaps, not other operations
    /// @dev The hook has afterSwap permission only, so other operations should work normally
    function test_taxHook_onlyTriggersOnSwaps() public createDefaultTaxToken {
        _graduateToken();

        // test that a normal transfer doesn't have any tax
        vm.prank(buyer);
        IERC20(testToken).transfer(alice, 1 ether);

        assertEq(IERC20(testToken).balanceOf(testToken), 0, "No tax should be collected on normal transfers");
        assertEq(IERC20(testToken).balanceOf(alice), 1 ether, "No tax should be collected on normal transfers");
    }

    /// @notice test that we can't transfer tokens to the pool manager before graduation
    function test_cannotTransferToPoolManagerBeforeGraduation() public createDefaultTaxToken {
        // Attempt to transfer tokens to the pool manager before graduation
        vm.prank(buyer);
        vm.expectRevert(LivoToken.TransferToPairBeforeGraduationNotAllowed.selector);
        IERC20(testToken).transfer(address(poolManagerAddress), 1 ether);
    }

    /////////////////////////////////// CATEGORY 7: LP FEE CLAIMING ///////////////////////////////////

    /// @notice Test that LP fees can be claimed by token owner for graduated tax token
    function test_claimLPFees_happyPath_tokenOwnerReceivesFees() public createDefaultTaxToken {
        _graduateToken();

        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 treasuryEthBalanceBefore = treasury.balance;

        // Perform buy swap to generate LP fees (1% total: 0.5% creator, 0.5% treasury)
        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        // Verify fees accumulated
        address[] memory tokens = new address[](1);
        tokens[0] = testToken;
        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, 0);
        assertGt(fees[0], 0, "Fees should have accumulated");
        assertApproxEqAbs(fees[0], buyAmount / 200, 1, "Expected ~0.5% of buy amount");

        // Claim LP fees
        _collectFees(testToken);
        graduatorWithFees.sweep();

        uint256 creatorEthBalanceAfter = creator.balance;
        uint256 treasuryEthBalanceAfter = treasury.balance;

        // Verify creator received ~0.5% of buy amount
        assertApproxEqAbs(
            creatorEthBalanceAfter - creatorEthBalanceBefore, buyAmount / 200, 1, "Creator should receive ~0.5% LP fees"
        );

        // Verify treasury received ~0.5% of buy amount
        assertApproxEqAbs(
            treasuryEthBalanceAfter - treasuryEthBalanceBefore,
            buyAmount / 200,
            1,
            "Treasury should receive ~0.5% LP fees"
        );
    }

    /// @notice Test that LP fees (ETH) and buy taxes (tokens) are collected independently during active tax period
    function test_claimLPFees_duringTaxPeriod_separateFromTaxes() public createDefaultTaxToken {
        _graduateToken();

        uint256 tokenContractBalanceBefore = IERC20(testToken).balanceOf(testToken);
        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 creatorWethBalanceBefore = IERC20(WETH_ADDRESS).balanceOf(creator);

        // Perform large buy swap during active tax period
        // This generates both: buy tax tokens (~3%) + LP fees (~1% ETH)
        uint256 buyAmount = 200 ether;
        deal(buyer, buyAmount);
        uint256 buyerBalanceBefore = IERC20(testToken).balanceOf(buyer);
        _swapBuy(buyer, buyAmount, 0, true);
        uint256 buyerBalanceAfter = IERC20(testToken).balanceOf(buyer);

        // Verify buy tax tokens accumulated in token contract
        uint256 tokenContractBalanceAfter = IERC20(testToken).balanceOf(testToken);
        uint256 taxTokensAccumulated = tokenContractBalanceAfter - tokenContractBalanceBefore;
        assertGt(taxTokensAccumulated, 0, "Buy tax tokens should have accumulated");

        // Calculate expected buy tax: ~3% of tokens received
        uint256 tokensReceived = buyerBalanceAfter - buyerBalanceBefore;
        uint256 expectedTaxTokens = (tokensReceived * DEFAULT_BUY_TAX_BPS) / (10000 - DEFAULT_BUY_TAX_BPS);
        assertApproxEqRel(taxTokensAccumulated, expectedTaxTokens, 0.0001e18, "Should accumulate ~3% buy tax");

        // Verify LP fees accumulated separately (in ETH, not tokens)
        address[] memory tokens = new address[](1);
        tokens[0] = testToken;
        uint256[] memory claimableFees = graduatorWithFees.getClaimableFees(tokens, 0);
        assertApproxEqAbs(claimableFees[0], buyAmount / 200, 2, "LP fees should be ~0.5% of buy amount in ETH");

        // Claim LP fees (paid in native ETH to creator)
        _collectFees(testToken);
        graduatorWithFees.sweep();

        uint256 creatorEthBalanceAfterLPClaim = creator.balance;
        uint256 lpFeesReceivedEth = creatorEthBalanceAfterLPClaim - creatorEthBalanceBefore;
        assertApproxEqAbs(lpFeesReceivedEth, buyAmount / 200, 2, "Creator should receive ~1 ETH from LP fees");

        // Verify token contract still has tax tokens (threshold met, will swap on next transfer)
        assertGt(IERC20(testToken).balanceOf(testToken), 0, "Tax tokens should remain in contract");

        // Trigger tax swap by transferring tokens (accumulated > 0.1% threshold)
        // Tax swap converts accumulated tokens to WETH and sends to creator
        vm.prank(buyer);
        IERC20(testToken).transfer(alice, 1e18);

        uint256 creatorWethBalanceAfterTaxSwap = IERC20(WETH_ADDRESS).balanceOf(creator);
        uint256 taxWethReceived = creatorWethBalanceAfterTaxSwap - creatorWethBalanceBefore;

        // Verify creator received WETH from tax swap (separate from LP fees which are native ETH)
        assertGt(taxWethReceived, 0, "Creator should have received WETH from tax swap");

        // Verify the two fee streams are separate:
        // - LP fees: native ETH from Uniswap pool (lpFeesReceivedEth)
        // - Tax fees: WETH from swapping accumulated tax tokens (taxWethReceived)
        assertGt(lpFeesReceivedEth, 0, "LP fees should be in native ETH");
        assertGt(taxWethReceived, 0, "Tax fees should be in WETH");

        // Verify tax tokens were swapped (contract balance should be near 0 now)
        assertLt(
            IERC20(testToken).balanceOf(testToken),
            taxTokensAccumulated / 100,
            "Most tax tokens should have been swapped"
        );
    }

    /// @notice Test that LP fees continue to be claimable after tax period expires
    function test_claimLPFees_afterTaxPeriodExpires_stillClaimable() public createDefaultTaxToken {
        _graduateToken();

        // Fast-forward past tax period
        vm.warp(block.timestamp + DEFAULT_TAX_DURATION + 1);

        uint256 tokenContractBalanceBefore = IERC20(testToken).balanceOf(testToken);
        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 treasuryEthBalanceBefore = treasury.balance;

        // Perform buy swap (no taxes should be charged)
        uint256 buyAmount = 2 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        // Verify no tax tokens accumulated
        assertEq(
            IERC20(testToken).balanceOf(testToken),
            tokenContractBalanceBefore,
            "No buy tax should accumulate after period expires"
        );

        // Perform sell swap (no taxes should be charged)
        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        uint256 sellAmount = buyerTokenBalance / 2;
        _swapSell(buyer, sellAmount, 0, true);

        // Verify still no tax tokens accumulated
        assertEq(
            IERC20(testToken).balanceOf(testToken),
            tokenContractBalanceBefore,
            "No sell tax should accumulate after period expires"
        );

        // Claim LP fees from both swaps
        _collectFees(testToken);
        graduatorWithFees.sweep();

        uint256 creatorEthBalanceAfter = creator.balance;
        uint256 treasuryEthBalanceAfter = treasury.balance;

        // Verify creator + treasury received LP fees (~0.5% each from ~2 ETH volume)
        uint256 creatorFeesReceived = creatorEthBalanceAfter - creatorEthBalanceBefore;
        uint256 treasuryFeesReceived = treasuryEthBalanceAfter - treasuryEthBalanceBefore;

        assertGt(creatorFeesReceived, 0, "Creator should receive LP fees");
        assertGt(treasuryFeesReceived, 0, "Treasury should receive LP fees");

        // Total fees should be ~1% of buy amount (buy generates more fees than sell due to amounts)
        assertApproxEqAbs(
            creatorFeesReceived + treasuryFeesReceived, buyAmount / 100, 2, "Total LP fees should be ~1% of buy volume"
        );
    }

    /// @notice Test that LP fees are redirected to new owner after token ownership transfer
    function test_claimLPFees_withTokenOwnershipTransfer_feesGoToNewOwner() public createDefaultTaxToken {
        _graduateToken();

        // Perform buy swap to generate LP fees
        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        // Transfer ownership to alice
        vm.prank(creator);
        launchpad.transferTokenOwnership(testToken, alice);
        assertEq(launchpad.getTokenOwner(testToken), alice, "Alice should be the new token owner");

        // Record balances before claiming
        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 aliceEthBalanceBefore = alice.balance;

        // Claim LP fees
        address[] memory tokens = new address[](1);
        tokens[0] = testToken;
        uint256[] memory positionIndexes = new uint256[](1);
        positionIndexes[0] = 0;

        vm.prank(alice);
        graduatorWithFees.collectEthFees(tokens, positionIndexes);

        graduatorWithFees.sweep();

        uint256 creatorEthBalanceAfter = creator.balance;
        uint256 aliceEthBalanceAfter = alice.balance;

        // Verify alice received fees, creator did not
        assertGt(aliceEthBalanceAfter, aliceEthBalanceBefore, "Alice should receive LP fees as new owner");
        assertEq(creatorEthBalanceAfter, creatorEthBalanceBefore, "Creator should not receive fees after transfer");

        // Verify alice received ~0.5% of buy amount
        assertApproxEqAbs(
            aliceEthBalanceAfter - aliceEthBalanceBefore, buyAmount / 200, 1, "Alice should receive ~0.5% LP fees"
        );
    }

    /// @notice Test claiming LP fees from both positions (main + single-sided ETH) after price dips below graduation
    function test_claimLPFees_bothPositions_afterPriceDip() public createDefaultTaxToken {
        _graduateToken();

        // Perform large sell to dip price below graduation
        // This activates the second single-sided ETH position
        _swapSell(buyer, 10_000_000e18, 0.1 ether, true);

        // Perform buy to cross back through both positions
        uint256 buyAmount = 4 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        // Check fees from both positions
        address[] memory tokens = new address[](1);
        tokens[0] = testToken;

        uint256[] memory fees0 = graduatorWithFees.getClaimableFees(tokens, 0);
        uint256[] memory fees1 = graduatorWithFees.getClaimableFees(tokens, 1);

        uint256 totalClaimableFees = fees0[0] + fees1[0];
        assertGt(fees0[0], 0, "Position 0 should have fees");
        assertGt(fees1[0], 0, "Position 1 should have fees");

        // Record balances
        uint256 creatorEthBalanceBefore = creator.balance;

        // Claim from both positions
        uint256[] memory positionIndexes = new uint256[](2);
        positionIndexes[0] = 0;
        positionIndexes[1] = 1;
        vm.prank(creator);
        graduatorWithFees.collectEthFees(tokens, positionIndexes);
        graduatorWithFees.sweep();

        uint256 creatorEthBalanceAfter = creator.balance;
        uint256 totalCreatorFees = creatorEthBalanceAfter - creatorEthBalanceBefore;

        // Verify total creator fees ≈ 0.5% of buy amount (0.02 ETH)
        assertApproxEqAbsDecimal(
            totalCreatorFees, buyAmount / 200, 1, 18, "Creator should receive ~0.5% of buy amount from both positions"
        );

        // Verify claimed amount matches what was claimable
        assertApproxEqAbs(totalCreatorFees, totalClaimableFees, 1, "Claimed fees should match getClaimableFees total");
    }
}
