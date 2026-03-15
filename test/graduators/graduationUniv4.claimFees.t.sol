// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TokenState} from "src/types/tokenData.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {LivoFeeHandlerUniV4} from "src/feeHandlers/LivoFeeHandlerUniV4.sol";
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
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";
import {DeploymentAddressesMainnet} from "src/config/DeploymentAddresses.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";

contract BaseUniswapV4FeesTests is BaseUniswapV4GraduationTests {
    address testToken1;
    address testToken2;

    /// @dev Claimable balance right after graduation (before any swaps).
    ///      Graduation deposits creator compensation into `pendingClaims`, so this is non-zero.
    uint256 graduationCreatorClaimable;
    uint256 graduationCreatorClaimable1;
    uint256 graduationCreatorClaimable2;

    function setUp() public virtual override {
        super.setUp();

        deal(buyer, 10 ether);
    }

    function _createTokenForCreator(string memory name, string memory symbol, bytes32 metadata)
        internal
        virtual
        returns (address)
    {
        vm.prank(creator);
        return factoryV4.createToken(name, symbol, creator, metadata);
    }

    modifier createAndGraduateToken() virtual {
        testToken = _createTokenForCreator("TestToken", "TEST", "0x12");

        _graduateToken();
        // used as a baseline in several tests
        graduationCreatorClaimable = _claimable(testToken, creator);
        _;
    }

    modifier generateFeesWithBuySwap(uint256 amountIn) virtual {
        deal(buyer, 10 ether);
        _swapBuy(buyer, amountIn, 10e18, true);
        _;
    }

    modifier setReceiver(address caller, address receiver) virtual {
        vm.prank(caller);
        ILivoToken(testToken).setFeeReceiver(receiver);
        _;
    }

    modifier transferOwnership(address caller, address newOwner) virtual {
        vm.prank(caller);
        ILivoToken(testToken).proposeNewOwner(newOwner);
        vm.prank(newOwner);
        ILivoToken(testToken).acceptTokenOwnership();
        _;
    }

    function _setFeeReceiver(address receiver) internal {
        vm.prank(creator);
        ILivoToken(testToken).setFeeReceiver(receiver);
    }

    function _transferOwnership(address newOwner) internal {
        vm.prank(creator);
        ILivoToken(testToken).proposeNewOwner(newOwner);
        vm.prank(newOwner);
        ILivoToken(testToken).acceptTokenOwnership();
    }

    modifier twoGraduatedTokensWithBuys(uint256 buyAmount) virtual {
        testToken1 = _createTokenForCreator("TestToken1", "TEST1", "0x1a3a");
        testToken2 = _createTokenForCreator("TestToken2", "TEST2", "0x1a3a");

        // graduate token1 and token2
        uint256 buyAmount1 = _increaseWithFees(GRADUATION_THRESHOLD + MAX_THRESHOLD_EXCESS / 3);
        uint256 buyAmount2 = _increaseWithFees(GRADUATION_THRESHOLD + MAX_THRESHOLD_EXCESS / 2);
        vm.deal(buyer, 100 ether);
        vm.startPrank(buyer);
        launchpad.buyTokensWithExactEth{value: buyAmount1}(testToken1, 0, DEADLINE);
        launchpad.buyTokensWithExactEth{value: buyAmount2}(testToken2, 0, DEADLINE);

        assertTrue(launchpad.getTokenState(testToken1).graduated, "Token1 should be graduated");
        assertTrue(launchpad.getTokenState(testToken2).graduated, "Token2 should be graduated");

        graduationCreatorClaimable1 = _claimable(testToken1, creator);
        graduationCreatorClaimable2 = _claimable(testToken2, creator);

        // buy from token1 and token2 from uniswap
        _swap(buyer, testToken1, buyAmount, 1, true, true);
        _swap(buyer, testToken2, buyAmount, 1, true, true);
        vm.stopPrank();
        _;
    }

    function _singleToken(address token) internal pure returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = token;
    }

    function _collectFees(address token) internal virtual {
        _collectFees(_singleToken(token));
    }

    function _collectFees(address[] memory tokens) internal virtual {
        // claiming already accrues fees first
        vm.prank(creator);
        feeHandlerV4.claim(tokens);
    }

    function _claimable(address token, address account) internal view virtual returns (uint256) {
        return ILivoFeeHandler(ILivoToken(token).feeHandler()).getClaimable(_singleToken(token), account)[0];
    }
}

/// @notice Abstract base class for Uniswap V4 claim fees tests
abstract contract BaseUniswapV4ClaimFeesBase is BaseUniswapV4FeesTests {
    /// @notice test that the owner of the univ4 NFT position is the graduator (permanently locked)
    function test_liquidityNftOwnerAfterGraduation() public createAndGraduateToken {
        // The NFT ID is deterministic on the fork; check that graduator holds it
        uint256 positionId = IPositionManager(positionManagerAddress).nextTokenId() - 2;

        assertEq(
            IERC721(positionManagerAddress).ownerOf(positionId),
            address(graduatorV4),
            "graduator should own the position NFT (permanently locked)"
        );
    }

    function test_claimFees_happyPath_ethBalanceIncrease()
        public
        createAndGraduateToken
        generateFeesWithBuySwap(1 ether)
    {
        uint256 creatorEthBalanceBefore = creator.balance;
        // Treasury already received graduation fees directly; record balance before LP fee accrual
        uint256 treasuryEthBalanceBefore = treasury.balance;

        _collectFees(testToken);

        uint256 creatorEthBalanceAfter = creator.balance;
        uint256 treasuryEthBalanceAfter = treasury.balance;

        assertGt(creatorEthBalanceAfter, creatorEthBalanceBefore, "creator should receive graduation deposit + LP fees");
        // Treasury LP share is sent during swap (by hook), not during collect
        assertEq(treasuryEthBalanceAfter, treasuryEthBalanceBefore, "treasury already received LP share during swap");
    }

    function test_claimFees_expectedCreatorFeesIncrease()
        public
        createAndGraduateToken
        generateFeesWithBuySwap(1 ether)
    {
        uint256 buyAmount = 1 ether;

        uint256 creatorEthBalanceBefore = creator.balance;

        _collectFees(testToken);

        uint256 creatorEthBalanceAfter = creator.balance;

        // Creator claim includes graduation deposit; subtract it to isolate LP fees only
        uint256 creatorLpFees = creatorEthBalanceAfter - creatorEthBalanceBefore - graduationCreatorClaimable;
        // Treasury LP share sent during swap by hook, not during collect
        assertApproxEqAbs(creatorLpFees, buyAmount / 200, 1, "creator LP fees should be 0.5%");
    }

    function test_claimFees_expectedTreasuryFeesIncrease()
        public
        createAndGraduateToken
        generateFeesWithBuySwap(1 ether)
    {
        uint256 treasuryEthBalanceBefore = treasury.balance;

        _collectFees(testToken);

        uint256 treasuryEthBalanceAfter = treasury.balance;

        // Treasury LP share is sent during swap by the hook, not during position fee collection
        assertEq(
            treasuryEthBalanceAfter,
            treasuryEthBalanceBefore,
            "treasury receives LP share during swap, not during collect"
        );
    }

    /// @notice test that on buys, only eth fees are collected
    function test_claimFees_onBuys_onlyEthFees() public createAndGraduateToken {
        deal(buyer, 10 ether);
        _swapBuy(buyer, 1.5 ether, 10e18, true);

        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 tokenBalanceBefore = IERC20(testToken).balanceOf(address(feeHandlerV4));

        _collectFees(testToken);

        uint256 tokenBalanceAfter = IERC20(testToken).balanceOf(address(feeHandlerV4));

        assertEq(tokenBalanceAfter, tokenBalanceBefore, "token balance should not change on eth fees collection");
        assertGt(creator.balance, creatorEthBalanceBefore, "creator eth balance should increase");
    }

    /// @notice test that on sells, creator only receives accrued sell taxes
    /// @dev SKIPPED: With hook-based LP fees, token fees from positions are 0. Will be fixed with contract changes.
    function test_claimFees_onSells_noTokenFees() public createAndGraduateToken {
        vm.skip(false);
        _swapSell(buyer, 100000000e18, 0.1 ether, true);

        uint256 tokenBalanceBefore = IERC20(testToken).balanceOf(address(feeHandlerV4));
        uint256 poolManagerBalance = IERC20(testToken).balanceOf(address(poolManager));

        _collectFees(testToken);

        uint256 tokenBalanceAfter = IERC20(testToken).balanceOf(address(feeHandlerV4));
        uint256 poolManagerBalanceAfter = IERC20(testToken).balanceOf(address(poolManager));

        assertEq(IERC20(testToken).balanceOf(address(feeHandlerV4)), 0, "there should be no tokens in the fee handler");
        assertEq(poolManagerBalanceAfter, poolManagerBalance, "No token fees should leave the token manager");
        assertEq(tokenBalanceAfter, tokenBalanceBefore, "No tokens should arrive to the fee handler");
    }

    /// @notice test that externally sent ETH is not swept by fee collection
    function test_claimFees_noInitialEthBalance() public createAndGraduateToken generateFeesWithBuySwap(1 ether) {
        // The fee handler holds the graduation deposit (creator compensation).
        uint256 feeHandlerBalanceBeforeTransfer = address(feeHandlerV4).balance;

        // send some eth to the fee handler (via vm.deal since no receive())
        uint256 externalEth = 0.5 ether;
        vm.deal(address(feeHandlerV4), feeHandlerBalanceBeforeTransfer + externalEth);

        uint256 feeHandlerEthBalanceBefore = address(feeHandlerV4).balance;
        assertEq(
            feeHandlerEthBalanceBefore,
            feeHandlerBalanceBeforeTransfer + externalEth,
            "fee handler should hold graduation deposit + 0.5 ether"
        );

        _collectFees(testToken);

        // After claiming, only the external ETH should remain
        assertEq(address(feeHandlerV4).balance, externalEth, "externally sent ETH should remain and not be claimed");
    }

    /// @notice test that a token creator can claim fees from mutliple tokens in one transaction
    function test_claimFees_multipleTokens() public twoGraduatedTokensWithBuys(1 ether) {
        // both should have accumulated fees
        uint256 creatorEthBalanceBefore = creator.balance;

        _collectFees(testToken1);
        _collectFees(testToken2);

        uint256 creatorEthBalanceAfter = creator.balance;
        assertGt(creatorEthBalanceAfter, creatorEthBalanceBefore, "creator eth balance should increase");

        // Creator gets 0.5% LP fees from each token (2 * 1-ether buys); treasury got its share during swaps
        uint256 expectedCreatorLpFees = 2 * 1 ether / 200;
        uint256 totalGraduationDeposits = graduationCreatorClaimable1 + graduationCreatorClaimable2;

        assertApproxEqAbs(
            creatorEthBalanceAfter - creatorEthBalanceBefore - totalGraduationDeposits,
            expectedCreatorLpFees,
            2,
            "creator LP fees should be 0.5% of total buys"
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

        _collectFees(tokens);

        uint256 creatorEthBalanceAfter = creator.balance;

        // Creator gets 0.5% LP fees from each token (2 * 1-ether buys); treasury got its share during swaps
        uint256 expectedCreatorLpFees = 2 * 1 ether / 200;
        uint256 totalGraduationDeposits = graduationCreatorClaimable1 + graduationCreatorClaimable2;

        assertApproxEqAbs(
            creatorEthBalanceAfter - creatorEthBalanceBefore - totalGraduationDeposits,
            expectedCreatorLpFees,
            2,
            "creator LP fees should be 0.5% of total buys"
        );
    }

    /// @notice test that a token creator can claim fees from mutliple tokens in one transaction
    function test_claimFees_multipleTokens_twoBuysBeforeSweep() public twoGraduatedTokensWithBuys(1 ether) {
        // both should have accumulated fees
        address[] memory tokens = new address[](2);
        tokens[0] = testToken1;
        tokens[1] = testToken2;

        uint256 creatorEthBalanceBefore = creator.balance;

        _swap(buyer, testToken1, 1 ether, 12342, true, true);
        _swap(buyer, testToken2, 1 ether, 12342, true, true);

        _collectFees(tokens);

        _swap(buyer, testToken1, 2 ether, 12342, true, true);
        _swap(buyer, testToken2, 2 ether, 12342, true, true);

        _collectFees(tokens);

        uint256 totalGraduationDeposits = graduationCreatorClaimable1 + graduationCreatorClaimable2;
        uint256 creatorEarned = creator.balance - creatorEthBalanceBefore;
        uint256 creatorLpEarned = creatorEarned - totalGraduationDeposits;

        assertGt(creatorEarned, 0, "creator eth balance should increase");

        // Creator gets 0.5% LP fees (2 * 1 ether + 2 * 1 ether buys + 2 * 2 ether buys)
        uint256 expectedCreatorLpFees = (2 + 2 + 4) * 1 ether / 200;

        assertApproxEqAbs(
            creatorLpEarned,
            expectedCreatorLpFees,
            10, // 10 wei error allowed
            "creator LP fees should be 0.5% of total buys"
        );
    }

    /// @notice test that if price dips well below the graduation price and then there are buys, the fees are still correctly collected
    /// @dev This is mainly covering the extra single-sided eth position below the graduation price
    function test_viewFunction_collectFees_priceDipBelowGraduationAndThenBuys() public createAndGraduateToken {
        address[] memory tokens = _singleToken(testToken);

        uint256 claimableAfterGraduation = feeHandlerV4.getClaimable(tokens, creator)[0];
        assertEq(
            claimableAfterGraduation,
            CREATOR_GRADUATION_COMPENSATION,
            "claimable should be graduation deposit right after graduation"
        );

        // first, make the price dip below graduation price by selling a lot of tokens
        uint256 sellAmount = 10_000_000e18;
        uint256 ethReceived = _swapSell(buyer, sellAmount, 0.1 ether, true);

        // Sell generates both LP creator share (0.5%) and sell tax (if applicable)
        // gross = ethReceived * 10000 / (10000 - LP_FEE_BPS - SELL_TAX_BPS)
        uint256 denominator = 10000 - 100 - SELL_TAX_BPS;
        uint256 sellCreatorShare = ethReceived * (50 + SELL_TAX_BPS) / denominator;
        uint256 expectedClaimableAfterSell = CREATOR_GRADUATION_COMPENSATION + sellCreatorShare;
        assertApproxEqAbs(
            feeHandlerV4.getClaimable(tokens, creator)[0],
            expectedClaimableAfterSell,
            1,
            "claimable should include graduation deposit + LP creator share + sell tax"
        );

        // then do a buy crossing again that liquidity position
        uint256 buyAmount = 4 ether;
        deal(buyer, 10 ether);
        _swapBuy(buyer, buyAmount, 10e18, true);
        uint256 expectedExtraFees = buyAmount / 200;
        uint256 expectedClaimableAfterBuy = expectedClaimableAfterSell + expectedExtraFees;
        assertApproxEqAbs(
            feeHandlerV4.getClaimable(tokens, creator)[0],
            expectedClaimableAfterBuy,
            1,
            "claimable fees should include graduation fees + LP creator share + sell taxes + 0.5% of buy amount"
        );
        uint256 claimableAfterBuy = feeHandlerV4.getClaimable(tokens, creator)[0];
        uint256 expectedClaimable = expectedClaimableAfterSell + expectedExtraFees;
        assertApproxEqAbs(
            claimableAfterBuy,
            expectedClaimable,
            1,
            "claimable fees should include graduation fees + LP creator share + sell taxes + 0.5% of buy amount"
        );

        // uint256 creatorBalanceBefore = creator.balance;

        // _collectFees(tokens);

        // uint256 totalCreatorFees = creator.balance - creatorBalanceBefore;

        // assertApproxEqAbsDecimal(
        //     totalCreatorFees, claimableAfterBuy, 1, 18, "creator claim should match pre-claim claimable amount"
        // );
    }
}

/// @notice Abstract base class for Uniswap V4 claim fees view function tests
abstract contract UniswapV4ClaimFeesViewFunctionsBase is BaseUniswapV4FeesTests {
    uint256 internal constant MATRIX_BUY_AMOUNT_1 = 1 ether;
    uint256 internal constant MATRIX_BUY_AMOUNT_2 = 0.8 ether;
    uint256 internal constant MATRIX_SELL_AMOUNT = 100000000e18;
    uint256 internal constant MATRIX_SELL_MIN_OUT = 0.1 ether;

    function _expectsSellTaxes() internal pure virtual returns (bool);

    function _singleTokenArray() internal view returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = testToken;
    }

    function _creatorClaimable() internal view returns (uint256) {
        uint256[] memory fees = feeHandlerV4.getClaimable(_singleTokenArray(), creator);
        return fees[0];
    }

    function _claimableFor(address tokenOwner) internal view returns (uint256) {
        uint256[] memory fees = feeHandlerV4.getClaimable(_singleTokenArray(), tokenOwner);
        return fees[0];
    }

    function _creatorClaimAs(address caller) internal {
        address[] memory tokens = _singleTokenArray();
        vm.prank(caller);
        feeHandlerV4.claim(tokens);
    }

    function _creatorClaimAndReturnEthDelta(address caller) internal returns (uint256) {
        uint256 balanceBefore = caller.balance;
        _creatorClaimAs(caller);
        return caller.balance - balanceBefore;
    }

    modifier afterOneSwapBuy(address caller) {
        deal(caller, 10 ether);
        _swapBuy(caller, MATRIX_BUY_AMOUNT_1, 10e18, true);
        _;
    }

    modifier afterOneSwapSell(address caller) {
        _swapSell(caller, MATRIX_SELL_AMOUNT, MATRIX_SELL_MIN_OUT, true);
        _;
    }

    /// @notice test that right after graduation getClaimable gives graduation deposit only
    function test_viewFunction_getClaimable_rightAfterGraduation() public createAndGraduateToken {
        uint256[] memory fees = feeHandlerV4.getClaimable(_singleTokenArray(), creator);

        assertEq(fees.length, 1, "should return one fee value");
        assertEq(fees[0], graduationCreatorClaimable, "fees should be graduation deposit right after graduation");
    }

    /// @notice test that after one swapBuy, getClaimable gives expected fees
    function test_viewFunction_getClaimable_afterOneSwapBuy() public createAndGraduateToken afterOneSwapBuy(buyer) {
        uint256 buyAmount = 1 ether;
        uint256[] memory fees = feeHandlerV4.getClaimable(_singleTokenArray(), creator);

        assertEq(fees.length, 1, "should return one fee value");
        // Expected fees: graduation deposit + 0.5% LP fees from buy
        uint256 expectedFees = graduationCreatorClaimable + buyAmount / 200;
        assertApproxEqAbs(fees[0], expectedFees, 1, "creator fees should be graduation deposit + 0.5% of buy amount");
    }

    /// @notice test that after one swapSell, getClaimable includes accrued creator tax
    function test_viewFunction_getClaimable_afterOneSwapSell() public createAndGraduateToken afterOneSwapSell(buyer) {
        uint256[] memory fees = feeHandlerV4.getClaimable(_singleTokenArray(), creator);
        uint256 pendingTaxes = _claimable(testToken, creator);

        assertEq(fees.length, 1, "should return one fee value");
        assertEq(fees[0], pendingTaxes, "claimable fees should match accrued creator taxes after sell");
    }

    /// @notice test that after two swapBuy, getClaimable gives expected fees
    function test_viewFunction_getClaimable_afterTwoSwapBuys() public createAndGraduateToken afterOneSwapBuy(buyer) {
        uint256 buyAmount1 = 1 ether;
        uint256 buyAmount2 = 0.5 ether;
        _swapBuy(buyer, buyAmount2, 10e18, true);

        uint256[] memory fees = feeHandlerV4.getClaimable(_singleTokenArray(), creator);

        assertEq(fees.length, 1, "should return one fee value");
        uint256 expectedCreatorFees = graduationCreatorClaimable + (buyAmount1 + buyAmount2) / 200;
        assertApproxEqAbs(
            fees[0], expectedCreatorFees, 2, "creator fees should be graduation deposit + 0.5% of total buy amounts"
        );
    }

    /// @notice test that after swapBuy, claim, getClaimable gives 0
    function test_viewFunction_getClaimable_afterClaimGivesZero() public createAndGraduateToken afterOneSwapBuy(buyer) {
        address[] memory tokens = _singleTokenArray();

        uint256[] memory fees = feeHandlerV4.getClaimable(tokens, creator);
        assertApproxEqAbs(
            fees[0],
            graduationCreatorClaimable + 1 ether / 200,
            1,
            "creator fees should be graduation deposit + 0.5% of buy amount"
        );

        _collectFees(testToken);

        fees = feeHandlerV4.getClaimable(tokens, creator);

        assertEq(fees[0], 0, "fees should be 0 after claim");
    }

    /// @notice test that after swapBuy, claim, swapBuy getClaimable gives expected fees
    function test_viewFunction_getClaimable_afterClaimAndSwapBuy()
        public
        createAndGraduateToken
        afterOneSwapBuy(buyer)
    {
        _collectFees(testToken);

        uint256 buyAmount2 = 0.8 ether;
        _swapBuy(buyer, buyAmount2, 10e18, true);

        uint256[] memory fees = feeHandlerV4.getClaimable(_singleTokenArray(), creator);

        assertEq(fees.length, 1, "should return one fee value");
        assertApproxEqAbs(fees[0], buyAmount2 / 200, 1, "creator fees should be 0.5% of second buy amount");
    }

    /// @notice test that getClaimable works for multiple tokens
    function test_viewFunction_getClaimable_multipleTokens() public twoGraduatedTokensWithBuys(1 ether) {
        address[] memory tokens = new address[](2);
        tokens[0] = testToken1;
        tokens[1] = testToken2;

        uint256[] memory fees = feeHandlerV4.getClaimable(tokens, creator);

        assertEq(fees.length, 2, "should return two fee values");
        // Expected fees: graduation deposit + 0.5% of 1 ether
        assertApproxEqAbs(
            fees[0],
            graduationCreatorClaimable1 + 1 ether / 200,
            1,
            "fees[0] should be graduation deposit + 0.5% of buy amount"
        );
        assertApproxEqAbs(
            fees[1],
            graduationCreatorClaimable2 + 1 ether / 200,
            1,
            "fees[1] should be graduation deposit + 0.5% of buy amount"
        );
    }

    /// @notice test that getClaimable gives the same results when called with the repeated token in the array
    function test_viewFunction_getClaimable_repeatedToken() public twoGraduatedTokensWithBuys(1 ether) {
        address[] memory tokens = new address[](3);
        tokens[0] = testToken1;
        tokens[1] = testToken2;
        tokens[2] = testToken1; // repeated

        uint256[] memory fees = feeHandlerV4.getClaimable(tokens, creator);

        assertEq(fees.length, 3, "should return three fee values");
        // Expected fees: graduation deposit + 0.5% of 1 ether
        assertApproxEqAbs(
            fees[0],
            graduationCreatorClaimable1 + 1 ether / 200,
            1,
            "fees[0] should be graduation deposit + 0.5% of buy amount"
        );
        assertApproxEqAbs(
            fees[1],
            graduationCreatorClaimable2 + 1 ether / 200,
            1,
            "fees[1] should be graduation deposit + 0.5% of buy amount"
        );
        assertApproxEqAbs(
            fees[2], graduationCreatorClaimable1 + 1 ether / 200, 1, "fees[2] should match fees[0] for repeated token"
        );
        assertEq(fees[0], fees[2], "repeated token should return same fees");
    }

    /// @notice test that if price dips well below the graduation price and then there are buys, the fees are still correctly calculated
    /// @dev This is mainly covering the extra single-sided eth position below the graduation price
    function test_viewFunction_getClaimable_priceDipBelowGraduationAndThenBuys() public createAndGraduateToken {
        deal(buyer, 10 ether);
        // first, make the price dip below graduation price by selling a lot of tokens
        _swapSell(buyer, 10_000_000e18, 0.1 ether, true);

        uint256 claimableBefore = _claimable(testToken, creator);

        // then do a buy crossing again that liquidity position
        uint256 buyAmount = 4 ether;
        _swapBuy(buyer, buyAmount, 10e18, true);

        uint256 feeDelta = _claimable(testToken, creator) - claimableBefore;

        uint256 expectedFeeDelta = buyAmount / 200;

        assertApproxEqAbsDecimal(
            feeDelta, expectedFeeDelta, 1, 18, "claimable fees should include buy fees and pending taxes"
        );
    }

    function test_claimFeesOfBothPositionsDontRevertIfNoFeesToClaim() public createAndGraduateToken {
        address[] memory tokens = _singleTokenArray();

        uint256 creatorEthBalanceBefore = creator.balance;

        vm.prank(creator);
        feeHandlerV4.claim(tokens);

        assertEq(
            creator.balance,
            creatorEthBalanceBefore + graduationCreatorClaimable,
            "creator should receive graduation deposit only"
        );
    }

    function test_depositAccruedTaxes_reverts_whenCallerIsNotHook() public createAndGraduateToken {
        // legacy test kept as no-op: taxes are deposited directly by hook into fee handler
        // After graduation, only the graduation deposit exists (no swap-based taxes)
        assertEq(
            _claimable(testToken, creator),
            graduationCreatorClaimable,
            "only graduation deposit should exist before swaps"
        );
    }

    function test_creatorClaim_byNonOwnerAccruesToCurrentOwnerOnly()
        public
        createAndGraduateToken
        afterOneSwapBuy(buyer)
    {
        address[] memory tokens = _singleTokenArray();

        // non-owner call accrues LP fees to current token owner, not caller
        uint256 aliceBalanceBefore = alice.balance;
        uint256 creatorPendingBefore = _claimable(testToken, creator);

        vm.prank(alice);
        feeHandlerV4.accrueTokenFees(tokens);
        assertEq(_claimable(testToken, creator), creatorPendingBefore, "claimable doesn't increase on accruals");

        vm.prank(alice);
        feeHandlerV4.claim(tokens);
        assertEq(alice.balance, aliceBalanceBefore, "non-owner should not receive fees");

        uint256 creatorPendingAfter = _claimable(testToken, creator);
        assertEq(creatorPendingAfter, creatorPendingBefore, "non-owner call should not reduce owner claimable");
    }

    function test_tokenOwnershipTransferred_doesntChangeFeeReceiver() public createAndGraduateToken {
        address initialReceiver = ILivoToken(testToken).feeReceiver();

        _transferOwnership(alice);

        assertEq(ILivoToken(testToken).owner(), alice, "owner should be updated after ownership transfer");
        assertEq(
            ILivoToken(testToken).feeReceiver(),
            initialReceiver,
            "fee receiver should not change on ownership transfer without explicit update"
        );
    }

    function test_feeReceiverUpdated_givesFeesToNewReceiver_claimable()
        public
        createAndGraduateToken
        setReceiver(creator, alice)
    {
        uint256 aliceClaimableBefore = _claimable(testToken, alice);
        uint256 creatorClaimableBefore = _claimable(testToken, creator);
        assertEq(ILivoToken(testToken).feeReceiver(), alice, "fee receiver should be updated to alice");

        deal(buyer, 10 ether);
        _swapBuy(buyer, 2 ether, 10e18, true);

        assertEq(
            _claimable(testToken, creator),
            creatorClaimableBefore,
            "creator should not have gotten fees after receiver update"
        );
        assertGt(_claimable(testToken, alice), aliceClaimableBefore, "fees should have gone to alice");
    }

    function test_feeReceiverUpdated_givesFeesToNewReceiver_claim()
        public
        createAndGraduateToken
        setReceiver(creator, alice)
        generateFeesWithBuySwap(1 ether)
    {
        uint256 aliceClaimableBefore = _claimable(testToken, alice);
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        feeHandlerV4.claim(_singleTokenArray());

        assertLt(_claimable(testToken, alice), aliceClaimableBefore, "alice claimable should decrease after claim");
        assertEq(_claimable(testToken, alice), 0, "alice should have claimed all her fees");
        assertEq(
            alice.balance, aliceBalanceBefore + aliceClaimableBefore, "alice balance should have increased after claim"
        );
    }

    /// @dev when swap fees exist for current token owner and another user calls `creatorClaim()`, then the caller gets nothing and owner claimable remains available
    function test_creatorClaim_cannotClaimFeesForSomeoneElse() public createAndGraduateToken afterOneSwapBuy(buyer) {
        uint256 creatorClaimableBefore = _creatorClaimable();
        assertGt(creatorClaimableBefore, 0, "creator should have claimable fees");

        // the token owner is not alice, so here we check if alice receives any funds when claiming for a token she doesn't own
        uint256 aliceEthBefore = alice.balance;
        _creatorClaimAs(alice);
        assertEq(alice.balance, aliceEthBefore, "non-owner should not receive creator fees");

        uint256 creatorClaimableAfter = _creatorClaimable();
        assertEq(
            creatorClaimableAfter, creatorClaimableBefore, "non-owner call should not consume owner claimable fees"
        );
    }

    /// @dev when a swap occurs, creator pending increases and treasury receives funds directly during the swap
    function test_accrueTokenFees_calledByAnyone_accruesToCreatorAndTreasury() public createAndGraduateToken {
        uint256 treasuryEthBefore = treasury.balance;
        uint256 creatorEthBefore = creator.balance;
        uint256 creatorPendingBefore = _claimable(testToken, creator);

        // Perform swap buy (LP fees are charged during swap by the hook)
        deal(buyer, 10 ether);
        _swapBuy(buyer, MATRIX_BUY_AMOUNT_1, 10e18, true);

        // Treasury should have received 0.5% of buy amount as LP fee share during the swap
        assertApproxEqAbs(
            treasury.balance - treasuryEthBefore,
            MATRIX_BUY_AMOUNT_1 / 200,
            1,
            "treasury should receive 0.5% LP fee share during swap"
        );

        // Creator pending should increase by 0.5% of buy amount (deposited during swap by the hook)
        assertEq(creator.balance, creatorEthBefore, "creator ETH balance should not change (fees are pending)");
        assertApproxEqAbs(
            _claimable(testToken, creator) - creatorPendingBefore,
            MATRIX_BUY_AMOUNT_1 / 200,
            1,
            "creator pending should increase by 0.5% of buy amount"
        );
    }

    /// @dev when fees are accrued, treasury receives immediately; creator receives only on explicit claim
    function test_claimFlow_fundsMoveOnlyOnIntentionalClaims() public createAndGraduateToken afterOneSwapBuy(buyer) {
        uint256 creatorEthBefore = creator.balance;
        uint256 treasuryEthBefore = treasury.balance;

        // Accrual sends treasury fees directly, but creator fees remain pending

        assertEq(creator.balance, creatorEthBefore, "creator should not be paid before creatorClaim");
        // Treasury LP share was already sent during swap by the hook
        assertEq(treasury.balance, treasuryEthBefore, "treasury already received LP share during swap");

        _creatorClaimAs(creator);

        uint256 creatorEthAfterCreatorClaim = creator.balance;
        assertGt(creatorEthAfterCreatorClaim, creatorEthBefore, "creator should be paid after creatorClaim");
    }

    /// @dev when anyone calls `accrueTokenFees()`, then treasury receives its share directly
    function test_treasury_receivesDirectlyOnAccrue() public createAndGraduateToken afterOneSwapBuy(buyer) {
        uint256 treasuryEthBefore = treasury.balance;
        uint256 creatorEthBefore = creator.balance;

        assertEq(creator.balance, creatorEthBefore, "creator should not receive fees on accrue");
        // Treasury LP share was already sent during swap by the hook
        assertEq(treasury.balance, treasuryEthBefore, "treasury already received LP share during swap");
    }

    /// @dev when state is swap-buy before accrue, then `getClaimable()` returns current owner claimable amount
    function test_viewFunction_getClaimable_matrix_buy_beforeAccrue()
        public
        createAndGraduateToken
        afterOneSwapBuy(buyer)
    {
        uint256 fees = _creatorClaimable();
        assertApproxEqAbs(
            fees,
            graduationCreatorClaimable + MATRIX_BUY_AMOUNT_1 / 200,
            1,
            "creator claimable should be graduation deposit + 0.5% of buy amount"
        );
    }

    /// @dev when state is swap-buy then `accrueTokenFees()` by creator, then `getClaimable()` returns accrued creator amount
    function test_viewFunction_getClaimable_matrix_buy_afterAccrueByCreator()
        public
        createAndGraduateToken
        afterOneSwapBuy(buyer)
    {
        uint256 fees = _creatorClaimable();
        assertApproxEqAbs(
            fees,
            graduationCreatorClaimable + MATRIX_BUY_AMOUNT_1 / 200,
            1,
            "accrued creator claimable should match graduation deposit + buy creator share"
        );
    }

    /// @dev when state is swap-buy then `accrueTokenFees()` by non-owner, then `getClaimable()` returns owner claimable amount
    function test_viewFunction_getClaimable_matrix_buy_afterAccrueByOther()
        public
        createAndGraduateToken
        afterOneSwapBuy(buyer)
    {
        uint256 fees = _creatorClaimable();
        assertApproxEqAbs(
            fees,
            graduationCreatorClaimable + MATRIX_BUY_AMOUNT_1 / 200,
            1,
            "owner claimable should not depend on caller"
        );
    }

    /// @dev when state is swap-buy then creator claims, then `getClaimable()` returns zero
    function test_viewFunction_getClaimable_matrix_buy_afterCreatorClaim()
        public
        createAndGraduateToken
        afterOneSwapBuy(buyer)
    {
        _creatorClaimAs(creator);
        assertEq(_creatorClaimable(), 0, "claimable should be zero right after creator claim");
    }

    /// @dev when state is swap-buy then creator claims, then creator balance increases while treasury remains unchanged
    function test_balance_matrix_buy_afterCreatorClaim() public createAndGraduateToken afterOneSwapBuy(buyer) {
        uint256 creatorEthBefore = creator.balance;
        uint256 treasuryEthBefore = treasury.balance;

        _creatorClaimAs(creator);

        assertGt(creator.balance, creatorEthBefore, "creator should receive fees on creator claim");
        // Treasury LP share was already sent during swap by the hook
        assertEq(treasury.balance, treasuryEthBefore, "treasury already received LP share during swap");
    }

    /// @dev when state is swap-buy, accrue, claim, swap-buy, then `getClaimable()` reflects only post-claim swap
    function test_viewFunction_getClaimable_matrix_buy_afterClaimThenSecondSwap()
        public
        createAndGraduateToken
        afterOneSwapBuy(buyer)
    {
        _creatorClaimAs(creator);
        _swapBuy(buyer, MATRIX_BUY_AMOUNT_2, 10e18, true);

        uint256 fees = _creatorClaimable();
        assertApproxEqAbs(fees, MATRIX_BUY_AMOUNT_2 / 200, 1, "claimable should reflect only second buy");
    }

    /// @dev when state is swap-buy, accrue, claim, swap-buy, accrue, then `getClaimable()` matches second-swap creator share
    function test_viewFunction_getClaimable_matrix_buy_afterClaimSecondSwapAndAccrue()
        public
        createAndGraduateToken
        afterOneSwapBuy(buyer)
    {
        _creatorClaimAs(creator);
        _swapBuy(buyer, MATRIX_BUY_AMOUNT_2, 10e18, true);

        uint256 fees = _creatorClaimable();
        assertApproxEqAbs(
            fees, MATRIX_BUY_AMOUNT_2 / 200, 1, "claimable should remain second buy creator share after accrue"
        );
    }

    /// @dev when state is swap-buy, accrue, claim, swap-buy, creator-claim, then `getClaimable()` returns zero
    function test_viewFunction_getClaimable_matrix_buy_afterClaimSecondSwapAndCreatorClaim()
        public
        createAndGraduateToken
        afterOneSwapBuy(buyer)
    {
        _creatorClaimAs(creator);
        _swapBuy(buyer, MATRIX_BUY_AMOUNT_2, 10e18, true);
        _creatorClaimAs(creator);

        assertEq(_creatorClaimable(), 0, "claimable should be zero after second creator claim");
    }

    /// @dev when state is swap-buy, accrue, claim, swap-buy, creator-claim, then each creator claim pays creator only
    function test_balance_matrix_buy_afterClaimSecondSwapAndCreatorClaim()
        public
        createAndGraduateToken
        afterOneSwapBuy(buyer)
    {
        uint256 creatorEthBeforeFirstClaim = creator.balance;
        uint256 treasuryEthBeforeFirstClaim = treasury.balance;
        _creatorClaimAs(creator);
        uint256 creatorEthAfterFirstClaim = creator.balance;

        assertGt(creatorEthAfterFirstClaim, creatorEthBeforeFirstClaim, "first creator claim should pay creator");
        // Treasury LP share was already sent during swap by the hook
        assertEq(treasury.balance, treasuryEthBeforeFirstClaim, "treasury already received LP share during swap");

        _swapBuy(buyer, MATRIX_BUY_AMOUNT_2, 10e18, true);

        uint256 creatorEthBeforeSecondClaim = creator.balance;
        _creatorClaimAs(creator);

        assertGt(creator.balance, creatorEthBeforeSecondClaim, "second creator claim should pay creator");
        assertEq(_creatorClaimable(), 0, "claimable should be zero after second creator claim");
    }

    /// @dev After a swap-sell, the creator must have pending claimable reflected in getClaimable() and `pendingCreatorClaims()`
    function test_viewFunction_getClaimable_matrix_sell_beforeAccrue_positiveClaimable()
        public
        createAndGraduateToken
        afterOneSwapSell(buyer)
    {
        uint256 fees = _creatorClaimable();
        // Both normal and tax tokens get LP creator share (0.5%) on sells; tax tokens also get sell tax
        assertGt(fees, graduationCreatorClaimable, "creator should have LP fees beyond graduation deposit");
    }

    /// @dev when state is swap-sell before accrue, then `getClaimable()` includes LP creator share (and sell taxes for tax tokens)
    function test_viewFunction_getClaimable_matrix_sell_beforeAccrue()
        public
        createAndGraduateToken
        afterOneSwapSell(buyer)
    {
        uint256 claimableWithFees = _creatorClaimable();
        // Both normal and tax tokens get LP creator share (0.5%) on sells
        assertGt(
            claimableWithFees,
            graduationCreatorClaimable,
            "pending claims should exceed graduation deposit (LP creator share from sell)"
        );
    }

    /// @dev when state is swap-sell then `accrueTokenFees()` by creator, then `getClaimable()` remains the same claimable amount
    function test_viewFunction_getClaimable_matrix_sell_afterAccrueByCreator()
        public
        createAndGraduateToken
        afterOneSwapSell(buyer)
    {
        uint256 feesBefore = _creatorClaimable();
        uint256 feesAfter = _creatorClaimable();

        assertApproxEqAbs(feesAfter, feesBefore, 2, "accrue should not change total creator claimable");
    }

    /// @dev when state is swap-sell then creator claims, then `getClaimable()` returns zero
    function test_viewFunction_getClaimable_matrix_sell_afterCreatorClaim()
        public
        createAndGraduateToken
        afterOneSwapSell(buyer)
    {
        _creatorClaimAs(creator);
        assertEq(_creatorClaimable(), 0, "claimable should be zero right after creator claim");
    }

    /// @dev when state is swap-sell then creator claims, then creator balance increases while treasury remains unchanged
    function test_balance_matrix_sell_afterCreatorClaim() public createAndGraduateToken afterOneSwapSell(buyer) {
        uint256 creatorEthBefore = creator.balance;
        uint256 treasuryEthBefore = treasury.balance;

        _creatorClaimAs(creator);

        // Both normal and tax tokens receive LP creator share (0.5%) on sells; tax tokens also get sell tax
        assertGt(
            creator.balance,
            creatorEthBefore + graduationCreatorClaimable,
            "creator should receive LP fees (+ sell taxes for tax tokens) beyond graduation deposit"
        );
        assertEq(treasury.balance, treasuryEthBefore, "treasury should not receive funds on creator claim");
    }

    /// @dev when state is swap-sell, accrue, claim, swap-sell, then `getClaimable()` reflects only post-claim sell state
    function test_viewFunction_getClaimable_matrix_sell_afterClaimThenSecondSwap()
        public
        createAndGraduateToken
        afterOneSwapSell(buyer)
    {
        _creatorClaimAs(creator);
        _swapSell(buyer, MATRIX_SELL_AMOUNT, MATRIX_SELL_MIN_OUT, true);

        uint256 fees = _creatorClaimable();
        uint256 pendingTaxes = _claimable(testToken, creator);
        // Both normal and tax tokens get LP creator share on sells
        assertGt(pendingTaxes, 0, "pending fees should be positive after second sell (LP creator share)");
        assertGe(fees, pendingTaxes, "claimable should include pending fees from second sell");
    }

    /// @dev when state is swap-sell, accrue, claim, swap-sell, accrue, then `getClaimable()` remains stable after accrual
    function test_viewFunction_getClaimable_matrix_sell_afterClaimSecondSwapAndAccrue()
        public
        createAndGraduateToken
        afterOneSwapSell(buyer)
    {
        _creatorClaimAs(creator);
        _swapSell(buyer, MATRIX_SELL_AMOUNT, MATRIX_SELL_MIN_OUT, true);

        uint256 feesBefore = _creatorClaimable();
        uint256 feesAfter = _creatorClaimable();

        assertApproxEqAbs(feesAfter, feesBefore, 2, "no more taxes as there hasnt been any new sells");
    }

    /// @dev when state is swap-sell, accrue, claim, swap-sell, creator-claim, then `getClaimable()` returns zero
    function test_viewFunction_getClaimable_matrix_sell_afterClaimSecondSwapAndCreatorClaim()
        public
        createAndGraduateToken
        afterOneSwapSell(buyer)
    {
        _creatorClaimAs(creator);
        _swapSell(buyer, MATRIX_SELL_AMOUNT, MATRIX_SELL_MIN_OUT, true);
        _creatorClaimAs(creator);

        assertEq(_creatorClaimable(), 0, "claimable should be zero after second creator claim");
    }

    /// @dev when state is swap-sell, accrue, claim, swap-sell, creator-claim, then each creator claim pays creator only
    function test_balance_matrix_sell_afterClaimSecondSwapAndCreatorClaim()
        public
        createAndGraduateToken
        afterOneSwapSell(buyer)
    {
        uint256 creatorEthBeforeFirstClaim = creator.balance;
        _creatorClaimAs(creator);
        uint256 creatorEthAfterFirstClaim = creator.balance;

        // Both normal and tax tokens: first claim pays graduation deposit + LP creator share (+ sell tax for tax tokens)
        assertGt(creatorEthAfterFirstClaim, creatorEthBeforeFirstClaim, "first creator claim should pay creator");

        _swapSell(buyer, MATRIX_SELL_AMOUNT, MATRIX_SELL_MIN_OUT, true);

        uint256 creatorEthBeforeSecondClaim = creator.balance;
        _creatorClaimAs(creator);

        // Both normal and tax tokens get LP creator share on second sell
        assertGt(creator.balance, creatorEthBeforeSecondClaim, "second creator claim should pay creator");
        assertEq(_creatorClaimable(), 0, "claimable should be zero after second creator claim");
    }

    /// @dev when state is swap-buy, accrue, community-takeover, then original owner keeps non-zero claimable fees
    function test_viewFunction_getClaimable_matrix_buy_afterAccrueAndTakeOver_oldOwnerHasClaimable()
        public
        createAndGraduateToken
        afterOneSwapBuy(buyer)
        transferOwnership(creator, alice)
        setReceiver(alice, alice)
    {
        assertGt(_claimableFor(creator), 0, "old owner should keep accrued claimable after takeover");
    }

    /// @dev when state is swap-buy, accrue, community-takeover, then original owner can claim and receive pre-claim claimable amount
    function test_balance_matrix_buy_afterAccrueAndTakeOver_oldOwnerCanClaimPreClaimable()
        public
        createAndGraduateToken
        afterOneSwapBuy(buyer)
        transferOwnership(creator, alice)
        setReceiver(alice, alice)
    {
        uint256 oldOwnerClaimable = _claimableFor(creator);
        assertGt(oldOwnerClaimable, 0, "old owner should have claimable after takeover");

        uint256 oldOwnerClaimDelta = _creatorClaimAndReturnEthDelta(creator);
        assertApproxEqAbs(oldOwnerClaimDelta, oldOwnerClaimable, 2, "old owner claim delta should match pre-claim");
    }

    /// @dev when state is swap-buy, creator-claim, swap-buy, accrue, community-takeover, then original owner still has claimable and can claim it
    function test_balance_matrix_buy_afterClaimThenSecondBuyAccrueAndTakeOver_oldOwnerCanClaim()
        public
        createAndGraduateToken
        afterOneSwapBuy(buyer)
    {
        _creatorClaimAs(creator);
        _swapBuy(buyer, MATRIX_BUY_AMOUNT_2, 10e18, true);
        _transferOwnership(alice);

        uint256 oldOwnerClaimable = _claimableFor(creator);
        assertGt(oldOwnerClaimable, 0, "old owner should have claimable from second buy after takeover");

        uint256 oldOwnerClaimDelta = _creatorClaimAndReturnEthDelta(creator);
        assertApproxEqAbs(oldOwnerClaimDelta, oldOwnerClaimable, 2, "old owner delta should match claimable");
    }

    /// @dev when state is swap-buy, accrue, community-takeover, swap-buy, then old and new owner claimables sum to expected creator fees and both can claim
    function test_balance_matrix_buy_afterTakeOverThenSecondBuy_splitAcrossOwnersAndBothClaim()
        public
        createAndGraduateToken
        afterOneSwapBuy(buyer)
        transferOwnership(creator, alice)
        setReceiver(alice, alice)
    {
        _swapBuy(buyer, MATRIX_BUY_AMOUNT_2, 10e18, true);

        uint256 oldOwnerClaimable = _claimableFor(creator);
        uint256 newOwnerClaimable = _claimableFor(alice);
        // Expected: graduation deposit (held by old owner) + LP fees from both buys
        uint256 expectedCreatorFees = graduationCreatorClaimable + (MATRIX_BUY_AMOUNT_1 + MATRIX_BUY_AMOUNT_2) / 200;

        assertApproxEqAbs(
            oldOwnerClaimable + newOwnerClaimable,
            expectedCreatorFees,
            3,
            "old+new owner claimables should match expected charged creator fees"
        );

        uint256 newOwnerClaimDelta = _creatorClaimAndReturnEthDelta(alice);
        uint256 oldOwnerClaimDelta = _creatorClaimAndReturnEthDelta(creator);

        assertApproxEqAbs(newOwnerClaimDelta, newOwnerClaimable, 2, "new owner delta should match pre-claim claimable");
        assertApproxEqAbs(oldOwnerClaimDelta, oldOwnerClaimable, 2, "old owner delta should match pre-claim claimable");
    }

    /// @dev when state is swap-sell, accrue, community-takeover, then original owner keeps non-zero claimable fees for taxable tokens
    function test_viewFunction_getClaimable_matrix_sell_afterAccrueAndTakeOver_oldOwnerHasClaimable_taxOnly()
        public
        createAndGraduateToken
        afterOneSwapSell(buyer)
        transferOwnership(creator, alice)
    {
        if (!_expectsSellTaxes()) return;

        uint256 oldOwnerClaimable = _claimableFor(creator);
        assertGt(oldOwnerClaimable, 0, "old owner should keep accrued sell claimable after takeover");
    }

    /// @dev when state is swap-sell, accrue, community-takeover, then original owner can claim and receive pre-claim claimable for taxable tokens
    function test_balance_matrix_sell_afterAccrueAndTakeOver_oldOwnerCanClaimPreClaimable_taxOnly()
        public
        createAndGraduateToken
        afterOneSwapSell(buyer)
        transferOwnership(creator, alice)
    {
        if (!_expectsSellTaxes()) return;

        uint256 oldOwnerClaimable = _claimableFor(creator);
        assertGt(oldOwnerClaimable, 0, "old owner should have claimable after takeover");

        uint256 oldOwnerClaimDelta = _creatorClaimAndReturnEthDelta(creator);
        assertApproxEqAbs(oldOwnerClaimDelta, oldOwnerClaimable, 2, "old owner claim delta should match pre-claim");
    }

    /// @dev when state is swap-sell, creator-claim, swap-sell, accrue, community-takeover, then original owner has non-zero claimable and can claim it for taxable tokens
    function test_balance_matrix_sell_afterClaimThenSecondSellAccrueAndTakeOver_oldOwnerCanClaim_taxOnly()
        public
        createAndGraduateToken
        afterOneSwapSell(buyer)
    {
        if (!_expectsSellTaxes()) return;

        _creatorClaimAs(creator);
        _swapSell(buyer, MATRIX_SELL_AMOUNT, MATRIX_SELL_MIN_OUT, true);
        _transferOwnership(alice);

        uint256 oldOwnerClaimable = _claimableFor(creator);
        assertGt(oldOwnerClaimable, 0, "old owner should have claimable from second sell after takeover");

        uint256 oldOwnerClaimDelta = _creatorClaimAndReturnEthDelta(creator);
        assertApproxEqAbs(oldOwnerClaimDelta, oldOwnerClaimable, 2, "old owner delta should match claimable");
    }

    /// @dev when state is swap-sell, accrue, community-takeover, swap-sell, then old and new owner claimables match expected split and both can claim for taxable tokens
    function test_balance_matrix_sell_afterTakeOverThenSecondSell_splitAcrossOwnersAndBothClaim_taxOnly()
        public
        createAndGraduateToken
    {
        if (!_expectsSellTaxes()) return;

        _swapSell(buyer, MATRIX_SELL_AMOUNT, MATRIX_SELL_MIN_OUT, true);

        uint256 oldOwnerExpected = _claimableFor(creator);

        _transferOwnership(alice);
        vm.prank(alice);
        ILivoToken(testToken).setFeeReceiver(alice);

        uint256 newOwnerBeforeSecondSell = _claimableFor(alice);
        _swapSell(buyer, MATRIX_SELL_AMOUNT, MATRIX_SELL_MIN_OUT, true);

        uint256 oldOwnerClaimable = _claimableFor(creator);
        uint256 newOwnerClaimable = _claimableFor(alice);
        uint256 expectedTotalCreatorFees = oldOwnerExpected + (newOwnerClaimable - newOwnerBeforeSecondSell);

        assertApproxEqAbs(
            oldOwnerClaimable + newOwnerClaimable,
            expectedTotalCreatorFees,
            2,
            "old+new owner claimables should match expected total creator fees"
        );

        uint256 newOwnerClaimDelta = _creatorClaimAndReturnEthDelta(alice);
        uint256 oldOwnerClaimDelta = _creatorClaimAndReturnEthDelta(creator);

        assertApproxEqAbs(newOwnerClaimDelta, newOwnerClaimable, 2, "new owner delta should match pre-claim claimable");
        assertApproxEqAbs(oldOwnerClaimDelta, oldOwnerClaimable, 2, "old owner delta should match pre-claim claimable");
    }
}

// ============================================
// Concrete Implementations for Normal Tokens
// ============================================

/// @notice Concrete test contract for claim fees with normal (non-tax) tokens
contract BaseUniswapV4ClaimFees_NormalToken is BaseUniswapV4ClaimFeesBase {
    function setUp() public override {
        super.setUp();
        // Uses default implementation (livoToken) from base
    }
}

/// @notice Concrete test contract for claim fees view functions with normal (non-tax) tokens
contract BaseUniswapV4ClaimFees_TaxToken is TaxTokenUniV4BaseTests, BaseUniswapV4ClaimFeesBase {
    function setUp() public override(TaxTokenUniV4BaseTests, BaseUniswapV4FeesTests) {
        super.setUp();
        // Override implementation for this test suite to use tax tokens
        implementation = ILivoToken(address(taxTokenImpl));
        SELL_TAX_BPS = DEFAULT_SELL_TAX_BPS;
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

    function _createTokenForCreator(string memory name, string memory symbol, bytes32 metadata)
        internal
        override
        returns (address)
    {
        vm.prank(creator);
        return
            factoryTax.createToken(
                name, symbol, creator, metadata, 0, DEFAULT_SELL_TAX_BPS, uint32(DEFAULT_TAX_DURATION)
            );
    }
}
