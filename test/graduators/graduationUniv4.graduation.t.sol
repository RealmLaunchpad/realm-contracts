// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
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
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {DeploymentAddressesMainnet} from "src/config/DeploymentAddresses.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";

/// @notice Abstract base class for Uniswap V4 graduation tests
/// @dev Contains all test methods that work with both normal and tax tokens
abstract contract UniswapV4GraduationTestsBase is BaseUniswapV4GraduationTests {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    //////////////////////////////////// tests ///////////////////////////////

    function test_justDeployTokenWithUni4Graduator() public createTestToken {
        // just create the token
    }

    /// @notice Test that pool is created in the pool manager at token creation
    function test_poolCreatedInPoolManagerAtTokenCreation() public createTestToken {
        PoolKey memory poolKey = _getPoolKey(testToken);
        PoolId poolId = poolKey.toId();

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        // the starting price is the graduation price, which would only be achieved at graduation
        // before that there should be no activity on this pool (token transfers are forbidden to the pool manager)
        uint256 poolSetPrice = _convertSqrtX96ToTokenPrice(sqrtPriceX96);

        assertApproxEqAbs(
            poolSetPrice, GRADUATION_PRICE, 10, "Pool price should match graduation price. 10 wei error difference"
        );
        assertGt(tick, 0, "Tick should be positive");
    }

    /// @notice Test that pool cannot be created after token creation with the same parameters
    function test_poolCannotBeRecreatedWithSameParameters() public createTestToken {
        PoolKey memory poolKey = _getPoolKey(testToken);

        // The pool is already initialized, so re-initializing should revert, even with a different price (cos has same key)
        vm.expectRevert(bytes4(0x7983c051)); // PoolAlreadyInitialized()
        poolManager.initialize(poolKey, 2505414483750479155158843392);
    }

    /// @notice Test that a pool can be created with different parameters
    function test_poolCanBeCreatedWithDifferentParameters() public createTestToken {
        // Create a pool with different fee tier
        PoolKey memory differentPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(testToken)),
            fee: 3000, // Different fee
            tickSpacing: 60, // Different tick spacing
            hooks: IHooks(address(0))
        });

        // This should succeed as it's a different pool
        uint160 differentStartPrice = 2505414483750479155158843392;
        poolManager.initialize(differentPoolKey, differentStartPrice);

        PoolId poolId = differentPoolKey.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        assertEq(sqrtPriceX96, differentStartPrice, "Different pool should be initialized");
    }

    /// @notice Test that tokens cannot be transferred to the pool manager before graduation
    function test_tokensCannotBeTransferredToPoolManagerBeforeGraduation() public createTestToken {
        LivoToken token = LivoToken(testToken);

        // Buy some tokens first
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        uint256 buyerBalance = token.balanceOf(buyer);
        assertGt(buyerBalance, 0, "Buyer should have tokens");

        // Try to transfer to pool manager
        vm.prank(buyer);
        vm.expectRevert(LivoToken.TransferToPairBeforeGraduationNotAllowed.selector);
        token.transfer(address(poolManager), buyerBalance / 2);
    }

    /// @notice Test that tokens can be transferred to other addresses before graduation
    function test_tokensCanBeTransferredToOtherAddressesBeforeGraduation() public createTestToken {
        LivoToken token = LivoToken(testToken);

        // Buy some tokens first
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

        uint256 buyerBalance = token.balanceOf(buyer);
        assertGt(buyerBalance, 0, "Buyer should have tokens");

        uint256 transferAmount = buyerBalance / 2;

        // Transfer to alice should succeed
        vm.prank(buyer);
        token.transfer(alice, transferAmount);

        assertEq(token.balanceOf(alice), transferAmount, "Alice should receive tokens");
        assertEq(token.balanceOf(buyer), buyerBalance - transferAmount, "Buyer balance should decrease");
    }

    /// @notice test that after adding liquidity the slot0 price matches the graduation from bonding curve
    function test_correctPriceX96AfterAddingLiquidity() public createTestToken {
        _graduateToken();

        uint256 poolPrice = _convertSqrtX96ToTokenPrice(_readSqrtX96TokenPrice()); // tokens/ETH

        assertApproxEqAbs(poolPrice, GRADUATION_PRICE, 1, "Pool price should match graduation price");
    }

    /// @notice Test that token can be graduated successfully and pool has correct liquidity and price after graduation
    function test_successfulGraduation_happyPath() public createTestToken {
        _graduateToken();

        TokenState memory state = launchpad.getTokenState(testToken);
        assertTrue(state.graduated, "Token should be graduated");

        // Check price is as expected
        PoolKey memory poolKey = _getPoolKey(testToken);
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        // Token Price should be at or above starting price
        // since price is expressed as tokens/ETH, the sqrtPrice should be less than the starting price
        // (less tokens per ETH ==> token price is higher)

        // The token price (ETH/token) should be higher than the starting price
        // comparison in the tokens/ETH domain , on sqrtX96
        assertEq(
            sqrtPriceX96,
            startingPriceX96,
            "[sqrtX96-domain] The token price (ETH/token) should be higher than the starting price"
        );
        // comparison in the tokens/ETH domain , on price
        assertEq(
            _convertSqrtX96ToEthPrice(sqrtPriceX96),
            _convertSqrtX96ToEthPrice(startingPriceX96),
            "[eth-price domain] The token price (ETH/token) should be higher than the starting price"
        );
        // comparison in the ETH/tokens domain (token price)
        assertEq(
            _convertSqrtX96ToTokenPrice(sqrtPriceX96),
            _convertSqrtX96ToTokenPrice(startingPriceX96),
            "[token-price domain] The token price (ETH/token) should be higher than the starting price"
        );
    }

    /// @notice Test that token can be graduated successfully and pool has correct liquidity and price after graduation
    function test_successfulGraduation_happyPath_excessGraduation() public createTestToken {
        _launchpadBuy(testToken, MAX_THRESHOLD_EXCESS - 0.01 ether);
        _graduateToken();

        uint160 sqrtPriceX96 = _readSqrtX96TokenPrice();

        // Token Price should be at or above starting price
        // since price is expressed as tokens/ETH, the sqrtPrice should be less than the starting price
        // (less tokens per ETH ==> token price is higher)

        // The token price (ETH/token) should be higher than the starting price
        // comparison in the tokens/ETH domain , on sqrtX96
        assertEq(
            sqrtPriceX96,
            startingPriceX96,
            "[sqrtX96-domain] The token price (ETH/token) should be higher than the starting price"
        );
        // comparison in the tokens/ETH domain , on price
        assertEq(
            _convertSqrtX96ToEthPrice(sqrtPriceX96),
            _convertSqrtX96ToEthPrice(startingPriceX96),
            "[eth-price domain] The token price (ETH/token) should be higher than the starting price"
        );
        // comparison in the ETH/tokens domain (token price)
        assertEq(
            _convertSqrtX96ToTokenPrice(sqrtPriceX96),
            _convertSqrtX96ToTokenPrice(startingPriceX96),
            "[token-price domain] The token price (ETH/token) should be higher than the starting price"
        );
    }

    /// @notice Test that after graduation there are no tokens left in the graduator or launchpad contracts
    function test_tokenBalancesAfterExactGraduationAreZero() public createTestToken {
        _graduateToken();

        assertEq(
            LivoToken(testToken).balanceOf(address(launchpad)),
            0,
            "there should be no tokens in the launchpad after graduation"
        );
        assertLt(
            LivoToken(testToken).balanceOf(address(graduator)),
            0.000000000001e18,
            "there should be no tokens in the graduator after graduation"
        );
    }

    /// @notice Test that after graduation (with excess eth) there are no tokens left in the graduator or launchpad contracts
    function test_tokenBalancesAfterGraduationWithExcessAreZero() public createTestToken {
        _launchpadBuy(testToken, MAX_THRESHOLD_EXCESS - 0.01 ether);
        _graduateToken();

        assertEq(
            LivoToken(testToken).balanceOf(address(launchpad)),
            0,
            "there should be no tokens in the launchpad after graduation"
        );
        assertLt(
            LivoToken(testToken).balanceOf(address(graduator)),
            0.000000000001e18,
            "there should be no tokens in the graduator after graduation"
        );
    }

    /// @notice Test that after graduation there is no ETH left in the graduator or launchpad contracts
    function test_ethBalanceAfterExactGraduationAreZero() public createTestToken {
        _graduateToken();

        assertEq(address(graduator).balance, 0, "there should be no ETH in the graduator after graduation");
    }

    /// @notice Test that after graduation (with excess eth) there is no ETH left in the graduator or launchpad contracts
    function test_ethBalanceAfterGraduationWithExcessAreZero() public createTestToken {
        _launchpadBuy(testToken, MAX_THRESHOLD_EXCESS - 0.01 ether);
        _graduateToken();

        assertEq(address(graduator).balance, 0, "there should be no ETH in the graduator after graduation");
    }

    /// @notice Test that after graduation the creator has received exactly 0% of the supply, and 1% has been burned to the dead address
    function test_creatorTokenBalanceAfterExactGraduation() public createTestToken {
        assertEq(LivoToken(testToken).balanceOf(creator), 0, "creator should start with 0 tokens");

        _launchpadBuy(testToken, 0.1 ether);
        _graduateToken();

        assertEq(LivoToken(testToken).balanceOf(creator), 0, "creator should have 0% supply");
    }

    /// @notice Test that after graduation (exact eth) all the token supply is in the buyer's balance and the pool manager
    function test_poolManagerTokenBalanceAfterExactGraduation() public createTestToken {
        assertEq(LivoToken(testToken).balanceOf(address(launchpad)), TOTAL_SUPPLY, "creator should start with 0 tokens");

        _graduateToken();

        uint256 buyerBalance = LivoToken(testToken).balanceOf(buyer);
        uint256 poolManagerBalance = LivoToken(testToken).balanceOf(poolManagerAddress);
        uint256 creatorBalance = LivoToken(testToken).balanceOf(creator);
        uint256 graduatorBalance = LivoToken(testToken).balanceOf(address(graduator));
        uint256 burnedBalance = LivoToken(testToken).balanceOf(address(0xdead));

        assertEq(
            buyerBalance + poolManagerBalance + creatorBalance + graduatorBalance + burnedBalance,
            TOTAL_SUPPLY,
            "some tokens have disappeared"
        );
        assertLt(graduatorBalance, 5e18, "burned tokens exceeds 5 tokens");
        assertLt(graduatorBalance, TOTAL_SUPPLY / 100_000_000, "more than 0.000001% of the supply is burned");
    }

    /// @notice Test that after graduation (exact eth) the eth worth of tokens dead is negligible
    function test_negligibleEthWorthOfTokensBurnedAtExactGraduation() public createTestToken {
        _graduateToken();
        // tokens left in the graduator are considered burned
        uint256 burntSupply = LivoToken(testToken).balanceOf(address(graduator));
        // there is always some leftovers burned
        assertGt(burntSupply, 0);

        uint256 tokenPrice = _convertSqrtX96ToTokenPrice(_readSqrtX96TokenPrice());
        // console.log("token price after graduation", tokenPrice);

        // the eth worth of the burnt tokens should be negligible (less than 0.01 ETH)
        uint256 ethWorthOfBurntTokens = (burntSupply * tokenPrice) / 1e18;
        // console.log("eth worth of burnt tokens", ethWorthOfBurntTokens);
        assertLt(ethWorthOfBurntTokens, 0.002 ether, "eth worth of burnt tokens is greater than (0.002 ETH) 8$");
    }

    /// @notice Test that after graduation (exact eth) all the token supply is in the buyer's balance and the pool manager
    function test_poolManagerTokenBalanceAfterExcessGraduation() public createTestToken {
        assertEq(LivoToken(testToken).balanceOf(address(launchpad)), TOTAL_SUPPLY, "creator should start with 0 tokens");
        _launchpadBuy(testToken, GRADUATION_THRESHOLD - 0.01 ether);
        _graduateToken();

        uint256 buyerBalance = LivoToken(testToken).balanceOf(buyer);
        uint256 poolManagerBalance = LivoToken(testToken).balanceOf(poolManagerAddress);
        uint256 creatorBalance = LivoToken(testToken).balanceOf(creator);
        uint256 graduatorSupply = LivoToken(testToken).balanceOf(address(graduator));
        uint256 burnedSupply = LivoToken(testToken).balanceOf(address(0xdead));

        assertEq(
            buyerBalance + poolManagerBalance + creatorBalance + graduatorSupply + burnedSupply,
            TOTAL_SUPPLY,
            "some tokens have disappeared"
        );
        assertLt(graduatorSupply, 5e18, "burned tokens exceeds 5 tokens");
        assertLt(graduatorSupply, TOTAL_SUPPLY / 100_000_000, "more than 0.000001% of the supply is burned");
    }

    /// @notice Test that after graduation (exact eth) the eth worth of tokens dead is negligible
    function test_negligibleEthWorthOfTokensBurnedAtExcessGraduation() public createTestToken {
        assertEq(LivoToken(testToken).balanceOf(address(launchpad)), TOTAL_SUPPLY, "creator should start with 0 tokens");
        _launchpadBuy(testToken, GRADUATION_THRESHOLD - 0.01 ether);
        _graduateToken();

        uint256 burntSupply = LivoToken(testToken).balanceOf(address(graduator));
        // there is always some leftovers burned
        assertGt(burntSupply, 0);

        uint256 tokenPrice = _convertSqrtX96ToTokenPrice(_readSqrtX96TokenPrice());
        // console.log("token price after graduation", tokenPrice);

        // the eth worth of the burnt tokens should be negligible (less than 0.01 ETH)
        uint256 ethWorthOfBurntTokens = (burntSupply * tokenPrice) / 1e18;
        // console.log("eth worth of burnt tokens", ethWorthOfBurntTokens);
        assertLt(ethWorthOfBurntTokens, 0.000001 ether, "eth worth of burnt tokens is greater than 0.00004$");
    }

    function test_smallSwapPrice_matchesGraduationPrice() public createTestToken {
        _graduateToken();
        deal(buyer, 1 ether);

        uint256 ethBalanceBefore = buyer.balance;
        uint256 tokenBalanceBefore = LivoToken(testToken).balanceOf(buyer);

        _swapBuy(buyer, 0.001 ether, 1, true);

        uint256 ethDelta = ethBalanceBefore - buyer.balance;
        uint256 tokenDelta = LivoToken(testToken).balanceOf(buyer) - tokenBalanceBefore;

        uint256 swapPrice = 1e18 * ethDelta / tokenDelta;
        uint256 swapPriceExcludingFees = 1e18 * (ethDelta * (10000 - BASE_BUY_FEE_BPS) / 10000) / tokenDelta;
        // accepting here a 0.02% price increase between swap and graduation starting point price
        assertGt(swapPrice, GRADUATION_PRICE, "small swap price should be above graduation price");
        assertGt(swapPriceExcludingFees, GRADUATION_PRICE, "small swap price should be above graduation price");
        assertApproxEqRel(
            swapPriceExcludingFees, GRADUATION_PRICE, 0.0002 ether, "small swap price should match graduation price"
        );
    }

    /// @notice Test that the price given at graduation is lower than pool price in uniswapv4
    function test_priceGivenAtGraduation_smallTx_MatchesUniv4() public createTestToken {
        _launchpadBuy(testToken, GRADUATION_THRESHOLD - 1);
        uint256 remainingForGraduation;
        remainingForGraduation = GRADUATION_THRESHOLD - launchpad.getTokenState(testToken).ethCollected;
        _launchpadBuy(testToken, remainingForGraduation - 1);
        remainingForGraduation = GRADUATION_THRESHOLD - launchpad.getTokenState(testToken).ethCollected;
        _launchpadBuy(testToken, remainingForGraduation - 1);
        assertFalse(launchpad.getTokenState(testToken).graduated, "Token should not be graduated yet");

        deal(buyer, 10 ether);
        uint256 buyerEthBalance = buyer.balance;
        uint256 buyerTokenBalance = LivoToken(testToken).balanceOf(buyer);
        console.log("Buyer eth balance before last tx", buyerEthBalance);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 0.00001 ether}(testToken, 0, DEADLINE);

        assertTrue(launchpad.getTokenState(testToken).graduated, "Token should be graduated now");

        uint256 ethSpent = buyerEthBalance - buyer.balance;
        uint256 tokensBought = LivoToken(testToken).balanceOf(buyer) - buyerTokenBalance;
        uint256 effectiveEth = ethSpent - ((ethSpent * BASE_BUY_FEE_BPS) / 10000);
        uint256 effectivePrice = (effectiveEth * 1e18) / tokensBought;
        console.log("Eth spent in last tx", ethSpent);
        console.log("Effective Eth spent in last tx", effectiveEth);
        console.log("Tokens bought in last tx", tokensBought);
        console.log("Effective price at graduation (eth/token)", effectivePrice);
        uint256 poolPrice = _convertSqrtX96ToTokenPrice(_readSqrtX96TokenPrice());

        // 39405360036 raw
        // 39011306436 as if there were no fees
        assertApproxEqRel(
            effectivePrice, poolPrice, 0.011e18, "Effective price at graduation should match pool price (small last tx)"
        );
        assertGt(poolPrice, effectivePrice, "Pool price should be above effective price at graduation (small last tx)");
    }

    /// @notice Test that after exact graduation, the first purchase has a similar price than the last purchase in the bonding curve
    function test_priceGivenAtGraduation_smallTx_MatchesUniv4_Swap() public createTestToken {
        _launchpadBuy(testToken, GRADUATION_THRESHOLD - 1);
        uint256 remainingForGraduation;
        remainingForGraduation = GRADUATION_THRESHOLD - launchpad.getTokenState(testToken).ethCollected;
        _launchpadBuy(testToken, remainingForGraduation - 1);
        remainingForGraduation = GRADUATION_THRESHOLD - launchpad.getTokenState(testToken).ethCollected;
        _launchpadBuy(testToken, remainingForGraduation - 1);
        assertFalse(launchpad.getTokenState(testToken).graduated, "Token should not be graduated yet");

        uint256 referenceBuyAmount = 0.00001 ether;

        deal(buyer, 10 ether);
        uint256 buyerEthBalance = buyer.balance;
        uint256 buyerTokenBalance = LivoToken(testToken).balanceOf(buyer);
        console.log("Buyer eth balance before last tx", buyerEthBalance);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: referenceBuyAmount}(testToken, 0, DEADLINE);

        assertTrue(launchpad.getTokenState(testToken).graduated, "Token should be graduated now");

        uint256 ethSpent = buyerEthBalance - buyer.balance;
        uint256 tokensBought = LivoToken(testToken).balanceOf(buyer) - buyerTokenBalance;
        uint256 effectivePrice = (ethSpent * 1e18) / tokensBought;
        console.log("Eth spent in last tx", ethSpent);
        console.log("Tokens bought in last tx", tokensBought);
        console.log("Effective price at graduation (eth/token)", effectivePrice);

        buyerEthBalance = buyer.balance;
        buyerTokenBalance = LivoToken(testToken).balanceOf(buyer);
        _swapBuy(buyer, referenceBuyAmount, 0, true);
        uint256 ethSpentInSwap = buyerEthBalance - buyer.balance;
        uint256 tokensBoughtInSwap = LivoToken(testToken).balanceOf(buyer) - buyerTokenBalance;
        uint256 swapPrice = (ethSpentInSwap * 1e18) / tokensBoughtInSwap;
        console.log("Eth spent in swap", ethSpentInSwap);
        console.log("Tokens bought in swap", tokensBoughtInSwap);
        console.log("Swap price (eth/token)", swapPrice);

        assertGt(swapPrice, effectivePrice, "Swap price should be above effective price at graduation");
        assertApproxEqRel(effectivePrice, swapPrice, 0.011e18, "Effective price at graduation should match swap price");
    }

    /// @notice Test that when token is graduated at graduation threshold plus MAX_THRESHOLD_EXCESS, the price purchasing in univ4 is above the price in the bonding curve
    function test_priceGivenAtGraduationMatchesUniv4_largeLastPurchase_matchesSwap() public createTestToken {
        _launchpadBuy(testToken, GRADUATION_THRESHOLD - 0.5 ether);
        assertFalse(launchpad.getTokenState(testToken).graduated, "Token should not be graduated yet");

        // if a crazy user buys the remaining tokens, will get a hell of a price impact ...
        uint256 buyerEthBalance = buyer.balance;
        uint256 buyerTokenBalance = LivoToken(testToken).balanceOf(buyer);
        console.log("Buyer eth balance before last tx", buyerEthBalance);
        _graduateToken();
        assertTrue(launchpad.getTokenState(testToken).graduated, "Token should be graduated now");

        uint256 ethSpent = buyerEthBalance - buyer.balance;
        uint256 tokensBought = LivoToken(testToken).balanceOf(buyer) - buyerTokenBalance;
        uint256 effectivePrice = (ethSpent * 1e18) / tokensBought;
        console.log("Eth spent in last tx", ethSpent);
        console.log("Tokens bought in last tx", tokensBought);
        console.log("Effective price at graduation (eth/token)", effectivePrice);

        // now we do a similar purchase in uniswapv4, to account for the price impact
        deal(buyer, 2 ether);
        buyerEthBalance = buyer.balance;
        buyerTokenBalance = LivoToken(testToken).balanceOf(buyer);
        _swapBuy(buyer, 1 ether, 0, true);
        uint256 ethSpentInSwap = buyerEthBalance - buyer.balance;
        uint256 tokensBoughtInSwap = LivoToken(testToken).balanceOf(buyer) - buyerTokenBalance;
        uint256 swapPrice = (ethSpentInSwap * 1e18) / tokensBoughtInSwap;
        console.log("Eth spent in swap", ethSpentInSwap);
        console.log("Tokens bought in swap", tokensBoughtInSwap);
        console.log("Swap price (eth/token)", swapPrice);

        // the swap price should be higher, and due to the price impact, they are not expected to match at all
        assertGt(swapPrice, effectivePrice, "Swap price should be above effective price at graduation");
    }

    /////////////////////////////////// EXPLOITS / DOS / MISSUSAGE /////////////////////////////////////////

    /// @notice Test that demonstrates DoS vulnerability where griefer can block graduation by sending tokens to graduator
    /// @dev Griefer buys tokens early, then sends them to graduator contract before graduation
    /// @dev This causes underflow in graduateToken() when calculating tokensDeposited = tokenAmount - tokenBalanceAfterDeposit
    function test_griefing_dosGraduationByTokenTransfer() public createTestToken {
        address griefer = makeAddr("griefer");

        // Step 1: Griefer buys tokens early to get approximately 190M tokens
        // This is roughly the amount that will be sent to graduator during graduation
        // Based on bonding curve, buying with ~0.625 ETH should give us the target amount
        vm.deal(griefer, 1 ether);
        vm.prank(griefer);
        launchpad.buyTokensWithExactEth{value: 0.625 ether}(testToken, 0, DEADLINE);

        uint256 grieferTokenBalance = LivoToken(testToken).balanceOf(griefer);
        assertGt(grieferTokenBalance, 180_000_000e18, "Griefer should have bought tokens");
        assertLt(grieferTokenBalance, 210_000_000e18, "Griefer should have bought around 190M tokens");

        // Step 2: Normal user buys tokens to approach graduation threshold
        address normalUser = makeAddr("normalUser");
        vm.deal(normalUser, 10 ether);
        vm.prank(normalUser);
        launchpad.buyTokensWithExactEth{value: 7 ether}(testToken, 0, DEADLINE);

        // Verify we're close to graduation but not graduated yet
        TokenState memory state = launchpad.getTokenState(testToken);
        assertFalse(state.graduated, "Token should not be graduated yet");
        assertGt(state.ethCollected, GRADUATION_THRESHOLD - 1 ether, "Should be close to graduation");

        // Step 3: Griefer transfers tokens to the graduator contract
        // This is the key griefing action - tokens sent directly to graduator
        vm.prank(griefer);
        LivoToken(testToken).transfer(address(graduator), grieferTokenBalance);

        uint256 graduatorTokenBalance = LivoToken(testToken).balanceOf(address(graduator));
        assertEq(graduatorTokenBalance, grieferTokenBalance, "Graduator should have received griefer's tokens");

        // Step 4: Attempt to graduate - this should revert due to underflow
        // When graduateToken() is called, it will try to calculate:
        // tokensDeposited = tokenAmount - tokenBalanceAfterDeposit
        // But tokenBalanceAfterDeposit > tokenAmount, causing underflow
        uint256 ethReserves = launchpad.getTokenState(testToken).ethCollected;
        uint256 missingForGraduation = _increaseWithFees(GRADUATION_THRESHOLD - ethReserves);

        vm.deal(buyer, missingForGraduation);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: missingForGraduation}(testToken, 0, DEADLINE);

        // Make sure the token has graduated
        state = launchpad.getTokenState(testToken);
        assertTrue(state.graduated, "Token should have graduated due to griefing");
    }

    /// @notice Test that a large liquidity position involving only ETH before graduation doesn't affect graduation
    function test_largeEthLiquidityPosition_graduationSucceeds() public createTestToken {
        _addEthLiquidity(buyer, 50 ether); // add a large liquidity position with eth only
        _graduateToken();
    }

    // @notice Test that a large liquidity position involving only ETH before graduation doesn't affect the desired price after graduation
    function test_largeEthPosition_poolPriceMatchesGraduationPrice() public createTestToken {
        _addEthLiquidity(buyer, 50 ether); // add a large liquidity position with eth only

        assertApproxEqAbs(
            _convertSqrtX96ToTokenPrice(_readSqrtX96TokenPrice()),
            GRADUATION_PRICE,
            1, // 1 wei error due to roundings in calcualtions
            "Price before graduation should be as expected"
        );

        _graduateToken();

        assertApproxEqAbs(
            _convertSqrtX96ToTokenPrice(_readSqrtX96TokenPrice()),
            GRADUATION_PRICE,
            1, // 1 wei error due to roundings in calcualtions
            "Price after graduation should be as expected"
        );
    }

    /// @notice Test that a liquidity position involving tokens cannot be set before graduation
    function test_liquidityPositionWithTokensCannotBeSetBeforeGraduation() public createTestToken {
        assertEq(LivoToken(testToken).balanceOf(address(poolManager)), 0, "no tokens in the manager");
        // even adding 1 wei of tokens should revert
        _addMixedLiquidity(buyer, 1 ether, 1000 ether, false);
    }

    ///////////////////////////////// SWAPS BEFORE GRADUATION ////////////////////////////////

    function test_buyingFromUniv4BeforeGraduation_reverts() public createTestToken {
        deal(buyer, 1 ether);
        // a purchase accepting minimum 1 wei of tokens will revert
        // the "false" below indicates that we expect it shouldn't succeed. The expectRevert has to be right before the router.execute() call
        _swapBuy(buyer, 0.1 ether, 1, false);
    }

    function test_sellingFromUniv4BeforeGraduation_reverts() public createTestToken {
        _launchpadBuy(testToken, 0.31 ether);
        uint256 sellAmount = LivoToken(testToken).balanceOf(buyer) / 3;
        // a purchase accepting minimum 1 wei of tokens should revert
        // the "false" below indicates that we expect it shouldn't succeed. The expectRevert has to be right before the router.execute() call
        _swapSell(buyer, sellAmount, 1, false);
    }

    ///////////////////////////////////////// NORMAL UNIV4 ACTIVITY POST GRADUATION ////////////////////////////////////

    function test_buyingFromUniv4AfterGraduation_succeeds() public createTestToken {
        // after graduation, the same swap should succeed
        _graduateToken();

        deal(buyer, 1 ether);

        uint256 tokenBalanceBefore = LivoToken(testToken).balanceOf(buyer);
        uint256 etherBalanceBefore = buyer.balance;

        _swapBuy(buyer, 0.1 ether, 1, true);

        assertLt(buyer.balance, etherBalanceBefore, "Buyer eth balance should decrease after successful swap");
        assertGt(
            LivoToken(testToken).balanceOf(buyer),
            tokenBalanceBefore,
            "Buyer token balance should increase after successful swap"
        );
    }

    function test_sellingFromUniv4AfterGraduation_succeeds() public createTestToken {
        _launchpadBuy(testToken, 0.31 ether);
        uint256 sellAmount = LivoToken(testToken).balanceOf(buyer) / 3;

        // after graduation, the same swap should succeed
        _graduateToken();

        uint256 tokenBalanceBefore = LivoToken(testToken).balanceOf(buyer);
        uint256 etherBalanceBefore = buyer.balance;

        _swapSell(buyer, sellAmount, 0.1 ether, true);

        uint256 tokenBalanceAfter = LivoToken(testToken).balanceOf(buyer);
        uint256 etherBalanceAfter = buyer.balance;

        assertGt(etherBalanceAfter, etherBalanceBefore, "Buyer eth balance should increase after successful swap");
        assertLt(tokenBalanceAfter, tokenBalanceBefore, "Buyer token balance should decrease after successful swap");

        assertGt(
            etherBalanceAfter - etherBalanceBefore, 0.1 ether, "Buyer eth balance should increase by at least 0.1 eth"
        );
        assertEq(tokenBalanceBefore - tokenBalanceAfter, sellAmount, "Sell amount should match");
    }

    function test_sellingFromUniv4AfterGraduation_sellAllTokensPurchasedByGraduator() public createTestToken {
        // after graduation, the same swap should succeed
        _graduateToken();

        // the buyer has now a huge part of the supply
        uint256 tokenBalanceBefore = LivoToken(testToken).balanceOf(buyer);
        uint256 etherBalanceBefore = buyer.balance;

        _swapSell(buyer, tokenBalanceBefore, 6 ether, true);

        uint256 tokenBalanceAfter = LivoToken(testToken).balanceOf(buyer);
        uint256 etherBalanceAfter = buyer.balance;

        assertGt(etherBalanceAfter, etherBalanceBefore, "Buyer eth balance should increase after successful swap");
        assertLt(tokenBalanceAfter, tokenBalanceBefore, "Buyer token balance should decrease after successful swap");

        assertGt(etherBalanceAfter - etherBalanceBefore, 6 ether, "Buyer eth balance didnt increase enough");
        assertEq(tokenBalanceAfter, 0, "Buyer should have sold all tokens");
    }

    function test_sellingFromUniv4AfterGraduation_sellFullSupply_everyOneSells() public createTestToken {
        // after graduation, the same swap should succeed
        _graduateToken();

        uint256 buyerBalanceBefore = LivoToken(testToken).balanceOf(buyer);

        _swapSell(buyer, buyerBalanceBefore, 6 ether, true);

        assertEq(LivoToken(testToken).balanceOf(buyer), 0, "Buyer should have sold all tokens");
        assertEq(LivoToken(testToken).balanceOf(creator), 0, "Creator should have sold all tokens");

        uint256 poolManagerBalance = LivoToken(testToken).balanceOf(address(poolManager));
        uint256 graduatorBalance = LivoToken(testToken).balanceOf(address(graduator));
        uint256 deadAddressBalance = LivoToken(testToken).balanceOf(address(0xdead));

        assertEq(
            poolManagerBalance + graduatorBalance + deadAddressBalance,
            TOTAL_SUPPLY,
            "All tokens should be sold to the pool manager"
        );
    }

    function test_sellingFromUniv4AfterGraduation_priceCanDipBelowGraduation() public createTestToken {
        // after graduation, the same swap should succeed
        _graduateToken();

        // the buyer has now a huge part of the supply
        uint256 tokenBalanceBefore = LivoToken(testToken).balanceOf(buyer);
        uint256 etherBalanceBefore = buyer.balance;

        uint256 sellAmount = (tokenBalanceBefore * 9) / 10;

        _swapSell(buyer, sellAmount, 1 ether, true);

        uint256 tokenBalanceAfter = LivoToken(testToken).balanceOf(buyer);
        uint256 etherBalanceAfter = buyer.balance;

        assertGt(etherBalanceAfter, etherBalanceBefore, "Buyer eth balance should increase after successful swap");
        assertLt(tokenBalanceAfter, tokenBalanceBefore, "Buyer token balance should decrease after successful swap");

        assertGt(etherBalanceAfter - etherBalanceBefore, 1 ether, "Buyer eth balance should increase by at least 1 eth");
        assertEq(tokenBalanceBefore - tokenBalanceAfter, sellAmount, "Sell amount should match");
    }

    /// @notice Test that the TokenGraduated event is emitted at graduation
    function test_tokenGraduatedEventEmittedAtGraduation_byGraduator_univ4() public createTestToken {
        vm.skip(true);
        vm.expectEmit(true, true, false, true);
        emit LivoGraduatorUniswapV4.TokenGraduated(
            testToken,
            bytes32(0xb8316c7a029f0486576cea8a548043cc6942604f7a8ffb742a5bcc103a03b821),
            191123250949901652977521310,
            7456000000000052224,
            55296381402046003400649
        );

        _graduateToken();
    }
    /// @notice Test that the TokenGraduated event is emitted at graduation

    function test_tokenGraduatedEventEmittedAtGraduation_byLaunchpad_univ4() public createTestToken {
        uint256 expectedTokenBalance = TOTAL_SUPPLY - bondingCurve.buyTokensWithExactEth(0, GRADUATION_THRESHOLD);

        vm.expectEmit(true, false, false, true);
        // After refactoring, launchpad emits full amounts (before fees/burning handled by graduator)
        emit LivoLaunchpad.TokenGraduated(testToken, GRADUATION_THRESHOLD, expectedTokenBalance);

        _graduateToken();
    }

    /// @notice test that after graduating, all the eth in the liquidity pool can be extracted again by selling all token supply
    function test_sellingFromUniv4AfterGraduation_sellFullSupply_whereIsTheEth() public virtual createTestToken {
        uint256 poolBalanceBefore = address(poolManager).balance;
        _graduateToken();

        uint256 buyerBalanceBefore = LivoToken(testToken).balanceOf(buyer);
        uint256 creatorBalanceBefore = LivoToken(testToken).balanceOf(creator);
        uint256 poolTokenBalanceBefore = LivoToken(testToken).balanceOf(address(poolManager));

        assertApproxEqAbs(
            buyerBalanceBefore + creatorBalanceBefore + poolTokenBalanceBefore,
            0.0001 ether,
            TOTAL_SUPPLY,
            "some supply is missing"
        );

        uint256 poolBalanceAfterGraduation = address(poolManager).balance;
        uint256 buyerEtherBefore = buyer.balance;
        uint256 creatorEtherBefore = creator.balance;

        // ~190M tokens are in liquidity, 10M owned by the creator, and ~800M owned by `buyer`
        // when selling everything back, almost all eth deposited as liquidity should be recovered

        // sell the full balance of the buyer, who has most of the supply
        _swapSell(buyer, buyerBalanceBefore, 6 ether, true);

        uint256 ethRecoveredByBuyer = buyer.balance - buyerEtherBefore;
        uint256 ethRecoveredByCreator = creator.balance - creatorEtherBefore;
        uint256 ethLeavingFromThePoolManager = poolBalanceAfterGraduation - address(poolManager).balance;
        // check that the eth collected by buyer and seller matches the eth left the pool
        assertEq(
            ethRecoveredByBuyer + ethRecoveredByCreator,
            ethLeavingFromThePoolManager,
            "eth recovered by buyer and creator should match eth in pool"
        );

        // because of the liquidity boundaries set when adding liquidity, there is a tiny amount of eth that won't be recoverable
        // even when all token supply is sold.
        // We have tuned the ticks so that this amount is lower than 0.005 ether
        uint256 nonRecoverableEth = address(poolManager).balance - poolBalanceBefore;
        assertLtDecimal(nonRecoverableEth, 0.22 ether, 18, "Non recoverable ether from pool manager is too large");
    }

    function test_unintentionalFeesGoingToTreasury() public createTestToken {
        uint256 treasuryBalanceBefore = address(treasury).balance;
        uint256 expectedGraduationFee = 0.5001 ether;

        _graduateToken();

        uint256 treasuryBalanceAfter = address(treasury).balance;
        assertLtDecimal(
            treasuryBalanceAfter - treasuryBalanceBefore,
            expectedGraduationFee,
            18,
            "Treasury got more fees than intended"
        );
    }

    /// @notice If the last buyer immediately sells after graduation, they shouldn't be at profit
    function test_arbitrageOpportunityAtGraduation(uint256 initialEthBuy) public createTestToken {
        initialEthBuy = bound(initialEthBuy, 0.01 ether, GRADUATION_THRESHOLD - 0.01 ether);

        _launchpadBuy(testToken, initialEthBuy);
        assertFalse(launchpad.getTokenState(testToken).graduated, "Token should not be graduated yet");

        uint256 sellerBalanceBefore = seller.balance;

        vm.startPrank(seller);
        uint256 ethReserves = launchpad.getTokenState(testToken).ethCollected;
        uint256 missingForGraduation = _increaseWithFees(GRADUATION_THRESHOLD - ethReserves);
        vm.deal(seller, missingForGraduation);
        launchpad.buyTokensWithExactEth{value: missingForGraduation}(testToken, 0, DEADLINE);
        vm.stopPrank();

        assertTrue(LivoToken(testToken).graduated(), "graduation should have been triggered already");

        uint256 tokenBalance = LivoToken(testToken).balanceOf(seller);
        _swapSell(seller, tokenBalance, 0, true);
        vm.stopPrank();

        uint256 sellerBalanceAfter = seller.balance;

        // if the seller sells all tokens he purchased for 0.02 eth, he should not be at profit due to trading fees
        // otherwise there is an arbitrage opportunity
        assertLtDecimal(sellerBalanceAfter, sellerBalanceBefore, 18, "Seller should not be at profit");
    }

    /// @notice test that if a swapBuy happens on a token pregraduation, this doesn't alter the graduation transaction
    function test_swapBuyBeforeGraduation_doesntAffectGraduation() public createTestToken {
        // Token is created but not graduated
        assertFalse(ILivoToken(testToken).graduated(), "Token should not be graduated");

        // Perform a large swap buy before graduation
        deal(buyer, 10 ether);
        // swaps should revert before the token is graduated
        _swapBuy(buyer, 10 ether, 0, false);

        // Graduate the token
        _graduateToken();

        // Verify that graduation was successful and pool is initialized correctly
        assertTrue(ILivoToken(testToken).graduated(), "Token should be graduated successfully");

        // Further checks can be added to verify pool state if needed
    }
}

/// @notice Concrete test contract for normal (non-tax) tokens
contract UniswapV4GraduationTests_NormalToken is UniswapV4GraduationTestsBase {
    function setUp() public override {
        super.setUp();
        // Uses default implementation (livoToken) from base
    }
}

/// @notice Concrete test contract for tax tokens
contract UniswapV4GraduationTests_TaxToken is TaxTokenUniV4BaseTests, UniswapV4GraduationTestsBase {
    function setUp() public override(TaxTokenUniV4BaseTests, BaseUniswapV4GraduationTests) {
        super.setUp();
        // Override implementation for this test suite to use tax tokens
        implementation = ILivoToken(address(taxTokenImpl));
    }

    // Use TaxTokenUniV4BaseTests implementation of _swap
    function _swap(
        address caller,
        address token,
        uint256 amountIn,
        uint256 minAmountOut,
        bool isBuy,
        bool expectSuccess
    ) internal override(BaseUniswapV4GraduationTests, TaxTokenUniV4BaseTests) {
        TaxTokenUniV4BaseTests._swap(caller, token, amountIn, minAmountOut, isBuy, expectSuccess);
    }

    /// @notice Override createTestToken modifier to provide tokenCalldata for tax configuration
    modifier createTestToken() override {
        bytes memory tokenCalldata = taxTokenImpl.encodeTokenCalldata(DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);

        vm.prank(creator);
        testToken = launchpad.createToken("TestToken", "TEST", address(implementation), address(bondingCurve), address(graduator), creator, "0x003", tokenCalldata);
        _;
    }

    /// @notice test that after graduating, all the eth in the liquidity pool can be extracted again by selling all token supply
    /// @dev in this test we treat the dead address as if it was a normal address that can sell tokens, just for the math exercise
    function test_sellingFromUniv4AfterGraduation_sellFullSupply_whereIsTheEth() public override createTestToken {
        uint256 poolBalanceBefore = address(poolManager).balance;
        _graduateToken();

        uint256 buyerBalanceBefore = LivoToken(testToken).balanceOf(buyer);
        uint256 creatorBalanceBefore = LivoToken(testToken).balanceOf(creator);
        uint256 poolTokenBalanceBefore = LivoToken(testToken).balanceOf(address(poolManager));

        assertApproxEqAbs(
            buyerBalanceBefore + creatorBalanceBefore + poolTokenBalanceBefore,
            0.0001 ether,
            TOTAL_SUPPLY,
            "some supply is missing"
        );

        uint256 poolBalanceAfterGraduation = address(poolManager).balance;
        uint256 buyerEtherBefore = buyer.balance;
        uint256 creatorEtherBefore = creator.balance;

        // ~190M tokens are in liquidity, 10M owned by the dead address, and ~800M owned by `buyer`
        // when selling everything back, almost all eth deposited as liquidity should be recovered

        // sell the full balance of the buyer, who has most of the supply
        _swapSell(buyer, buyerBalanceBefore, 6 ether, true);

        uint256 ethRecoveredByBuyer = buyer.balance - buyerEtherBefore;
        uint256 ethRecoveredByCreator = creator.balance - creatorEtherBefore;
        uint256 ethLeavingFromThePoolManager = poolBalanceAfterGraduation - address(poolManager).balance;
        uint256 wethFeesEarnedByCreator = WETH.balanceOf(creator);

        // check that the eth collected by buyer and seller matches the eth left the pool
        assertEq(
            ethRecoveredByBuyer + ethRecoveredByCreator + wethFeesEarnedByCreator,
            ethLeavingFromThePoolManager,
            "eth recovered by buyer and creator should match eth in pool"
        );

        // because of the liquidity boundaries set when adding liquidity, there is a tiny amount of eth that won't be recoverable
        // even when all token supply is sold.
        // We have tuned the ticks so that this amount is lower than 0.005 ether
        uint256 nonRecoverableEth = address(poolManager).balance - poolBalanceBefore;
        assertLtDecimal(nonRecoverableEth, 0.22 ether, 18, "Non recoverable ether from pool manager is too large");
    }
}
