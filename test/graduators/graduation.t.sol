// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {
    LaunchpadBaseTests,
    LaunchpadBaseTestsWithUniv2Graduator,
    LaunchpadBaseTestsWithUniv4Graduator
} from "test/launchpad/base.t.sol";
import {RealmLaunchpad} from "src/RealmLaunchpad.sol";
import {IRealmBondingCurve} from "src/interfaces/IRealmBondingCurve.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TokenState} from "src/types/tokenData.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IWETH} from "src/interfaces/IWETH.sol";
import {IRealmClaims} from "src/interfaces/IRealmClaims.sol";

/// @dev These tests should should pass regardless of the of graduator, so we test it with both
abstract contract ProtocolAgnosticGraduationTests is LaunchpadBaseTests {
    /// @dev Returns the fee handler for the current test token
    function _tokenFeeHandler() internal view virtual returns (IRealmClaims);

    /// @dev Creator graduation compensation for the active graduator. Both V2 and V4 = 0.125 ether (50/50 split).
    function _creatorCompensation() internal pure virtual returns (uint256) {
        return CREATOR_GRADUATION_COMPENSATION;
    }

    /// @dev Triggerer compensation taken from the graduation fee. V2 = 0.005 ether, V4 = 0.
    function _triggererCompensation() internal pure virtual returns (uint256) {
        return 0;
    }

    //////////////////////////////////// modifiers and utilities ///////////////////////////////

    /// @notice Test that graduated boolean turns true in launchpad
    function test_graduatedBooleanTurnsTrueInLaunchpad() public createTestToken {
        TokenState memory stateBefore = launchpad.getTokenState(testToken);
        assertFalse(stateBefore.graduated, "Token should not be graduated initially");

        _graduateToken();

        TokenState memory stateAfter = launchpad.getTokenState(testToken);
        assertTrue(stateAfter.graduated, "Token should be graduated in launchpad");
    }

    /// @notice Test that graduated boolean turns true in RealmToken
    function test_graduatedBooleanTurnsTrueInRealmToken() public createTestToken {
        RealmToken token = RealmToken(testToken);
        assertFalse(token.graduated(), "Token should not be graduated initially");

        _graduateToken();

        assertTrue(token.graduated(), "Token should be graduated in RealmToken contract");
    }

    /// @notice Test that tokens cannot be bought from the launchpad after graduation
    function test_tokensCannotBeBoughtFromLaunchpadAfterGraduation() public createTestToken {
        _graduateToken();

        deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(RealmLaunchpad.AlreadyGraduated.selector));
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
    }

    /// @notice creator gets the CREATOR_GRADUATION_COMPENSATION at graduation
    function test_creatorGetsGraduationCompensation() public virtual createTestToken {
        IRealmClaims tokenFeeHandler = _tokenFeeHandler();

        address[] memory _tokens = new address[](1);
        _tokens[0] = testToken;
        uint256 claimableBefore = tokenFeeHandler.getClaimable(_tokens, creator)[0];

        // The graduating buy also pays an LP fee; the creator's share of it accrues to the same
        // claimable bucket as the graduation compensation.
        uint256 missingForGraduation =
            _increaseWithFees(GRADUATION_THRESHOLD - launchpad.getTokenState(testToken).ethCollected);
        uint256 tradingFee = (missingForGraduation * BASE_BUY_FEE_BPS) / 10000;
        uint256 creatorTradingShare = tradingFee - _treasuryShareOf(tradingFee);

        _graduateToken();

        uint256 claimableAfter = tokenFeeHandler.getClaimable(_tokens, creator)[0];
        assertEq(
            claimableAfter,
            claimableBefore + _creatorCompensation() + creatorTradingShare,
            "Creator claimable should include graduation compensation"
        );
    }

    /// @notice Test that tokens cannot be sold to the launchpad after graduation
    function test_tokensCannotBeSoldToLaunchpadAfterGraduation() public createTestToken {
        _graduateToken();

        // Get some tokens from the creator to test selling
        uint256 creatorBalance = IERC20(testToken).balanceOf(creator);
        uint256 transferAmount = creatorBalance / 2;
        vm.prank(creator);
        IERC20(testToken).transfer(buyer, transferAmount);

        uint256 tokenBalance = IERC20(testToken).balanceOf(buyer);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(RealmLaunchpad.AlreadyGraduated.selector));
        launchpad.sellExactTokens(testToken, tokenBalance, 0, DEADLINE);
    }

    /// @notice Test that token balance of the contract after graduation is zero
    function test_tokenBalanceOfContractAfterGraduationIsZero() public createTestToken {
        uint256 balanceBefore = IERC20(testToken).balanceOf(address(launchpad));
        assertTrue(balanceBefore > 0, "Launchpad should have tokens before graduation");

        _graduateToken();

        uint256 balanceAfter = IERC20(testToken).balanceOf(address(launchpad));
        assertEq(balanceAfter, 0, "Launchpad should have zero tokens after graduation");
    }

    /// @notice test exact graduation price
    function test_exactGraduationPrice() public createTestToken {
        uint256 ethReserves = launchpad.getTokenState(testToken).ethCollected;
        uint256 missingForGraduation = _increaseWithFees(GRADUATION_THRESHOLD - ethReserves);
        // This buy should get right below graduation by one wei
        _launchpadBuy(testToken, missingForGraduation - 1);
        assertFalse(launchpad.getTokenState(testToken).graduated, "Token should not be graduated after this buy");

        uint256 tokenBalanceBefore = IERC20(testToken).balanceOf(buyer);

        // now a small buy makes the purchase, and we assert against the expected graduation price
        uint256 ethValue = 0.0001 ether;
        _launchpadBuy(testToken, ethValue);

        uint256 tokensReceived = IERC20(testToken).balanceOf(buyer) - tokenBalanceBefore;

        // but the buyer spent the full ethValue
        uint256 expectedPriceAtGraduation = (1e18 * ethValue) / tokensReceived;
        console.log("expectedPriceAtGraduation (1e18 ETH / token)", expectedPriceAtGraduation);

        assertEq(expectedPriceAtGraduation, GRADUATION_PRICE, "missmatch with expected graduation price");
    }

    /// @notice Test that at graduation the team collects the graduation fee in eth (sent directly to treasury)
    function test_teamCollectsGraduationFeeInEthAtGraduation() public virtual createTestToken {
        uint256 treasuryBalanceBefore = treasury.balance;

        // Calculate the ETH that will be spent to graduate (for trading fee calculation)
        uint256 ethReserves = launchpad.getTokenState(testToken).ethCollected;
        uint256 missingForGraduation = _increaseWithFees(GRADUATION_THRESHOLD - ethReserves);
        // Treasury only collects its share of the trading fee; the creator gets the remainder.
        uint256 expectedTreasuryTradingFee = _treasuryShareOf((missingForGraduation * BASE_BUY_FEE_BPS) / 10000);

        _graduateToken();

        // this will include both trading fees and graduation fees
        uint256 treasuryBalanceAfter = treasury.balance;
        uint256 feeCollected = treasuryBalanceAfter - treasuryBalanceBefore;

        assertEq(
            feeCollected,
            (GRADUATION_FEE - _creatorCompensation() - _triggererCompensation()) + expectedTreasuryTradingFee,
            "Treasury should receive graduation fee share plus trading fees"
        );
    }

    /// @notice Test that a buy exceeding the graduation + excess limit reverts
    function test_buyExceedingGraduationPlusExcessLimitReverts() public createTestToken {
        vm.deal(buyer, 2 * GRADUATION_THRESHOLD);

        uint256 exactLimitBeforeFees = GRADUATION_THRESHOLD + MAX_THRESHOLD_EXCESS;

        // This purchase should be fine, hitting right below graduation
        uint256 value = exactLimitBeforeFees - MAX_THRESHOLD_EXCESS - 0.000001 ether;
        vm.startPrank(buyer);
        launchpad.buyTokensWithExactEth{value: value}(testToken, 0, DEADLINE);
        // make sure the token hasn't graduated
        assertFalse(launchpad.getTokenState(testToken).graduated, "Token should not be graduated yet");

        // actual reserves after applying fees
        uint256 effectiveReserves = (value * (10000 - BASE_BUY_FEE_BPS)) / 10000;
        uint256 triggerOfExcess = GRADUATION_THRESHOLD + MAX_THRESHOLD_EXCESS - effectiveReserves;
        // now the next purchase needs to take the reserves beyond GRADUATION_THRESHOLD + MAX_THRESHOLD_EXCESS
        vm.expectRevert(abi.encodeWithSelector(IRealmBondingCurve.MaxEthReservesExceeded.selector));
        launchpad.buyTokensWithExactEth{value: triggerOfExcess + 0.01 ether}(testToken, 0, DEADLINE);
    }

    /// @notice Test graduation happens with a small excess
    function test_graduationWorksWithSmallExcess() public createTestToken {
        uint256 graduationThreshold = GRADUATION_THRESHOLD;
        // Buy a bit more than graduation threshold but within allowed excess
        uint256 smallExcessAmount = graduationThreshold + 0.01 ether;
        uint256 ethAmountWithSmallExcess = _increaseWithFees(smallExcessAmount);

        vm.deal(buyer, ethAmountWithSmallExcess);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmountWithSmallExcess}(testToken, 0, DEADLINE);

        TokenState memory state = launchpad.getTokenState(testToken);
        assertTrue(state.graduated, "Token should be graduated");
    }

    /// @notice Test that graduation does not transfer creator tokens to creator address
    function test_graduationTransfersCreatorTokensToCreatorAddress() public createTestToken {
        uint256 creatorBalanceBefore = IERC20(testToken).balanceOf(creator);
        assertEq(creatorBalanceBefore, 0, "Creator should have no tokens initially");

        _graduateToken();

        uint256 creatorBalanceAfter = IERC20(testToken).balanceOf(creator);
        assertEq(creatorBalanceAfter, 0, "Creator should not receive reserved supply");
    }

    /// @notice Test that circulating token supply updated after graduation to be all except the tokens sent to liquidity
    function test_releasedSupplyUpdatedAfterGraduation() public createTestToken {
        TokenState memory stateBefore = launchpad.getTokenState(testToken);
        uint256 circulatingBefore = stateBefore.releasedSupply;
        assertEq(circulatingBefore, 0, "Initially no circulating supply");

        _graduateToken();

        TokenState memory stateAfter = launchpad.getTokenState(testToken);
        uint256 circulatingAfter = stateAfter.releasedSupply;

        assertGt(circulatingAfter, circulatingBefore, "Circulating supply should increase after graduation");
        assertEq(circulatingAfter, TOTAL_SUPPLY, "Circulating supply should be total supply minus reserved supplies");
    }

    /// @notice Test that token eth reserves are reset to 0 after graduation
    function test_ethReservesResetAfterGraduation() public createTestToken {
        assertEq(launchpad.getTokenState(testToken).ethCollected, 0, "Initial ETH reserves should be zero");

        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: GRADUATION_THRESHOLD - 1 ether}(testToken, 0, DEADLINE);
        assertFalse(launchpad.getTokenState(testToken).graduated, "Token should not be graduated");
        assertGt(
            launchpad.getTokenState(testToken).ethCollected, 0, "ETH reserves should be greater than 0 after a purchase"
        );

        _graduateToken();
        assertTrue(launchpad.getTokenState(testToken).graduated, "Token should be graduated");
        assertEq(launchpad.getTokenState(testToken).ethCollected, 0, "ETH reserves should be reset to 0 at graduation");
    }

    /// @notice Test that eth treasury balance change at graduation is the graduation fee or larger (including the trading fee)
    function test_treasuryEthBalanceChangeAtGraduationAccountsForGraduationFee() public virtual createTestToken {
        vm.deal(buyer, 100 ether);

        uint256 treasuryEthBefore = treasury.balance;

        // buy but not graduate
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: GRADUATION_THRESHOLD - 1 ether}(testToken, 0, DEADLINE);
        assertFalse(launchpad.getTokenState(testToken).graduated, "Token should not be graduated yet");
        uint256 expectedTradingFees = _treasuryShareOf(((GRADUATION_THRESHOLD - 1 ether) * BASE_BUY_FEE_BPS) / 10000);
        assertEq(treasury.balance - treasuryEthBefore, expectedTradingFees, "Treasury should collect expected fees");

        uint256 treasuryBalanceBeforeGraduation = treasury.balance;

        // this graduates the token
        uint256 purchaseValue = 1 ether + MAX_THRESHOLD_EXCESS;
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: purchaseValue}(testToken, 0, DEADLINE);
        assertTrue(launchpad.getTokenState(testToken).graduated, "Token should be graduated");

        // Treasury only collects its share of the trading fee on the graduating buy.
        uint256 tradingFee = _treasuryShareOf((BASE_BUY_FEE_BPS * purchaseValue) / 10000);

        uint256 totalTreasuryChange = treasury.balance - treasuryBalanceBeforeGraduation;

        assertEq(
            totalTreasuryChange,
            tradingFee + (GRADUATION_FEE - _creatorCompensation() - _triggererCompensation()),
            "Treasury should collect its graduation fee share (plus trading fee)"
        );
    }

    /// @notice Test that at graduation the token only uses eth allocated to its reserves
    function test_graduationUsesOnlyAllocatedEthReserves() public createTestToken {
        vm.deal(buyer, 100 ether);
        uint256 initialLaunchpadBalance = address(launchpad).balance;

        // buy but not graduate
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: GRADUATION_THRESHOLD - 1 ether}(testToken, 0, DEADLINE);
        assertFalse(launchpad.getTokenState(testToken).graduated, "Token should not be graduated yet");

        uint256 launchpadEthAfterFirstBuy = address(launchpad).balance - initialLaunchpadBalance;
        uint256 etherReservesPreGraduation = launchpad.getTokenState(testToken).ethCollected;
        assertEq(launchpadEthAfterFirstBuy, etherReservesPreGraduation, "balance missmatch (there is only one token)");

        // the eth from this purchase would go straight into liquidity
        uint256 purchaseValue = 1 ether + MAX_THRESHOLD_EXCESS;
        vm.prank(seller);
        launchpad.buyTokensWithExactEth{value: purchaseValue}(testToken, 0, DEADLINE);
        assertTrue(launchpad.getTokenState(testToken).graduated, "Token should be graduated");

        uint256 launchpadEthAfterGraduation = address(launchpad).balance - initialLaunchpadBalance;
        assertEq(launchpadEthAfterGraduation, 0, "launchpad should hold no ETH after graduation (single token)");
    }

    /// @notice Test that launchpad eth balance change at graduation is the exact reserves pre graduation
    function test_graduationReservesConservationOfFunds() public createTestToken {
        vm.deal(buyer, 100 ether);

        // buy but not graduate
        vm.prank(buyer);
        // value sent: 6956000000000052224
        launchpad.buyTokensWithExactEth{value: GRADUATION_THRESHOLD - 1 ether}(testToken, 0, DEADLINE);
        assertFalse(launchpad.getTokenState(testToken).graduated, "Token should not be graduated yet");
        // collect the eth trading fees to have a clean comparison

        uint256 etherReservesPreGraduation = launchpad.getTokenState(testToken).ethCollected; // 6886440000000051702
        uint256 launchpadEthBefore = address(launchpad).balance;

        // the eth from this purchase would go straight into liquidity
        uint256 purchaseValue = 1 ether + MAX_THRESHOLD_EXCESS;
        vm.prank(seller);
        launchpad.buyTokensWithExactEth{value: purchaseValue}(testToken, 0, DEADLINE);
        assertTrue(launchpad.getTokenState(testToken).graduated, "Token should be graduated");

        uint256 launchpadEthAfter = address(launchpad).balance;

        // Trading fees go directly to treasury now, so launchpad only holds reserves.
        // After graduation of a single token, launchpad should hold 0.
        assertEq(launchpadEthAfter, 0, "launchpad should hold no ETH after single token graduation");

        // The launchpad balance decrease equals the pre-graduation reserves
        assertEq(
            launchpadEthBefore - launchpadEthAfter,
            etherReservesPreGraduation,
            "eth balance change should equal pre-graduation reserves"
        );
    }
}

/// @dev run all the tests in ProtocolAgnosticGraduationTests, with Uniswap V2 graduator
contract UniswapV2AgnosticGraduationTests is ProtocolAgnosticGraduationTests, LaunchpadBaseTestsWithUniv2Graduator {
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator) {
        super.setUp();
    }

    /// @dev V2 tokens share the same fee handler as V4
    function _tokenFeeHandler() internal view override returns (IRealmClaims) {
        return IRealmClaims(IRealmToken(testToken).feeHandler());
    }

    /// @dev V2 graduator splits the graduation fee 50/50 between treasury and creator
    function _creatorCompensation() internal pure override returns (uint256) {
        return GRADUATION_FEE / 2;
    }

    /// @dev V2 graduator pays out 0.005 ether to the graduation triggerer (`tx.origin`)
    function _triggererCompensation() internal pure override returns (uint256) {
        return TRIGGERER_GRADUATION_COMPENSATION;
    }
}

/// @dev run all the tests in ProtocolAgnosticGraduationTests, with Uniswap V4 graduator
contract UniswapV4AgnosticGraduationTests is ProtocolAgnosticGraduationTests, LaunchpadBaseTestsWithUniv4Graduator {
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv4Graduator) {
        super.setUp();
    }

    function _tokenFeeHandler() internal view override returns (IRealmClaims) {
        return IRealmClaims(IRealmToken(testToken).feeHandler());
    }
}
