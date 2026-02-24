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
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {DeploymentAddressesMainnet} from "src/config/DeploymentAddresses.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";

interface ILivoGraduatorWithFees is ILivoGraduator {
    function creatorClaim(address[] calldata tokens, uint256[] calldata positionIndexes) external;
    function accrueTokenFees(address[] calldata tokens, uint256[] calldata positionIndexes) external;
    function positionIds(address token, uint256 positionIndex) external view returns (uint256);
    function getClaimableFees(address[] calldata tokens, uint256[] calldata positionIndexes, address tokenOwner)
        external
        view
        returns (uint256[] memory creatorFees);
    function treasuryClaim() external;
}

contract BaseUniswapV4FeesTests is BaseUniswapV4GraduationTests {
    ILivoGraduatorWithFees graduatorWithFees;

    address testToken1;
    address testToken2;

    function setUp() public virtual override {
        super.setUp();

        graduatorWithFees = ILivoGraduatorWithFees(address(graduator));
        deal(buyer, 10 ether);
    }

    function _singleElementArray(uint256 value) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = value;
        return arr;
    }

    modifier createAndGraduateToken() virtual {
        vm.prank(creator);
        // this graduator is not defined here in the base, so it will be address(0) unless inherited by LaunchpadBaseTestsWithUniv2Graduator or V4
        testToken = launchpad.createToken(
            "TestToken", "TEST", address(implementation), address(bondingCurve), address(graduator), creator, "0x12", ""
        );

        _graduateToken();
        _;
    }

    modifier twoGraduatedTokensWithBuys(uint256 buyAmount) virtual {
        vm.startPrank(creator);
        testToken1 = launchpad.createToken(
            "TestToken1",
            "TEST1",
            address(implementation),
            address(bondingCurve),
            address(graduator),
            creator,
            "0x1a3a",
            ""
        );
        testToken2 = launchpad.createToken(
            "TestToken2",
            "TEST2",
            address(implementation),
            address(bondingCurve),
            address(graduator),
            creator,
            "0x1a3a",
            ""
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
        uint256[] memory positionIndexes = new uint256[](1);
        positionIndexes[0] = 0;
        vm.prank(creator);
        graduatorWithFees.creatorClaim(tokens, positionIndexes);
    }
}

/// @notice Abstract base class for Uniswap V4 claim fees tests
abstract contract BaseUniswapV4ClaimFeesBase is BaseUniswapV4FeesTests {
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
        graduatorWithFees.treasuryClaim();

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
        graduatorWithFees.treasuryClaim();

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

    /// @notice test that on sells, creator only receives accrued sell taxes
    function test_claimFees_onSells_noTokenFees() public createAndGraduateToken {
        _swapSell(buyer, 100000000e18, 0.1 ether, true);

        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 pendingTaxesBeforeClaim =
            LivoGraduatorUniswapV4(payable(address(graduatorWithFees))).pendingCreatorTaxes(testToken, creator);
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
        assertEq(
            creator.balance - creatorEthBalanceBefore,
            pendingTaxesBeforeClaim,
            "creator should receive only accrued sell taxes"
        );
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

        graduatorWithFees.treasuryClaim();

        assertEq(
            address(graduatorWithFees).balance,
            graduatorEthBalanceBefore,
            "externally sent ETH should remain and not be claimable by treasury"
        );
    }

    /// @notice test that a token creator can claim fees from mutliple tokens in one transaction
    function test_claimFees_multipleTokens() public twoGraduatedTokensWithBuys(1 ether) {
        // both should have accumulated fees
        address[] memory tokens = new address[](2);
        tokens[0] = testToken1;
        tokens[1] = testToken2;

        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 treasuryEthBalanceBefore = treasury.balance;

        _collectFees(tokens[0]);
        _collectFees(tokens[1]);
        graduatorWithFees.treasuryClaim();

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

        uint256[] memory positionIndexes = new uint256[](1);
        positionIndexes[0] = 0;

        vm.prank(creator);
        graduatorWithFees.creatorClaim(tokens, positionIndexes);
        graduatorWithFees.treasuryClaim();

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

        uint256[] memory positionIndexes = new uint256[](2);
        positionIndexes[0] = 0;
        positionIndexes[1] = 1;

        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 treasuryEthBalanceBefore = treasury.balance;

        _swap(buyer, testToken1, 1 ether, 12342, true, true);
        _swap(buyer, testToken2, 1 ether, 12342, true, true);

        vm.prank(creator);
        graduatorWithFees.creatorClaim(tokens, positionIndexes);

        _swap(buyer, testToken1, 2 ether, 12342, true, true);
        _swap(buyer, testToken2, 2 ether, 12342, true, true);

        vm.prank(creator);
        graduatorWithFees.creatorClaim(tokens, positionIndexes);
        graduatorWithFees.treasuryClaim();

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

    function test_treasuryClaim_emitsEvent_whenEthBalanceIsZero() public createAndGraduateToken {
        vm.expectEmit(true, true, false, true, address(graduatorWithFees));
        emit LivoGraduatorUniswapV4.TreasuryFeesClaimed(address(this), treasury, 0);

        graduatorWithFees.treasuryClaim();
    }

    function test_treasuryClaim_emitsEvent_withClaimedAmount() public createAndGraduateToken {
        deal(buyer, 10 ether);
        _swapBuy(buyer, 1 ether, 10e18, true);
        _collectFees(testToken);

        uint256 claimAmount = address(graduatorWithFees).balance;
        assertGt(claimAmount, 0, "graduator should hold treasury fees before claim");

        vm.expectEmit(true, true, false, true, address(graduatorWithFees));
        emit LivoGraduatorUniswapV4.TreasuryFeesClaimed(address(this), treasury, claimAmount);

        graduatorWithFees.treasuryClaim();

        assertEq(address(graduatorWithFees).balance, 0, "graduator should be empty after treasury claim");
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
        uint256[] memory positionIndexes = new uint256[](2);
        positionIndexes[0] = 0;
        positionIndexes[1] = 1;

        uint256 pendingTaxes =
            LivoGraduatorUniswapV4(payable(address(graduatorWithFees))).pendingCreatorTaxes(testToken, creator);
        uint256 creatorBalanceBefore = creator.balance;

        vm.prank(creator);
        graduatorWithFees.creatorClaim(tokens, positionIndexes);

        uint256 totalCreatorFees = creator.balance - creatorBalanceBefore;

        // Expected fees: 1% of buyAmount split 50/50 between creator and treasury
        // plus any pending creator taxes accrued from the prior sell
        uint256 expectedFees = buyAmount / 200 + pendingTaxes;
        assertApproxEqAbsDecimal(
            totalCreatorFees, expectedFees, 1, 18, "creator claim should include buy fees and pending taxes"
        );
    }

    function test_claimFeesInvalidPositionIndexesEmptyArray() public {
        address[] memory tokens = new address[](1);
        tokens[0] = testToken;
        uint256[] memory positionIndexes = new uint256[](0);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSignature("InvalidPositionIndexes()"));
        graduatorWithFees.creatorClaim(tokens, positionIndexes);
    }

    function test_claimFeesInvalidPositionIndexesTooMany() public {
        address[] memory tokens = new address[](1);
        tokens[0] = testToken;
        uint256[] memory positionIndexes = new uint256[](3);
        positionIndexes[0] = 0;
        positionIndexes[1] = 0;
        positionIndexes[2] = 0;

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSignature("InvalidPositionIndexes()"));
        graduatorWithFees.creatorClaim(tokens, positionIndexes);
    }

    function test_claimFeesInvalidPositionIndex_TooHigh() public createAndGraduateToken {
        address[] memory tokens = new address[](1);
        tokens[0] = testToken;
        uint256[] memory positionIndexes = new uint256[](2);
        positionIndexes[0] = 1;
        positionIndexes[0] = 2;

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSignature("InvalidPositionIndex()"));
        graduatorWithFees.creatorClaim(tokens, positionIndexes);
    }
}

/// @notice Abstract base class for Uniswap V4 claim fees view function tests
abstract contract UniswapV4ClaimFeesViewFunctionsBase is BaseUniswapV4FeesTests {
    uint256 internal constant MATRIX_BUY_AMOUNT_1 = 1 ether;
    uint256 internal constant MATRIX_BUY_AMOUNT_2 = 0.8 ether;
    uint256 internal constant MATRIX_SELL_AMOUNT = 100000000e18;
    uint256 internal constant MATRIX_SELL_MIN_OUT = 0.1 ether;

    function _expectsSellTaxes() internal pure virtual returns (bool);

    function _singleTokenClaimInputs()
        internal
        view
        returns (address[] memory tokens, uint256[] memory positionIndexes)
    {
        tokens = new address[](1);
        tokens[0] = testToken;
        positionIndexes = _singleElementArray(0);
    }

    function _creatorClaimable() internal view returns (uint256) {
        (address[] memory tokens, uint256[] memory positionIndexes) = _singleTokenClaimInputs();
        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, positionIndexes, creator);
        return fees[0];
    }

    function _claimableFor(address tokenOwner) internal view returns (uint256) {
        (address[] memory tokens, uint256[] memory positionIndexes) = _singleTokenClaimInputs();
        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, positionIndexes, tokenOwner);
        return fees[0];
    }

    function _accrueTokenFeesAs(address caller) internal {
        (address[] memory tokens, uint256[] memory positionIndexes) = _singleTokenClaimInputs();
        vm.prank(caller);
        graduatorWithFees.accrueTokenFees(tokens, positionIndexes);
    }

    function _creatorClaimAs(address caller) internal {
        (address[] memory tokens, uint256[] memory positionIndexes) = _singleTokenClaimInputs();
        vm.prank(caller);
        graduatorWithFees.creatorClaim(tokens, positionIndexes);
    }

    function _creatorClaimAndReturnEthDelta(address caller) internal returns (uint256) {
        uint256 balanceBefore = caller.balance;
        _creatorClaimAs(caller);
        return caller.balance - balanceBefore;
    }

    modifier afterOneSwapBuy() {
        deal(buyer, 10 ether);
        _swapBuy(buyer, MATRIX_BUY_AMOUNT_1, 10e18, true);
        _;
    }

    modifier afterOneSwapSell() {
        _swapSell(buyer, MATRIX_SELL_AMOUNT, MATRIX_SELL_MIN_OUT, true);
        _;
    }

    function test_viewFunction_positionId() public createAndGraduateToken {
        uint256 positionId = graduatorWithFees.positionIds(testToken, 0);

        assertEq(positionId, 62898, "wrong position id registered at graduation");
    }

    /// @notice test that right after graduation getClaimableFees gives 0
    function test_viewFunction_getClaimableFees_rightAfterGraduation() public createAndGraduateToken {
        address[] memory tokens = new address[](1);
        tokens[0] = testToken;

        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, _singleElementArray(0), creator);

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

        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, _singleElementArray(0), creator);

        assertEq(fees.length, 1, "should return one fee value");
        // Expected fees: 1% of buyAmount split 50/50 between creator and treasury
        // So creator gets 0.5% = buyAmount / 200
        uint256 expectedFees = buyAmount / 200;
        assertApproxEqAbs(fees[0], expectedFees, 1, "creator fees should be 0.5% of buy amount");
    }

    /// @notice test that after one swapSell, getClaimableFees includes accrued creator tax
    function test_viewFunction_getClaimableFees_afterOneSwapSell() public createAndGraduateToken {
        _swapSell(buyer, 100000000e18, 0.1 ether, true);

        address[] memory tokens = new address[](1);
        tokens[0] = testToken;

        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, _singleElementArray(0), creator);
        uint256 pendingTaxes =
            LivoGraduatorUniswapV4(payable(address(graduatorWithFees))).pendingCreatorTaxes(testToken, creator);

        assertEq(fees.length, 1, "should return one fee value");
        assertEq(fees[0], pendingTaxes, "claimable fees should match accrued creator taxes after sell");
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

        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, _singleElementArray(0), creator);

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

        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, _singleElementArray(0), creator);
        assertApproxEqAbs(fees[0], 1 ether / 200, 1, "creator fees should be 0.5% of buy amount");

        _collectFees(testToken);

        fees = graduatorWithFees.getClaimableFees(tokens, _singleElementArray(0), creator);

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

        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, _singleElementArray(0), creator);

        assertEq(fees.length, 1, "should return one fee value");
        assertApproxEqAbs(fees[0], buyAmount2 / 200, 1, "creator fees should be 0.5% of second buy amount");
    }

    /// @notice test that getClaimableFees works for multiple tokens
    function test_viewFunction_getClaimableFees_multipleTokens() public twoGraduatedTokensWithBuys(1 ether) {
        address[] memory tokens = new address[](2);
        tokens[0] = testToken1;
        tokens[1] = testToken2;

        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, _singleElementArray(0), creator);

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

        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, _singleElementArray(0), creator);

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
        // estimate from both positions in one call to avoid double-counting pending balances
        uint256[] memory positionIndexes = new uint256[](2);
        positionIndexes[0] = 0;
        positionIndexes[1] = 1;
        uint256[] memory fees = graduatorWithFees.getClaimableFees(tokens, positionIndexes, creator);
        uint256 totalFees = fees[0];
        uint256 pendingTaxes =
            LivoGraduatorUniswapV4(payable(address(graduatorWithFees))).pendingCreatorTaxes(testToken, creator);

        // Expected fees: 1% of buyAmount split 50/50 between creator and treasury
        // plus any pending creator taxes accrued from the prior sell
        uint256 expectedFees = buyAmount / 200 + pendingTaxes;
        assertApproxEqAbsDecimal(
            totalFees, expectedFees, 1, 18, "claimable fees should include buy fees and pending taxes"
        );
    }

    function test_claimFeesOfBothPsitionsDontRevertIfNoFeesToClaim() public createAndGraduateToken {
        // there shouldn't be any fees to claim yet
        address[] memory tokens = new address[](1);
        tokens[0] = testToken;
        uint256[] memory positionIndexes = new uint256[](2);
        positionIndexes[0] = 0;
        positionIndexes[1] = 1;

        uint256 creatorEthBalanceBefore = creator.balance;

        // should not revert even if there are no fees to claim
        vm.prank(creator);
        graduatorWithFees.creatorClaim(tokens, positionIndexes);

        assertEq(creator.balance, creatorEthBalanceBefore, "creator eth balance should not change");
    }

    function test_claimFees_arrayOfZeroTokens() public createAndGraduateToken {
        address[] memory tokens = new address[](0);
        uint256[] memory positionIndexes = new uint256[](0);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSignature("NoTokensToCollectFees()"));
        graduatorWithFees.creatorClaim(tokens, positionIndexes);
    }

    function test_depositAccruedTaxes_reverts_whenCallerIsNotHook() public createAndGraduateToken {
        vm.prank(alice);
        vm.expectRevert(LivoGraduatorUniswapV4.OnlyHookAllowed.selector);
        LivoGraduatorUniswapV4(payable(address(graduatorWithFees))).depositAccruedTaxes{value: 1}(testToken, creator);
    }

    function test_viewFunction_getClaimableFees_reverts_onEmptyPositionIndexes() public createAndGraduateToken {
        address[] memory tokens = new address[](1);
        tokens[0] = testToken;
        uint256[] memory positionIndexes = new uint256[](0);

        vm.expectRevert(abi.encodeWithSignature("InvalidPositionIndexes()"));
        graduatorWithFees.getClaimableFees(tokens, positionIndexes, creator);
    }

    function test_viewFunction_getClaimableFees_reverts_onTooManyPositionIndexes() public createAndGraduateToken {
        address[] memory tokens = new address[](1);
        tokens[0] = testToken;
        uint256[] memory positionIndexes = new uint256[](3);
        positionIndexes[0] = 0;
        positionIndexes[1] = 1;
        positionIndexes[2] = 0;

        vm.expectRevert(abi.encodeWithSignature("InvalidPositionIndexes()"));
        graduatorWithFees.getClaimableFees(tokens, positionIndexes, creator);
    }

    function test_creatorClaim_byNonOwnerAccruesToCurrentOwnerOnly() public createAndGraduateToken {
        deal(buyer, 10 ether);
        _swapBuy(buyer, 1 ether, 10e18, true);

        address[] memory tokens = new address[](1);
        tokens[0] = testToken;
        uint256[] memory positionIndexes = new uint256[](1);
        positionIndexes[0] = 0;

        // non-owner call accrues LP fees to current token owner, not caller
        uint256 aliceBalanceBefore = alice.balance;
        uint256 creatorPendingBefore =
            LivoGraduatorUniswapV4(payable(address(graduatorWithFees))).pendingCreatorFees(testToken, creator);
        vm.prank(alice);
        graduatorWithFees.creatorClaim(tokens, positionIndexes);
        assertEq(alice.balance, aliceBalanceBefore, "non-owner should not receive fees");
        uint256 creatorPendingAfter =
            LivoGraduatorUniswapV4(payable(address(graduatorWithFees))).pendingCreatorFees(testToken, creator);
        assertGt(creatorPendingAfter, creatorPendingBefore, "non-owner call should accrue fees to current owner");

        // creator should claim the fees that were accrued by alice's call
        vm.prank(creator);
        graduatorWithFees.creatorClaim(tokens, positionIndexes);
    }

    function test_tokenOwnershipTransferred_givesFeesToNewOwner() public createAndGraduateToken {
        deal(buyer, 10 ether);
        _swapBuy(buyer, 1 ether, 10e18, true);

        // some fees should have been accumulated by now. Let's transfer ownership via admin
        vm.prank(admin);
        launchpad.communityTakeOver(testToken, alice);

        uint256 creatorEthBalanceBefore = creator.balance;
        uint256 aliceEthBalanceBefore = alice.balance;

        address[] memory tokens = new address[](1);
        tokens[0] = testToken;
        uint256[] memory positionIndexes = new uint256[](1);
        positionIndexes[0] = 0;
        vm.prank(alice);
        graduatorWithFees.creatorClaim(tokens, positionIndexes);

        assertEq(creator.balance, creatorEthBalanceBefore, "creator should not have gotten fees");
        assertGt(alice.balance, aliceEthBalanceBefore, "fees should have gone to alice");
    }

    function test_tokenOwnershipTransferred_onlyNewOwnerCanClaimFees() public createAndGraduateToken {
        deal(buyer, 10 ether);
        _swapBuy(buyer, 1 ether, 10e18, true);

        // Transfer ownership to Alice via admin
        vm.prank(admin);
        launchpad.communityTakeOver(testToken, alice);

        address[] memory tokens = new address[](1);
        tokens[0] = testToken;
        uint256[] memory positionIndexes = new uint256[](1);
        positionIndexes[0] = 0;

        // old owner call should be a no-op for fresh LP fee collection
        uint256 creatorBalanceBefore = creator.balance;
        vm.prank(creator);
        graduatorWithFees.creatorClaim(tokens, positionIndexes);
        assertEq(creator.balance, creatorBalanceBefore, "old owner should not receive fresh fees");

        // Alice should be able to claim fees
        vm.prank(alice);
        graduatorWithFees.creatorClaim(tokens, positionIndexes);
    }

    /// @dev when swap fees exist for current token owner and another user calls `creatorClaim()`, then the caller gets nothing and owner claimable remains available
    function test_creatorClaim_cannotClaimFeesForSomeoneElse() public createAndGraduateToken afterOneSwapBuy {
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

    /// @dev when anyone calls `accrueTokenFees()`, then fees are accrued in storage and no destination balance is transferred
    function test_accrueTokenFees_calledByAnyone_onlyAccruesNoTransfers()
        public
        createAndGraduateToken
        afterOneSwapBuy
    {
        LivoGraduatorUniswapV4 graduatorv4 = LivoGraduatorUniswapV4(payable(address(graduatorWithFees)));

        uint256 creatorEthBefore = creator.balance;
        uint256 treasuryEthBefore = treasury.balance;
        uint256 aliceEthBefore = alice.balance;
        uint256 creatorPendingBefore = graduatorv4.pendingCreatorFees(testToken, creator);
        uint256 treasuryPendingBefore = graduatorv4.treasuryPendingFees();

        _accrueTokenFeesAs(alice);

        assertEq(creator.balance, creatorEthBefore, "creator balance should not change on accrue");
        assertEq(treasury.balance, treasuryEthBefore, "treasury balance should not change on accrue");
        assertEq(alice.balance, aliceEthBefore, "caller balance should not change on accrue");
        assertGt(
            graduatorv4.pendingCreatorFees(testToken, creator), creatorPendingBefore, "creator pending should increase"
        );
        assertGt(graduatorv4.treasuryPendingFees(), treasuryPendingBefore, "treasury pending should increase");
    }

    /// @dev when fees are accrued and no claim runs, then no destination receives funds; when claims run, then each destination receives only its own share
    function test_claimFlow_fundsMoveOnlyOnIntentionalClaims() public createAndGraduateToken afterOneSwapBuy {
        uint256 creatorEthBefore = creator.balance;
        uint256 treasuryEthBefore = treasury.balance;

        _accrueTokenFeesAs(alice);

        assertEq(creator.balance, creatorEthBefore, "creator should not be paid before creatorClaim");
        assertEq(treasury.balance, treasuryEthBefore, "treasury should not be paid before treasuryClaim");

        _creatorClaimAs(creator);

        uint256 creatorEthAfterCreatorClaim = creator.balance;
        assertGt(creatorEthAfterCreatorClaim, creatorEthBefore, "creator should be paid after creatorClaim");
        assertEq(treasury.balance, treasuryEthBefore, "treasury should still wait for treasuryClaim");

        graduatorWithFees.treasuryClaim();
        assertGt(treasury.balance, treasuryEthBefore, "treasury should be paid after treasuryClaim");
        assertEq(creator.balance, creatorEthAfterCreatorClaim, "creator should not receive more after treasuryClaim");
    }

    /// @dev when creator does not claim and any account calls `accrueTokenFees()`, then treasury can still claim its accrued share
    function test_treasury_canAccrueViaAnyoneAndClaimLater() public createAndGraduateToken afterOneSwapBuy {
        uint256 treasuryEthBefore = treasury.balance;
        uint256 creatorEthBefore = creator.balance;

        _accrueTokenFeesAs(alice);

        vm.prank(alice);
        graduatorWithFees.treasuryClaim();

        assertEq(creator.balance, creatorEthBefore, "creator should not receive more after treasuryClaim");
        assertGt(treasury.balance, treasuryEthBefore, "treasury should receive accrued share after treasuryClaim");
    }

    /// @dev when state is swap-buy before accrue, then `getClaimableFees()` returns current owner claimable amount
    function test_viewFunction_getClaimableFees_matrix_buy_beforeAccrue()
        public
        createAndGraduateToken
        afterOneSwapBuy
    {
        uint256 fees = _creatorClaimable();
        assertApproxEqAbs(fees, MATRIX_BUY_AMOUNT_1 / 200, 1, "creator claimable should be 0.5% of buy amount");
    }

    /// @dev when state is swap-buy then `accrueTokenFees()` by creator, then `getClaimableFees()` returns accrued creator amount
    function test_viewFunction_getClaimableFees_matrix_buy_afterAccrueByCreator()
        public
        createAndGraduateToken
        afterOneSwapBuy
    {
        _accrueTokenFeesAs(creator);
        uint256 fees = _creatorClaimable();
        assertApproxEqAbs(
            fees, MATRIX_BUY_AMOUNT_1 / 200, 1, "accrued creator claimable should match buy creator share"
        );
    }

    /// @dev when state is swap-buy then `accrueTokenFees()` by non-owner, then `getClaimableFees()` returns owner claimable amount
    function test_viewFunction_getClaimableFees_matrix_buy_afterAccrueByOther()
        public
        createAndGraduateToken
        afterOneSwapBuy
    {
        _accrueTokenFeesAs(alice);
        uint256 fees = _creatorClaimable();
        assertApproxEqAbs(fees, MATRIX_BUY_AMOUNT_1 / 200, 1, "owner claimable should not depend on caller");
    }

    /// @dev when state is swap-buy then creator claims, then `getClaimableFees()` returns zero
    function test_viewFunction_getClaimableFees_matrix_buy_afterCreatorClaim()
        public
        createAndGraduateToken
        afterOneSwapBuy
    {
        _creatorClaimAs(creator);
        assertEq(_creatorClaimable(), 0, "claimable should be zero right after creator claim");
    }

    /// @dev when state is swap-buy then creator claims, then creator balance increases while treasury remains unchanged
    function test_balance_matrix_buy_afterCreatorClaim() public createAndGraduateToken afterOneSwapBuy {
        uint256 creatorEthBefore = creator.balance;
        uint256 treasuryEthBefore = treasury.balance;

        _creatorClaimAs(creator);

        assertGt(creator.balance, creatorEthBefore, "creator should receive fees on creator claim");
        assertEq(treasury.balance, treasuryEthBefore, "treasury should not receive funds on creator claim");
    }

    /// @dev when state is swap-buy, accrue, claim, swap-buy, then `getClaimableFees()` reflects only post-claim swap
    function test_viewFunction_getClaimableFees_matrix_buy_afterClaimThenSecondSwap()
        public
        createAndGraduateToken
        afterOneSwapBuy
    {
        _accrueTokenFeesAs(creator);
        _creatorClaimAs(creator);
        _swapBuy(buyer, MATRIX_BUY_AMOUNT_2, 10e18, true);

        uint256 fees = _creatorClaimable();
        assertApproxEqAbs(fees, MATRIX_BUY_AMOUNT_2 / 200, 1, "claimable should reflect only second buy");
    }

    /// @dev when state is swap-buy, accrue, claim, swap-buy, accrue, then `getClaimableFees()` matches second-swap creator share
    function test_viewFunction_getClaimableFees_matrix_buy_afterClaimSecondSwapAndAccrue()
        public
        createAndGraduateToken
        afterOneSwapBuy
    {
        _accrueTokenFeesAs(creator);
        _creatorClaimAs(creator);
        _swapBuy(buyer, MATRIX_BUY_AMOUNT_2, 10e18, true);
        _accrueTokenFeesAs(alice);

        uint256 fees = _creatorClaimable();
        assertApproxEqAbs(
            fees, MATRIX_BUY_AMOUNT_2 / 200, 1, "claimable should remain second buy creator share after accrue"
        );
    }

    /// @dev when state is swap-buy, accrue, claim, swap-buy, creator-claim, then `getClaimableFees()` returns zero
    function test_viewFunction_getClaimableFees_matrix_buy_afterClaimSecondSwapAndCreatorClaim()
        public
        createAndGraduateToken
        afterOneSwapBuy
    {
        _accrueTokenFeesAs(creator);
        _creatorClaimAs(creator);
        _swapBuy(buyer, MATRIX_BUY_AMOUNT_2, 10e18, true);
        _creatorClaimAs(creator);

        assertEq(_creatorClaimable(), 0, "claimable should be zero after second creator claim");
    }

    /// @dev when state is swap-buy, accrue, claim, swap-buy, creator-claim, then each creator claim pays creator only
    function test_balance_matrix_buy_afterClaimSecondSwapAndCreatorClaim()
        public
        createAndGraduateToken
        afterOneSwapBuy
    {
        uint256 treasuryEthBefore = treasury.balance;

        _accrueTokenFeesAs(creator);

        uint256 creatorEthBeforeFirstClaim = creator.balance;
        _creatorClaimAs(creator);
        uint256 creatorEthAfterFirstClaim = creator.balance;

        assertGt(creatorEthAfterFirstClaim, creatorEthBeforeFirstClaim, "first creator claim should pay creator");
        assertEq(treasury.balance, treasuryEthBefore, "treasury should not be paid by creator claim");

        _swapBuy(buyer, MATRIX_BUY_AMOUNT_2, 10e18, true);

        uint256 creatorEthBeforeSecondClaim = creator.balance;
        _creatorClaimAs(creator);

        assertGt(creator.balance, creatorEthBeforeSecondClaim, "second creator claim should pay creator");
        assertEq(treasury.balance, treasuryEthBefore, "treasury should remain unchanged across creator claims");
        assertEq(_creatorClaimable(), 0, "claimable should be zero after second creator claim");
    }

    /// @dev After a swap-sell, the crator must have pending claimable reflected in getClaimableFees() and pendingCreatorTaxes()
    function test_viewFunction_getClaimableFees_matrix_sell_beforeAccrue_positiveClaimable()
        public
        createAndGraduateToken
        afterOneSwapSell
    {
        uint256 fees = _creatorClaimable();
        if (_expectsSellTaxes()) {
            assertGt(fees, 0, "creator should have some claimable fees from sell");
        } else {
            assertEq(fees, 0, "creator should have no claimable fees from sell");
        }
    }

    /// @dev when state is swap-sell before accrue, then `getClaimableFees()` includes at least pending creator taxes and no transfer happens during swap
    function test_viewFunction_getClaimableFees_matrix_sell_beforeAccrue()
        public
        createAndGraduateToken
        afterOneSwapSell
    {
        LivoGraduatorUniswapV4 graduatorv4 = LivoGraduatorUniswapV4(payable(address(graduatorWithFees)));
        uint256 fees = _creatorClaimable();
        uint256 pendingTaxes = graduatorv4.pendingCreatorTaxes(testToken, creator);
        if (_expectsSellTaxes()) {
            assertGt(pendingTaxes, 0, "pending creator taxes should be positive for tax tokens");
            assertGe(fees, pendingTaxes, "claimable should include pending creator taxes");
        } else {
            assertEq(pendingTaxes, 0, "pending creator taxes should be zero for normal tokens");
            assertEq(fees, 0, "claimable should be zero for normal tokens after sell");
        }
    }

    /// @dev when state is swap-sell then `accrueTokenFees()` by creator, then `getClaimableFees()` remains the same claimable amount
    function test_viewFunction_getClaimableFees_matrix_sell_afterAccrueByCreator()
        public
        createAndGraduateToken
        afterOneSwapSell
    {
        uint256 feesBefore = _creatorClaimable();
        _accrueTokenFeesAs(creator);
        uint256 feesAfter = _creatorClaimable();

        assertApproxEqAbs(feesAfter, feesBefore, 2, "accrue should not change total creator claimable");
    }

    /// @dev when state is swap-sell then creator claims, then `getClaimableFees()` returns zero
    function test_viewFunction_getClaimableFees_matrix_sell_afterCreatorClaim()
        public
        createAndGraduateToken
        afterOneSwapSell
    {
        _creatorClaimAs(creator);
        assertEq(_creatorClaimable(), 0, "claimable should be zero right after creator claim");
    }

    /// @dev when state is swap-sell then creator claims, then creator balance increases while treasury remains unchanged
    function test_balance_matrix_sell_afterCreatorClaim() public createAndGraduateToken afterOneSwapSell {
        uint256 creatorEthBefore = creator.balance;
        uint256 treasuryEthBefore = treasury.balance;

        _creatorClaimAs(creator);

        if (_expectsSellTaxes()) {
            assertGt(creator.balance, creatorEthBefore, "creator should receive accrued sell taxes on creator claim");
        } else {
            assertEq(creator.balance, creatorEthBefore, "creator should receive no sell taxes on creator claim");
        }
        assertEq(treasury.balance, treasuryEthBefore, "treasury should not receive funds on creator claim");
    }

    /// @dev when state is swap-sell, accrue, claim, swap-sell, then `getClaimableFees()` reflects only post-claim sell state
    function test_viewFunction_getClaimableFees_matrix_sell_afterClaimThenSecondSwap()
        public
        createAndGraduateToken
        afterOneSwapSell
    {
        _accrueTokenFeesAs(creator);
        _creatorClaimAs(creator);
        _swapSell(buyer, MATRIX_SELL_AMOUNT, MATRIX_SELL_MIN_OUT, true);

        LivoGraduatorUniswapV4 graduatorv4 = LivoGraduatorUniswapV4(payable(address(graduatorWithFees)));
        uint256 fees = _creatorClaimable();
        uint256 pendingTaxes = graduatorv4.pendingCreatorTaxes(testToken, creator);
        if (_expectsSellTaxes()) {
            assertGt(pendingTaxes, 0, "pending taxes should be positive after second sell");
            assertGe(fees, pendingTaxes, "claimable should include pending taxes from second sell");
        } else {
            assertEq(pendingTaxes, 0, "pending taxes should stay zero for normal tokens");
            assertEq(fees, 0, "claimable should stay zero for normal tokens");
        }
    }

    /// @dev when state is swap-sell, accrue, claim, swap-sell, accrue, then `getClaimableFees()` remains stable after accrual
    function test_viewFunction_getClaimableFees_matrix_sell_afterClaimSecondSwapAndAccrue()
        public
        createAndGraduateToken
        afterOneSwapSell
    {
        _accrueTokenFeesAs(creator);
        _creatorClaimAs(creator);
        _swapSell(buyer, MATRIX_SELL_AMOUNT, MATRIX_SELL_MIN_OUT, true);

        uint256 feesBefore = _creatorClaimable();
        _accrueTokenFeesAs(alice);
        uint256 feesAfter = _creatorClaimable();

        assertApproxEqAbs(feesAfter, feesBefore, 2, "no more taxes as there hasnt been any new sells");
    }

    /// @dev when state is swap-sell, accrue, claim, swap-sell, creator-claim, then `getClaimableFees()` returns zero
    function test_viewFunction_getClaimableFees_matrix_sell_afterClaimSecondSwapAndCreatorClaim()
        public
        createAndGraduateToken
        afterOneSwapSell
    {
        _accrueTokenFeesAs(creator);
        _creatorClaimAs(creator);
        _swapSell(buyer, MATRIX_SELL_AMOUNT, MATRIX_SELL_MIN_OUT, true);
        _creatorClaimAs(creator);

        assertEq(_creatorClaimable(), 0, "claimable should be zero after second creator claim");
    }

    /// @dev when state is swap-sell, accrue, claim, swap-sell, creator-claim, then each creator claim pays creator only
    function test_balance_matrix_sell_afterClaimSecondSwapAndCreatorClaim()
        public
        createAndGraduateToken
        afterOneSwapSell
    {
        uint256 treasuryEthBefore = treasury.balance;

        _accrueTokenFeesAs(creator);

        uint256 creatorEthBeforeFirstClaim = creator.balance;
        _creatorClaimAs(creator);
        uint256 creatorEthAfterFirstClaim = creator.balance;

        if (_expectsSellTaxes()) {
            assertGt(creatorEthAfterFirstClaim, creatorEthBeforeFirstClaim, "first creator claim should pay creator");
        } else {
            assertEq(creatorEthAfterFirstClaim, creatorEthBeforeFirstClaim, "first creator claim should not pay");
        }
        assertEq(treasury.balance, treasuryEthBefore, "treasury should not be paid by creator claim");

        _swapSell(buyer, MATRIX_SELL_AMOUNT, MATRIX_SELL_MIN_OUT, true);

        uint256 creatorEthBeforeSecondClaim = creator.balance;
        _creatorClaimAs(creator);

        if (_expectsSellTaxes()) {
            assertGt(creator.balance, creatorEthBeforeSecondClaim, "second creator claim should pay creator");
        } else {
            assertEq(creator.balance, creatorEthBeforeSecondClaim, "second creator claim should not pay");
        }
        assertEq(treasury.balance, treasuryEthBefore, "treasury should remain unchanged across creator claims");
        assertEq(_creatorClaimable(), 0, "claimable should be zero after second creator claim");
    }

    /// @dev when state is swap-buy, accrue, community-takeover, then original owner keeps non-zero claimable fees
    function test_viewFunction_getClaimableFees_matrix_buy_afterAccrueAndTakeOver_oldOwnerHasClaimable()
        public
        createAndGraduateToken
        afterOneSwapBuy
    {
        _accrueTokenFeesAs(alice);

        vm.prank(admin);
        launchpad.communityTakeOver(testToken, alice);

        uint256 oldOwnerClaimable = _claimableFor(creator);
        assertGt(oldOwnerClaimable, 0, "old owner should keep accrued claimable after takeover");
    }

    /// @dev when state is swap-buy, accrue, community-takeover, then original owner can claim and receive pre-claim claimable amount
    function test_balance_matrix_buy_afterAccrueAndTakeOver_oldOwnerCanClaimPreClaimable()
        public
        createAndGraduateToken
        afterOneSwapBuy
    {
        _accrueTokenFeesAs(alice);

        vm.prank(admin);
        launchpad.communityTakeOver(testToken, alice);

        uint256 oldOwnerClaimable = _claimableFor(creator);
        assertGt(oldOwnerClaimable, 0, "old owner should have claimable after takeover");

        uint256 oldOwnerClaimDelta = _creatorClaimAndReturnEthDelta(creator);
        assertApproxEqAbs(oldOwnerClaimDelta, oldOwnerClaimable, 2, "old owner claim delta should match pre-claim");
    }

    /// @dev when state is swap-buy, creator-claim, swap-buy, accrue, community-takeover, then original owner still has claimable and can claim it
    function test_balance_matrix_buy_afterClaimThenSecondBuyAccrueAndTakeOver_oldOwnerCanClaim()
        public
        createAndGraduateToken
        afterOneSwapBuy
    {
        _creatorClaimAs(creator);
        _swapBuy(buyer, MATRIX_BUY_AMOUNT_2, 10e18, true);
        _accrueTokenFeesAs(alice);

        vm.prank(admin);
        launchpad.communityTakeOver(testToken, alice);

        uint256 oldOwnerClaimable = _claimableFor(creator);
        assertGt(oldOwnerClaimable, 0, "old owner should have claimable from second buy after takeover");

        uint256 oldOwnerClaimDelta = _creatorClaimAndReturnEthDelta(creator);
        assertApproxEqAbs(oldOwnerClaimDelta, oldOwnerClaimable, 2, "old owner delta should match claimable");
    }

    /// @dev when state is swap-buy, accrue, community-takeover, swap-buy, then old and new owner claimables sum to expected creator fees and both can claim
    function test_balance_matrix_buy_afterTakeOverThenSecondBuy_splitAcrossOwnersAndBothClaim()
        public
        createAndGraduateToken
        afterOneSwapBuy
    {
        _accrueTokenFeesAs(alice);

        vm.prank(admin);
        launchpad.communityTakeOver(testToken, alice);

        _swapBuy(buyer, MATRIX_BUY_AMOUNT_2, 10e18, true);

        uint256 oldOwnerClaimable = _claimableFor(creator);
        uint256 newOwnerClaimable = _claimableFor(alice);
        uint256 expectedCreatorFees = (MATRIX_BUY_AMOUNT_1 + MATRIX_BUY_AMOUNT_2) / 200;

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
    function test_viewFunction_getClaimableFees_matrix_sell_afterAccrueAndTakeOver_oldOwnerHasClaimable_taxOnly()
        public
        createAndGraduateToken
        afterOneSwapSell
    {
        if (!_expectsSellTaxes()) return;

        _accrueTokenFeesAs(alice);

        vm.prank(admin);
        launchpad.communityTakeOver(testToken, alice);

        uint256 oldOwnerClaimable = _claimableFor(creator);
        assertGt(oldOwnerClaimable, 0, "old owner should keep accrued sell claimable after takeover");
    }

    /// @dev when state is swap-sell, accrue, community-takeover, then original owner can claim and receive pre-claim claimable for taxable tokens
    function test_balance_matrix_sell_afterAccrueAndTakeOver_oldOwnerCanClaimPreClaimable_taxOnly()
        public
        createAndGraduateToken
        afterOneSwapSell
    {
        if (!_expectsSellTaxes()) return;

        vm.prank(admin);
        launchpad.communityTakeOver(testToken, alice);

        uint256 oldOwnerClaimable = _claimableFor(creator);
        assertGt(oldOwnerClaimable, 0, "old owner should have claimable after takeover");

        uint256 oldOwnerClaimDelta = _creatorClaimAndReturnEthDelta(creator);
        assertApproxEqAbs(oldOwnerClaimDelta, oldOwnerClaimable, 2, "old owner claim delta should match pre-claim");
    }

    /// @dev when state is swap-sell, creator-claim, swap-sell, accrue, community-takeover, then original owner has non-zero claimable and can claim it for taxable tokens
    function test_balance_matrix_sell_afterClaimThenSecondSellAccrueAndTakeOver_oldOwnerCanClaim_taxOnly()
        public
        createAndGraduateToken
        afterOneSwapSell
    {
        if (!_expectsSellTaxes()) return;

        _creatorClaimAs(creator);
        _swapSell(buyer, MATRIX_SELL_AMOUNT, MATRIX_SELL_MIN_OUT, true);

        vm.prank(admin);
        launchpad.communityTakeOver(testToken, alice);

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

        vm.prank(admin);
        launchpad.communityTakeOver(testToken, alice);

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

    /// @notice Override createAndGraduateToken modifier to provide tokenCalldata for tax configuration
    modifier createAndGraduateToken() override {
        bytes memory tokenCalldata = taxTokenImpl.encodeTokenCalldata(DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);

        vm.prank(creator);
        testToken = launchpad.createToken(
            "TestToken",
            "TEST",
            address(implementation),
            address(bondingCurve),
            address(graduator),
            creator,
            "0x12",
            tokenCalldata
        );

        _graduateToken();
        _;
    }

    /// @notice Override twoGraduatedTokensWithBuys modifier for tax tokens
    modifier twoGraduatedTokensWithBuys(uint256 buyAmount) override {
        bytes memory tokenCalldata = taxTokenImpl.encodeTokenCalldata(DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);

        vm.startPrank(creator);
        testToken1 = launchpad.createToken(
            "TestToken1",
            "TEST1",
            address(implementation),
            address(bondingCurve),
            address(graduator),
            creator,
            "0x1a3a",
            tokenCalldata
        );
        testToken2 = launchpad.createToken(
            "TestToken2",
            "TEST2",
            address(implementation),
            address(bondingCurve),
            address(graduator),
            creator,
            "0x1a3a",
            tokenCalldata
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
}
