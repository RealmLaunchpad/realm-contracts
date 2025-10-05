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

/// @notice Tests for Uniswap V4 graduator functionality
contract UniswapV4GraduationTests is LaunchpadBaseTestsWithUniv4Graduator {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    uint256 constant DEADLINE = type(uint256).max;
    uint256 MAX_THRESHOLD_EXCESS;

    IPoolManager poolManager;

    // these are copied from the graduator ... // review if they are modified in the graduator this tests may break
    uint24 constant lpFee = 10000;
    int24 constant tickSpacing = 200;

    // review this is hardcoded and shoud match the contract ... // review
    uint160 constant startingPriceX96 = 401129254579132618442796085280768;

    function setUp() public override {
        super.setUp();
        poolManager = IPoolManager(poolManagerAddress);

        MAX_THRESHOLD_EXCESS = launchpad.MAX_THRESHOLD_EXCESS();
    }

    //////////////////////////////////// modifiers and utilities ///////////////////////////////

    function _getPoolKey(address tokenAddress) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(tokenAddress)),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    function _buy(uint256 value) internal {
        vm.deal(buyer, value);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: value}(testToken, 0, DEADLINE);
    }

    function _graduateToken() internal {
        uint256 graduationThreshold = BASE_GRADUATION_THRESHOLD;
        uint256 ethAmountToGraduate = (graduationThreshold * 10000) / (10000 - BASE_BUY_FEE_BPS);

        _buy(ethAmountToGraduate);
    }

    function _readSqrtX96TokenPrice() internal view returns (uint160) {
        // Check price is as expected
        PoolKey memory poolKey = _getPoolKey(testToken);
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        return sqrtPriceX96;
    }

    function _convertSqrtX96ToEthPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        // price expressed as token1/token0 == tokens per native ETH
        // price = (sqrtPriceX96 / 2^96)^2 = (sqrtPriceX96^2) / 2^192
        return (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 192;
    }

    function _convertSqrtX96ToTokenPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        // revert the sqrtprice and convert it as token price (ETH per token) with 18 decimals
        return (uint256(1e18) << 192) / (uint256(sqrtPriceX96) * uint256(sqrtPriceX96));
    }


    function _swap(uint256 amountIn, uint256 minAmountOut) internal {
        // now a purchase through uniswap v4
        vm.startPrank(buyer);
        IERC20(testToken).approve(address(permit2Address), type(uint256).max);
        IPermit2(permit2Address).approve(address(testToken), universalRouter, type(uint160).max, type(uint48).max);

        bytes[] memory params = new bytes[](3);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(testToken)),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        // First parameter: swap configuration
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,            // true if we're swapping token0 for token1 (buying tokens with eth)
                amountIn: uint128(amountIn),          // amount of tokens we're swapping
                amountOutMinimum: uint128(minAmountOut), // minimum amount we expect to receive
                hookData: bytes("")             // no hook data needed
            })
        );

        // Encode the Universal Router command
        uint256 V4_SWAP = 0x10;
        bytes memory commands = abi.encodePacked(uint8(V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

            // Encode V4Router actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        params[1] = abi.encode(key.currency0, amountIn);
        params[2] = abi.encode(key.currency1, minAmountOut);

        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, params);

        // Execute the swap
        IUniversalRouter(universalRouter).execute{value: amountIn}(commands, inputs, block.timestamp);
    }

    //////////////////////////////////// tests ///////////////////////////////

    /// @notice Test that pool is created in the pool manager at token creation
    function test_poolCreatedInPoolManagerAtTokenCreation() public createTestToken {
        PoolKey memory poolKey = _getPoolKey(testToken);
        PoolId poolId = poolKey.toId();

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        // the starting price is the graduation price, which would only be achieved at graduation
        // before that there should be no activity on this pool (token transfers are forbidden to the pool manager)
        uint256 graduationPrice = 39011306440; // wei per token
        uint256 poolSetPrice = _convertSqrtX96ToTokenPrice(sqrtPriceX96);

        assertApproxEqAbs(poolSetPrice, graduationPrice, 10, "Pool price should match graduation price. 10 wei error difference");
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
        vm.expectRevert(LivoToken.TranferToPairBeforeGraduationNotAllowed.selector);
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
        _buy(MAX_THRESHOLD_EXCESS - 0.1 ether);
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
        assertEq(
            LivoToken(testToken).balanceOf(address(graduator)),
            0,
            "there should be no tokens in the graduator after graduation"
        );
    }

    /// @notice Test that after graduation (with excess eth) there are no tokens left in the graduator or launchpad contracts
    function test_tokenBalancesAfterGraduationWithExcessAreZero() public createTestToken {
        _buy(MAX_THRESHOLD_EXCESS - 0.1 ether);
        _graduateToken();

        assertEq(
            LivoToken(testToken).balanceOf(address(launchpad)),
            0,
            "there should be no tokens in the launchpad after graduation"
        );
        assertEq(
            LivoToken(testToken).balanceOf(address(graduator)),
            0,
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
        _buy(MAX_THRESHOLD_EXCESS - 0.1 ether);
        _graduateToken();

        assertEq(address(graduator).balance, 0, "there should be no ETH in the graduator after graduation");
    }

    /// @notice Test that after graduation the creator has received exactly 1% of the supply
    function test_creatorTokenBalanceAfterExactGraduation() public createTestToken {
        assertEq(LivoToken(testToken).balanceOf(creator), 0, "creator should start with 0 tokens");
        _buy(0.1 ether);
        _graduateToken();

        assertEq(
            LivoToken(testToken).balanceOf(creator),
            TOTAL_SUPPLY / 100,
            "creator should have less than 1% of the supply"
        );
    }

    /// @notice Test that after graduation (exact eth) all the token supply is in the buyer's balance and the pool manager
    function test_poolManagerTokenBalanceAfterExactGraduation() public createTestToken {
        assertEq(LivoToken(testToken).balanceOf(address(launchpad)), TOTAL_SUPPLY, "creator should start with 0 tokens");

        _graduateToken();

        uint256 buyerBalance = LivoToken(testToken).balanceOf(buyer);
        uint256 poolManagerBalance = LivoToken(testToken).balanceOf(poolManagerAddress);
        uint256 creatorBalance = LivoToken(testToken).balanceOf(creator);
        uint256 burntSupply = LivoToken(testToken).balanceOf(address(0xdead));

        assertEq(
            buyerBalance + poolManagerBalance + creatorBalance + burntSupply,
            TOTAL_SUPPLY,
            "some tokens have disappeared"
        );
        assertLt(burntSupply, 5e18, "burned tokens exceeds 5 tokens");
        assertLt(burntSupply, TOTAL_SUPPLY / 100_000_000, "more than 0.000001% of the supply is burned");
    }

    /// @notice Test that after graduation (exact eth) the eth worth of tokens dead is negligible
    function test_negligibleEthWorthOfTokensBurnedAtExactGraduation() public createTestToken {
        _graduateToken();
        uint256 burntSupply = LivoToken(testToken).balanceOf(address(0xdead));
        // there is always some leftovers burned
        assertGt(burntSupply, 0);

        uint256 tokenPrice = _convertSqrtX96ToTokenPrice(_readSqrtX96TokenPrice());
        // console.log("token price after graduation", tokenPrice);

        // the eth worth of the burnt tokens should be negligible (less than 0.01 ETH)
        uint256 ethWorthOfBurntTokens = (burntSupply * tokenPrice) / 1e18;
        // console.log("eth worth of burnt tokens", ethWorthOfBurntTokens);
        assertLt(ethWorthOfBurntTokens, 0.000001 ether, "eth worth of burnt tokens is greater than 0.00004$");
    }

    /// @notice Test that after graduation (exact eth) all the token supply is in the buyer's balance and the pool manager
    function test_poolManagerTokenBalanceAfterExcessGraduation() public createTestToken {
        assertEq(LivoToken(testToken).balanceOf(address(launchpad)), TOTAL_SUPPLY, "creator should start with 0 tokens");
        _buy(BASE_GRADUATION_THRESHOLD - 0.01 ether);
        _buy(0.5 ether);

        uint256 buyerBalance = LivoToken(testToken).balanceOf(buyer);
        uint256 poolManagerBalance = LivoToken(testToken).balanceOf(poolManagerAddress);
        uint256 creatorBalance = LivoToken(testToken).balanceOf(creator);
        uint256 burntSupply = LivoToken(testToken).balanceOf(address(0xdead));

        assertEq(
            buyerBalance + poolManagerBalance + creatorBalance + burntSupply,
            TOTAL_SUPPLY,
            "some tokens have disappeared"
        );
        assertLt(burntSupply, 5e18, "burned tokens exceeds 5 tokens");
        assertLt(burntSupply, TOTAL_SUPPLY / 100_000_000, "more than 0.000001% of the supply is burned");
    }

    /// @notice Test that after graduation (exact eth) the eth worth of tokens dead is negligible
    function test_negligibleEthWorthOfTokensBurnedAtExcessGraduation() public createTestToken {
        assertEq(LivoToken(testToken).balanceOf(address(launchpad)), TOTAL_SUPPLY, "creator should start with 0 tokens");
        _buy(BASE_GRADUATION_THRESHOLD - 0.01 ether);
        _buy(0.5 ether);
        
        uint256 burntSupply = LivoToken(testToken).balanceOf(address(0xdead));
        // there is always some leftovers burned
        assertGt(burntSupply, 0);

        uint256 tokenPrice = _convertSqrtX96ToTokenPrice(_readSqrtX96TokenPrice());
        // console.log("token price after graduation", tokenPrice);

        // the eth worth of the burnt tokens should be negligible (less than 0.01 ETH)
        uint256 ethWorthOfBurntTokens = (burntSupply * tokenPrice) / 1e18;
        // console.log("eth worth of burnt tokens", ethWorthOfBurntTokens);
        assertLt(ethWorthOfBurntTokens, 0.000001 ether, "eth worth of burnt tokens is greater than 0.00004$");
    }


    /// @notice Test that the price given at graduation is lower than pool price in uniswapv4
    function test_priceGivenAtGraduation_smallTx_MatchesUniv4() public createTestToken {
        _buy(BASE_GRADUATION_THRESHOLD - 1);
        uint256 remainingForGraduation;
        remainingForGraduation = BASE_GRADUATION_THRESHOLD - launchpad.getTokenState(testToken).ethCollected;
        _buy(remainingForGraduation-1);
        remainingForGraduation = BASE_GRADUATION_THRESHOLD - launchpad.getTokenState(testToken).ethCollected;
        _buy(remainingForGraduation-1);
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
        assertApproxEqRel(effectivePrice, poolPrice, 0.00001e18, "Effective price at graduation should match pool price (small last tx)");
        assertGt(poolPrice, effectivePrice, "Pool price should be above effective price at graduation (small last tx)");
    }


    /// @notice Test that after exact graduation, the first purchase has a similar price than the last purchase in the bonding curve
    function test_priceGivenAtGraduation_smallTx_MatchesUniv4_Swap() public createTestToken {
        _buy(BASE_GRADUATION_THRESHOLD - 1);
        uint256 remainingForGraduation;
        remainingForGraduation = BASE_GRADUATION_THRESHOLD - launchpad.getTokenState(testToken).ethCollected;
        _buy(remainingForGraduation-1);
        remainingForGraduation = BASE_GRADUATION_THRESHOLD - launchpad.getTokenState(testToken).ethCollected;
        _buy(remainingForGraduation-1);
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
        uint256 effectivePrice = (ethSpent * 1e18) / tokensBought;
        console.log("Eth spent in last tx", ethSpent);
        console.log("Tokens bought in last tx", tokensBought);
        console.log("Effective price at graduation (eth/token)", effectivePrice);

        buyerEthBalance = buyer.balance;
        buyerTokenBalance = LivoToken(testToken).balanceOf(buyer);
        _swap(0.00001 ether, 0);
        uint256 ethSpentInSwap = buyerEthBalance - buyer.balance;
        uint256 tokensBoughtInSwap = LivoToken(testToken).balanceOf(buyer) - buyerTokenBalance;
        uint256 swapPrice = (ethSpentInSwap * 1e18) / tokensBoughtInSwap;
        console.log("Eth spent in swap", ethSpentInSwap);
        console.log("Tokens bought in swap", tokensBoughtInSwap);
        console.log("Swap price (eth/token)", swapPrice);
        
        assertApproxEqRel(effectivePrice, swapPrice, 0.0001e18, "Effective price at graduation should match swap price");
        assertGt(swapPrice, effectivePrice, "Swap price should be above effective price at graduation");
    }

    /// @notice Test that when token is graduated at graduation threshold plus MAX_THRESHOLD_EXCESS, the price purchasing in univ4 is above the price in the bonding curve
    function test_priceGivenAtGraduationMatchesUniv4_largeLastPurchase_matchesSwap() public createTestToken {
        _buy(BASE_GRADUATION_THRESHOLD - 0.5 ether);
        assertFalse(launchpad.getTokenState(testToken).graduated, "Token should not be graduated yet");

        // if a crazy user buys the remaining tokens, will get a hell of a price impact ...
        deal(buyer, 10 ether);
        uint256 buyerEthBalance = buyer.balance;
        uint256 buyerTokenBalance = LivoToken(testToken).balanceOf(buyer);
        console.log("Buyer eth balance before last tx", buyerEthBalance);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
        assertTrue(launchpad.getTokenState(testToken).graduated, "Token should be graduated now");

        uint256 ethSpent = buyerEthBalance - buyer.balance;
        uint256 tokensBought = LivoToken(testToken).balanceOf(buyer) - buyerTokenBalance;
        uint256 effectivePrice = (ethSpent * 1e18) / tokensBought;
        console.log("Eth spent in last tx", ethSpent);
        console.log("Tokens bought in last tx", tokensBought);
        console.log("Effective price at graduation (eth/token)", effectivePrice);

        // now we do a similar purchase in uniswapv4, to account for the price impact
        buyerEthBalance = buyer.balance;
        buyerTokenBalance = LivoToken(testToken).balanceOf(buyer);
        _swap(1 ether, 0);
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

    // /// @notice Test that a large liquidity position involving only ETH before graduation doesn't affect graduation
    // function test_largeEthPositionDoesntAffectGraduation() public createTestToken {
    //     // In Uniswap v4, we can't easily create ETH-only positions in the pool manager.
    //     // The key point is that other pools or positions shouldn't affect this token's graduation.
    //     // We verify this by ensuring graduation works normally.

    //     _graduateToken();

    //     TokenState memory state = launchpad.getTokenState(testToken);
    //     assertTrue(state.graduated, "Token should be graduated");
    // }

    // /// @notice Test that a large liquidity position involving only ETH before graduation doesn't affect the desired price after graduation
    // function test_largeEthPositionDoesntAffectGraduationPrice() public createTestToken {
    //     // The graduation price should be determined solely by the token's own liquidity,
    //     // not by any other pools or positions that might exist in the pool manager.

    //     _graduateToken();

    //     // Check price is as expected
    //     PoolKey memory poolKey = _getPoolKey(testToken);
    //     PoolId poolId = poolKey.toId();
    //     (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

    //     // Price should be at or above starting price
    //     assertGe(sqrtPriceX96, startingPriceX96, "Pool price should be at or above starting price");
    // }

    // /// @notice Test that a liquidity position involving tokens cannot be set before graduation
    // function test_liquidityPositionWithTokensCannotBeSetBeforeGraduation() public createTestToken {
    //     LivoToken token = LivoToken(testToken);

    //     // Buy some tokens first
    //     vm.prank(buyer);
    //     launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);

    //     uint256 buyerBalance = token.balanceOf(buyer);

    //     revert("Not Implemented properly! Try creating an actual liquidity position here");
    // }

    // /// @notice Test that a liquidity position involving ETH can be set before graduation
    // function test_liquidityPositionWithEthCanBeSetBeforeGraduation() public createTestToken {
    //     revert("Not Implemented properly! Try creating an actual liquidity position here");
    // }

    // /// @notice Test that a liquidity position involving ETH doesn't prevent graduation
    // function test_ethLiquidityPositionDoesntPreventGraduation() public createTestToken {
    //     // The main point of this test is that graduation should work normally
    //     // even if there are other pools or positions in the pool manager.
    //     // We test this by simply verifying graduation works as expected.

    //     _graduateToken();

    //     TokenState memory state = launchpad.getTokenState(testToken);
    //     assertTrue(state.graduated, "Token should be graduated");
    // }

    // function test_buyingFromUniv4BeforeGraduation_reverts() public createTestToken {
    //     revert("Not implemented");
    // }

    // function test_sellingFromUniv4BeforeGraduation_reverts() public createTestToken {
    //     revert("Not implemented");
    // }

    ///////////////////////////////////////// NORMAL UNIV4 ACTIVITY POST GRADUATION ////////////////////////////////////

    // function test_buyingFromUniv4AfterGraduation_succeeds() public createTestToken {
    //     revert("Not implemented");
    // }

    // function test_sellingFromUniv4AfterGraduation_succeeds() public createTestToken {
    //     revert("Not implemented");
    // }

    // function test_sellingFromUniv4AfterGraduation_priceCanDipBelowGraduation() public createTestToken {
    //     revert("Not implemented");
    // }
}
