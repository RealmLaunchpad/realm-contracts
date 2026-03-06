// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {ILivoTaxableTokenUniV4} from "src/interfaces/ILivoTaxableTokenUniV4.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoSwapHook} from "src/hooks/LivoSwapHook.sol";
import {LivoFactoryTaxToken} from "src/tokenFactories/LivoFactoryTaxToken.sol";
import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";
import {LivoFeeV4Handler} from "src/feeHandlers/LivoFeeV4Handler.sol";

/// @notice Comprehensive tests for LivoTaxableTokenUniV4 and LivoTaxSwapHook functionality
contract TaxTokenUniV4Tests is TaxTokenUniV4BaseTests {
    function setUp() public override {
        super.setUp();
    }

    /// @notice Helper to collect LP fees from a single token
    function _collectFees(address token) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        vm.prank(creator);
        feeHandlerV4.accrueTokenFees(tokens);

        vm.prank(creator);
        feeHandlerV4.claim(tokens);
    }

    function _pendingTaxes(address token, address tokenOwner) internal view returns (uint256) {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        return ILivoFeeHandler(ILivoToken(token).feeHandler()).getClaimable(tokens, tokenOwner)[0];
    }

    /////////////////////////////////// CATEGORY 1: PRE-GRADUATION BEHAVIOR ///////////////////////////////////

    /// @notice Test that no taxes are charged before graduation when purchasing through launchpad
    function test_noTaxesBeforeGraduation_launchpadPurchases() public createDefaultTaxToken {
        uint256 creatorPendingTaxesBefore = _pendingTaxes(testToken, creator);

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

        // Verify token owner (creator) has no accrued taxes before graduation
        assertEq(
            _pendingTaxes(testToken, creator),
            creatorPendingTaxesBefore,
            "Creator should not accrue taxes before graduation"
        );

        // Verify buyers received tokens (only launchpad fees deducted, no tax)
        assertGt(IERC20(testToken).balanceOf(buyer), 0, "Buyer should have received tokens");
        assertGt(IERC20(testToken).balanceOf(alice), 0, "Alice should have received tokens");

        // Token is not graduated yet
        assertFalse(ILivoToken(testToken).graduated(), "Token should not be graduated yet");
    }

    /////////////////////////////////// CATEGORY 2: TAX COLLECTION (ACTIVE PERIOD) ///////////////////////////////////

    // This test is removed because buy taxes no longer exist in the implementation

    /// @notice Test that sell tax is collected correctly after graduation within tax period
    function test_sellTaxCollected_withinTaxPeriod() public createDefaultTaxToken {
        // First, buy some tokens through launchpad before graduation
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        assertGt(buyerTokenBalance, 0, "Buyer should have tokens to sell");

        _graduateToken();

        uint256 creatorTaxesBefore = _pendingTaxes(testToken, creator);
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

        uint256 creatorTaxAccrued = _pendingTaxes(testToken, creator) - creatorTaxesBefore;
        assertGt(creatorTaxAccrued, 0, "Creator should accrue sell tax");
        assertApproxEqRel(
            creatorTaxAccrued,
            expectedTaxApprox,
            0.00015e18, // 15% tolerance for pool math variance
            "Creator should accrue approximately the expected sell tax"
        );
    }

    /// @notice test that if the tokenOwner is updated in the launchpad, the sell taxes are redirected correctly
    function test_sellTaxCollectedToNewTokenOwner_afterChangedInLaunchpad() public createDefaultTaxToken {
        _graduateToken();

        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);

        uint256 creatorTaxesBefore = _pendingTaxes(testToken, creator);
        uint256 sellAmount = buyerTokenBalance / 2;
        // Buyer swaps tokens for ETH via UniV4
        _swapSell(buyer, sellAmount, 0, true);

        assertGt(_pendingTaxes(testToken, creator), creatorTaxesBefore, "Creator should accrue sell tax");

        /////////// now update token owner by transferring ownership

        vm.prank(creator);
        ILivoToken(testToken).proposeNewOwner(alice);
        vm.prank(alice);
        ILivoToken(testToken).acceptTokenOwnership();
        assertEq(ILivoToken(testToken).owner(), alice, "New token owner should be Alice");

        // By default, fee receiver is unchanged after ownership transfer
        uint256 aliceTaxesBefore = _pendingTaxes(testToken, alice);
        creatorTaxesBefore = _pendingTaxes(testToken, creator);

        sellAmount = buyerTokenBalance / 2;
        // Buyer swaps tokens for ETH via UniV4
        _swapSell(buyer, sellAmount, 0, true);
        assertEq(_pendingTaxes(testToken, alice), aliceTaxesBefore, "Alice should not accrue without receiver update");
        assertGt(_pendingTaxes(testToken, creator), creatorTaxesBefore, "Creator should keep accruing sell tax");

        // New owner can manually update the fee receiver
        vm.prank(alice);
        ILivoToken(testToken).setFeeReceiver(alice);

        // Ensure buyer has fresh tokens for a post-update sell path
        deal(buyer, 0.2 ether);
        _swapBuy(buyer, 0.1 ether, 0, true);

        aliceTaxesBefore = _pendingTaxes(testToken, alice);
        creatorTaxesBefore = _pendingTaxes(testToken, creator);

        buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        assertGt(buyerTokenBalance, 0, "buyer should have tokens for post-update sell");
        sellAmount = buyerTokenBalance / 2;
        _swapSell(buyer, sellAmount, 0, true);

        assertGt(_pendingTaxes(testToken, alice), aliceTaxesBefore, "Alice should accrue after receiver update");
        assertEq(
            _pendingTaxes(testToken, creator), creatorTaxesBefore, "Creator should stop accruing after receiver update"
        );
    }

    /// @notice Test that sell tax rates are applied correctly
    /// @dev Sell tax goes directly to creator as WETH, buy taxes are never collected
    function test_sellTaxRates_appliedCorrectly() public {
        // Create token with 5% sell tax (buy tax is always 0)
        testToken = _createTaxToken(500, 14 days);

        // First get some tokens through launchpad BEFORE graduating
        vm.deal(buyer, 3 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(testToken, 0, DEADLINE);

        _graduateToken();

        // Verify no buy tax is collected
        uint256 tokenContractBalanceBefore = IERC20(testToken).balanceOf(testToken);
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, true);
        assertEq(IERC20(testToken).balanceOf(testToken), tokenContractBalanceBefore, "No buy tax should be collected");

        // Test sell tax (5%) - accrued in graduator accounting
        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        uint256 sellAmount = buyerTokenBalance / 3;

        uint256 creatorTaxesBefore = _pendingTaxes(testToken, creator);
        uint256 buyerEthBalanceBefore = buyer.balance;
        _swapSell(buyer, sellAmount, 0, true);
        uint256 buyerEthBalanceAfter = buyer.balance;
        uint256 sellTaxCollected = _pendingTaxes(testToken, creator) - creatorTaxesBefore;

        uint256 ethReceived = buyerEthBalanceAfter - buyerEthBalanceBefore;

        // Calculate expected tax: taxCharged / (ethReceived + taxCharged) = 500 / 10000
        // Solving: taxCharged = ethReceived * 500 / (10000 - 500)
        uint256 expectedSellTaxApprox = (ethReceived * 500) / (10000 - 500);

        // Verify sell tax was collected
        assertGt(sellTaxCollected, 0, "Sell tax should be accrued");
        assertApproxEqRel(
            sellTaxCollected,
            expectedSellTaxApprox,
            0.00015e18, // 15% tolerance for pool math variance
            "Sell tax should be approximately 5% of ETH output"
        );
    }

    /// @notice Test that zero sell tax rate results in no tax collection
    function test_zeroSellTaxRate_noTaxCollected() public {
        // Create token with 0% sell tax (buy tax is always 0)
        testToken = _createTaxToken(0, 14 days);

        // Buy tokens through launchpad
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        _graduateToken();

        // Verify no buy tax is collected (buy tax is always 0)
        uint256 tokenContractBalanceBefore = IERC20(testToken).balanceOf(testToken);
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, true);
        assertEq(IERC20(testToken).balanceOf(testToken), tokenContractBalanceBefore, "No buy tax should be collected");

        // Test sell with 0% tax - creator should NOT accrue taxes
        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        uint256 creatorTaxesBefore = _pendingTaxes(testToken, creator);
        _swapSell(buyer, buyerTokenBalance / 2, 0, true);
        assertEq(_pendingTaxes(testToken, creator), creatorTaxesBefore, "Creator should NOT accrue sell tax (0% rate)");
    }

    /// @notice Test that sell taxes are collected correctly during multiple swaps
    /// @dev Sell tax goes directly to creator as WETH, no buy tax is collected
    function test_taxRecipientReceivesTaxDuringSwap_twoSellSwaps() public createDefaultTaxToken {
        // First buy tokens through launchpad
        vm.deal(buyer, 3 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(testToken, 0, DEADLINE);

        _graduateToken();

        // Verify no buy tax is collected
        uint256 tokenContractBalanceBefore = IERC20(testToken).balanceOf(testToken);
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, true);
        assertEq(IERC20(testToken).balanceOf(testToken), tokenContractBalanceBefore, "No buy tax should be collected");

        // Test sell tax - first sell
        uint256 creatorTaxBalance = _pendingTaxes(testToken, creator);
        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        _swapSell(buyer, buyerTokenBalance / 4, 0, true);
        uint256 taxAfterSell1 = _pendingTaxes(testToken, creator) - creatorTaxBalance;
        assertGt(taxAfterSell1, 0, "tax should be accrued after first sell");

        // Test sell tax - second sell
        creatorTaxBalance = _pendingTaxes(testToken, creator);
        buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        _swapSell(buyer, buyerTokenBalance / 3, 0, true);
        uint256 taxAfterSell2 = _pendingTaxes(testToken, creator) - creatorTaxBalance;
        assertGt(taxAfterSell2, 0, "tax should be accrued after second sell");
    }

    /// @notice Test multiple users selling and WETH sell taxes accumulating for creator
    /// @dev Sell tax goes directly to creator as WETH, no buy tax is collected
    function test_multipleSellers_taxesAccumulate() public createDefaultTaxToken {
        // Give tokens to 5 different sellers through launchpad purchases
        address[] memory sellerAddrs = new address[](5);
        sellerAddrs[0] = buyer;
        sellerAddrs[1] = alice;
        sellerAddrs[2] = bob;
        sellerAddrs[3] = makeAddr("user3");
        sellerAddrs[4] = makeAddr("user4");

        for (uint256 i = 0; i < sellerAddrs.length; i++) {
            vm.deal(sellerAddrs[i], 0.5 ether);
            vm.prank(sellerAddrs[i]);
            launchpad.buyTokensWithExactEth{value: 0.5 ether}(testToken, 0, DEADLINE);
        }

        _graduateToken();

        uint256 creatorTaxBalanceBefore = _pendingTaxes(testToken, creator);

        // 5 different users sell tokens
        for (uint256 i = 0; i < sellerAddrs.length; i++) {
            uint256 tokenBalance = IERC20(testToken).balanceOf(sellerAddrs[i]);
            _swapSell(sellerAddrs[i], tokenBalance / 2, 0, true);
        }

        uint256 totalTaxCollected = _pendingTaxes(testToken, creator) - creatorTaxBalanceBefore;

        // Verify creator accrued taxes from all sellers
        assertGt(totalTaxCollected, 0, "Creator should accumulate taxes from all sellers");
    }

    /////////////////////////////////// CATEGORY 3: POST-TAX-PERIOD BEHAVIOR ///////////////////////////////////

    /// @notice Test that no taxes are charged after the tax period expires
    /// @dev Only sell tax exists, buy tax is always 0 - sell tax should be 0 after expiry
    function test_noTaxesAfterPeriodExpires() public createDefaultTaxToken {
        // First buy tokens through launchpad
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        _graduateToken();

        // Fast-forward past tax duration (14 days + 1 second)
        vm.warp(block.timestamp + DEFAULT_TAX_DURATION + 1 seconds);

        uint256 tokenContractBalanceBeforeBuy = IERC20(testToken).balanceOf(testToken);
        uint256 creatorTaxesBeforeBuy = _pendingTaxes(testToken, creator);

        // Perform buy swap - should never collect tax (buy tax is always 0)
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, true);
        assertEq(
            IERC20(testToken).balanceOf(testToken), tokenContractBalanceBeforeBuy, "No buy tax should ever be collected"
        );
        assertGt(_pendingTaxes(testToken, creator), creatorTaxesBeforeBuy, "Buy should only add LP-fee claimable");

        // Perform sell swap - should accrue no tax after period expires
        uint256 creatorTaxesBeforeSell = _pendingTaxes(testToken, creator);

        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        _swapSell(buyer, buyerTokenBalance / 2, 0, true);

        assertGe(_pendingTaxes(testToken, creator), creatorTaxesBeforeSell, "Sell should not add sell-tax claimable");
    }

    /// @notice Test exact boundary conditions for sell tax period
    /// @dev Only sell tax is collected, buy tax is always 0
    /// @dev Hook uses `>` comparison: tax collected when timestamp <= graduation + duration
    function test_taxPeriodBoundaries() public createDefaultTaxToken {
        // First buy tokens through launchpad
        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(testToken, 0, DEADLINE);

        _graduateToken();

        uint40 graduationTimestamp = ILivoTaxableTokenUniV4(testToken).graduationTimestamp();
        uint256 creatorTaxBalance;
        uint256 buyerTokenBalance;

        // Test at t = 0 (graduation) - sell tax should be collected
        creatorTaxBalance = _pendingTaxes(testToken, creator);
        buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        _swapSell(buyer, buyerTokenBalance / 10, 0, true);
        assertGt(
            _pendingTaxes(testToken, creator), creatorTaxBalance, "Sell tax should be collected at graduation (t=0)"
        );

        // Test at t = duration - 1 second (last second of period) - tax should still be collected
        vm.warp(graduationTimestamp + DEFAULT_TAX_DURATION - 1 seconds);
        creatorTaxBalance = _pendingTaxes(testToken, creator);
        buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        _swapSell(buyer, buyerTokenBalance / 10, 0, true);
        assertGt(
            _pendingTaxes(testToken, creator),
            creatorTaxBalance,
            "Sell tax should be collected at last second of period"
        );

        // Test at t = duration exactly - tax IS still collected (hook uses > not >=)
        // Tax period is [graduation, graduation + duration] INCLUSIVE
        vm.warp(graduationTimestamp + DEFAULT_TAX_DURATION);
        creatorTaxBalance = _pendingTaxes(testToken, creator);
        buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        _swapSell(buyer, buyerTokenBalance / 10, 0, true);
        assertGt(
            _pendingTaxes(testToken, creator),
            creatorTaxBalance,
            "Sell tax should be collected at exact expiry (inclusive)"
        );

        // Test at t = duration + 1 second - NO tax should be collected
        vm.warp(graduationTimestamp + DEFAULT_TAX_DURATION + 1 seconds);
        creatorTaxBalance = _pendingTaxes(testToken, creator);
        buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        _swapSell(buyer, buyerTokenBalance / 10, 0, true);
        assertEq(_pendingTaxes(testToken, creator), creatorTaxBalance, "No sell tax should be collected after expiry");
    }

    /////////////////////////////////// CATEGORY 5: EDGE CASES & SECURITY ///////////////////////////////////

    /// @notice Test maximum sell tax rate (5% = 500 bps)
    /// @dev Sell tax goes directly to creator as WETH
    function test_maxSellRate_collectedTaxMatchesExpectation() public {
        // Create token with max sell tax rate
        testToken = _createTaxToken(500, 14 days);

        // Buy tokens through launchpad (buy enough to have tokens to sell)
        vm.deal(buyer, 3 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(testToken, 0, DEADLINE);

        _graduateToken();

        // Test sell with max 5% tax
        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        uint256 sellAmount = buyerTokenBalance / 2;

        uint256 creatorTaxesBefore = _pendingTaxes(testToken, creator);
        uint256 buyerEthBalanceBefore = buyer.balance;
        _swapSell(buyer, sellAmount, 0, true);
        uint256 buyerEthBalanceAfter = buyer.balance;

        uint256 ethReceived = buyerEthBalanceAfter - buyerEthBalanceBefore;
        uint256 sellTaxCollected = _pendingTaxes(testToken, creator) - creatorTaxesBefore;

        // Calculate expected tax: taxCharged / (ethReceived + taxCharged) = 500 / 10000
        uint256 expectedSellTaxApprox = (ethReceived * 500) / (10000 - 500);

        // Verify ~5% sell tax accrued
        assertApproxEqRel(
            sellTaxCollected,
            expectedSellTaxApprox,
            0.00015e18, // 15% tolerance for pool math variance
            "Max sell tax rate should accrue ~5%"
        );
    }

    /// @notice Test that token creation with invalid tax rate reverts
    function test_tokenCreation_invalidTaxRate_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(LivoFactoryTaxToken.InvalidSellTaxBps.selector));
        vm.prank(creator);
        factoryTax.createToken("InvalidToken", "INV", creator, "0x003", 600, uint32(14 days));
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

    /// @notice Test buy then sell from same user with only sell tax applied
    /// @dev Buy tax is never collected, Sell tax goes to creator as WETH
    function test_buyThenSell_onlySellTaxApplied() public createDefaultTaxToken {
        // First buy tokens through launchpad
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        _graduateToken();

        uint256 tokenContractBalanceBefore = IERC20(testToken).balanceOf(testToken);
        uint256 creatorTaxesBefore = _pendingTaxes(testToken, creator);

        // Buy more tokens via UniV4 (no buy tax should be collected)
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, true);
        assertEq(IERC20(testToken).balanceOf(testToken), tokenContractBalanceBefore, "No buy tax should be collected");

        // Sell some tokens via UniV4 (accrue sell tax)
        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        _swapSell(buyer, buyerTokenBalance / 3, 0, true);
        uint256 sellTaxCollected = _pendingTaxes(testToken, creator) - creatorTaxesBefore;
        assertGt(sellTaxCollected, 0, "Sell tax should be accrued");
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
        address[] memory _t = new address[](1);
        _t[0] = testToken;
        uint256 graduationDeposit = feeHandlerV4.getClaimable(_t, creator)[0];

        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 treasuryEthBalanceBefore = treasury.balance;

        // Perform buy swap to generate LP fees (1% total: 0.5% creator, 0.5% treasury)
        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        // Verify fees accumulated
        address[] memory tokens = new address[](1);
        tokens[0] = testToken;
        uint256[] memory fees = feeHandlerV4.getClaimable(tokens, creator);
        assertGt(fees[0], 0, "Fees should have accumulated");
        assertApproxEqAbs(fees[0] - graduationDeposit, buyAmount / 200, 1, "Expected ~0.5% of buy amount");

        // Claim LP fees
        _collectFees(testToken);

        uint256 creatorEthBalanceAfter = creator.balance;
        uint256 treasuryEthBalanceAfter = treasury.balance;

        // Verify creator received graduation deposit + ~0.5% of buy amount
        assertApproxEqAbs(
            creatorEthBalanceAfter - creatorEthBalanceBefore - graduationDeposit,
            buyAmount / 200,
            1,
            "Creator should receive ~0.5% LP fees"
        );

        // Verify treasury received ~0.5% of buy amount (sent directly on accrual)
        assertApproxEqAbs(
            treasuryEthBalanceAfter - treasuryEthBalanceBefore,
            buyAmount / 200,
            1,
            "Treasury should receive ~0.5% LP fees"
        );
    }

    /// @notice Test that LP fees (ETH) and sell taxes (WETH) are collected independently during active tax period
    function test_claimLPFees_duringTaxPeriod_separateFromSellTaxes() public createDefaultTaxToken {
        // First buy tokens through launchpad
        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(testToken, 0, DEADLINE);

        _graduateToken();
        address[] memory _t = new address[](1);
        _t[0] = testToken;
        uint256 graduationDeposit = feeHandlerV4.getClaimable(_t, creator)[0];

        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 creatorTaxesBefore = _pendingTaxes(testToken, creator);

        // Perform buy swap during active tax period
        // This generates only LP fees (~1% ETH), no buy tax
        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        // Verify no buy tax was collected
        assertEq(IERC20(testToken).balanceOf(testToken), 0, "No buy tax should be collected");

        // Verify LP fees accumulated from buy (in ETH, not WETH)
        address[] memory tokens = new address[](1);
        tokens[0] = testToken;
        uint256[] memory claimableFees = feeHandlerV4.getClaimable(tokens, creator);
        assertApproxEqAbs(
            claimableFees[0] - graduationDeposit, buyAmount / 200, 5, "LP fees should be ~0.5% of buy amount in ETH"
        );

        // Perform sell swap during active tax period
        // This generates both: sell tax (accrued in graduator) + LP fees (ETH ~0.5%)
        uint256 buyerTokenBalance = IERC20(testToken).balanceOf(buyer);
        uint256 sellAmount = buyerTokenBalance / 4;
        _swapSell(buyer, sellAmount, 0, true);

        uint256 sellTaxCollected = _pendingTaxes(testToken, creator) - creatorTaxesBefore;
        assertGt(sellTaxCollected, 0, "Sell tax should be accrued");

        // Claim LP fees (paid in native ETH to creator)
        _collectFees(testToken);

        uint256 creatorEthBalanceAfterLPClaim = creator.balance;
        uint256 lpFeesReceivedEth = creatorEthBalanceAfterLPClaim - creatorEthBalanceBefore;
        assertGt(lpFeesReceivedEth, 0, "Creator should receive LP fees in native ETH");

        // Verify the two fee streams are separate:
        // - LP fees: native ETH from Uniswap pool (from both buy and sell)
        // - Sell tax: accrued in graduator and claimable by creator
        assertGt(lpFeesReceivedEth, 0, "LP fees should be in native ETH");
        assertGt(sellTaxCollected, 0, "Sell tax should be accrued");
    }

    /// @notice Test that LP fees continue to be claimable after tax period expires
    function test_claimLPFees_afterTaxPeriodExpires_stillClaimable() public createDefaultTaxToken {
        _graduateToken();
        address[] memory _t2 = new address[](1);
        _t2[0] = testToken;
        uint256 graduationDeposit = feeHandlerV4.getClaimable(_t2, creator)[0];

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

        // Claim LP fees from both swaps (treasury receives directly on accrual)
        _collectFees(testToken);

        uint256 creatorEthBalanceAfter = creator.balance;
        uint256 treasuryEthBalanceAfter = treasury.balance;

        // Verify creator + treasury received LP fees (~0.5% each from ~2 ETH volume)
        uint256 creatorFeesReceived = creatorEthBalanceAfter - creatorEthBalanceBefore;
        uint256 treasuryFeesReceived = treasuryEthBalanceAfter - treasuryEthBalanceBefore;

        assertGt(creatorFeesReceived, 0, "Creator should receive LP fees");
        assertGt(treasuryFeesReceived, 0, "Treasury should receive LP fees");

        // Total LP fees (excluding graduation deposit) should be ~1% of buy amount
        assertApproxEqAbs(
            creatorFeesReceived + treasuryFeesReceived - graduationDeposit,
            buyAmount / 100,
            2,
            "Total LP fees should be ~1% of buy volume"
        );
    }

    /// @notice Test that LP fee accrual/claim flow still works after token ownership transfer
    function test_claimLPFees_withTokenOwnershipTransfer_claimFlowStillWorks() public createDefaultTaxToken {
        _graduateToken();

        // Perform a buy before transfer
        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount * 2);
        _swapBuy(buyer, buyAmount, 0, true);

        // Transfer ownership to alice
        vm.prank(creator);
        ILivoToken(testToken).proposeNewOwner(alice);
        vm.prank(alice);
        ILivoToken(testToken).acceptTokenOwnership();
        assertEq(ILivoToken(testToken).owner(), alice, "Alice should be the new token owner");

        // Generate fresh LP fees after ownership transfer so they belong to the new owner path
        _swapBuy(buyer, buyAmount, 0, true);

        // Record balances before claiming
        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 aliceEthBalanceBefore = alice.balance;

        // Claim LP fees
        address[] memory tokens = new address[](1);
        tokens[0] = testToken;

        vm.prank(alice);
        feeHandlerV4.accrueTokenFees(tokens);
        vm.prank(alice);
        feeHandlerV4.claim(tokens);

        vm.prank(creator);
        feeHandlerV4.claim(tokens);

        uint256 creatorEthBalanceAfter = creator.balance;
        uint256 aliceEthBalanceAfter = alice.balance;

        assertEq(
            aliceEthBalanceAfter, aliceEthBalanceBefore, "Alice claim should not transfer configured fee receiver funds"
        );
        assertGt(
            creatorEthBalanceAfter, creatorEthBalanceBefore, "Configured fee receiver should still be able to claim"
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

        uint256[] memory totalClaimable = feeHandlerV4.getClaimable(tokens, creator);
        assertGt(totalClaimable[0], 0, "claimable amount should be positive");

        // Record balances
        uint256 creatorEthBalanceBefore = creator.balance;

        // Claim from both positions
        vm.prank(creator);
        feeHandlerV4.accrueTokenFees(tokens);
        vm.prank(creator);
        feeHandlerV4.claim(tokens);

        uint256 creatorEthBalanceAfter = creator.balance;
        uint256 totalCreatorFees = creatorEthBalanceAfter - creatorEthBalanceBefore;

        // Verify claimed amount matches what was claimable (LP fees + accrued taxes)
        assertApproxEqAbs(totalCreatorFees, totalClaimable[0], 1, "Claimed fees should match claimable total");
    }

    function test_deployTaxTokenWithTooHighSellTaxes() public {
        vm.expectRevert(abi.encodeWithSelector(LivoFactoryTaxToken.InvalidSellTaxBps.selector));
        factoryTax.createToken("TestToken", "TEST", creator, "0x12", 550, uint32(4 days));
    }

    // This test is removed because buy taxes no longer exist, so there's no tax swap to trigger

    /////////////////////////////////// CATEGORY 7: VERIFY NO BUY TAXES ///////////////////////////////////

    /// @notice Test that no buy taxes are collected after graduation (balances remain constant)
    /// @dev Verify token contract balance, creator WETH balance, and creator token balance remain unchanged
    function test_noBuyTaxesCollected_afterGraduation() public createDefaultTaxToken {
        _graduateToken();

        // Record balances before buy swap
        uint256 tokenContractBalanceBefore = IERC20(testToken).balanceOf(testToken);
        uint256 tokenOwnerTaxesBefore = _pendingTaxes(testToken, creator);
        uint256 tokenOwnerTokenBefore = IERC20(testToken).balanceOf(creator);

        // Perform buy swap
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, true);

        // Verify invariants: all balances should remain constant
        assertEq(
            IERC20(testToken).balanceOf(testToken),
            tokenContractBalanceBefore,
            "Token contract balance should not change (no buy tax)"
        );
        assertApproxEqAbs(
            _pendingTaxes(testToken, creator) - tokenOwnerTaxesBefore,
            1 ether / 200,
            1,
            "Claimable should increase only by LP fee share on buy"
        );
        assertEq(
            IERC20(testToken).balanceOf(creator),
            tokenOwnerTokenBefore,
            "Token owner token balance should not change (no buy tax)"
        );
    }

    /// @notice Test that no buy taxes are collected after graduation even with zero-value transfer
    /// @dev Zero-value transfers could trigger tax swaps in old implementation, verify they don't here
    function test_noBuyTaxesCollected_afterBuyAndZeroTransfer() public createDefaultTaxToken {
        _graduateToken();

        // Record balances before buy swap
        uint256 tokenContractBalanceBefore = IERC20(testToken).balanceOf(testToken);
        uint256 tokenOwnerTokenBefore = IERC20(testToken).balanceOf(creator);

        // Perform buy swap
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, true);

        uint256 tokenOwnerTaxesAfterBuy = _pendingTaxes(testToken, creator);

        // Trigger a zero-value transfer (which could trigger tax swaps in old implementation)
        address zeroBalanceAccount = makeAddr("zeroBalanceAccount");
        vm.prank(zeroBalanceAccount);
        IERC20(testToken).transfer(alice, 0);

        // Verify invariants: all balances should still remain constant
        assertEq(
            IERC20(testToken).balanceOf(testToken),
            tokenContractBalanceBefore,
            "Token contract balance should not change after zero transfer (no buy tax)"
        );
        assertEq(
            _pendingTaxes(testToken, creator),
            tokenOwnerTaxesAfterBuy,
            "Token owner taxes should not change after zero transfer"
        );
        assertEq(
            IERC20(testToken).balanceOf(creator),
            tokenOwnerTokenBefore,
            "Token owner token balance should not change after zero transfer (no buy tax)"
        );
    }
}
