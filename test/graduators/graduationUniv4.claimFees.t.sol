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
}

/// @notice Tests for Uniswap V4 graduator functionality
contract UniswapV4ClaimFeesTests is BaseUniswapV4GraduationTests {
    ILivoGraduatorWithFees graduatorWithFees;

    function setUp() public override {
        super.setUp();

        graduatorWithFees = ILivoGraduatorWithFees(address(graduator));
    }

    function test_claimFees_happyPath_ethBalanceIncrease() public createTestToken {
        _graduateToken();

        deal(buyer, 1 ether);
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

    function test_claimFees_happyPath_tokenBalances() public createTestToken {
        revert("Not implemented");
    }

}
