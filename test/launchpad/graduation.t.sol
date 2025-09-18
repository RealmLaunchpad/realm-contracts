// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {LaunchpadBaseTest} from "./base.t.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoToken} from "src/LivoToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TokenState} from "src/types/tokenData.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IWETH} from "src/interfaces/IWETH.sol";

/// @dev These tests should be agnostic of the type of graduator.
contract BaseAgnosticGraduationTests is LaunchpadBaseTest {
    uint256 constant DEADLINE = type(uint256).max;
    uint256 constant MAX_THRESHOLD_EXCEESS = 0.5 ether;
    address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    function setUp() public override {
        super.setUp();
    }

    //////////////////////////////////// modifiers and utilities ///////////////////////////////

    modifier createTestTokenWithPair() {
        vm.prank(creator);
        testToken = launchpad.createToken(
            "TestToken", "TEST", "ipfs://test-metadata", address(bondingCurve), address(graduator)
        );
        _;
    }

    function _graduateToken() internal {
        uint256 graduationThreshold = BASE_GRADUATION_THRESHOLD;
        uint256 ethAmountToGraduate = (graduationThreshold * 10000) / (10000 - BASE_BUY_FEE_BPS);

        vm.deal(buyer, ethAmountToGraduate + 1 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmountToGraduate}(testToken, 0, DEADLINE);
    }
}

contract ProtocolAgnosticGraduationTests is BaseAgnosticGraduationTests {
    /// @notice Test that graduated boolean turns true in launchpad
    function test_graduatedBooleanTurnsTrueInLaunchpad() public createTestTokenWithPair {
        TokenState memory stateBefore = launchpad.getTokenState(testToken);
        assertFalse(stateBefore.graduated, "Token should not be graduated initially");

        _graduateToken();

        TokenState memory stateAfter = launchpad.getTokenState(testToken);
        assertTrue(stateAfter.graduated, "Token should be graduated in launchpad");
    }

    /// @notice Test that graduated boolean turns true in LivoToken
    function test_graduatedBooleanTurnsTrueInLivoToken() public createTestTokenWithPair {
        LivoToken token = LivoToken(testToken);
        assertFalse(token.graduated(), "Token should not be graduated initially");

        _graduateToken();

        assertTrue(token.graduated(), "Token should be graduated in LivoToken contract");
    }

    /// @notice Test that tokens cannot be bought from the launchpad after graduation
    function test_tokensCannotBeBoughtFromLaunchpadAfterGraduation() public createTestTokenWithPair {
        _graduateToken();

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.AlreadyGraduated.selector));
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
    }

    /// @notice Test that tokens cannot be sold to the launchpad after graduation
    function test_tokensCannotBeSoldToLaunchpadAfterGraduation() public createTestTokenWithPair {
        _graduateToken();

        // Get some tokens from the creator to test selling
        uint256 creatorBalance = IERC20(testToken).balanceOf(creator);
        uint256 transferAmount = creatorBalance / 2;
        vm.prank(creator);
        IERC20(testToken).transfer(buyer, transferAmount);

        uint256 tokenBalance = IERC20(testToken).balanceOf(buyer);

        vm.prank(buyer);
        IERC20(testToken).approve(address(launchpad), tokenBalance);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.AlreadyGraduated.selector));
        launchpad.sellExactTokens(testToken, tokenBalance, 0, DEADLINE);
    }

    /// @notice Test that token balance of the contract after graduation is zero
    function test_tokenBalanceOfContractAfterGraduationIsZero() public createTestTokenWithPair {
        uint256 balanceBefore = IERC20(testToken).balanceOf(address(launchpad));
        assertTrue(balanceBefore > 0, "Launchpad should have tokens before graduation");

        _graduateToken();

        uint256 balanceAfter = IERC20(testToken).balanceOf(address(launchpad));
        assertEq(balanceAfter, 0, "Launchpad should have zero tokens after graduation");
    }

    /// @notice Test that at graduation the team collects the graduation fee in eth
    function test_teamCollectsGraduationFeeInEthAtGraduation() public createTestTokenWithPair {
        uint256 treasuryBalanceBefore = launchpad.treasuryEthFeesCollected();

        _graduateToken();

        uint256 treasuryBalanceAfter = launchpad.treasuryEthFeesCollected();
        uint256 feeCollected = treasuryBalanceAfter - treasuryBalanceBefore;

        assertGe(feeCollected, BASE_GRADUATION_FEE, "Graduation fee should be collected");
    }

    /// @notice Test that a buy exceeding the graduation + excess limit reverts
    function test_buyExceedingGraduationPlusExcessLimitReverts() public createTestTokenWithPair {
        vm.deal(buyer, 2 * BASE_GRADUATION_THRESHOLD);

        uint256 exactLimitBeforeFees = BASE_GRADUATION_THRESHOLD + MAX_THRESHOLD_EXCEESS;

        // This purchase should be fine, hitting right below graduation
        uint256 value = exactLimitBeforeFees - MAX_THRESHOLD_EXCEESS - 0.000001 ether;
        vm.startPrank(buyer);
        launchpad.buyTokensWithExactEth{value: value}(testToken, 0, DEADLINE);
        // make sure the token hasn't graduated
        assertFalse(launchpad.getTokenState(testToken).graduated, "Token should not be graduated yet");

        // actual reserves after applying fees
        uint256 effectiveReserves = (value * (10000 - BASE_BUY_FEE_BPS)) / 10000;
        uint256 triggerOfExcess = BASE_GRADUATION_THRESHOLD + MAX_THRESHOLD_EXCEESS - effectiveReserves;
        // now the next purchase needs to take the reserves beyond BASE_GRADUATION_THRESHOLD + MAX_THRESHOLD_EXCEESS
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.PurchaseExceedsLimitPostGraduation.selector));
        launchpad.buyTokensWithExactEth{value: triggerOfExcess + 0.01 ether}(testToken, 0, DEADLINE);
    }

    /// @notice Test that difference between launchpad price and uniswap price is not more than 5% if last purchase reaches the excess cap

    /// @notice Test graduation happens with a small excess
    function test_graduationWorksWithSmallExcess() public createTestTokenWithPair {
        uint256 graduationThreshold = BASE_GRADUATION_THRESHOLD;
        // Buy a bit more than graduation threshold but within allowed excess
        uint256 smallExcessAmount = graduationThreshold + 0.1 ether;
        uint256 ethAmountWithSmallExcess = (smallExcessAmount * 10000) / (10000 - BASE_BUY_FEE_BPS);

        vm.deal(buyer, ethAmountWithSmallExcess);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmountWithSmallExcess}(testToken, 0, DEADLINE);

        TokenState memory state = launchpad.getTokenState(testToken);
        assertTrue(state.graduated, "Token should be graduated");
    }

    /// @notice Test that graduation transfers creator tokens to creator address
    function test_graduationTransfersCreatorTokensToCreatorAddress() public createTestTokenWithPair {
        uint256 creatorBalanceBefore = IERC20(testToken).balanceOf(creator);
        assertEq(creatorBalanceBefore, 0, "Creator should have no tokens initially");

        _graduateToken();

        uint256 creatorBalanceAfter = IERC20(testToken).balanceOf(creator);
        assertEq(creatorBalanceAfter, CREATOR_RESERVED_SUPPLY, "Creator should receive reserved supply");
    }

    /// @notice Test that circulating token supply updated after graduation to be all except the tokens sent to liquidity
    function test_releasedSupplyUpdatedAfterGraduation() public createTestTokenWithPair {
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
    function test_tokenEthReservesRemainAfterGraduation() public createTestTokenWithPair {
        TokenState memory stateBefore = launchpad.getTokenState(testToken);
        assertEq(stateBefore.ethCollected, 0, "Initial ETH reserves should be zero");

        _graduateToken();

        TokenState memory stateAfter = launchpad.getTokenState(testToken);
        assertEq(stateAfter.ethCollected, 0, "ETH reserves should be reset to 0 at graduation");
    }

    /// @notice Test that launchpad eth balance change at graduation is the exact reserves pre graduation
    function test_graduationConservationOfFunds() public createTestTokenWithPair {
        vm.deal(buyer, 100 ether);

        // buy but not graduate
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: BASE_GRADUATION_THRESHOLD - 1 ether}(testToken, 0, DEADLINE);
        assertFalse(launchpad.getTokenState(testToken).graduated, "Token should not be graduated yet");
        // collect the eth trading fees to have a clean comparison

        uint256 etherReservesPreGraduation = launchpad.getTokenState(testToken).ethCollected;
        uint256 launchpadEthBefore = address(launchpad).balance;
        uint256 treasuryBefore = launchpad.treasuryEthFeesCollected();
        uint256 purchaseValue = 1.5 ether;

        // the eth from this purchase would go straight into liquidity
        vm.prank(seller);
        launchpad.buyTokensWithExactEth{value: purchaseValue}(testToken, 0, DEADLINE);
        assertTrue(launchpad.getTokenState(testToken).graduated, "Token should be graduated");

        uint256 launchpadEthAfter = address(launchpad).balance;
        uint256 ethLaunchpadBalanceChange = launchpadEthBefore - launchpadEthAfter;
        uint256 treasuryAfter = launchpad.treasuryEthFeesCollected();
        uint256 treasuryChange = treasuryAfter - treasuryBefore;

        // launchpad balance change should be exactly the reserves pre graduation (minus the trading fee portion that went to treasury)
        // review these two assertions
        assertEq(
            ethLaunchpadBalanceChange + treasuryChange,
            etherReservesPreGraduation,
            "Launchpad balance change should equal reserves pre graduation"
        );
        assertEq(
            ethLaunchpadBalanceChange,
            etherReservesPreGraduation,
            "All ETH reserves of the token should be gone to liquidity"
        );
    }

    /// @notice Test that eth treasury balance change at graduation is the graduation fee or larger (including the trading fee)
    function test_treasuryEthBalanceChangeAtGraduationAccountsForGraduationFee() public createTestTokenWithPair {
        vm.deal(buyer, 100 ether);

        uint256 treasuryStartingBalance = launchpad.treasuryEthFeesCollected();

        // buy but not graduate
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: BASE_GRADUATION_THRESHOLD - 1 ether}(testToken, 0, DEADLINE);
        assertFalse(launchpad.getTokenState(testToken).graduated, "Token should not be graduated yet");
        uint256 expectedFees = ((BASE_GRADUATION_THRESHOLD - 1 ether) * BASE_BUY_FEE_BPS) / 10000;
        assertEq(
            launchpad.treasuryEthFeesCollected(),
            treasuryStartingBalance + expectedFees,
            "Treasury should collect expected fees"
        );

        uint256 treasuryFeesBeforeGraduation = launchpad.treasuryEthFeesCollected();
        uint256 etherReservesPreGraduation = launchpad.getTokenState(testToken).ethCollected;

        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1.5 ether}(testToken, 0, DEADLINE);
        assertTrue(launchpad.getTokenState(testToken).graduated, "Token should be graduated");

        uint256 launchpadEthAfter = address(launchpad).balance;
        uint256 treasuryFeesAfterGraduation = launchpad.treasuryEthFeesCollected();

        assertGe(
            treasuryFeesAfterGraduation - treasuryFeesBeforeGraduation,
            BASE_GRADUATION_FEE,
            "Treasury should collect graduation fee (plus trading fee)"
        );
    }
}
