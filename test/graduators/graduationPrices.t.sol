// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {
    LaunchpadBaseTests,
    LaunchpadBaseTestsWithUniv2Graduator,
    LaunchpadBaseTestsWithUniv4Graduator
} from "test/launchpad/base.t.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoToken} from "src/LivoToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TokenState} from "src/types/tokenData.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IWETH} from "src/interfaces/IWETH.sol";

import {BaseUniswapV4GraduationTests} from "test/graduators/graduationUniv4.base.t.sol";
import {BaseUniswapV2GraduationTests} from "test/graduators/graduationUniv2.t.sol";

/// @dev Test that the graduation price matches between launchpad and graduators
abstract contract GraduationPricesTests is LaunchpadBaseTests {
    // below this value, no graduation. Above this value, graduation
    uint256 ETH_PURCHASE_TO_GRADUATE;

    // below this value, graduation is allowed. Above this value, purchase reverts
    uint256 ETH_PURCHASE_TRIGGERS_EXCESS;

    function setUp() public virtual override {
        super.setUp();

        uint256 graduationThreshold = BASE_GRADUATION_THRESHOLD;

        ETH_PURCHASE_TO_GRADUATE = _increaseWithFees(graduationThreshold);

        ETH_PURCHASE_TRIGGERS_EXCESS = _increaseWithFees(graduationThreshold + MAX_THRESHOLD_EXCESS);
    }

    function _graduateExact() internal {
        _launchpadBuy(testToken, ETH_PURCHASE_TO_GRADUATE);
    }

    function _graduateExcess() internal {
        uint256 graduationThreshold = BASE_GRADUATION_THRESHOLD;
        uint256 ethAmountToGraduate = _increaseWithFees(graduationThreshold);

        _launchpadBuy(testToken, ethAmountToGraduate + MAX_THRESHOLD_EXCESS - 1);
    }

    function _uniswapBuy(address account, uint256 ethAmount) public virtual {
        account;
        ethAmount;
        revert("must be overriden");
    }

    function _uniswapSell(address account, uint256 tokenAmount) public virtual {
        account;
        tokenAmount;
        revert("must be overriden");
    }

    /////////////////////////////// BASIC TESTS //////////////////////////////////

    function test_exactEthPurchaseGraduates() public createTestToken {
        _launchpadBuy(testToken, ETH_PURCHASE_TO_GRADUATE);
        assertTrue(launchpad.getTokenState(testToken).graduated, "not graduated");
    }

    function test_exactlyBelowEthPurchaseDoesNotGraduate() public createTestToken {
        _launchpadBuy(testToken, ETH_PURCHASE_TO_GRADUATE - 1);
        assertFalse(launchpad.getTokenState(testToken).graduated, "graduated");
    }

    function test_exactExcessTriggersRevert() public createTestToken {
        vm.expectRevert(abi.encodeWithSignature("PurchaseExceedsLimitPostGraduation()"));
        _launchpadBuy(testToken, ETH_PURCHASE_TRIGGERS_EXCESS);
    }

    function test_belowExcessDoesNotRevert() public createTestToken {
        _launchpadBuy(testToken, ETH_PURCHASE_TRIGGERS_EXCESS - 1);
        assertTrue(launchpad.getTokenState(testToken).graduated, "not graduated");
    }

    /////////////////////// liquidity, mcap, etc //////////////////////////////////

    function test_metricsAtExactGraduation() public createTestToken {
        // these values are computed from the current bonding curve parameters, and may change if those change
        uint256 expectedTokensInLiquidity = 190_000_000e18;
        uint256 expectedEthInLiquidity = 7.5 ether;
        uint256 expectedPriceAtGraduation = 0.0000000392 ether;
        uint256 expectedMcapAtGraduation = 39.2 ether;

        _graduateExact();

        // buy on uniswap, and derive the price from how many tokens were bought
        uint256 ethAmount = 0.01 ether;
        uint256 tokenBalanceBefore = IERC20(testToken).balanceOf(buyer);
        _uniswapBuy(buyer, ethAmount);
        uint256 tokensBoughtSwap = IERC20(testToken).balanceOf(buyer) - tokenBalanceBefore;
        uint256 effectiveSwapPrice = (ethAmount * 1e18) / tokensBoughtSwap;
        uint256 tokensInPair = IERC20(testToken).balanceOf(LivoToken(testToken).pair());

        // regardless of both univ2 and univ4.
        // 1% error margin below
        assertApproxEqRel(
            expectedPriceAtGraduation, effectiveSwapPrice, 0.01 ether, "price at graduation does not match"
        );
        assertApproxEqRel(
            expectedMcapAtGraduation,
            effectiveSwapPrice * TOTAL_SUPPLY / 1e18,
            0.01 ether,
            "mcap at graduation does not match"
        );
        assertApproxEqRel(
            expectedTokensInLiquidity, tokensInPair, 0.01 ether, "liquidity tokens at graduation do not match"
        );
        assertApproxEqRel(
            expectedEthInLiquidity,
            effectiveSwapPrice * tokensInPair / 1e18,
            0.01 ether,
            "liquidity eth at graduation does not match"
        );
    }

    /////////////////////////////// PRICING TESTS //////////////////////////////////

    function test_graduationPriceMatch_exactGraduation() public createTestToken {
        uint256 ethAmount = 0.001 ether;

        // buy just below graduation
        _launchpadBuy(testToken, ETH_PURCHASE_TO_GRADUATE - 1);
        // this buy triggering graduation
        uint256 tokenBalanceBeforeLaunchpadBuy = IERC20(testToken).balanceOf(buyer);
        _launchpadBuy(testToken, ethAmount);
        uint256 tokensBoughtLaunchpad = IERC20(testToken).balanceOf(buyer) - tokenBalanceBeforeLaunchpadBuy;
        uint256 effectiveLaunchpadPrice = (ethAmount * 1e18) / tokensBoughtLaunchpad;

        // buy on uniswap, and register how many tokens were bought
        uint256 tokenBalanceBefore = IERC20(testToken).balanceOf(buyer);
        _uniswapBuy(buyer, ethAmount);
        uint256 tokensBoughtSwap = IERC20(testToken).balanceOf(buyer) - tokenBalanceBefore;
        uint256 effectiveSwapPrice = (ethAmount * 1e18) / tokensBoughtSwap;

        // uniswapv2 yields a lower swap price due to the lower fees (0.3% vs 1% in launchpad)
        // ensure that either swapPrice > launchpadPrice (univ4), or that they are very close (univ2)
        if (effectiveSwapPrice < effectiveLaunchpadPrice) {
            assertApproxEqRel(
                effectiveSwapPrice, effectiveLaunchpadPrice, 0.01e18, "swap price more than 1% lower than launchpad"
            );
        }
    }

    function test_graduationPriceMatch_graduationBuyWithExcess() public createTestToken {
        // buy all the way up until the max allowed before triggering the revert
        uint256 ethAmount = MAX_THRESHOLD_EXCESS;

        // buy just below graduation
        _launchpadBuy(testToken, ETH_PURCHASE_TO_GRADUATE - 1);
        // this buy triggering graduation
        uint256 tokenBalanceBeforeLaunchpadBuy = IERC20(testToken).balanceOf(buyer);
        _launchpadBuy(testToken, ethAmount);
        uint256 tokensBoughtLaunchpad = IERC20(testToken).balanceOf(buyer) - tokenBalanceBeforeLaunchpadBuy;
        uint256 effectiveLaunchpadPrice = (ethAmount * 1e18) / tokensBoughtLaunchpad;

        // buy on uniswap, and register how many tokens were bought
        uint256 tokenBalanceBefore = IERC20(testToken).balanceOf(buyer);
        _uniswapBuy(buyer, ethAmount);
        uint256 tokensBoughtSwap = IERC20(testToken).balanceOf(buyer) - tokenBalanceBefore;
        uint256 effectiveSwapPrice = (ethAmount * 1e18) / tokensBoughtSwap;

        // uniswapv2 yields a lower swap price due to the lower fees (0.3% vs 1% in launchpad)
        // ensure that either swapPrice > launchpadPrice (univ4), or that they are very close (univ2)
        if (effectiveSwapPrice < effectiveLaunchpadPrice) {
            assertApproxEqRel(
                effectiveSwapPrice, effectiveLaunchpadPrice, 0.01e18, "swap price more than 1% lower than launchpad"
            );
        }
    }

    function test_graduationPriceMatch_graduationWithExcess_withSmallSubsequentBuy() public createTestToken {
        // buy all the way up until the max allowed before triggering the revert
        uint256 ethAmount = MAX_THRESHOLD_EXCESS;
        uint256 secondAmount = 0.0001 ether;

        // buy just below graduation
        _launchpadBuy(testToken, ETH_PURCHASE_TO_GRADUATE - 1);
        // this buy triggering graduation
        uint256 tokenBalanceBeforeLaunchpadBuy = IERC20(testToken).balanceOf(buyer);
        _launchpadBuy(testToken, ethAmount);
        uint256 tokensBoughtLaunchpad = IERC20(testToken).balanceOf(buyer) - tokenBalanceBeforeLaunchpadBuy;
        uint256 effectiveLaunchpadPrice = (ethAmount * 1e18) / tokensBoughtLaunchpad;

        // buy on uniswap, and register how many tokens were bought
        uint256 tokenBalanceBefore = IERC20(testToken).balanceOf(buyer);
        _uniswapBuy(buyer, secondAmount);
        uint256 tokensBoughtSwap = IERC20(testToken).balanceOf(buyer) - tokenBalanceBefore;
        uint256 effectiveSwapPrice = (secondAmount * 1e18) / tokensBoughtSwap;

        // uniswapv2 yields a lower swap price due to the lower fees (0.3% vs 1% in launchpad)
        // ensure that either swapPrice > launchpadPrice (univ4), or that they are very close (univ2)
        if (effectiveSwapPrice < effectiveLaunchpadPrice) {
            assertApproxEqRel(
                effectiveSwapPrice, effectiveLaunchpadPrice, 0.01e18, "swap price more than 1% lower than launchpad"
            );
        }
    }

    function test_compareTokenPricesMidCurve_launchpadVsSwap() public createTestToken {
        // it is accepted that the price going up the bonding curve and going down with swap will not reach the same price point
        // Not all the eth used for purchases is used in reserves (eth fees) and not all the eth reserves are used for liquidity (graduation fees).
        vm.skip(true);

        uint256 midCurvePurchase = 0.5 ether;
        uint256 smallBuyAmount = 0.001 ether;

        // purchase 4 eth worth on launchpad (mid-curve)
        _launchpadBuy(testToken, midCurvePurchase);

        // small buy to register launchpad price at mid-curve
        uint256 tokenBalanceBeforeLaunchpadBuy = IERC20(testToken).balanceOf(buyer);
        _launchpadBuy(testToken, smallBuyAmount);
        uint256 tokensBoughtLaunchpad = IERC20(testToken).balanceOf(buyer) - tokenBalanceBeforeLaunchpadBuy;
        uint256 effectiveLaunchpadPrice = (smallBuyAmount * 1e18) / tokensBoughtLaunchpad;

        // graduate (register how many tokens were bought)
        uint256 tokenBalanceBeforeGraduation = IERC20(testToken).balanceOf(buyer);
        _launchpadBuy(testToken, ETH_PURCHASE_TO_GRADUATE - midCurvePurchase);
        assertTrue(launchpad.getTokenState(testToken).graduated, "not graduated");
        uint256 tokensFromGraduation = IERC20(testToken).balanceOf(buyer) - tokenBalanceBeforeGraduation;

        // sell all the tokens to reach the mid curve again, but selling against uniswap this time
        _uniswapSell(buyer, tokensFromGraduation);

        // buy on uniswap with small amount to register price
        uint256 tokenBalanceBeforeSwap = IERC20(testToken).balanceOf(buyer);
        _uniswapBuy(buyer, smallBuyAmount);
        uint256 tokensBoughtSwap = IERC20(testToken).balanceOf(buyer) - tokenBalanceBeforeSwap;
        uint256 effectiveSwapPrice = (smallBuyAmount * 1e18) / tokensBoughtSwap;

        console.log(midCurvePurchase, " eth: launchpad price", effectiveLaunchpadPrice);
        console.log(midCurvePurchase, " eth: swap price", effectiveSwapPrice);
        assertApproxEqRel(
            effectiveLaunchpadPrice, effectiveSwapPrice, 0.001e18, "not within 0.1% when selling back all supply"
        );
    }
}

// This runs all the tests in GraduationPricesTests, but using the Univ2 graduator
contract GraduationPriceTests_Univ2 is GraduationPricesTests, BaseUniswapV2GraduationTests {
    function setUp() public override(GraduationPricesTests, BaseUniswapV2GraduationTests) {
        super.setUp();
    }

    function _uniswapBuy(address account, uint256 ethAmount) public override {
        deal(account, 2 * ethAmount);
        _swapBuy(account, testToken, ethAmount, 0);
    }

    function _uniswapSell(address account, uint256 tokenAmount) public override {
        _swapSell(account, testToken, tokenAmount, 0);
    }
}

// This runs all the tests in GraduationPricesTests, but using the Univ4 graduator
contract GraduationPriceTests_Univ4 is GraduationPricesTests, BaseUniswapV4GraduationTests {
    function setUp() public override(GraduationPricesTests, BaseUniswapV4GraduationTests) {
        super.setUp();
    }

    function _uniswapBuy(address account, uint256 ethAmount) public override {
        deal(account, 2 * ethAmount);
        _swapBuy(account, ethAmount, 0, true);
    }

    function _uniswapSell(address account, uint256 tokenAmount) public override {
        _swapSell(account, tokenAmount, 0, true);
    }
}
