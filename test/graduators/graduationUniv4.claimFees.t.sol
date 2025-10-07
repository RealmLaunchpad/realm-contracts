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

interface ILivoGraduatorWithFees is ILivoGraduator {
    function collectEthFees(address token) external;
    function tokenPositionIds(address token) external view returns (uint256);
}

/// @notice Tests for Uniswap V4 graduator functionality
contract UniswapV4ClaimFeesTests is BaseUniswapV4GraduationTests {
    ILivoGraduatorWithFees graduatorWithFees;

    function setUp() public override {
        super.setUp();

        graduatorWithFees = ILivoGraduatorWithFees(address(graduator));
        deal(buyer, 10 ether);
    }

    modifier createAndGraduateToken() {
        vm.prank(creator);
        // this graduator is not defined here in the base, so it will be address(0) unless inherited by LaunchpadBaseTestsWithUniv2Graduator or V4
        testToken = launchpad.createToken(
            "TestToken", "TEST", "ipfs://test-metadata", address(bondingCurve), address(graduator)
        );

        _graduateToken();
        _;
    }

    function test_rightPositionIdAfterGraduation() public createAndGraduateToken {
        uint256 positionId = LivoGraduatorUniswapV4(payable(address(graduator))).tokenPositionIds(testToken);

        assertEq(positionId, 62898, "wrong position id registered at graduation");
    }

    function test_claimFees_happyPath_ethBalanceIncrease() public createAndGraduateToken {
        deal(buyer, 10 ether);
        _swapBuy(buyer, 1 ether, 10e18, true);

        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 treasuryEthBalanceBefore = treasury.balance;

        graduatorWithFees.collectEthFees(testToken);

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

    function test_claimFees_expectedFeesIncrease() public createAndGraduateToken {
        deal(buyer, 10 ether);
        uint256 buyAmount = 1 ether;
        _swapBuy(buyer, buyAmount, 10e18, true);

        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 treasuryEthBalanceBefore = treasury.balance;

        graduatorWithFees.collectEthFees(testToken);

        uint256 creatorEthBalanceAfter = creator.balance;
        uint256 treasuryEthBalanceAfter = treasury.balance;

        uint256 creatorFees = creatorEthBalanceAfter - creatorEthBalanceBefore;
        uint256 treasuryFees = treasuryEthBalanceAfter - treasuryEthBalanceBefore;

        uint256 totalFeesCollected = creatorFees + treasuryFees;

        assertApproxEqAbs(totalFeesCollected, buyAmount / 100, 1, "total fees should be 1%");
    }

    /// @notice test that on buys, only eth fees are collected
    function test_claimFees_onBuys_onlyEthFees() public createAndGraduateToken {
        deal(buyer, 10 ether);
        _swapBuy(buyer, 1.5 ether, 10e18, true);

        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 tokenBalanceBefore = IERC20(testToken).balanceOf(address(graduatorWithFees));

        graduatorWithFees.collectEthFees(testToken);

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

        graduatorWithFees.collectEthFees(testToken);

        uint256 tokenBalanceAfter = IERC20(testToken).balanceOf(address(graduatorWithFees));
        uint256 poolManagerBalanceAfter = IERC20(testToken).balanceOf(address(poolManager));

        assertGt(
            IERC20(testToken).balanceOf(address(graduatorWithFees)), 0, "there should be some tokens in the graduator"
        );
        assertLt(poolManagerBalanceAfter, poolManagerBalance, "token fees should leave the token manager");
        assertGt(tokenBalanceAfter, tokenBalanceBefore, "Tokens should arrive to the graduator");
        assertEq(creator.balance, creatorEthBalanceBefore, "No fees should be collected now");
    }
}
