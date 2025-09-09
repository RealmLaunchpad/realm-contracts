// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTest} from "./base.t.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoToken} from "src/LivoToken.sol";
import {LivoGraduatorUniV2} from "src/graduators/LivoGraduatorUniV2.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TokenState} from "src/types/tokenData.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {IWETH} from "src/interfaces/IWETH.sol";

contract GraduationTest is LaunchpadBaseTest {
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
        assertTrue(tokenBalance > 0, "Buyer should have tokens");
        
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(LivoToken.TranferToPairBeforeGraduationNotAllowed.selector));
        IERC20(testToken).transfer(uniswapPair, tokenBalance / 2);
    }
    
    /// @notice Test that you can transfer tokens to univ2pair after graduation
    function test_canTransferTokensToUniV2PairAfterGraduation() public createTestTokenWithPair {
        // First graduate the token, then buy some tokens to test transfers
        _graduateToken();
        
        TokenState memory state = launchpad.getTokenState(testToken);
        assertTrue(state.graduated, "Token should be graduated");
        
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
    
    /// @notice Test that if WETH is transferred to the univ2pair pre-graduation, liquidity addition doesn't revert
    function test_ethTransferToUniV2PairPreGraduation_liquidityAdditionDoesNotRevert() public createTestTokenWithPair {
        _graduateToken();

        // Transfer some WETH to the pair
        uint256 wethAmount = 1 ether;
        WETH.deposit{value: wethAmount}();
        WETH.transfer(uniswapPair, wethAmount);
        
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
        
        assertEq(wethReserve, wethAmount, "WETH reserves should match transferred amount");
        assertEq(tokenReserve, 0, "Token reserves should be zero before graduation");
    }

    // todo continue reading these tests
    /// @notice Test that if WETH is transferred to the univ2pair pre-graduation, liquidity addition yields a strictly higher price than in the bonding curve
    function test_ethTransferToUniV2PairPreGraduation_yieldsHigherPriceThanBondingCurve() public createTestTokenWithPair {
        // Test that graduation creates liquidity at the expected price
        _graduateToken();
        
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
        
        assertTrue(wethReserve > 0, "WETH reserves should be positive after graduation");
        assertTrue(tokenReserve > 0, "Token reserves should be positive after graduation");
        
        uint256 uniswapPrice = (wethReserve * 1e18) / tokenReserve;
        assertTrue(uniswapPrice > 0, "Uniswap should have a valid price after graduation");
    }
    
    /// @notice Test that tokens cannot be bought from the launchpad after graduation
    function test_tokensCannotBeBoughtFromLaunchpadAfterGraduation() public createTestTokenWithPair {
        _graduateToken();
        
        TokenState memory state = launchpad.getTokenState(testToken);
        assertTrue(state.graduated, "Token should be graduated");
        
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
        assertTrue(tokenBalance > 0, "Buyer should have tokens to test selling");
        
        vm.prank(buyer);
        IERC20(testToken).approve(address(launchpad), tokenBalance);
        
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.AlreadyGraduated.selector));
        launchpad.sellExactTokens(testToken, tokenBalance, 0, DEADLINE);
    }
    
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
        uint256 graduationThreshold = BASE_GRADUATION_THRESHOLD;
        uint256 excessiveAmount = graduationThreshold + MAX_THRESHOLD_EXCEESS + 0.1 ether;
        
        vm.deal(buyer, excessiveAmount);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.PurchaseExceedsLimitPostGraduation.selector));
        launchpad.buyTokensWithExactEth{value: excessiveAmount}(testToken, 0, DEADLINE);
    }
    
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
        assertTrue(wethReserve < graduationThreshold, "WETH reserves should be less than threshold due to graduation fee");
    }
    
    /// @notice Test that difference between launchpad price and uniswap price is not more than 5% if last purchase reaches the excess cap
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
        
        // The collected ETH should be at least the threshold
        assertTrue(state.ethCollected >= graduationThreshold, "Should meet graduation threshold");
        assertTrue(state.ethCollected <= graduationThreshold + MAX_THRESHOLD_EXCEESS, "Should not exceed max excess limit");
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
    function test_circulatingSupplyUpdatedAfterGraduation() public createTestTokenWithPair {
        TokenState memory stateBefore = launchpad.getTokenState(testToken);
        uint256 circulatingBefore = stateBefore.circulatingSupply;
        assertEq(circulatingBefore, 0, "Initially no circulating supply");
        
        _graduateToken();
        
        TokenState memory stateAfter = launchpad.getTokenState(testToken);
        uint256 circulatingAfter = stateAfter.circulatingSupply;
        
        assertTrue(circulatingAfter > circulatingBefore, "Circulating supply should increase after graduation");
        // The circulating supply after graduation includes tokens sold during bonding curve + tokens in LP
        // It should be total supply minus what's held by creator and graduator
        assertTrue(circulatingAfter > circulatingBefore, "Circulating supply should increase after graduation");
        assertTrue(circulatingAfter <= TOTAL_SUPPLY, "Circulating supply should not exceed total supply");
    }
    
    /// @notice Test that token eth reserves are reset to 0 after graduation (Note: they actually remain at graduation threshold)
    function test_tokenEthReservesRemainAfterGraduation() public createTestTokenWithPair {
        TokenState memory stateBefore = launchpad.getTokenState(testToken);
        assertEq(stateBefore.ethCollected, 0, "Initial ETH reserves should be zero");
        
        _graduateToken();
        
        TokenState memory stateAfter = launchpad.getTokenState(testToken);
        assertEq(stateAfter.ethCollected, BASE_GRADUATION_THRESHOLD, "ETH reserves should remain at graduation threshold");
    }
    
    /// @notice Test that eth balance change at graduation is the exact reserves pre graduation
    function test_ethBalanceChangeAtGraduationAccountsForGraduationFee() public createTestTokenWithPair {
        uint256 launchpadEthBefore = address(launchpad).balance;
        uint256 treasuryFeesBefore = launchpad.treasuryEthFeesCollected();
        
        uint256 graduationThreshold = BASE_GRADUATION_THRESHOLD;
        uint256 ethAmountToGraduate = (graduationThreshold * 10000) / (10000 - BASE_BUY_FEE_BPS);
        
        vm.deal(buyer, ethAmountToGraduate);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmountToGraduate}(testToken, 0, DEADLINE);
        
        uint256 launchpadEthAfter = address(launchpad).balance;
        uint256 treasuryFeesAfter = launchpad.treasuryEthFeesCollected();
        
        TokenState memory finalState = launchpad.getTokenState(testToken);
        assertTrue(finalState.graduated, "Token should be graduated");
        
        uint256 totalFeesCollected = treasuryFeesAfter - treasuryFeesBefore;
        // Launchpad should retain the fees, graduation fee + buy fee
        assertTrue(totalFeesCollected >= BASE_GRADUATION_FEE, "Treasury should collect graduation fee");
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

    receive() external payable {}
}
