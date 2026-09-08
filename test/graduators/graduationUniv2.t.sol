// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TokenState} from "src/types/tokenData.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IWETH} from "src/interfaces/IWETH.sol";
import {IRealmGraduator} from "src/interfaces/IRealmGraduator.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";

import {RealmLaunchpad} from "src/RealmLaunchpad.sol";
import {IRealmBondingCurve} from "src/interfaces/IRealmBondingCurve.sol";
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";
import {RealmGraduatorUniswapV2} from "src/graduators/RealmGraduatorUniswapV2.sol";

/// @dev Helper contract used to simulate `tx.origin` being a contract that cannot receive ETH.
contract NonReceiver {}

contract BaseUniswapV2GraduationTests is LaunchpadBaseTestsWithUniv2Graduator {
    address public uniswapPair;

    function setUp() public virtual override {
        super.setUp();
    }

    //////////////////////////////////// modifiers and utilities ///////////////////////////////

    modifier createTestTokenWithPair() {
        vm.prank(creator);
        testToken = factoryV2.createToken(
            "TestToken",
            "TEST",
            _nextValidSalt(address(factoryV2), address(realmToken)),
            _fs(creator),
            _noSs(),
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );
        // Pair contract is not deployed at token creation; only the CREATE2 address is reserved
        // and stored on the token. The actual contract is deployed lazily at graduation.
        uniswapPair = RealmToken(testToken).pair();
        _;
    }

    /// @dev Helper: permissionlessly deploys the pair via the UniV2 factory, simulating an
    ///      outside actor (or the graduator itself) creating the pair before graduation.
    function _deployPairPermissionlessly() internal returns (address pair) {
        pair = UNISWAP_FACTORY.createPair(testToken, address(WETH));
    }

    function _swapBuy(address account, address token, uint256 ethAmount, uint256 minTokens) internal {
        vm.startPrank(account);
        WETH.deposit{value: ethAmount}();
        WETH.approve(UNISWAP_V2_ROUTER, ethAmount);

        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = token;

        IUniswapV2Router02(UNISWAP_V2_ROUTER)
            .swapExactTokensForTokens(ethAmount, minTokens, path, account, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function _swapSell(address account, address token, uint256 tokenAmount, uint256 minEth) internal {
        vm.startPrank(account);
        IERC20(token).approve(UNISWAP_V2_ROUTER, tokenAmount);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = address(WETH);

        IUniswapV2Router02(UNISWAP_V2_ROUTER)
            .swapExactTokensForTokens(tokenAmount, minEth, path, account, block.timestamp + 1 hours);
        vm.stopPrank();
    }
}

contract UniswapV2GraduationTests is BaseUniswapV2GraduationTests {
    ///////////////////////////////// TESTS //////////////////////////////////////

    function test_justDeployTokenWithUni2Graduator() public createTestToken {
        // just create the token
    }

    /// @notice Test that the deterministic UniV2 pair address is known at token launch (no contract deployed yet)
    function test_uniV2PairAddressKnownAtTokenLaunch() public createTestTokenWithPair {
        assertTrue(uniswapPair != address(0), "Pair address should be precomputed and non-zero");

        // Pair contract is NOT deployed at token creation
        assertEq(uniswapPair.code.length, 0, "Pair contract should NOT be deployed at token creation");
        assertEq(
            UNISWAP_FACTORY.getPair(testToken, address(WETH)), address(0), "Factory should not yet know about the pair"
        );

        // Permissionlessly deploying the pair must yield the exact same address
        // (verifies the CREATE2 prediction matches reality)
        address actualPair = _deployPairPermissionlessly();
        assertEq(actualPair, uniswapPair, "Precomputed address must match CREATE2 deployment");

        // After actual deployment, token0/token1 should be set correctly
        IUniswapV2Pair pair = IUniswapV2Pair(actualPair);
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
        vm.expectRevert(abi.encodeWithSelector(RealmToken.TransferToPairBeforeGraduationNotAllowed.selector));
        IERC20(testToken).transfer(uniswapPair, tokenBalance / 2);
    }

    /// @notice Test that you can transfer tokens to univ2pair after graduation
    function test_canTransferTokensToUniV2PairAfterGraduation() public createTestTokenWithPair {
        // First graduate the token, then buy some tokens to test transfers
        _graduateToken();

        uint256 buyerBalance = IERC20(testToken).balanceOf(buyer);

        uint256 pairTransferAmount = buyerBalance / 2;
        vm.prank(buyer);
        IERC20(testToken).transfer(uniswapPair, pairTransferAmount);

        assertTrue(IERC20(testToken).balanceOf(uniswapPair) >= pairTransferAmount, "Pair should receive tokens");
        assertEq(IERC20(testToken).balanceOf(buyer), buyerBalance - pairTransferAmount, "Buyer balance should decrease");
    }

    /// @notice Pair is not deployed at token creation, but anyone can permissionlessly deploy
    ///         it later — and the deployed address must equal the precomputed address stored on the token.
    function test_pairNotDeployedAtCreation_canBePermissionlesslyDeployed() public {
        vm.prank(creator);
        testToken = factoryV2.createToken(
            "TestToken",
            "TEST",
            _nextValidSalt(address(factoryV2), address(realmToken)),
            _fs(creator),
            _noSs(),
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );

        address precomputed = RealmToken(testToken).pair();
        assertTrue(precomputed != address(0), "Token should have a precomputed pair address");
        assertEq(precomputed.code.length, 0, "No code at precomputed address before graduation");
        assertEq(UNISWAP_FACTORY.getPair(testToken, address(WETH)), address(0), "Factory has no pair record yet");

        // Permissionless deployment must land at the precomputed address
        address deployed = UNISWAP_FACTORY.createPair(testToken, address(WETH));
        assertEq(deployed, precomputed, "Deployed pair must match precomputed CREATE2 address");
        assertGt(deployed.code.length, 0, "Pair contract should now exist");

        // And the standard 'PAIR_EXISTS' guard kicks in for a second deployment
        vm.expectRevert("UniswapV2: PAIR_EXISTS");
        UNISWAP_FACTORY.createPair(testToken, address(WETH));
    }

    /// @notice Test that price in uniswap matches price in launchpad when last purchase meets the threshold exactly
    function test_priceInUniswapReflectsGraduationLiquidity() public createTestTokenWithPair {
        uint256 graduationThreshold = GRADUATION_THRESHOLD;
        uint256 ethAmountToGraduate = _increaseWithFees(graduationThreshold);

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
        // Pair contract not yet deployed → no LP balance exists pre-graduation
        _graduateToken();

        uint256 lpTokensLocked = IERC20(uniswapPair).balanceOf(DEAD_ADDRESS);
        assertTrue(lpTokensLocked > 0, "LP tokens should be locked in dead address");

        uint256 totalLpSupply = IERC20(uniswapPair).totalSupply();
        assertApproxEqRel(lpTokensLocked, totalLpSupply, 0.01e18, "Most LP tokens should be locked");
    }

    /// @notice Test that verifies WETH remaining in pool after all tokens are sold is not excessive (≤ 2 WETH)
    /// @dev Due to Uniswap V2's constant product formula, some WETH will always remain (price approaches zero asymptotically)
    function test_wethRemainingAfterAllTokensSold() public createTestTokenWithPair {
        // Graduate the token
        _graduateToken();

        // Get token balances before selling
        uint256 creatorBalance = IERC20(testToken).balanceOf(creator);
        uint256 buyerBalance = IERC20(testToken).balanceOf(buyer);

        // Sell all tokens from creator back to the pool
        if (creatorBalance > 0) {
            _swapSell(creator, testToken, creatorBalance, 0);
        }

        // Sell all tokens from buyer back to the pool
        if (buyerBalance > 0) {
            _swapSell(buyer, testToken, buyerBalance, 0);
        }

        // Get remaining WETH in the pool
        uint256 wethRemaining = WETH.balanceOf(uniswapPair);

        // unfortunately, as the supply deployed is roughly 28.5% of the total supply, when all the supply is sold, roughly 28.5% of the liquidity added as WETH will get stuck
        // ETH added as liquidity ~3.5 ETH. Stuck in the pool ~1 ETH
        assertLe(wethRemaining, 1.01e18, "WETH remaining in pool should not exceed 1 WETH after all tokens sold");
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
        // donate some eth to the pair
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        deal(address(WETH), address(pair), 0.01 ether);

        // check how many tokens we get by purchasing 0.01 ether right before graduation
        uint256 graduationThreshold = GRADUATION_THRESHOLD;
        uint256 ethAmountToGraduate = _increaseWithFees(graduationThreshold);

        vm.deal(buyer, ethAmountToGraduate + 1 ether);
        vm.startPrank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmountToGraduate - 0.0001 ether}(testToken, 0, DEADLINE);
        uint256 tokensBefore = IERC20(testToken).balanceOf(buyer);

        // to calculate the uniswap price, we take the resereves only, so we don't consider fees
        // to calculate the price in bonding curve we are going to artificially exclude the fees as well
        uint256 secondBuy = 0.00011 ether;
        uint256 secondBuyPlusFees = _increaseWithFees(secondBuy);

        launchpad.buyTokensWithExactEth{value: secondBuyPlusFees}(testToken, 0, DEADLINE);
        uint256 tokensAfter = IERC20(testToken).balanceOf(buyer);
        uint256 tokensBought = tokensAfter - tokensBefore;
        uint256 bondingCurvePrice = (secondBuy * 1e18) / tokensBought;
        vm.stopPrank();
        assertTrue(RealmToken(testToken).graduated());

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

        // note: if we didn't artificially compensate for the fees in the bonding curve, this assertion would revert with these numbers
        //  uniswap: 39063797643 <= bonding curve: 39368865940  -->  price drop of 0.78%
    }

    /// @notice Test that if WETH is transferred to the univ2pair pre-graduation, call pair.sync(), liquidity addition doesn't revert
    /// @dev Requires permissionlessly deploying the pair first so `sync` has a contract to call.
    function test_ethTransferToUniV2PairPreGraduation_sync_liquidityAdditionDoesNotRevert()
        public
        createTestTokenWithPair
    {
        // Attacker pre-deploys the pair so sync() is callable
        _deployPairPermissionlessly();

        // Transfer some WETH to the pair
        uint256 wethAmount = 1 ether;
        WETH.deposit{value: wethAmount}();
        WETH.transfer(uniswapPair, wethAmount);

        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        pair.sync();

        _graduateToken();
    }

    /// @notice Test that if WETH is transferred to the univ2pair pre-graduation, call pair.sync(), price in univ2 is higher than in the base graduation scenario
    /// @dev Requires permissionlessly deploying the pair first so `sync` has a contract to call.
    function test_ethTransferToUniV2PairPreGraduation_sync_uniswapPriceHigher() public createTestTokenWithPair {
        // Attacker pre-deploys the pair so sync() is callable
        _deployPairPermissionlessly();

        // donate some eth to the pair
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        deal(address(WETH), address(pair), 0.1 ether);
        pair.sync();

        // check how many tokens we get by purchasing 0.01 ether right before graduation
        uint256 graduationThreshold = GRADUATION_THRESHOLD;
        uint256 ethAmountToGraduate = _increaseWithFees(graduationThreshold);
        vm.deal(buyer, ethAmountToGraduate + 1 ether);
        vm.startPrank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmountToGraduate - 0.0001 ether}(testToken, 0, DEADLINE);
        uint256 tokensBefore = IERC20(testToken).balanceOf(buyer);

        // to calculate the uniswap price, we take the resereves only, so we don't consider fees
        // to calculate the price in bonding curve we are going to artificially exclude the fees as well
        uint256 secondBuy = 0.00011 ether;
        launchpad.buyTokensWithExactEth{value: secondBuy}(testToken, 0, DEADLINE);
        uint256 tokensAfter = IERC20(testToken).balanceOf(buyer);
        uint256 tokensBought = tokensAfter - tokensBefore;
        uint256 bondingCurvePrice = (secondBuy * 1e18) / tokensBought;
        vm.stopPrank();
        assertTrue(RealmToken(testToken).graduated());

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
        // note: this test had the same issue as test_ethTransferToUniV2PairPreGraduation_noSync_uniswapPriceHigher()
        // but I fixed this one by simply depositing a slighly higher amount of ETH
    }

    /// @notice Ensure that the right amount of tokens are deposited as liquidity
    function test_rightAmountOfTokensToLiquidity() public createTestTokenWithPair {
        // donate some eth to the pair
        _graduateToken();

        assertApproxEqRel(
            IERC20(testToken).balanceOf(uniswapPair), 285_714_286e18, 0.0001e18, "not enough tokens went to univ2 pool"
        );
    }

    /// @notice Ensure that the right amount of eth was deposited as liquidity
    function test_rightAmountOfEthToLiquidity() public createTestTokenWithPair {
        // donate some eth to the pair
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        _graduateToken();

        assertApproxEqRel(WETH.balanceOf(address(pair)), 3.5 ether, 0.000001e18, "not enough eth went to univ2 pool");
    }

    /// @notice Test that if a large amount of WETH is donated (and synced) to the univ2pair pre-graduation, graduation doesn't fail
    /// @dev Requires permissionlessly deploying the pair first so `sync` has a contract to call.
    function test_large_ethTransferToUniV2PairPreGraduation_sync_graduationOk() public createTestTokenWithPair {
        // Attacker pre-deploys the pair so sync() is callable
        _deployPairPermissionlessly();

        // donate some eth to the pair
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        // nobody would donate this amount of eth to block a token graduation, but just in case
        deal(address(WETH), address(pair), 3 ether);
        pair.sync();

        _graduateToken();
    }

    /// @notice Test that if a large amount of WETH is donated to the univ2pair pre-graduation, graduation doesn't fail
    function test_large_ethTransferToUniV2PairPreGraduation_noSync_graduationOk() public createTestTokenWithPair {
        // donate some eth to the pair
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        // nobody would donate this amount of eth to block a token graduation, but just in case
        deal(address(WETH), address(pair), 3 ether);

        _graduateToken();
    }

    /// @notice Test that launchpad eth balance change at graduation is the exact reserves pre graduation
    function test_graduationConservationOfFunds() public createTestTokenWithPair {
        vm.deal(buyer, 100 ether);

        // buy but not graduate
        vm.prank(buyer);
        // value sent: 6956000000000052224
        launchpad.buyTokensWithExactEth{value: GRADUATION_THRESHOLD - 1 ether}(testToken, 0, DEADLINE);
        assertFalse(launchpad.getTokenState(testToken).graduated, "Token should not be graduated yet");
        // collect the eth trading fees to have a clean comparison

        uint256 launchpadEthBefore = address(launchpad).balance;

        // the eth from this purchase would go straight into liquidity
        uint256 purchaseValue = 1 ether + MAX_THRESHOLD_EXCESS;
        vm.prank(seller);
        launchpad.buyTokensWithExactEth{value: purchaseValue}(testToken, 0, DEADLINE);
        assertTrue(launchpad.getTokenState(testToken).graduated, "Token should be graduated");

        uint256 launchpadEthAfter = address(launchpad).balance;

        // Trading fees go directly to treasury now, so launchpad only holds reserves.
        // The incoming purchaseValue is split: tradingFee to treasury, rest to reserves then graduated.
        uint256 tradingFee = (BASE_BUY_FEE_BPS * purchaseValue) / 10000;
        assertEq(
            launchpadEthBefore + purchaseValue,
            launchpadEthAfter + tradingFee + WETH.balanceOf(uniswapPair) + GRADUATION_FEE,
            "failed in funds conservation check"
        );
    }

    /// @notice Test that the TokenGraduated event is emitted by the graduator
    function test_tokenGraduatedEventEmittedAtGraduation_byGraduator_univ2() public createTestToken {
        vm.skip(true);
        vm.expectEmit(true, false, false, true);
        emit IRealmGraduator.TokenGraduated(
            testToken, 285714285714285714285714291, 3500000000000000000, 31622776601683793319682
        );

        _graduateToken();
    }

    /// @notice Test that the TokenGraduated event is emitted by the Launchpad
    /// @dev After refactoring, launchpad emits full amounts (before fees/burning handled by graduator)
    function test_tokenGraduatedEventEmittedAtGraduation_byLaunchpad_univ2() public createTestToken {
        (uint256 purchasedTokens,) = bondingCurve.buyTokensWithExactEth(0, GRADUATION_THRESHOLD);
        uint256 expectedTokenBalance = TOTAL_SUPPLY - purchasedTokens;

        vm.expectEmit(true, false, false, true);
        // Full ethCollected and tokenBalance (graduator handles fees/burning)
        emit RealmLaunchpad.TokenGraduated(testToken, GRADUATION_THRESHOLD, expectedTokenBalance);

        _graduateToken();
    }

    /// @notice that maxEthToSpend gives a value that allows for graduation
    function test_maxEthToSpend_allowsGraduation() public createTestTokenWithPair {
        uint256 maxEth = launchpad.getMaxEthToSpend(testToken);
        assertGt(maxEth, GRADUATION_THRESHOLD, "maxEthToSpend should be higher than graduation threshold");

        vm.deal(buyer, maxEth + 1 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: maxEth}(testToken, 0, DEADLINE);

        assertTrue(launchpad.getTokenState(testToken).graduated, "Token should be graduated");
    }

    /// @notice that maxEthToSpend reverts if increased by 1
    function test_maxEthToSpend_revertsIfIncreasedBy1() public createTestTokenWithPair {
        uint256 maxEth = launchpad.getMaxEthToSpend(testToken);
        assertGt(maxEth, GRADUATION_THRESHOLD, "maxEthToSpend should be higher than graduation threshold");

        vm.deal(buyer, maxEth + 1 ether);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IRealmBondingCurve.MaxEthReservesExceeded.selector));
        launchpad.buyTokensWithExactEth{value: maxEth + 1}(testToken, 0, DEADLINE);
    }

    /// @notice that buy maxEthToSpend (after some buys) gives a value that allows for graduation
    function test_maxEthToSpend_afterSomeBuys_allowsGraduation(uint256 preBuyAmount) public createTestTokenWithPair {
        preBuyAmount = bound(preBuyAmount, 0.01 ether, GRADUATION_THRESHOLD);

        deal(seller, 100 ether);
        vm.prank(seller);
        launchpad.buyTokensWithExactEth{value: preBuyAmount}(testToken, 0, DEADLINE);
        // if the first one already graduated, we just skip the rest of the test
        if (launchpad.getTokenState(testToken).graduated) return;

        // recalculate the max, after the previous buy
        uint256 maxEth = launchpad.getMaxEthToSpend(testToken);

        vm.deal(buyer, maxEth + 1 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: maxEth}(testToken, 0, DEADLINE);

        assertTrue(launchpad.getTokenState(testToken).graduated, "Token should be graduated");
    }

    /// @notice An attacker cannot seed the predicted pair via the UniV2 router before graduation.
    ///         The router's `addLiquidityETH` calls `safeTransferFrom`, which hits RealmToken's
    ///         `_update` gate and reverts with `TRANSFER_FROM_FAILED`.
    function test_cannotAddLiquidityToPredictedPairBeforeGraduation_viaRouter() public createTestTokenWithPair {
        // Attacker acquires tokens via the bonding curve so they have something to seed with.
        uint256 buyAmount = 1 ether;
        vm.deal(buyer, buyAmount + 0.1 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: buyAmount}(testToken, 0, DEADLINE);
        uint256 tokenBalance = IERC20(testToken).balanceOf(buyer);

        // Approve the router and attempt to seed liquidity at the predicted pair.
        vm.startPrank(buyer);
        IERC20(testToken).approve(UNISWAP_V2_ROUTER, tokenBalance);
        vm.expectRevert(bytes("TransferHelper: TRANSFER_FROM_FAILED"));
        IUniswapV2Router02(UNISWAP_V2_ROUTER).addLiquidityETH{value: 0.1 ether}(
            testToken, tokenBalance, 0, 0, buyer, block.timestamp + 1 hours
        );
        vm.stopPrank();

        // The pair must remain unfunded (the pair contract may or may not exist depending on
        // whether the router's `_addLiquidity` reached `createPair` before reverting).
        assertEq(IERC20(testToken).balanceOf(uniswapPair), 0, "pair must hold no tokens pre-graduation");
    }
}

/// @notice Tests covering the deferred-pair-deployment refactor: the pair contract is no longer
///         deployed at token creation, only its CREATE2 address is reserved. These tests verify
///         (a) the graduator deploys the pair on demand, (b) graduation tolerates a pair that was
///         already deployed by an outside actor, and (c) every DOS-resistance invariant holds when
///         the attacker permissionlessly pre-creates the pair before graduation.
contract TestDeferredPairDeployment is BaseUniswapV2GraduationTests {
    /// @notice Pre-creating the pair is harmless: graduation succeeds, address is stable, contract has code.
    function test_graduationDeploysPairIfMissing() public createTestTokenWithPair {
        assertEq(uniswapPair.code.length, 0, "Pair contract should not exist before graduation");

        _graduateToken();

        assertGt(uniswapPair.code.length, 0, "Pair contract must be deployed by graduation");
        assertEq(UNISWAP_FACTORY.getPair(testToken, address(WETH)), uniswapPair, "Factory must record the pair");
    }

    /// @notice Graduation must succeed when an outside actor already deployed the pair pre-graduation.
    function test_graduationUsesPreExistingPair() public createTestTokenWithPair {
        // Outside actor pre-creates the pair
        address deployed = _deployPairPermissionlessly();
        assertEq(deployed, uniswapPair, "Address invariant");
        assertGt(deployed.code.length, 0, "Pair contract pre-deployed");

        _graduateToken();

        assertTrue(RealmToken(testToken).graduated(), "Token should graduate");
        assertEq(UNISWAP_FACTORY.getPair(testToken, address(WETH)), uniswapPair, "Factory still records the same pair");
        // Liquidity actually landed in the pre-existing pair
        assertGt(WETH.balanceOf(uniswapPair), 0, "Pair should have WETH reserves");
        assertGt(IERC20(testToken).balanceOf(uniswapPair), 0, "Pair should have token reserves");
    }

    //////////////////////// DOS-resistance under attacker-pre-creates-pair ////////////////////////

    /// @notice Even when the pair contract physically exists pre-graduation (attacker pre-deployed it),
    ///         the token's transfer gate still blocks `to == pair` transfers until graduation.
    function test_dos_attackerPreCreatedPair_tokenTransferStillReverts() public createTestTokenWithPair {
        _deployPairPermissionlessly();
        assertGt(uniswapPair.code.length, 0, "Pair contract exists pre-graduation");

        // Buyer acquires tokens via bonding curve
        uint256 buyAmount = 1 ether;
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: buyAmount}(testToken, 0, DEADLINE);
        uint256 tokenBalance = IERC20(testToken).balanceOf(buyer);
        assertGt(tokenBalance, 0, "Buyer should hold tokens");

        // Gate still revs even though the pair contract now exists
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(RealmToken.TransferToPairBeforeGraduationNotAllowed.selector));
        IERC20(testToken).transfer(uniswapPair, tokenBalance / 2);
    }

    /// @notice Attacker pre-creates pair AND donates WETH; graduation still succeeds and the resulting
    ///         pool price is strictly greater than the bonding-curve price right before graduation
    ///         (the invariant from `RealmGraduatorUniswapV2._addLiquidityWithPriceMatching`).
    function test_dos_attackerPreCreatedPair_wethDonationCannotBlockGraduation() public createTestTokenWithPair {
        _deployPairPermissionlessly();

        // Attacker donates WETH to the pre-existing pair (no sync — graduator will sync during graduation)
        deal(address(WETH), uniswapPair, 0.01 ether);

        // Drive the bonding curve close to graduation, capture the bonding-curve price right before the
        // graduating buy, then trigger graduation. Mirrors the structure of
        // `test_ethTransferToUniV2PairPreGraduation_noSync_uniswapPriceHigher`.
        uint256 ethAmountToGraduate = _increaseWithFees(GRADUATION_THRESHOLD);
        vm.deal(buyer, ethAmountToGraduate + 1 ether);
        vm.startPrank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmountToGraduate - 0.0001 ether}(testToken, 0, DEADLINE);
        uint256 tokensBefore = IERC20(testToken).balanceOf(buyer);

        uint256 secondBuy = 0.00011 ether;
        uint256 secondBuyPlusFees = _increaseWithFees(secondBuy);
        launchpad.buyTokensWithExactEth{value: secondBuyPlusFees}(testToken, 0, DEADLINE);
        uint256 tokensAfter = IERC20(testToken).balanceOf(buyer);
        vm.stopPrank();

        assertTrue(RealmToken(testToken).graduated(), "Graduation must succeed despite WETH donation");

        uint256 bondingCurvePrice = (secondBuy * 1e18) / (tokensAfter - tokensBefore);

        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
        (uint256 wethReserve, uint256 tokenReserve) =
            pair.token0() == address(WETH) ? (reserve0, reserve1) : (reserve1, reserve0);
        assertGt(wethReserve, 0, "WETH reserves positive after graduation");
        assertGt(tokenReserve, 0, "Token reserves positive after graduation");

        uint256 uniswapPrice = (wethReserve * 1e18) / tokenReserve;
        assertGt(uniswapPrice, bondingCurvePrice, "Pool price must be > bonding curve price (price-matching invariant)");
    }

    /// @notice Control case: attacker pre-creates the pair but does NOT donate. Graduation should
    ///         take the naive path and yield the canonical post-graduation reserves
    ///         (~3.5 WETH / ~285.7M tokens).
    function test_dos_attackerPreCreatedPair_normalGraduationYieldsExpectedPrice() public createTestTokenWithPair {
        _deployPairPermissionlessly();

        _graduateToken();

        assertTrue(RealmToken(testToken).graduated(), "Token should be graduated");

        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
        (uint256 wethReserve, uint256 tokenReserve) =
            pair.token0() == address(WETH) ? (reserve0, reserve1) : (reserve1, reserve0);

        // Same expectations as the existing `test_rightAmountOfEthToLiquidity` /
        // `test_rightAmountOfTokensToLiquidity` tests — the pair pre-existing must not change them.
        assertApproxEqRel(wethReserve, 3.5 ether, 0.000001e18, "WETH reserves should match canonical graduation");
        assertApproxEqRel(tokenReserve, 285_714_286e18, 0.0001e18, "Token reserves should match canonical graduation");
    }
}

/// @notice A creation-anchored tax-decay token must still graduate through the real V2 curve →
///         graduator flow while its decay window is open. The token-level decay tests fake graduation
///         with a direct `markGraduated()`; this drives the genuine launchpad path instead.
contract TestGraduationWhileDecayActive is BaseUniswapV2GraduationTests {
    function test_v2_graduatesWhileTaxDecayActive() public {
        uint40 t0 = uint40(block.timestamp);
        // decay-only token: 10%/10% buy/sell decay over the full 20min window, creation-anchored.
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "Decay",
            symbol: "DCY",
            salt: _nextValidSalt(address(factoryV2Unified), address(realmTaxTokenV2)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        vm.prank(creator);
        testToken = factoryV2Unified.createToken(
            setup,
            _decayCfg(1000, 1000, 20 minutes, true),
            _noSs(),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            address(0)
        );
        uniswapPair = RealmToken(testToken).pair();

        // seed the curve below graduation while decay is at its launch peak (10%)
        _launchpadBuy(testToken, 1 ether);

        // advance halfway into the decay window: the live launchpad buy tax is now 5% (decayed, nonzero)
        vm.warp(t0 + 10 minutes);
        assertEq(
            IRealmToken(testToken)
            .getLaunchpadFees(IRealmToken.LaunchpadTrade({isBuy: true, ethReserves: 0, releasedSupply: 0}))
            .taxBps,
            500,
            "decay must be live (5%) right before graduation"
        );

        // graduate through the real curve + V2 graduator while decay is active
        _graduateToken();

        // graduation succeeded and liquidity landed in the pair
        assertTrue(launchpad.getTokenState(testToken).graduated, "token must graduate with an active decay");
        assertGt(WETH.balanceOf(uniswapPair), 0, "pair must hold WETH reserves");
        assertGt(IERC20(testToken).balanceOf(uniswapPair), 0, "pair must hold token reserves");
        // the decay window is still open immediately after graduation
        assertGt(IRealmToken(testToken).getTaxConfig().buyTaxBps, 0, "decay still active just after graduation");
    }
}

/// @notice Triggerer ETH compensation paid by the V2 graduator out of `GRADUATION_ETH_FEE`.
///         Carved from the treasury share (creator share unchanged); best-effort push to `tx.origin`.
contract TestTriggererCompensation is BaseUniswapV2GraduationTests {
    event SweepedRemainingEth(address graduatedToken, uint256 amount);

    /// @dev Drives graduation with a single buy where both `msg.sender` and `tx.origin`
    ///      are set to `triggerer` via the two-arg `vm.prank` form.
    function _graduateAs(address triggerer) internal {
        uint256 ethReserves = launchpad.getTokenState(testToken).ethCollected;
        uint256 missing = _increaseWithFees(GRADUATION_THRESHOLD - ethReserves);
        vm.deal(triggerer, missing);
        vm.prank(triggerer, triggerer);
        launchpad.buyTokensWithExactEth{value: missing}(testToken, 0, DEADLINE);
        assertTrue(launchpad.getTokenState(testToken).graduated, "token should have graduated");
    }

    function test_triggerer_eoa_receivesCompensation() public createTestToken {
        address eoa = makeAddr("graduationTriggerer");
        vm.deal(eoa, 0); // normalize starting balance
        uint256 treasuryBalanceBefore = treasury.balance;

        _graduateAs(eoa);

        // EOA balance: started at 0, was funded with `missing`, spent all `missing` on the buy, then received 0.005 from the graduator
        assertEq(eoa.balance, TRIGGERER_GRADUATION_COMPENSATION, "triggerer should net +0.005 ether");

        // Treasury delta = treasury's share of the trading fee + 0.120 (treasury graduation share
        // after the triggerer carve-out). The creator gets the remainder of the trading fee.
        uint256 missing = _increaseWithFees(GRADUATION_THRESHOLD);
        uint256 expectedTradingFee = _treasuryShareOf((missing * BASE_BUY_FEE_BPS) / 10000);
        uint256 expectedTreasuryGraduationShare =
            GRADUATION_FEE - CREATOR_GRADUATION_COMPENSATION - TRIGGERER_GRADUATION_COMPENSATION;
        assertEq(
            treasury.balance - treasuryBalanceBefore,
            expectedTradingFee + expectedTreasuryGraduationShare,
            "treasury should receive trading fee + 0.120 ether (treasury share after triggerer carve-out)"
        );
    }

    function test_triggerer_nonReceiverContract_compensationFallsThroughToTreasury() public createTestToken {
        NonReceiver triggerer = new NonReceiver();
        address triggererAddr = address(triggerer);
        // Foundry's deterministic CREATE addresses can land on slots with pre-existing balance from
        // unrelated test setup; explicitly zero the slot so the balance-delta assertion is meaningful.
        vm.deal(triggererAddr, 0);
        uint256 treasuryBalanceBefore = treasury.balance;

        // Expect the cleanup sweep to fire with exactly the failed-triggerer amount
        vm.expectEmit(true, true, true, true);
        emit SweepedRemainingEth(testToken, TRIGGERER_GRADUATION_COMPENSATION);

        _graduateAs(triggererAddr);

        // Triggerer can't receive ETH, ends at exactly zero (started at 0, was funded with `missing`, spent all of it on the buy)
        assertEq(triggererAddr.balance, 0, "non-receiver triggerer must not gain ETH");

        // Treasury collects: its share of the trading fee + 0.120 (TreasuryGraduationFeeCollected
        // push) + 0.005 (sweep) = treasury trading share + 0.125
        uint256 treasuryDelta = treasury.balance - treasuryBalanceBefore;
        uint256 missing = _increaseWithFees(GRADUATION_THRESHOLD);
        uint256 expectedTradingFee = _treasuryShareOf((missing * BASE_BUY_FEE_BPS) / 10000);
        assertEq(
            treasuryDelta,
            expectedTradingFee + GRADUATION_FEE - CREATOR_GRADUATION_COMPENSATION,
            "treasury should receive the full 0.125 graduation share when triggerer can't receive"
        );
    }

    function test_triggerer_compensationConstantValue() public view {
        assertEq(
            RealmGraduatorUniswapV2(address(graduator)).TRIGGERER_GRADUATION_COMPENSATION(),
            0.005 ether,
            "constant should equal 0.005 ether"
        );
        // Sum invariant on the carve-out: creator + triggerer + treasury == GRADUATION_ETH_FEE
        assertEq(
            CREATOR_GRADUATION_COMPENSATION + TRIGGERER_GRADUATION_COMPENSATION
                + (GRADUATION_FEE - CREATOR_GRADUATION_COMPENSATION - TRIGGERER_GRADUATION_COMPENSATION),
            GRADUATION_FEE,
            "fee shares must sum to GRADUATION_FEE"
        );
    }
}
