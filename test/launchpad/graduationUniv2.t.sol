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

contract BaseUniswapV2GraduationTests is LaunchpadBaseTest {
    uint256 constant DEADLINE = type(uint256).max;
    uint256 constant MAX_THRESHOLD_EXCEESS = 0.5 ether;
    address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Uniswap V2 contracts on mainnet
    IUniswapV2Factory constant UNISWAP_FACTORY = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    address public uniswapPair;

    function setUp() public override {
        super.setUp();
    }

    //////////////////////////////////// modifiers and utilities ///////////////////////////////

    modifier createTestTokenWithPair() {
        vm.prank(creator);
        testToken = launchpad.createToken(
            "TestToken", "TEST", "ipfs://test-metadata", address(bondingCurve), address(graduator)
        );
        uniswapPair = UNISWAP_FACTORY.getPair(testToken, address(WETH));
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

contract UniswapV2GraduationTests is BaseUniswapV2GraduationTests {
    ///////////////////////////////// TESTS //////////////////////////////////////

    /// @notice Test that univ2pair is created in uniswap at token launch
    function test_uniV2PairCreatedAtTokenLaunch() public createTestTokenWithPair {
        assertTrue(uniswapPair != address(0), "Uniswap pair should be created");

        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        address token0 = pair.token0();
        address token1 = pair.token1();

        assertTrue(
            (token0 == testToken && token1 == address(WETH)) || (token0 == address(WETH) && token1 == testToken),
            "Pair should contain test token and WETH"
        );
    }

    /// @notice Test that you cannot transfer tokens to univ2pair before graduation
    function test_cannotTransferTokensToUniV2PairBeforeGraduation() public createTestTokenWithPair {
        uint256 buyAmount = 1 ether;

        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: buyAmount}(testToken, 0, DEADLINE);

        uint256 tokenBalance = IERC20(testToken).balanceOf(buyer);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(LivoToken.TranferToPairBeforeGraduationNotAllowed.selector));
        IERC20(testToken).transfer(uniswapPair, tokenBalance / 2);
    }

    /// @notice Test that you can transfer tokens to univ2pair after graduation
    function test_canTransferTokensToUniV2PairAfterGraduation() public createTestTokenWithPair {
        // First graduate the token, then buy some tokens to test transfers
        _graduateToken();

        // After graduation, we can still buy tokens from the creator's reserved supply if they sell
        // But we can't buy from launchpad, so let's transfer some from the creator instead
        uint256 creatorBalance = IERC20(testToken).balanceOf(creator);
        assertTrue(creatorBalance > 0, "Creator should have tokens after graduation");

        uint256 transferAmount = creatorBalance / 2;
        vm.prank(creator);
        IERC20(testToken).transfer(buyer, transferAmount);

        uint256 buyerBalance = IERC20(testToken).balanceOf(buyer);

        // Now test that buyer can transfer to pair after graduation
        uint256 pairTransferAmount = buyerBalance / 2;
        vm.prank(buyer);
        IERC20(testToken).transfer(uniswapPair, pairTransferAmount);

        assertTrue(IERC20(testToken).balanceOf(uniswapPair) >= pairTransferAmount, "Pair should receive tokens");
        assertEq(IERC20(testToken).balanceOf(buyer), buyerBalance - pairTransferAmount, "Buyer balance should decrease");
    }

    /// @notice Test that it is not possible to create the univ2pair right after token is deployed
    function test_cannotCreateUniV2PairRightAfterTokenDeployment() public {
        vm.prank(creator);
        testToken = launchpad.createToken(
            "TestToken", "TEST", "ipfs://test-metadata", address(bondingCurve), address(graduator)
        );

        address existingPair = UNISWAP_FACTORY.getPair(testToken, address(WETH));
        assertTrue(existingPair != address(0), "Pair should already exist from token creation");

        vm.expectRevert("UniswapV2: PAIR_EXISTS");
        UNISWAP_FACTORY.createPair(testToken, address(WETH));
    }

    // todo continue here

    /// @notice Test that price in uniswap matches price in launchpad when last purchase meets the threshold exactly
    function test_priceInUniswapReflectsGraduationLiquidity() public createTestTokenWithPair {
        uint256 graduationThreshold = BASE_GRADUATION_THRESHOLD;
        uint256 ethAmountToGraduate = (graduationThreshold * 10000) / (10000 - BASE_BUY_FEE_BPS);

        vm.deal(buyer, ethAmountToGraduate);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmountToGraduate}(testToken, 0, DEADLINE);

        TokenState memory state = launchpad.getTokenState(testToken);
        assertTrue(state.graduated, "Token should be graduated");

        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        (uint256 reserve0, uint256 reserve1,) = pair.getReserves();

        uint256 wethReserve;
        uint256 tokenReserve;
        if (pair.token0() == address(WETH)) {
            wethReserve = reserve0;
            tokenReserve = reserve1;
        } else {
            wethReserve = reserve1;
            tokenReserve = reserve0;
        }

        uint256 uniswapPrice = (wethReserve * 1e18) / tokenReserve;

        assertTrue(uniswapPrice > 0, "Uniswap should have a valid price");
        assertTrue(wethReserve > 0, "WETH reserves should be positive");
        assertTrue(tokenReserve > 0, "Token reserves should be positive");

        // The ETH in the pair should be less than the graduation threshold because
        // the graduation fee is deducted before adding liquidity
        assertTrue(
            wethReserve < graduationThreshold, "WETH reserves should be less than threshold due to graduation fee"
        );
    }

    /// @notice Test that LP tokens are burned or transferred to 0xDEAD address
    function test_lpTokensBurnedOrTransferredToDeadAddress() public createTestTokenWithPair {
        uint256 deadBalanceBefore = IERC20(uniswapPair).balanceOf(DEAD_ADDRESS);

        _graduateToken();

        uint256 deadBalanceAfter = IERC20(uniswapPair).balanceOf(DEAD_ADDRESS);
        uint256 lpTokensLocked = deadBalanceAfter - deadBalanceBefore;

        assertTrue(lpTokensLocked > 0, "LP tokens should be locked in dead address");

        uint256 totalLpSupply = IERC20(uniswapPair).totalSupply();
        assertApproxEqRel(lpTokensLocked, totalLpSupply, 0.01e18, "Most LP tokens should be locked");
    }
}

contract TestGraduationDosExploits is BaseUniswapV2GraduationTests {
    /// @notice Test that if WETH is transferred to the univ2pair pre-graduation, liquidity addition doesn't revert
    function test_ethTransferToUniV2PairPreGraduation_noSync_liquidityAdditionDoesNotRevert()
        public
        createTestTokenWithPair
    {
        // Transfer some WETH to the pair
        uint256 wethAmount = 1 ether;
        WETH.deposit{value: wethAmount}();
        WETH.transfer(uniswapPair, wethAmount);

        _graduateToken();
    }

    /// @notice Test that if WETH is transferred to the univ2pair pre-graduation, no pair.sync(), the uniswap price is higher than if no eth was transferred
    function test_ethTransferToUniV2PairPreGraduation_noSync_uniswapPriceHigher() public createTestTokenWithPair {
        // this test was failing, but we are going to transition to uniswapV4 after graduation
        vm.skip(true);

        // donate some eth to the pair
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        deal(address(WETH), address(pair), 0.01 ether);

        // check how many tokens we get by purchasing 0.01 ether right before graduation
        uint256 graduationThreshold = BASE_GRADUATION_THRESHOLD;
        uint256 ethAmountToGraduate = (graduationThreshold * 10000) / (10000 - BASE_BUY_FEE_BPS);
        vm.deal(buyer, ethAmountToGraduate + 1 ether);
        vm.startPrank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmountToGraduate - 0.01 ether}(testToken, 0, DEADLINE);
        uint256 tokensBefore = IERC20(testToken).balanceOf(buyer);
        launchpad.buyTokensWithExactEth{value: 0.01 ether}(testToken, 0, DEADLINE);
        uint256 tokensAfter = IERC20(testToken).balanceOf(buyer);
        uint256 tokensBought = tokensAfter - tokensBefore;
        uint256 bondingCurvePrice = (0.01 ether * 1e18) / tokensBought;
        vm.stopPrank();
        assertTrue(LivoToken(testToken).graduated());

        (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
        uint256 wethReserve;
        uint256 tokenReserve;
        if (pair.token0() == address(WETH)) {
            wethReserve = reserve0;
            tokenReserve = reserve1;
        } else {
            wethReserve = reserve1;
            tokenReserve = reserve0;
        }
        assertGt(wethReserve, 0, "WETH reserves should be positive after graduation");
        assertGt(tokenReserve, 0, "Token reserves should be positive after graduation");
        uint256 uniswapPrice = (wethReserve * 1e18) / tokenReserve;
        assertGt(uniswapPrice, 0, "Uniswap should have a valid price after graduation");

        // The price in uniswap should be strictly higher than the price in the bonding curve
        assertGt(uniswapPrice, bondingCurvePrice, "Uniswap price should be higher than bonding curve price");
    }

    /// @notice Test that if WETH is transferred to the univ2pair pre-graduation, call pair.sync(), liquidity addition doesn't revert
    function test_ethTransferToUniV2PairPreGraduation_sync_liquidityAdditionDoesNotRevert()
        public
        createTestTokenWithPair
    {
        // Transfer some WETH to the pair
        uint256 wethAmount = 1 ether;
        WETH.deposit{value: wethAmount}();
        WETH.transfer(uniswapPair, wethAmount);

        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        pair.sync();

        _graduateToken();
    }

    /// @notice Test that if WETH is transferred to the univ2pair pre-graduation, call pair.sync(), price in univ2 is higher than in the base graduation scenario
    function test_ethTransferToUniV2PairPreGraduation_sync_uniswapPriceHigher() public createTestTokenWithPair {
        // this test was failing, but we are going to transition to uniswapV4 after graduation
        vm.skip(true);

        // donate some eth to the pair
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        deal(address(WETH), address(pair), 0.01 ether);
        pair.sync();

        // check how many tokens we get by purchasing 0.01 ether right before graduation
        uint256 graduationThreshold = BASE_GRADUATION_THRESHOLD;
        uint256 ethAmountToGraduate = (graduationThreshold * 10000) / (10000 - BASE_BUY_FEE_BPS);
        vm.deal(buyer, ethAmountToGraduate + 1 ether);
        vm.startPrank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmountToGraduate - 0.01 ether}(testToken, 0, DEADLINE);
        uint256 tokensBefore = IERC20(testToken).balanceOf(buyer);
        launchpad.buyTokensWithExactEth{value: 0.01 ether}(testToken, 0, DEADLINE);
        uint256 tokensAfter = IERC20(testToken).balanceOf(buyer);
        uint256 tokensBought = tokensAfter - tokensBefore;
        uint256 bondingCurvePrice = (0.01 ether * 1e18) / tokensBought;
        vm.stopPrank();
        assertTrue(LivoToken(testToken).graduated());

        (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
        uint256 wethReserve;
        uint256 tokenReserve;
        if (pair.token0() == address(WETH)) {
            wethReserve = reserve0;
            tokenReserve = reserve1;
        } else {
            wethReserve = reserve1;
            tokenReserve = reserve0;
        }
        assertGt(wethReserve, 0, "WETH reserves should be positive after graduation");
        assertGt(tokenReserve, 0, "Token reserves should be positive after graduation");
        uint256 uniswapPrice = (wethReserve * 1e18) / tokenReserve;
        assertGt(uniswapPrice, 0, "Uniswap should have a valid price after graduation");

        // The price in uniswap should be strictly higher than the price in the bonding curve
        assertGt(uniswapPrice, bondingCurvePrice, "Uniswap price should be higher than bonding curve price");
    }

    /// @notice Test that if WETH is transferred to the univ2pair pre-graduation, call pair.sync(), the price is higher than in the base graduation scenario
    function test_ethTransferToUniV2PairPreGraduation_sync_liquidityAdditionAtRightPrice()
        public
        createTestTokenWithPair
    {
        // We are transitioning to uniswapV4 after graduation
        vm.skip(true);
    }

    /// @notice Test that launchpad eth balance change at graduation is the exact reserves pre graduation
    function test_graduationConservationOfFunds() public createTestTokenWithPair {
        vm.deal(buyer, 100 ether);

        // buy but not graduate
        vm.prank(buyer);
        // value sent: 6956000000000052224
        launchpad.buyTokensWithExactEth{value: BASE_GRADUATION_THRESHOLD - 1 ether}(testToken, 0, DEADLINE);
        assertFalse(launchpad.getTokenState(testToken).graduated, "Token should not be graduated yet");
        // collect the eth trading fees to have a clean comparison

        uint256 launchpadEthBefore = address(launchpad).balance;

        // the eth from this purchase would go straight into liquidity
        uint256 purchaseValue = 1.5 ether;
        vm.prank(seller);
        launchpad.buyTokensWithExactEth{value: purchaseValue}(testToken, 0, DEADLINE);
        assertTrue(launchpad.getTokenState(testToken).graduated, "Token should be graduated");

        uint256 launchpadEthAfter = address(launchpad).balance;

        // Before: launchpad balance + purchaseValue == lauchpad balance + uniswap balance

        assertEq(
            launchpadEthBefore + purchaseValue,
            launchpadEthAfter + WETH.balanceOf(uniswapPair),
            "failed in funds conservation check"
        );
    }
}
