// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {LivoToken} from "src/LivoToken.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TokenState} from "src/types/tokenData.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IUniversalRouter} from "src/interfaces/IUniswapV4UniversalRouter.sol";
import {LiquidityAmounts} from "lib/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {BaseUniswapV4GraduationTests} from "test/graduators/graduationUniv4.base.t.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

interface ILivoGraduatorWithFees is ILivoGraduator {
    function collectEthFees(address[] calldata tokens, uint256 positionIndex) external;
    function positionIds(address token, uint256 positionIndex) external view returns (uint256);
    function getClaimableFees(address[] calldata tokens, uint256 positionIndex)
        external
        view
        returns (uint256[] memory creatorFees);
    function sweep() external;
}

contract BaseUniswapV4FeesTests is BaseUniswapV4GraduationTests {
    ILivoGraduatorWithFees graduatorWithFees;

    address testToken1;
    address testToken2;

    function setUp() public override {
        super.setUp();

        graduatorWithFees = ILivoGraduatorWithFees(address(graduator));
        deal(buyer, 10 ether);
    }

    modifier createAndGraduateToken() {
        vm.prank(creator);
        // this graduator is not defined here in the base, so it will be address(0) unless inherited by LaunchpadBaseTestsWithUniv2Graduator or V4
        testToken = launchpad.createToken(
            "TestToken", "TEST", address(implementation), address(bondingCurve), address(graduator), "0x12"
        );

        _graduateToken();
        _;
    }

    modifier twoGraduatedTokensWithBuys(uint256 buyAmount) {
        vm.startPrank(creator);
        testToken1 = launchpad.createToken(
            "TestToken1", "TEST1", address(implementation), address(bondingCurve), address(graduator), "0x1a3a"
        );
        testToken2 = launchpad.createToken(
            "TestToken2", "TEST2", address(implementation), address(bondingCurve), address(graduator), "0x1a3a"
        );
        vm.stopPrank();

        // graduate token1 and token2
        uint256 buyAmount1 = _increaseWithFees(GRADUATION_THRESHOLD + MAX_THRESHOLD_EXCESS / 3);
        uint256 buyAmount2 = _increaseWithFees(GRADUATION_THRESHOLD + MAX_THRESHOLD_EXCESS / 2);
        vm.deal(buyer, 100 ether);
        vm.startPrank(buyer);
        launchpad.buyTokensWithExactEth{value: buyAmount1}(testToken1, 0, DEADLINE);
        launchpad.buyTokensWithExactEth{value: buyAmount2}(testToken2, 0, DEADLINE);

        assertTrue(launchpad.getTokenState(testToken1).graduated, "Token1 should be graduated");
        assertTrue(launchpad.getTokenState(testToken2).graduated, "Token2 should be graduated");

        // buy from token1 and token2 from uniswap
        _swap(buyer, testToken1, buyAmount, 1, true, true);
        _swap(buyer, testToken2, buyAmount, 1, true, true);
        vm.stopPrank();
        _;
    }

    function _collectFees(address token) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        graduatorWithFees.collectEthFees(tokens, 0);
    }
}

/// @notice Tests for Uniswap V4 graduator functionality
contract BaseUniswapV4ClaimFees is BaseUniswapV4FeesTests {
    function test_rightPositionIdAfterGraduation() public createAndGraduateToken {
        uint256 positionId = LivoGraduatorUniswapV4(payable(address(graduator))).positionIds(testToken, 0);

        assertEq(positionId, 62898, "wrong position id registered at graduation");
    }

    /// @notice test that the owner of the univ4 NFT position is the liquidity lock contract
    function test_liquidityNftOwnerAfterGraduation() public createAndGraduateToken {
        uint256 positionId = LivoGraduatorUniswapV4(payable(address(graduator))).positionIds(testToken, 0);

        assertEq(
            IERC721(positionManagerAddress).ownerOf(positionId),
            address(liquidityLock),
            "liquidity lock should own the position NFT"
        );
    }

    /// @notice test that in the liquidity lock, the graduator appears as the owner of the liquidity position
    function test_liquidityLock_ownerOfPositionIsGraduator() public createAndGraduateToken {
        uint256 positionId = LivoGraduatorUniswapV4(payable(address(graduator))).positionIds(testToken, 0);

        assertEq(
            liquidityLock.lockOwners(positionId),
            address(graduatorWithFees),
            "graduator should be the owner of the locked position"
        );
    }

    function test_claimFees_happyPath_ethBalanceIncrease() public createAndGraduateToken {
        deal(buyer, 10 ether);
        _swapBuy(buyer, 1 ether, 10e18, true);

        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 treasuryEthBalanceBefore = treasury.balance;

        _collectFees(testToken);
        graduatorWithFees.sweep();

        uint256 creatorEthBalanceAfter = creator.balance;
        uint256 treasuryEthBalanceAfter = treasury.balance;

        assertGt(creatorEthBalanceAfter, creatorEthBalanceBefore);
        assertGt(treasuryEthBalanceAfter, treasuryEthBalanceBefore);

        assertApproxEqAbs(
            creatorEthBalanceAfter - creatorEthBalanceBefore,
            (treasuryEthBalanceAfter - treasuryEthBalanceBefore),
            1,
            "creators and treasury should get approx equal fees"
        );
    }

    /// @notice test that the token balance of the graduator increases when claiming fees
    function test_claimFees_graduatorTokenBalanceIncrease() public createAndGraduateToken {
        deal(buyer, 10 ether);
        _swapSell(buyer, 10 ether, 10, true);

        uint256 tokenBalanceBefore = IERC20(testToken).balanceOf(address(graduatorWithFees));

        _collectFees(testToken);

        uint256 tokenBalanceAfter = IERC20(testToken).balanceOf(address(graduatorWithFees));

        assertGt(tokenBalanceAfter, tokenBalanceBefore, "graduator token balance should increase");
    }

    function test_claimFees_expectedCreatorFeesIncrease() public createAndGraduateToken {
        deal(buyer, 10 ether);
        uint256 buyAmount = 1 ether;
        _swapBuy(buyer, buyAmount, 10e18, true);

        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 treasuryEthBalanceBefore = treasury.balance;
        uint256 graduatorBalanceBefore = address(graduatorWithFees).balance;

        _collectFees(testToken);

        uint256 creatorEthBalanceAfter = creator.balance;
        uint256 treasuryEthBalanceAfter = treasury.balance;
        uint256 graduatorBalanceAfter = address(graduatorWithFees).balance;

        assertEq(treasuryEthBalanceAfter, treasuryEthBalanceBefore, "treasury eth balance should not change");

        uint256 creatorFees = creatorEthBalanceAfter - creatorEthBalanceBefore;
        uint256 treasuryFees = graduatorBalanceAfter - graduatorBalanceBefore;

        assertApproxEqAbs(creatorFees + treasuryFees, buyAmount / 100, 1, "total fees should be 1%");
    }

    function test_claimFees_expectedTreasuryFeesIncrease() public createAndGraduateToken {
        deal(buyer, 10 ether);
        uint256 buyAmount = 1 ether;
        _swapBuy(buyer, buyAmount, 10e18, true);

        uint256 treasuryEthBalanceBefore = treasury.balance;

        _collectFees(testToken);
        graduatorWithFees.sweep();

        uint256 treasuryEthBalanceAfter = treasury.balance;
        uint256 treasuryFees = treasuryEthBalanceAfter - treasuryEthBalanceBefore;

        assertApproxEqAbs(treasuryFees, buyAmount / 200, 1, "total fees should be 1% between treasury and creator");
    }

    /// @notice test that on buys, only eth fees are collected
    function test_claimFees_onBuys_onlyEthFees() public createAndGraduateToken {
        deal(buyer, 10 ether);
        _swapBuy(buyer, 1.5 ether, 10e18, true);

        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 tokenBalanceBefore = IERC20(testToken).balanceOf(address(graduatorWithFees));

        _collectFees(testToken);

        uint256 tokenBalanceAfter = IERC20(testToken).balanceOf(address(graduatorWithFees));

        assertEq(tokenBalanceAfter, tokenBalanceBefore, "token balance should not change on eth fees collection");
        assertGt(creator.balance, creatorEthBalanceBefore, "creator eth balance should increase");
    }

    /// @notice test that on sells, only token fees are collected
    function test_claimFees_onSells_noTokenFees() public createAndGraduateToken {
        _swapSell(buyer, 100000000e18, 0.1 ether, true);

        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 tokenBalanceBefore = IERC20(testToken).balanceOf(address(graduatorWithFees));
        uint256 poolManagerBalance = IERC20(testToken).balanceOf(address(poolManager));

        _collectFees(testToken);

        uint256 tokenBalanceAfter = IERC20(testToken).balanceOf(address(graduatorWithFees));
        uint256 poolManagerBalanceAfter = IERC20(testToken).balanceOf(address(poolManager));

        assertGt(
            IERC20(testToken).balanceOf(address(graduatorWithFees)), 0, "there should be some tokens in the graduator"
        );
        assertLt(poolManagerBalanceAfter, poolManagerBalance, "token fees should leave the token manager");
        assertGt(tokenBalanceAfter, tokenBalanceBefore, "Tokens should arrive to the graduator");
        assertEq(creator.balance, creatorEthBalanceBefore, "No fees should be collected now");
    }

    /// @notice test that any eth balance is not collected by the first call to claimFees
    function test_claimFees_noInitialEthBalance() public createAndGraduateToken {
        deal(buyer, 10 ether);
        _swapBuy(buyer, 1 ether, 10e18, true);

        // send some eth to the graduator
        vm.prank(buyer);
        payable(address(graduatorWithFees)).transfer(0.5 ether);

        uint256 graduatorEthBalanceBefore = address(graduatorWithFees).balance;
        assertEq(graduatorEthBalanceBefore, 0.5 ether, "graduator should have exactly 0.5 ether");

        _collectFees(testToken);
        // if there is no sweep, the treasury fees stay in the contract
        assertGt(
            address(graduatorWithFees).balance,
            graduatorEthBalanceBefore,
            "graduator should have more than 0.5 (the treasury fees)"
        );

        graduatorWithFees.sweep();

        assertEq(address(graduatorWithFees).balance, 0, "graduator eth balance should be 0 after sweep");
    }

    /// @notice test that a token creator can claim fees from mutliple tokens in one transaction
    function test_claimFees_multipleTokens() public twoGraduatedTokensWithBuys(1 ether) {
        // both should have accumulated fees
        address[] memory tokens = new address[](2);
        tokens[0] = testToken1;
        tokens[1] = testToken2;

        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 treasuryEthBalanceBefore = treasury.balance;

        graduatorWithFees.collectEthFees(tokens, 0);
        graduatorWithFees.sweep();

        uint256 creatorEthBalanceAfter = creator.balance;
        uint256 treasuryEthBalanceAfter = treasury.balance;
        assertGt(creatorEthBalanceAfter, creatorEthBalanceBefore, "creator eth balance should increase");
        assertGt(treasuryEthBalanceAfter, treasuryEthBalanceBefore, "treasury eth balance should increase");

        // 1% fees expected from each token (2 * 10-ether buys)
        uint256 expectedTotalFees = 2 * 1 ether / 100;

        assertApproxEqAbs(
            (creatorEthBalanceAfter - creatorEthBalanceBefore) + (treasuryEthBalanceAfter - treasuryEthBalanceBefore),
            expectedTotalFees,
            2,
            "total fees should be 1% of total buys"
        );
    }

    /// @notice test that including the same token twice in the claim array does not double count fees
    function test_claimFees_multipleTokens_withDuplicate() public twoGraduatedTokensWithBuys(1 ether) {
        // both should have accumulated fees
        address[] memory tokens = new address[](3);
        tokens[0] = testToken1;
        tokens[1] = testToken2;
        tokens[2] = testToken1; // duplicate
        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 treasuryEthBalanceBefore = treasury.balance;

        graduatorWithFees.collectEthFees(tokens, 0);
        graduatorWithFees.sweep();

        uint256 creatorEthBalanceAfter = creator.balance;
        uint256 treasuryEthBalanceAfter = treasury.balance;

        // 1% fees expected from each token (2 * 10-ether buys)
        uint256 expectedTotalFees = 2 * 1 ether / 100;

        assertApproxEqAbs(
            (creatorEthBalanceAfter - creatorEthBalanceBefore) + (treasuryEthBalanceAfter - treasuryEthBalanceBefore),
            expectedTotalFees,
            2,
            "total fees should be 1% of total buys"
        );
    }

    /// @notice test that a token creator can claim fees from mutliple tokens in one transaction
    function test_claimFees_multipleTokens_twoBuysBeforeSweep() public twoGraduatedTokensWithBuys(1 ether) {
        // both should have accumulated fees
        address[] memory tokens = new address[](2);
        tokens[0] = testToken1;
        tokens[1] = testToken2;

        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 treasuryEthBalanceBefore = treasury.balance;

        _swap(buyer, testToken1, 1 ether, 12342, true, true);
        _swap(buyer, testToken2, 1 ether, 12342, true, true);

        graduatorWithFees.collectEthFees(tokens, 0);

        _swap(buyer, testToken1, 2 ether, 12342, true, true);
        _swap(buyer, testToken2, 2 ether, 12342, true, true);

        graduatorWithFees.collectEthFees(tokens, 0);
        graduatorWithFees.sweep();

        uint256 creatorEarned = creator.balance - creatorEthBalanceBefore;
        uint256 treasuryEarned = treasury.balance - treasuryEthBalanceBefore;

        assertGt(creatorEarned, 0, "creator eth balance should increase");
        assertGt(treasuryEarned, 0, "treasury eth balance should increase");
        // 10 wei error allowed here
        assertApproxEqAbs(creatorEarned, treasuryEarned, 10, "creator and treasury should earn approx the same");

        // 1% fees expected from each creator (2 * 1 ether + 2 * 1 ether buys + 2 * 2 ether buys)
        uint256 expectedTotalFees = (2 + 2 + 4) * 1 ether / 100;

        assertApproxEqAbs(
            creatorEarned + treasuryEarned,
            expectedTotalFees,
            10, // 10 wei error allowed
            "total fees should be 1% of total buys"
        );
    }

    /// @notice test that if price dips well below the graduation price and then there are buys, the fees are still correctly collected
    /// @dev This is mainly covering the extra single-sided eth position below the graduation price
    function test_viewFunction_collectFees_priceDipBelowGraduationAndThenBuys() public createAndGraduateToken {
        deal(buyer, 10 ether);
        // first, make the price dip below graduation price by selling a lot of tokens
        _swapSell(buyer, 10_000_000e18, 0.1 ether, true);

        // then do a buy crossing again that liquidity position
        uint256 buyAmount = 4 ether;
        _swapBuy(buyer, buyAmount, 10e18, true);

        address[] memory tokens = new address[](1);
        tokens[0] = testToken;

        uint256 creatorBalanceBefore = creator.balance;
        graduatorWithFees.collectEthFees(tokens, 0);
        graduatorWithFees.collectEthFees(tokens, 1);
        uint256 totalCreatorFees = creator.balance - creatorBalanceBefore;

        // Expected fees: 1% of buyAmount split 50/50 between creator and treasury
        // So creator gets 0.5% = buyAmount / 200
        uint256 expectedFees = buyAmount / 200;
        assertApproxEqAbsDecimal(totalCreatorFees, expectedFees, 1, 18, "creator fees should be 0.5% of buy amount");
    }
}

contract UniswapV4ClaimFeesViewFunctions is BaseUniswapV4FeesTests {
    function test_viewFunction_positionId() public createAndGraduateToken {
        uint256 positionId = graduatorWithFees.positionIds(testToken, 0);

        assertEq(positionId, 62898, "wrong position id registered at graduation");
    }

    /// @notice test that right after graduation getClaimableFees gives 0
    function test_viewFunction_getClaimableFees_rightAfterGraduation() public createAndGraduateToken {
        address[] memory tokens = new address[](1);
        tokens[0] = testToken;

        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, 0);

        assertEq(fees.length, 1, "should return one fee value");
        assertEq(fees[0], 0, "fees should be 0 right after graduation");
    }

    /// @notice test that after one swapBuy, getClaimableFees gives expected fees
    function test_viewFunction_getClaimableFees_afterOneSwapBuy() public createAndGraduateToken {
        deal(buyer, 10 ether);
        uint256 buyAmount = 1 ether;
        _swapBuy(buyer, buyAmount, 10e18, true);

        address[] memory tokens = new address[](1);
        tokens[0] = testToken;

        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, 0);

        assertEq(fees.length, 1, "should return one fee value");
        // Expected fees: 1% of buyAmount split 50/50 between creator and treasury
        // So creator gets 0.5% = buyAmount / 200
        uint256 expectedFees = buyAmount / 200;
        assertApproxEqAbs(fees[0], expectedFees, 1, "creator fees should be 0.5% of buy amount");
    }

    /// @notice test that after one swapSell, getClaimableFees gives 0
    function test_viewFunction_getClaimableFees_afterOneSwapSell() public createAndGraduateToken {
        _swapSell(buyer, 100000000e18, 0.1 ether, true);

        address[] memory tokens = new address[](1);
        tokens[0] = testToken;

        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, 0);

        assertEq(fees.length, 1, "should return one fee value");
        assertEq(fees[0], 0, "no eth fees should be claimable after sell");
    }

    /// @notice test that after two swapBuy, getClaimableFees gives expected fees
    function test_viewFunction_getClaimableFees_afterTwoSwapBuys() public createAndGraduateToken {
        deal(buyer, 10 ether);
        uint256 buyAmount1 = 1 ether;
        uint256 buyAmount2 = 0.5 ether;
        _swapBuy(buyer, buyAmount1, 10e18, true);
        _swapBuy(buyer, buyAmount2, 10e18, true);

        address[] memory tokens = new address[](1);
        tokens[0] = testToken;

        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, 0);

        assertEq(fees.length, 1, "should return one fee value");
        uint256 expectedCreatorFees = (buyAmount1 + buyAmount2) / 200;
        assertApproxEqAbs(fees[0], expectedCreatorFees, 2, "creator fees should be 0.5% of total buy amounts");
    }

    /// @notice test that after swapBuy, claim, getClaimableFees gives 0
    function test_viewFunction_getClaimableFees_afterClaimGivesZero() public createAndGraduateToken {
        address[] memory tokens = new address[](1);
        tokens[0] = testToken;

        deal(buyer, 10 ether);
        _swapBuy(buyer, 1 ether, 10e18, true);

        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, 0);
        assertApproxEqAbs(fees[0], 1 ether / 200, 1, "creator fees should be 0.5% of buy amount");

        _collectFees(testToken);

        fees = graduatorWithFees.getClaimableFees(tokens, 0);

        assertEq(fees[0], 0, "fees should be 0 after claim");
    }

    /// @notice test that after swapBuy, claim, swapBuy getClaimableFees gives expected fees
    function test_viewFunction_getClaimableFees_afterClaimAndSwapBuy() public createAndGraduateToken {
        deal(buyer, 10 ether);
        _swapBuy(buyer, 1 ether, 10e18, true);

        _collectFees(testToken);

        uint256 buyAmount2 = 0.8 ether;
        _swapBuy(buyer, buyAmount2, 10e18, true);

        address[] memory tokens = new address[](1);
        tokens[0] = testToken;

        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, 0);

        assertEq(fees.length, 1, "should return one fee value");
        assertApproxEqAbs(fees[0], buyAmount2 / 200, 1, "creator fees should be 0.5% of second buy amount");
    }

    /// @notice test that getClaimableFees works for multiple tokens
    function test_viewFunction_getClaimableFees_multipleTokens() public twoGraduatedTokensWithBuys(1 ether) {
        address[] memory tokens = new address[](2);
        tokens[0] = testToken1;
        tokens[1] = testToken2;

        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, 0);

        assertEq(fees.length, 2, "should return two fee values");
        // Expected fees: 0.5% of 1 ether = 1 ether / 200
        assertApproxEqAbs(fees[0], 1 ether / 200, 1, "fees[0] should be 0.5% of buy amount");
        assertApproxEqAbs(fees[1], 1 ether / 200, 1, "fees[1] should be 0.5% of buy amount");
    }

    /// @notice test that getClaimableFees gives the same results when called with the repeated token in the array
    function test_viewFunction_getClaimableFees_repeatedToken() public twoGraduatedTokensWithBuys(1 ether) {
        address[] memory tokens = new address[](3);
        tokens[0] = testToken1;
        tokens[1] = testToken2;
        tokens[2] = testToken1; // repeated

        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, 0);

        assertEq(fees.length, 3, "should return three fee values");
        // Expected fees: 0.5% of 1 ether = 1 ether / 200
        assertApproxEqAbs(fees[0], 1 ether / 200, 1, "fees[0] should be 0.5% of buy amount");
        assertApproxEqAbs(fees[1], 1 ether / 200, 1, "fees[1] should be 0.5% of buy amount");
        assertApproxEqAbs(fees[2], 1 ether / 200, 1, "fees[2] should match fees[0] for repeated token");
        assertEq(fees[0], fees[2], "repeated token should return same fees");
    }

    /// @notice test that if price dips well below the graduation price and then there are buys, the fees are still correctly calculated
    /// @dev This is mainly covering the extra single-sided eth position below the graduation price
    function test_viewFunction_getClaimableFees_priceDipBelowGraduationAndThenBuys() public createAndGraduateToken {
        deal(buyer, 10 ether);
        // first, make the price dip below graduation price by selling a lot of tokens
        _swapSell(buyer, 10_000_000e18, 0.1 ether, true);

        // then do a buy crossing again that liquidity position
        uint256 buyAmount = 4 ether;
        _swapBuy(buyer, buyAmount, 10e18, true);

        address[] memory tokens = new address[](1);
        tokens[0] = testToken;
        // claim from both positions to claim all ETH possible
        uint256[] memory fees0;
        fees0 = graduatorWithFees.getClaimableFees(tokens, 0);
        uint256[] memory fees1;
        fees1 = graduatorWithFees.getClaimableFees(tokens, 1);
        uint256 totalFees = fees0[0] + fees1[0];

        // Expected fees: 1% of buyAmount split 50/50 between creator and treasury
        // So creator gets 0.5% = buyAmount / 200
        uint256 expectedFees = buyAmount / 200;
        assertApproxEqAbsDecimal(totalFees, expectedFees, 1, 18, "creator fees should be 0.5% of buy amount");
    }
}
