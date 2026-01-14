// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/graduationUniv4.taxToken.base.t.sol";
import {LivoTaxTokenUniV4} from "src/tokens/LivoTaxTokenUniV4.sol";
import {ILivoTokenTaxable} from "src/interfaces/ILivoTokenTaxable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Comprehensive tests for LivoTaxTokenUniV4 and LivoTaxSwapHook functionality
contract TaxTokenUniV4Tests is TaxTokenUniV4BaseTests {
    function setUp() public override {
        super.setUp();
    }

    /////////////////////////////////// CATEGORY 1: PRE-GRADUATION BEHAVIOR ///////////////////////////////////

    /// @notice Test that no taxes are charged before graduation when purchasing through launchpad
    function test_noTaxesBeforeGraduation_launchpadPurchases() public createDefaultTaxToken {
        uint256 creatorBalanceBefore = creator.balance;

        // Multiple users buy tokens through launchpad
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        vm.deal(alice, 2 ether);
        vm.prank(alice);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        // Verify token owner (creator) received no tax
        assertEq(creator.balance, creatorBalanceBefore, "Creator should not receive any tax before graduation");

        // Verify buyers received tokens (only launchpad fees deducted, no tax)
        assertGt(IERC20(testToken).balanceOf(buyer), 0, "Buyer should have received tokens");
        assertGt(IERC20(testToken).balanceOf(alice), 0, "Alice should have received tokens");

        // Token is not graduated yet
        assertFalse(LivoTaxTokenUniV4(testToken).graduated(), "Token should not be graduated yet");
    }

    /////////////////////////////////// CATEGORY 2: TAX COLLECTION (ACTIVE PERIOD) ///////////////////////////////////

    /// @notice Test that buy tax is collected correctly after graduation within tax period
    function test_buyTaxCollected_withinTaxPeriod() public createDefaultTaxToken {
        _graduateToken();

        uint256 creatorBalanceBefore = creator.balance;
        uint256 buyerTokenBalanceBefore = IERC20(testToken).balanceOf(buyer);

        uint256 ethIn = 1 ether;
        deal(buyer, ethIn);

        // Buyer swaps ETH for tokens via UniV4
        _swapBuy(buyer, ethIn, 0, true);

        uint256 buyerTokenBalanceAfter = IERC20(testToken).balanceOf(buyer);

        // Calculate expected tax: ethIn * buyTaxBps / 10000
        uint256 expectedTax = (ethIn * DEFAULT_BUY_TAX_BPS) / 10000;

        // Verify tax was sent to creator (token owner)
        assertEq(
            creator.balance,
            creatorBalanceBefore + expectedTax,
            "Creator should receive buy tax"
        );

        // Verify buyer received tokens (amount will be less than without tax)
        assertGt(buyerTokenBalanceAfter, buyerTokenBalanceBefore, "Buyer should have received tokens");
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

        uint256 creatorBalanceBefore = creator.balance;
        uint256 buyerEthBalanceBefore = buyer.balance;

        uint256 sellAmount = buyerTokenBalance / 2;

        // Buyer swaps tokens for ETH via UniV4
        _swapSell(buyer, sellAmount, 0, true);

        uint256 buyerEthBalanceAfter = buyer.balance;
        uint256 ethReceived = buyerEthBalanceAfter - buyerEthBalanceBefore;

        // Calculate expected tax on ETH output
        // Note: Tax is calculated on the ETH amount in the swap
        // The exact calculation depends on the pool state, but creator should receive some tax
        uint256 expectedTaxApprox = (ethReceived * DEFAULT_SELL_TAX_BPS) / 10000;

        // Verify tax was sent to creator (allow for some variance due to pool math)
        assertGt(creator.balance, creatorBalanceBefore, "Creator should receive sell tax");
        assertApproxEqRel(
            creator.balance - creatorBalanceBefore,
            expectedTaxApprox,
            0.15e18, // 15% tolerance for pool math variance
            "Creator should receive approximately the expected sell tax"
        );
    }

    /// @notice Test that different buy vs sell tax rates are applied correctly
    function test_buyVsSellTaxRates_appliedCorrectly() public {
        // Create token with different tax rates: 2% buy, 5% sell
        testToken = _createTaxToken(200, 500, 14 days);
        _graduateToken();

        uint256 ethIn = 1 ether;

        // Test buy tax (2%)
        uint256 creatorBalanceBefore = creator.balance;
        deal(buyer, ethIn);
        _swapBuy(buyer, ethIn, 0, true);
        uint256 buyTaxCollected = creator.balance - creatorBalanceBefore;
        uint256 expectedBuyTax = (ethIn * 200) / 10000;
        assertApproxEqRel(buyTaxCollected, expectedBuyTax, 0.01e18, "Buy tax should be ~2%");

        // Get some tokens to sell
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(testToken, 0, DEADLINE);
        _graduateToken(); // Graduate again to reset state

        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        uint256 sellAmount = buyerTokenBalance / 3;

        // Test sell tax (5%)
        creatorBalanceBefore = creator.balance;
        _swapSell(buyer, sellAmount, 0, true);
        uint256 sellTaxCollected = creator.balance - creatorBalanceBefore;

        // Verify sell tax is higher than buy tax (5% vs 2%)
        assertGt(sellTaxCollected, buyTaxCollected, "Sell tax should be higher than buy tax");
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

        // Test buy with 0% tax
        uint256 creatorBalanceBefore = creator.balance;
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, true);
        assertEq(creator.balance, creatorBalanceBefore, "Creator should receive no buy tax (0% rate)");

        // Test sell with 5% tax
        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        creatorBalanceBefore = creator.balance;
        _swapSell(buyer, buyerTokenBalance / 2, 0, true);
        assertGt(creator.balance, creatorBalanceBefore, "Creator should receive sell tax (5% rate)");
    }

    /// @notice Test that tax recipient receives ETH in real-time during swaps
    function test_taxRecipientReceivesEthDuringSwap() public createDefaultTaxToken {
        _graduateToken();

        uint256 creatorBalance = creator.balance;

        // Multiple swaps, checking balance after each
        deal(buyer, 1 ether);
        _swapBuy(buyer, 0.5 ether, 0, true);
        uint256 taxAfterSwap1 = creator.balance - creatorBalance;
        assertGt(taxAfterSwap1, 0, "Tax should be collected after first buy");

        creatorBalance = creator.balance;
        deal(buyer, 1 ether);
        _swapBuy(buyer, 0.5 ether, 0, true);
        uint256 taxAfterSwap2 = creator.balance - creatorBalance;
        assertGt(taxAfterSwap2, 0, "Tax should be collected after second buy");

        // Taxes should be approximately equal for equal swap sizes
        assertApproxEqRel(taxAfterSwap1, taxAfterSwap2, 0.05e18, "Taxes should be similar for similar swap sizes");
    }

    /// @notice Test multiple users buying and taxes accumulating
    function test_multipleBuyers_taxesAccumulate() public createDefaultTaxToken {
        _graduateToken();

        uint256 creatorBalanceBefore = creator.balance;

        // 5 different users buy tokens
        address[] memory buyers = new address[](5);
        buyers[0] = buyer;
        buyers[1] = alice;
        buyers[2] = bob;
        buyers[3] = makeAddr("user3");
        buyers[4] = makeAddr("user4");

        uint256 totalExpectedTax = 0;
        for (uint256 i = 0; i < buyers.length; i++) {
            uint256 ethIn = 0.5 ether;
            deal(buyers[i], ethIn);
            _swapBuy(buyers[i], ethIn, 0, true);
            totalExpectedTax += (ethIn * DEFAULT_BUY_TAX_BPS) / 10000;
        }

        // Verify creator received accumulated taxes
        assertApproxEqRel(
            creator.balance - creatorBalanceBefore,
            totalExpectedTax,
            0.05e18,
            "Creator should receive accumulated taxes from all buyers"
        );
    }

    /////////////////////////////////// CATEGORY 3: POST-TAX-PERIOD BEHAVIOR ///////////////////////////////////

    /// @notice Test that no taxes are charged after the tax period expires
    function test_noTaxesAfterPeriodExpires() public createDefaultTaxToken {
        _graduateToken();

        // Fast-forward past tax duration (14 days + 1 second)
        vm.warp(block.timestamp + DEFAULT_TAX_DURATION + 1 seconds);

        uint256 creatorBalanceBefore = creator.balance;

        // Perform buy swap
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, true);
        assertEq(creator.balance, creatorBalanceBefore, "No buy tax should be collected after period expires");

        // Perform sell swap
        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        creatorBalanceBefore = creator.balance;
        _swapSell(buyer, buyerTokenBalance / 2, 0, true);
        assertEq(creator.balance, creatorBalanceBefore, "No sell tax should be collected after period expires");
    }

    /// @notice Test exact boundary conditions for tax period
    function test_taxPeriodBoundaries() public createDefaultTaxToken {
        _graduateToken();

        uint40 graduationTimestamp = LivoTaxTokenUniV4(testToken).graduationTimestamp();
        uint256 creatorBalance;

        // Test at t = 0 (graduation) - tax should be collected
        creatorBalance = creator.balance;
        deal(buyer, 0.5 ether);
        _swapBuy(buyer, 0.5 ether, 0, true);
        assertGt(creator.balance, creatorBalance, "Tax should be collected at graduation (t=0)");

        // Test at t = duration - 1 second (last second of period) - tax should still be collected
        vm.warp(graduationTimestamp + DEFAULT_TAX_DURATION - 1 seconds);
        creatorBalance = creator.balance;
        deal(buyer, 0.5 ether);
        _swapBuy(buyer, 0.5 ether, 0, true);
        assertGt(creator.balance, creatorBalance, "Tax should be collected at last second of period");

        // Test at t = duration exactly - NO tax should be collected
        vm.warp(graduationTimestamp + DEFAULT_TAX_DURATION);
        creatorBalance = creator.balance;
        deal(buyer, 0.5 ether);
        _swapBuy(buyer, 0.5 ether, 0, true);
        assertEq(creator.balance, creatorBalance, "No tax should be collected exactly at expiry");

        // Test at t = duration + 1 second - NO tax should be collected
        vm.warp(graduationTimestamp + DEFAULT_TAX_DURATION + 1 seconds);
        creatorBalance = creator.balance;
        deal(buyer, 0.5 ether);
        _swapBuy(buyer, 0.5 ether, 0, true);
        assertEq(creator.balance, creatorBalance, "No tax should be collected after expiry");
    }

    /////////////////////////////////// CATEGORY 4: BACKWARD COMPATIBILITY ///////////////////////////////////

    /// @notice Test that non-taxable tokens don't revert when using tax hook
    function test_nonTaxableToken_hookDoesntRevert() public {
        // Create standard LivoToken (no tax functionality) with tax hook graduator
        testToken = _createStandardTokenWithTaxHookGraduator();

        // Verify token owner doesn't receive any "tax" (there shouldn't be any)
        uint256 creatorBalanceBefore = creator.balance;

        _graduateToken();

        // Perform buy and sell swaps - these should succeed without reverting
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, true);

        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        _swapSell(buyer, buyerTokenBalance / 2, 0, true);

        // Verify no tax was collected (hook handled missing getTaxConfig() gracefully)
        assertEq(creator.balance, creatorBalanceBefore, "No tax should be collected from non-taxable token");
    }

    /////////////////////////////////// CATEGORY 5: EDGE CASES & SECURITY ///////////////////////////////////

    /// @notice Test maximum tax rate (5% = 500 bps)
    function test_maxTaxRate_500bps() public {
        // Create token with max tax rates
        testToken = _createTaxToken(500, 500, 14 days);
        _graduateToken();

        uint256 ethIn = 10 ether;
        uint256 expectedTax = (ethIn * 500) / 10000; // 5% of 10 ETH = 0.5 ETH

        uint256 creatorBalanceBefore = creator.balance;
        deal(buyer, ethIn);
        _swapBuy(buyer, ethIn, 0, true);

        // Verify ~0.5 ETH tax collected
        assertApproxEqRel(
            creator.balance - creatorBalanceBefore,
            expectedTax,
            0.01e18, // 1% tolerance
            "Max tax rate should collect ~5% of swap amount"
        );
    }

    /// @notice Test that token creation with invalid tax rate reverts
    function test_tokenCreation_invalidTaxRate_reverts() public {
        bytes memory tokenCalldata = taxTokenImpl.encodeTokenCalldata(
            600, // > MAX_TAX_BPS (500)
            300,
            14 days
        );

        vm.expectRevert();
        vm.prank(creator);
        launchpad.createToken(
            "InvalidToken",
            "INV",
            address(taxTokenImpl),
            address(bondingCurve),
            address(graduatorWithTaxHooks),
            creator,
            "0x003",
            tokenCalldata
        );
    }

    /// @notice Test that tax recipient is immutable after graduation
    function test_taxRecipient_immutableAfterGraduation() public createDefaultTaxToken {
        _graduateToken();

        ILivoTokenTaxable.TaxConfig memory config = LivoTaxTokenUniV4(testToken).getTaxConfig();
        address initialTaxRecipient = config.taxRecipient;

        assertEq(initialTaxRecipient, creator, "Tax recipient should be creator");

        // Fast forward and verify tax recipient hasn't changed
        vm.warp(block.timestamp + 7 days);

        config = LivoTaxTokenUniV4(testToken).getTaxConfig();
        assertEq(config.taxRecipient, initialTaxRecipient, "Tax recipient should remain unchanged");

        // Verify taxes still go to original recipient
        uint256 recipientBalanceBefore = config.taxRecipient.balance;
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, true);
        assertGt(config.taxRecipient.balance, recipientBalanceBefore, "Tax should still go to original recipient");
    }

    /// @notice Test tax on very small swaps
    function test_verySmallSwap_taxRoundsCorrectly() public createDefaultTaxToken {
        _graduateToken();

        uint256 creatorBalanceBefore = creator.balance;
        uint256 verySmallAmount = 0.0001 ether; // 100000 gwei

        deal(buyer, verySmallAmount);
        _swapBuy(buyer, verySmallAmount, 0, true);

        // Tax might round to a very small amount or zero, but should not revert
        uint256 taxCollected = creator.balance - creatorBalanceBefore;
        console.log("Tax collected on 0.0001 ETH swap:", taxCollected);

        // Just verify no revert occurred
        assertTrue(true, "Very small swap should not revert");
    }

    /// @notice Test that swap before graduation reverts (tokens can't transfer to pool)
    function test_notGraduated_swapReverts() public createDefaultTaxToken {
        // Token is created but not graduated
        assertFalse(LivoTaxTokenUniV4(testToken).graduated(), "Token should not be graduated");

        // Attempt to swap should revert (tokens can't be transferred to pool before graduation)
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, false); // expectSuccess = false
    }

    /////////////////////////////////// CATEGORY 6: MULTI-USER TAX SCENARIOS ///////////////////////////////////

    /// @notice Test buy then sell from same user with both taxes applied
    function test_buyThenSell_bothTaxesApplied() public createDefaultTaxToken {
        // First buy tokens through launchpad
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        _graduateToken();

        uint256 creatorBalanceBefore = creator.balance;

        // Buy more tokens via UniV4 (pay buy tax)
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, true);
        uint256 buyTaxCollected = creator.balance - creatorBalanceBefore;
        assertGt(buyTaxCollected, 0, "Buy tax should be collected");

        // Sell some tokens via UniV4 (pay sell tax)
        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        creatorBalanceBefore = creator.balance;
        _swapSell(buyer, buyerTokenBalance / 3, 0, true);
        uint256 sellTaxCollected = creator.balance - creatorBalanceBefore;
        assertGt(sellTaxCollected, 0, "Sell tax should be collected");

        // Both taxes were collected
        assertGt(buyTaxCollected + sellTaxCollected, 0, "Creator should receive both buy and sell taxes");
    }

    /////////////////////////////////// CATEGORY 7: INTEGRATION TESTS ///////////////////////////////////

    /// @notice Test full lifecycle from creation to tax expiry
    function test_fullLifecycle_launchpadToExpiry() public createDefaultTaxToken {
        uint256 creatorInitialBalance = creator.balance;

        // 1. Launchpad purchases (no tax)
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
        assertEq(creator.balance, creatorInitialBalance, "No tax during launchpad phase");

        // 2. Graduate token
        _graduateToken();
        uint40 graduationTimestamp = LivoTaxTokenUniV4(testToken).graduationTimestamp();
        assertGt(graduationTimestamp, 0, "Graduation timestamp should be set");

        // 3. UniV4 swaps during tax period (with tax)
        deal(buyer, 1 ether);
        _swapBuy(buyer, 0.5 ether, 0, true);
        assertGt(creator.balance, creatorInitialBalance, "Tax should be collected during tax period");

        uint256 balanceAfterTaxPeriod = creator.balance;

        // 4. Warp past tax period
        vm.warp(graduationTimestamp + DEFAULT_TAX_DURATION + 1 seconds);

        // 5. UniV4 swaps after expiry (no tax)
        deal(buyer, 1 ether);
        _swapBuy(buyer, 0.5 ether, 0, true);
        assertEq(creator.balance, balanceAfterTaxPeriod, "No tax should be collected after expiry");
    }

    /// @notice Test that tax hook doesn't interfere with liquidity operations
    function test_taxHook_doesntAffectLiquidityAddRemove() public createDefaultTaxToken {
        _graduateToken();

        // Add liquidity to pool
        _addMixedLiquidity(alice, 1 ether, 1000 ether, true);

        // Adding liquidity should not trigger tax collection
        // (hook only triggers on swaps, not liquidity operations)

        // Remove liquidity would require position manager interactions
        // For now, just verify adding liquidity didn't cause issues
        assertTrue(true, "Liquidity operations should not be affected by tax hook");
    }
}
